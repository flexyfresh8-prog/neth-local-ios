"""Contract tests for the Neth Cloud backend: a real llama-server (b12631) queried the
way Neth Local queries it. These run on CPU with a small fixture model; what they verify
is the server contract, not model quality.

Requirement 11.11 (local iPad inference regression) is covered by the macOS check job
(scripts/check-chat.swift) and the device build; it cannot execute in this environment.
"""

from __future__ import annotations

import ast
import http.client
import json
import time
from pathlib import Path

import pytest

from cloud_contract import (API_KEY, CONTEXT, FIXTURES, PROJECT_GRAMMAR, Server,
                            chat_payload, free_port, remove_overlap, tool_grammar)


@pytest.fixture(scope="session")
def server():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    instance = Server(Path(manifest["server"]), Path(manifest["model"]), port=free_port())
    instance.start()
    yield instance
    instance.stop()


# 11.1 server startup
def test_server_startup_reports_health(server):
    status, body = server.request("GET", "/health", auth=False)
    assert status == 200
    assert json.loads(body) == {"status": "ok"}
    assert server.process.poll() is None


# 11.2 model loading
def test_loaded_model_is_served(server):
    status, body = server.request("GET", "/v1/models")
    assert status == 200
    models = json.loads(body)["data"]
    assert len(models) == 1 and models[0]["id"]
    status, body = server.request("GET", "/props")
    assert status == 200
    props = json.loads(body)
    assert props["default_generation_settings"]["n_ctx"] == CONTEXT
    status, body = server.chat([{"role": "user", "content": "Say OK."}], max_tokens=8)
    assert status == 200
    reply = json.loads(body)
    assert reply["choices"][0]["message"]["content"].strip() != ""


# 11.6 authentication failures
def test_authentication_failures(server):
    status, _ = server.request("GET", "/v1/models", auth=False)
    assert status == 401
    status, _ = server.request("GET", "/v1/models", key="nl-wrong-key")
    assert status == 401
    status, _ = server.chat([{"role": "user", "content": "hi"}], max_tokens=4, key="nl-wrong-key")
    assert status == 401


# 11.3 streaming generation
def test_streaming_generation_emits_tokens_and_usage(server):
    chunks = list(server.stream_chunks([{"role": "user", "content": "Count from one to five."}],
                                       max_tokens=48))
    text, finish, usage = chat_payload(chunks)
    assert text.strip() != ""
    assert finish in ("stop", "length")
    assert usage and usage.get("completion_tokens", 0) > 0
    assert chunks[-1].get("_done") is True


# 11.4 chat history (multi-turn, all message roles)
def test_multi_turn_history(server):
    value = "banana-yellow-42"
    status, body = server.chat(
        [{"role": "system", "content": "Store values exactly and answer briefly."},
         {"role": "user", "content": f"Store this value: {value}. Reply OK."}], max_tokens=8)
    assert status == 200
    status, body = server.chat(
        [{"role": "system", "content": "Store values exactly and answer briefly."},
         {"role": "user", "content": f"Store this value: {value}. Reply OK."},
         {"role": "assistant", "content": "OK"},
         {"role": "user", "content": "What is the stored value? Reply with just the value."}],
        max_tokens=24)
    assert status == 200
    reply = json.loads(body)["choices"][0]["message"]["content"]
    assert "banana" in reply.lower()


# 11.5 cancellation: drop the connection mid-stream; the server must cancel and survive
def test_client_disconnect_cancels_but_server_survives(server):
    connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=60)
    payload = json.dumps({"messages": [{"role": "user", "content": "Write a long story."}],
                          "max_tokens": 400, "stream": True,
                          "stream_options": {"include_usage": True}}).encode()
    connection.request("POST", "/v1/chat/completions", body=payload,
                       headers={"Authorization": f"Bearer {server.api_key}",
                                "Content-Type": "application/json"})
    response = connection.getresponse()
    assert response.status == 200
    received = 0
    for _ in range(3):
        line = response.fp.readline()
        received += len(line)
    assert received > 0
    connection.close()  # abrupt cancel, exactly like an iPad leaving mid-reply
    time.sleep(1.0)
    status, body = server.request("GET", "/health", auth=False)
    assert status == 200
    status, body = server.chat([{"role": "user", "content": "Say OK."}], max_tokens=8)
    assert status == 200


