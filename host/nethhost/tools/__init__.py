"""Validated tool registry for the NethHost agent.

Every tool the model may call lives here with a JSON schema, a danger class and
an implementation that receives a ToolContext bound to one project workspace.
The orchestrator executes tool calls ONLY through this registry: unknown tools,
malformed arguments and out-of-workspace paths are rejected as tool results the
model can read and recover from.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable

# Danger levels
SAFE = "safe"                 # inside workspace, no side effects beyond files
DESTRUCTIVE = "destructive"   # deletes files, installs packages, commits
ESCAPING = "escaping"         # leaves the workspace or touches credentials


class ToolError(Exception):
    pass


async def _noop(_event: dict) -> None:
    return None


@dataclass
class ToolContext:
    layout: Any                       # paths.Layout
    project: str                      # project name
    project_dir: Path
    emit: Callable[[dict], Awaitable[None]] = _noop
    approved: bool = False            # user approval for gated actions
    workspace_root: Path | None = None

    async def report(self, event: dict) -> None:
        result = self.emit(event)
        if hasattr(result, "__await__"):
            await result


@dataclass
class ToolResult:
    ok: bool
    output: str
    data: dict | None = None

    def as_message(self) -> str:
        if self.ok:
            return self.output
        return f"ERROR: {self.output}"


@dataclass
class ToolSpec:
    name: str
    description: str
    parameters: dict                  # JSON schema for the arguments object
    danger: str = SAFE
    needs_approval: bool = False      # must have ToolContext.approved

    def schema(self) -> dict:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }


ToolFunc = Callable[[ToolContext, dict], Awaitable[ToolResult]]


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, tuple[ToolSpec, ToolFunc]] = {}

    def register(self, spec: ToolSpec, func: ToolFunc) -> None:
        if spec.name in self._tools:
            raise ToolError(f"tool {spec.name} registered twice")
        self._tools[spec.name] = (spec, func)

    def spec(self, name: str) -> ToolSpec | None:
        entry = self._tools.get(name)
        return entry[0] if entry else None

    def names(self) -> list[str]:
        return sorted(self._tools)

    def schemas(self) -> list[dict]:
        return [spec.schema() for spec, _ in self._tools.values()]

    async def execute(self, name: str, arguments: dict, context: ToolContext) -> ToolResult:
        entry = self._tools.get(name)
        if not entry:
            known = ", ".join(self.names())
            return ToolResult(False, f"unknown tool '{name}'. Available tools: {known}")
        spec, func = entry
        if spec.needs_approval and not context.approved:
            return ToolResult(False, "approval required: this tool "
                              f"({name}, {spec.danger}) needs explicit user approval. "
                              "Ask the user to re-run with approval enabled.")
        try:
            arguments = _validate_arguments(spec, arguments)
        except ToolError as error:
            return ToolResult(False, f"invalid arguments for {name}: {error}")
        try:
            return await func(context, arguments)
        except ToolError as error:
            return ToolResult(False, str(error))
        except Exception as error:  # surface as structured tool output, never a crash
            return ToolResult(False, f"{type(error).__name__}: {error}")


def _validate_arguments(spec: ToolSpec, arguments: Any) -> dict:
    if not isinstance(arguments, dict):
        raise ToolError("arguments must be a JSON object")
    required = spec.parameters.get("required", [])
    for key in required:
        if key not in arguments:
            raise ToolError(f"missing required argument '{key}'")
    properties = spec.parameters.get("properties", {})
    extra = set(arguments) - set(properties)
    if extra:
        raise ToolError(f"unexpected argument(s): {sorted(extra)}")
    for key, value in arguments.items():
        schema = properties.get(key, {})
        expected = schema.get("type")
        if expected == "string" and not isinstance(value, str):
            raise ToolError(f"argument '{key}' must be a string")
        if expected == "integer" and not isinstance(value, int):
            raise ToolError(f"argument '{key}' must be an integer")
        if expected == "boolean" and not isinstance(value, bool):
            raise ToolError(f"argument '{key}' must be a boolean")
        if expected == "array" and not isinstance(value, list):
            raise ToolError(f"argument '{key}' must be an array")
    return arguments


def parse_tool_arguments(raw: Any) -> dict:
    """Parse the arguments string the backend streams with a tool call.
    Handles malformed JSON the way the agent loop expects: empty string -> {},
    invalid JSON -> ToolError the orchestrator feeds back to the model."""
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as error:
        raise ToolError(f"tool arguments are not valid JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise ToolError("tool arguments must decode to a JSON object")
    return parsed


def build_registry() -> ToolRegistry:
    """Assemble the full v2.0.0 toolset."""
    from . import browser, filesystem, git_tools, terminal

    registry = ToolRegistry()
    filesystem.register(registry)
    terminal.register(registry)
    git_tools.register(registry)
    browser.register(registry)
    return registry
