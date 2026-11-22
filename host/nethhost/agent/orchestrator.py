"""The NethHost agent orchestrator: a real tool-calling loop.

Cycle: plan -> select tools -> execute through the validated registry ->
inspect results -> update project -> run tests -> fix errors -> repeat, with
iteration caps, timeouts, cancellation and one emergency compaction retry on
context overflow. Tool calls arrive as OpenAI-compatible tool_calls streamed by
GPT-OSS on the Colab backend; malformed calls are fed back to the model for
repair instead of crashing the run.

Every event the loop produces is forwarded to the caller's emit callback so the
iPad shows tokens, tool activity and status live.
"""
from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass
from typing import Any, AsyncIterator, Callable

from ..config import Config
from ..context_manager import ContextManager
from ..database import Database
from ..tools import ToolContext, ToolRegistry, ToolResult, parse_tool_arguments
from .model_client import BackendError, ModelClient

MAX_ITERATIONS = 16
MAX_TOKENS_PER_STEP = 2048
MAX_TOKENS_FINAL = 4096

SYSTEM_PROMPT = """You are the NethHost coding agent working inside the project workspace
'{project}' on the user's Windows machine. You create and edit real files, run real
commands, start dev servers and test your work.

Rules:
- Think about what to do, then call tools; never only describe actions in text.
- Write complete files with write_file; make small edits with patch_file.
- After writing code, run it (run_command / run_python) or start the dev server, and fix errors.
- For a website, create index.html and start a static server so live preview works.
- Install dependencies only when the project needs them (needs approval).
- Finish with a short summary: what changed, what you ran, and what remains.
- Never invent tool results. If a tool fails, read the error and try a fix."""


@dataclass
class AgentEvent:
    type: str
    data: dict = None  # type: ignore[assignment]

    def as_dict(self) -> dict:
        return {"type": self.type, **(self.data or {})}