# 11.7 tool-call parsing through the Quattro grammar (structured, never free text)
def test_quattro_tool_grammar_constrained_call(server):
    tools = ["math.calculate", "convert.length.meter.to.kilometer", "answer"]
    grammar = tool_grammar(tools)
    prompt = ("Pick one tool needed for the request. Put its real arguments in the JSON object. "
              "Use tool \"answer\" with {} if the results are sufficient or no tool fits.\n"
              f"{tools[0]} <radius> — computes a circle area\n"
              f"{tools[1]} <value> — converts metres to kilometres\n"
              "\nUser request: Convert 2500 metres to kilometres\nPrior tool results: (none)")
    status, body = server.chat([{"role": "user", "content": prompt}], max_tokens=80, grammar=grammar)
    assert status == 200, body[:200]
    output = json.loads(body)["choices"][0]["message"]["content"]
    call = json.loads(output)
    assert call["tool"] in tools
    assert isinstance(call["arguments"], dict)


# 11.8 Quattro file creation: project manifest under the project grammar
def test_quattro_project_manifest_grammar(server):
    prompt = ("Plan the files for this task. Give a short project name and up to 4 compatible text, "
              "code or PDF files. Use short relative paths and one-sentence purposes. "
              "Avoid binary dependencies. Use HTML, CSS and JavaScript with matching relative references as needed.\n"
              "\nBuild a small browser page that shows a digital clock.")
    status, body = server.chat([{"role": "user", "content": prompt}], max_tokens=200,
                               grammar=PROJECT_GRAMMAR)
    assert status == 200, body[:200]
    manifest = json.loads(json.loads(body)["choices"][0]["message"]["content"])
    assert isinstance(manifest.get("name"), str) and manifest["name"]
    assert manifest["files"] and all(set(f) >= {"path", "purpose"} for f in manifest["files"])


# 11.9 Quattro code editing: continuation from a partial file. The server may echo the
# assistant seed; the app strips that with ReplyContinuation.removeOverlap, so the
# contract is: after dedupe the addition is real new content that completes the file.
def test_quattro_continuation_without_overlap(server):
    partial = "def total(numbers):\n    s = 0\n"
    status, body = server.chat(
        [{"role": "user", "content": "Write a Python function total(numbers) that returns the sum of a list of numbers. Return only the code."},
         {"role": "assistant", "content": partial}], max_tokens=64)
    assert status == 200, body[:200]
    addition = json.loads(body)["choices"][0]["message"]["content"]
    assert addition.strip() != ""
    cleaned = remove_overlap(partial, addition)
    assert cleaned.strip() != "", "the model only echoed the seed text"
    merged = partial + cleaned
    assert "return" in merged
    ast.parse(merged)


# 11.10 + 11.12 reconnection and reconfiguration: restart the same server, then a new one
def test_reconnection_after_restarts():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    binary, model = Path(manifest["server"]), Path(manifest["model"])
    instance = Server(binary, model, port=free_port(), name="reconnect-test")
    instance.start()
    try:
        assert instance.request("GET", "/health", auth=False)[0] == 200
        instance.stop()
        instance.start()  # same process object reconnects cleanly
        assert instance.request("GET", "/health", auth=False)[0] == 200
    finally:
        instance.stop()
    smaller = Server(binary, model, port=free_port(), context=1024, name="reconfig-test")
    smaller.start()
    try:
        status, body = smaller.request("GET", "/props")
        assert status == 200
        assert json.loads(body)["default_generation_settings"]["n_ctx"] == 1024
    finally:
        smaller.stop()


# 11.13 NethCode Mini benchmark smoke run (full benchmark: tests/nethcode_mini_benchmark.py)
def test_nethcode_mini_benchmark_smoke(server):
    import nethcode_mini_benchmark as benchmark
    report = benchmark.run_benchmark(server, runs=1, max_tokens=260)
    assert report["runs"] == 1
    assert report["syntax_checks"] and set(report["syntax_checks"][0]) >= {"valid", "detail"}
    assert "tokens_per_second" in report and "first_token_seconds" in report
    assert report["generated_bytes"] > 0


# NethCode Mini source syntax gate used by the benchmark
def parse_generated_python(source: str) -> tuple[bool, str]:
    fenced = None
    if "```" in source:
        blocks = source.split("```")
        for index in range(1, len(blocks), 2):
            block = blocks[index]
            if block.startswith("python"):
                block = block[len("python"):]
            fenced = block.strip("\n")
            break
    candidate = fenced if fenced is not None else source
    try:
        ast.parse(candidate)
        return True, "parsed"
    except SyntaxError as error:
        return False, f"line {error.lineno}: {error.msg}"
