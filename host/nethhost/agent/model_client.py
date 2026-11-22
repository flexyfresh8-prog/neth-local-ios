"""OpenAI-compatible client for the Neth Cloud backend (llama.cpp server).

Handles the streaming SSE protocol llama.cpp speaks, including the reasoning
channel and native tool-call deltas, plus health checks, capability detection
and exponential backoff. The backend is the user's Colab notebook or any GPU
host — the URL and key live only in local config.
"""
from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import AsyncIterator, Callable

import httpx


class BackendError(Exception):
    pass


@dataclass
class BackendStatus:
    connected: bool
    detail: str
    model: str | None = None
    context: int | None = None
    tools_capable: bool | None = None
    latency: float | None = None


@dataclass
class StreamDelta:
    content: str | None = None
    reasoning: str | None = None
    tool_calls: list[dict] = field(default_factory=list)
    finish: str | None = None
    usage: dict | None = None


class ModelClient:
    def __init__(self, url: str, api_key: str, model: str = "gpt-oss-20b",
                 timeout: float = 180.0) -> None:
        self.url = url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.timeout = timeout
        self.context: int | None = None

    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json"}

    async def health(self) -> BackendStatus:
        started = time.time()
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                response = await client.get(f"{self.url}/v1/models", headers=self._headers())
        except httpx.HTTPError as error:
            return BackendStatus(False, f"cannot reach backend: {type(error).__name__}")
        if response.status_code in (401, 403):
            return BackendStatus(False, "backend rejected the API key")
        if response.status_code != 200:
            return BackendStatus(False, f"backend returned HTTP {response.status_code}")
        models: list[str] = []
        try:
            models = [entry.get("id", "") for entry in response.json().get("data", [])]
        except (json.JSONDecodeError, ValueError):
            pass
        latency = time.time() - started
        context, tools = await self._props()
        if context:
            self.context = context
        return BackendStatus(True, "connected", models[0] if models else self.model,
                             context=context, tools_capable=tools, latency=latency)

    async def _props(self) -> tuple[int | None, bool | None]:
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.get(f"{self.url}/props", headers=self._headers())
            if response.status_code != 200:
                return None, None
            data = response.json()
            context = data.get("default_generation_settings", {}).get("n_ctx")
            template = data.get("chat_template", "") or ""
            return context, True if template else None
        except (httpx.HTTPError, ValueError, KeyError):
            return None, None

    async def chat(self, messages: list[dict], tools: list[dict] | None = None,
                   max_tokens: int = 2048, on_token: Callable[[str, str], None] | None = None,
                   temperature: float = 0.7) -> AsyncIterator[StreamDelta]:
        """Stream a completion. Yields deltas; the caller aggregates tool calls."""
        body: dict = {
            "messages": messages,
            "stream": True,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream_options": {"include_usage": True},
        }
        if self.model:
            body["model"] = self.model
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            async with client.stream("POST", f"{self.url}/v1/chat/completions",
                                     headers=self._headers(), json=body) as response:
                if response.status_code != 200:
                    detail = (await response.aread()).decode(errors="replace")[:400]
                    raise BackendError(f"HTTP {response.status_code}: {detail}")
                tool_buffers: dict[int, dict] = {}
                async for line in response.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:]
                    if payload.strip() == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload)
                    except json.JSONDecodeError:
                        continue  # tolerate keepalives / partial lines
                    if chunk.get("error"):
                        raise BackendError(str(chunk["error"].get("message", chunk["error"]))[:300])
                    if chunk.get("usage"):
                        yield StreamDelta(usage=chunk["usage"])
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}
                    if delta.get("content"):
                        if on_token:
                            on_token("content", delta["content"])
                        yield StreamDelta(content=delta["content"])
                    if delta.get("reasoning_content"):
                        if on_token:
                            on_token("reasoning", delta["reasoning_content"])
                        yield StreamDelta(reasoning=delta["reasoning_content"])
                    for call in delta.get("tool_calls") or []:
                        index = call.get("index", 0)
                        buffer = tool_buffers.setdefault(
                            index, {"id": call.get("id", f"call_{index}"),
                                    "name": "", "arguments": ""})
                        function = call.get("function") or {}
                        if function.get("name"):
                            buffer["name"] += function["name"]
                        if function.get("arguments"):
                            buffer["arguments"] += function["arguments"]
                    if choices[0].get("finish_reason"):
                        yield StreamDelta(finish=choices[0]["finish_reason"])
                for index in sorted(tool_buffers):
                    buffer = tool_buffers[index]
                    yield StreamDelta(tool_calls=[{
                        "id": buffer["id"], "type": "function",
                        "function": {"name": buffer["name"], "arguments": buffer["arguments"]}}])


async def chat_with_retry(client: ModelClient, messages: list[dict], tools: list[dict] | None,
                          max_tokens: int, on_token=None, attempts: int = 3):
    """Exponential backoff for transient failures (1.2^attempt seconds).
    Context overflows are NOT transient: they propagate immediately so the
    orchestrator's emergency compaction can react."""
    from ..context_manager import looks_like_overflow
    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            return [delta async for delta in client.chat(messages, tools, max_tokens, on_token)]
        except BackendError as error:
            if looks_like_overflow(str(error)):
                raise
            last_error = error
            if attempt + 1 >= attempts:
                raise
            await asyncio.sleep(1.2 ** attempt)
    raise last_error or BackendError("backend call failed")
