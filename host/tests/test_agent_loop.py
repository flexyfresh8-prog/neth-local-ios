"""The agent tool-calling loop against a scripted backend."""
from __future__ import annotations

import json

import pytest

from nethhost.agent.model_client import StreamDelta
from nethhost.agent.orchestrator import Orchestrator


class FakeClient:
    """Scripted OpenAI-compatible backend: pops one response per call."""

    def __init__(self, script: list[list[StreamDelta]]) -> None:
        self.script = list(script)
        self.calls: list[dict] = []

    async def chat(self, messages, tools=None, max_tokens=2048, on_token=None, temperature=0.7):
        self.calls.append({"messages": [dict(m) for m in messages], "tools": tools or []})
        if not self.script:
            yield StreamDelta(content="no script left", finish="stop")
            return
        for delta in self.script.pop(0):
            if on_token:
                if delta.reasoning:
                    on_token("reasoning", delta.reasoning)
                if delta.content:
                    on_token("content", delta.content)
            yield delta


def tool_call(name: str, arguments: dict, call_id: str = "call_1") -> StreamDelta:
    return StreamDelta(tool_calls=[{
        "id": call_id, "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)}}])


def make_orchestrator(config, db, registry, client):
    from nethhost.context_manager import ContextManager

    class NoopSummarizer:
        async def summarize(self, text):
            return "digest"

    manager = ContextManager(db, NoopSummarizer(), model_limit=32768)
    return Orchestrator(registry, client, manager, db, config)


async def collect(orchestrator, conversation_id="conv1", project="demo", task="test"):
    events = []
    async for event in orchestrator.run(conversation_id, project, task):
        events.append(event)
    return events


async def test_write_then_finish(config, db, registry, tool_context):
    client = FakeClient([
        [tool_call("write_file", {"path": "index.html", "content": "<h1>Physics</h1>"})],
        [StreamDelta(content="Created index.html with the simulation page.", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = await collect(orchestrator)
    done = events[-1]
    assert done["type"] == "done" and done["status"] == "complete"
    assert "index.html" in done["files"]
    assert (tool_context.project_dir / "index.html").read_text().startswith("<h1>")


async def test_tool_result_fed_back(config, db, registry, tool_context):
    client = FakeClient([
        [tool_call("write_file", {"path": "a.txt", "content": "A"})],
        [tool_call("read_file", {"path": "a.txt"})],
        [StreamDelta(content="verified", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    await collect(orchestrator)
    # the read_file tool result must appear in the messages the model saw last
    final_messages = client.calls[-1]["messages"]
    tool_messages = [m for m in final_messages if m.get("role") == "tool"]
    assert any("A" in m["content"] for m in tool_messages)


async def test_malformed_arguments_get_one_repair_cycle(config, db, registry, tool_context):
    client = FakeClient([
        [StreamDelta(tool_calls=[{"id": "call_1", "type": "function",
                                  "function": {"name": "write_file",
                                               "arguments": "{not json"}}])],
        [tool_call("write_file", {"path": "fixed.txt", "content": "ok"})],
        [StreamDelta(content="recovered", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = await collect(orchestrator)
    assert events[-1]["status"] == "complete"
    assert (tool_context.project_dir / "fixed.txt").exists()
    # the malformed error reached the model as a tool message
    final_messages = client.calls[1]["messages"]
    assert any("malformed tool arguments" in m.get("content", "") for m in final_messages
               if m.get("role") == "tool")


async def test_unknown_tool_reports_availability(config, db, registry, tool_context):
    client = FakeClient([
        [tool_call("deploy_to_production", {})],
        [StreamDelta(content="understood", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = await collect(orchestrator)
    assert events[-1]["status"] == "complete"
    final_messages = client.calls[-1]["messages"]
    tool_outputs = [m["content"] for m in final_messages if m.get("role") == "tool"]
    assert any("unknown tool" in output and "Available tools" in output for output in tool_outputs)


async def test_approval_gate_blocks_gated_tools(config, db, registry, tool_context):
    client = FakeClient([
        [tool_call("install_dependencies", {})],
        [StreamDelta(content="cannot install without approval", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = []
    async for event in orchestrator.run("conv2", "demo", "install deps", approved=False):
        events.append(event)
    assert events[-1]["status"] == "complete"
    final_messages = client.calls[-1]["messages"]
    assert any("approval required" in m.get("content", "") for m in final_messages
               if m.get("role") == "tool")


async def test_max_iterations_stops(config, db, registry, tool_context, monkeypatch):
    from nethhost.agent import orchestrator as orchestrator_module
    monkeypatch.setattr(orchestrator_module, "MAX_ITERATIONS", 3)
    looping = []
    for i in range(10):
        looping.append([tool_call("create_directory", {"path": f"d{i}"}, call_id=f"c{i}")])
    client = FakeClient(looping)
    orchestrator = make_orchestrator(config, db, registry, client)
    events = await collect(orchestrator, conversation_id="conv3")
    assert events[-1]["status"] == "max_iterations"


async def test_cancellation(config, db, registry, tool_context):
    client = FakeClient([
        [tool_call("create_directory", {"path": "x"})],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = []
    async for event in orchestrator.run("conv4", "demo", "task", cancelled=lambda: True):
        events.append(event)
    assert events[-1]["status"] == "cancelled"


async def test_emergency_compaction_on_overflow(config, db, registry, tool_context):
    from nethhost.agent.model_client import BackendError

    class OverflowClient(FakeClient):
        async def chat(self, messages, tools=None, max_tokens=2048, on_token=None, temperature=0.7):
            self.calls.append({"messages": [dict(m) for m in messages]})
            if len(self.calls) == 1:
                raise BackendError("context overflow: requested tokens exceed n_ctx")
            yield StreamDelta(content="done after compaction", finish="stop")

    client = OverflowClient([])
    orchestrator = make_orchestrator(config, db, registry, client)
    db.create_conversation("conv5", "t", "demo")
    for i in range(30):  # push usage above the compaction threshold
        db.add_message("conv5", "user", "error: fill the context " + "x" * 4000)
    events = []
    async for event in orchestrator.run("conv5", "demo", "continue",
                                        cancelled=lambda: False):
        events.append(event)
    assert events[-1]["status"] == "complete"
    kinds = [row["kind"] for row in db.compression_events("conv5")]
    assert "emergency" in kinds


async def test_streamed_events_include_tokens_and_tool_activity(config, db, registry, tool_context):
    client = FakeClient([
        [StreamDelta(reasoning="thinking"), StreamDelta(content="writing file"),
         tool_call("write_file", {"path": "b.txt", "content": "B"})],
        [StreamDelta(content="done", finish="stop")],
    ])
    orchestrator = make_orchestrator(config, db, registry, client)
    events = await collect(orchestrator, conversation_id="conv6")
    types = [e["type"] for e in events]
    assert "token" in types
    assert "tool_start" in types and "tool_result" in types
    assert "iteration" in types