class Orchestrator:
    def __init__(self, registry: ToolRegistry, client: ModelClient,
                 context_manager: ContextManager, db: Database, config: Config) -> None:
        self.registry = registry
        self.client = client
        self.context_manager = context_manager
        self.db = db
        self.config = config

    async def run(self, conversation_id: str, project: str, task: str,
                  approved: bool = False,
                  cancelled: Callable[[], bool] | None = None,
                  emit: Callable[[dict], Any] | None = None) -> AsyncIterator[dict]:
        """Run one user request to completion, yielding event dicts."""
        emit = emit or (lambda event: None)

        layout = self.config.layout
        project_dir = layout.project(project)
        project_dir.mkdir(parents=True, exist_ok=True)

        self.db.create_conversation(conversation_id, task[:80], project)
        self.db.add_message(conversation_id, "user", task)

        tool_context = ToolContext(
            layout=layout, project=project, project_dir=project_dir,
            emit=lambda event: _fire(emit, event), approved=approved,
            workspace_root=layout.workspace)

        system = SYSTEM_PROMPT.format(project=project)
        build = await self.context_manager.build_prompt(conversation_id, system)
        messages: list[dict] = list(build.messages)
        if build.compacted:
            event = {"type": "context", "detail": "compacted older conversation"}
            await _fire(emit, event)
            yield event

        started = time.time()
        files_touched: list[str] = []
        commands_run: list[str] = []
        emergency_used = False

        for iteration in range(1, MAX_ITERATIONS + 1):
            if cancelled and cancelled():
                yield {"type": "done", "status": "cancelled", "iterations": iteration - 1}
                return
            event = {"type": "iteration", "number": iteration,
                     "context_usage": round(build.usage, 3)}
            await _fire(emit, event)
            yield event

            import asyncio as _asyncio

            token_events: list[dict] = []

            def on_token(kind: str, text: str) -> None:
                event = {"type": "token", "channel": kind, "text": text}
                token_events.append(event)
                _asyncio.ensure_future(_fire(emit, event))

            assistant_text = ""
            try:
                deltas = await _call(self.client, messages, self.registry.schemas(),
                                     on_token=on_token)
            except BackendError as error:
                if not emergency_used and await self.context_manager.emergency(
                        conversation_id, str(error)):
                    emergency_used = True
                    event = {"type": "context", "detail": "emergency compaction"}
                    await _fire(emit, event)
                    yield event
                    build = await self.context_manager.build_prompt(conversation_id, system)
                    messages = list(build.messages)
                    continue
                yield {"type": "error", "detail": str(error)}
                return

            for event in token_events:
                yield event

            tool_calls: list[dict] = []
            for delta in deltas:
                if delta.content:
                    assistant_text += delta.content
                for call in delta.tool_calls:
                    tool_calls.append(call)
            if deltas and deltas[-1].usage:
                pass  # usage numbers are informational

            if not tool_calls:
                self.db.add_message(conversation_id, "assistant", assistant_text)
                yield {"type": "done", "status": "complete", "iterations": iteration,
                       "seconds": round(time.time() - started, 1),
                       "files": files_touched, "commands": commands_run,
                       "answer": assistant_text}
                return

            message_with_calls = {"role": "assistant", "content": assistant_text or "",
                                  "tool_calls": [
                                      {"id": call.get("id", f"call_{i}"), "type": "function",
                                       "function": {"name": call["function"]["name"],
                                                    "arguments": call["function"]["arguments"]}}
                                      for i, call in enumerate(tool_calls)]}
            messages.append(message_with_calls)
            self.db.add_message(conversation_id, "assistant",
                                assistant_text + "\n[tool calls: " +
                                ", ".join(c["function"]["name"] for c in tool_calls) + "]")

            for call in tool_calls:
                if cancelled and cancelled():
                    yield {"type": "done", "status": "cancelled", "iterations": iteration}
                    return
                name = call.get("function", {}).get("name", "")
                raw_arguments = call.get("function", {}).get("arguments")
                call_id = call.get("id", f"call_{name}")
                event = {"type": "tool_start", "tool": name}
                await _fire(emit, event)
                yield event

                try:
                    arguments = parse_tool_arguments(raw_arguments)
                except Exception as error:
                    result = ToolResult(False, f"malformed tool arguments: {error}. "
                                        "Reply with valid JSON arguments for this tool.")
                    self.db.add_message(conversation_id, "tool", result.as_message(),
                                        tool_name=name, tool_call_id=call_id)
                    messages.append({"role": "tool", "tool_call_id": call_id,
                                     "name": name, "content": result.as_message()})
                    continue

                result = await self.registry.execute(name, arguments, tool_context)
                if name in ("write_file", "patch_file") and result.ok:
                    files_touched.append(str(arguments.get("path", "")))
                if name in ("run_command", "run_python", "start_dev_server") and result.ok:
                    commands_run.append(name)
                event = {"type": "tool_result", "tool": name, "ok": result.ok,
                         "output": result.output[:2000]}
                await _fire(emit, event)
                yield event
                self.db.add_message(conversation_id, "tool", result.as_message(),
                                    tool_name=name, tool_call_id=call_id)
                messages.append({"role": "tool", "tool_call_id": call_id,
                                 "name": name, "content": result.as_message()})
            # loop continues: the model sees the tool results and decides next steps

        yield {"type": "done", "status": "max_iterations", "iterations": MAX_ITERATIONS,
               "seconds": round(time.time() - started, 1)}


async def _fire(emit: Callable, event: dict) -> None:
    try:
        result = emit(event)
        if hasattr(result, "__await__"):
            await result
    except Exception:
        pass  # a broken UI stream must never break the agent run


async def _call(client: ModelClient, messages: list[dict], tools: list[dict],
                on_token=None):
    from .model_client import chat_with_retry
    limit = MAX_TOKENS_FINAL if len(messages) <= 3 else MAX_TOKENS_PER_STEP
    return await chat_with_retry(client, messages, tools, limit, on_token)


def new_conversation_id() -> str:
    return uuid.uuid4().hex[:16]
