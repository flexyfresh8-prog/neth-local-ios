"""Shared helpers for the Neth Cloud contract tests: start a real llama-server and
talk to it exactly the way the iPad app does (Bearer auth, SSE streaming, grammar field).
"""

from __future__ import annotations

import json
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
API_KEY = "nl-test-key-123456789"
CONTEXT = 2048


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Server:
    """A llama-server process with the same flags the Colab launcher uses."""

    def __init__(self, binary: Path, model: Path, port: int | None = None, context: int = CONTEXT,
                 api_key: str = API_KEY, name="llama-server-test"):
        self.binary = binary
        self.model = model
        self.port = port or free_port()
        self.context = context
        self.api_key = api_key
        self.process: subprocess.Popen | None = None
        self.log_path = FIXTURES / f"{name}.log"

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def start(self, wait: bool = True, timeout: float = 300) -> "Server":
        command = [str(self.binary), "-m", str(self.model), "--host", "127.0.0.1", "--port", str(self.port),
                   "-ngl", "0", "-c", str(self.context), "--jinja", "--api-key", self.api_key,
                   "-b", "512", "-ub", "256", "-t", "2"]
        with self.log_path.open("w") as log:
            self.process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        if wait:
            self.wait_health(timeout)
        return self

    def wait_health(self, timeout: float = 300) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.process is not None and self.process.poll() is not None:
                tail = self.log_path.read_text(errors="replace").splitlines()[-30:]
                raise RuntimeError("llama-server exited during startup:\n  " + "\n  ".join(tail))
            try:
                status, _ = self.request("GET", "/health", auth=False, timeout=5)
                if status == 200:
                    return
            except Exception:  # noqa: BLE001 - not accepting connections yet
                time.sleep(0.5)
        raise RuntimeError(f"llama-server did not become healthy in {timeout}s; log: {self.log_path}")

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self.process = None

    def request(self, method: str, path: str, payload: dict | None = None, auth: bool = True,
                timeout: float = 600, key: str | None = None) -> tuple[int, bytes]:
        request = urllib.request.Request(self.base_url + path, method=method)
        if auth:
            request.add_header("Authorization", f"Bearer {key or self.api_key}")
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, data, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def chat(self, messages: list[dict], max_tokens: int = 64, stream: bool = False,
             auth: bool = True, key: str | None = None, **extra) -> tuple[int, bytes]:
        payload = {"messages": messages, "max_tokens": max_tokens, "stream": stream,
                   "stream_options": {"include_usage": True}, "cache_prompt": True, **extra}
        return self.request("POST", "/v1/chat/completions", payload, auth=auth, key=key)

    def stream_chunks(self, messages: list[dict], max_tokens: int = 64, **extra):
        """Yield parsed SSE JSON objects from a streaming chat completion."""
        status, body = self.chat(messages, max_tokens=max_tokens, stream=True, **extra)
        if status != 200:
            raise RuntimeError(f"stream request returned HTTP {status}: {body[:200]}")
        for line in body.decode(errors="replace").splitlines():
            line = line.strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                yield {"_done": True}
                return
            yield json.loads(payload)


def chat_payload(chunks) -> tuple[str, str | None, dict | None]:
    text: list[str] = []
    finish = None
    usage = None
    for chunk in chunks:
        if chunk.get("_done"):
            break
        usage = chunk.get("usage") or usage
        choices = chunk.get("choices") or []
        if not choices:
            continue
        delta = choices[0].get("delta", {})
        if delta.get("content"):
            text.append(delta["content"])
        if choices[0].get("finish_reason"):
            finish = choices[0]["finish_reason"]
    return "".join(text), finish, usage


# QuattroPlan.toolGrammar, replicated for the server contract test. Each id becomes the
# GBNF token "\"id\"" (a quoted string containing escaped quotes), matching the Swift
# source: "\"\\\"\($0)\\\"\"".
def tool_grammar(tool_ids: list[str]) -> str:
    choice = " | ".join('"\\\"%s\\\""' % tool_id for tool_id in ["answer"] + tool_ids)
    return (
        'root ::= ws "{" ws "\\"tool\\"" ws ":" ws choice ws "," ws "\\"arguments\\"" ws ":" ws object ws "}" ws\n'
        f"choice ::= {choice}\n"
        'object ::= "{" ws (pair (ws "," ws pair)*)? ws "}"\n'
        'pair ::= string ws ":" ws (string | number | "true" | "false")\n'
        'number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?\n'
        'ws ::= [ \\t\\r\\n]{0,4}\n'
        'string ::= "\\"" ([^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\\""'
    )


PROJECT_GRAMMAR = (
    'root ::= ws "{" ws "\\"name\\"" ws ":" ws string ws "," ws "\\"files\\"" ws ":" ws "[" ws file '
    '(ws "," ws file)* ws "]" ws "}" ws\n'
    'file ::= "{" ws "\\"path\\"" ws ":" ws string ws "," ws "\\"purpose\\"" ws ":" ws string ws "}"\n'
    'ws ::= [ \\t\\r\\n]{0,4}\n'
    'string ::= "\\"" ([^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\\""'
)


def overlapping_repeat(previous: str, added: str, minimum: int = 24) -> bool:
    tail = previous[-320:]
    head = added[:320]
    longest = min(len(tail), len(head))
    for count in range(longest, minimum - 1, -1):
        if tail.endswith(head[:count]):
            return True
    return False


def remove_overlap(previous: str, added: str, minimum: int = 24) -> str:
    """ReplyContinuation.removeOverlap: strip the model's echo of the assistant seed."""
    tail = previous[-320:]
    head = added[:320]
    longest = min(len(tail), len(head))
    for count in range(longest, minimum - 1, -1):
        if tail[-count:] == head[:count]:
            return added[count:]
    return added
