"""Terminal and process tools: run_command, run_python, install_dependencies,
start_dev_server, stop_dev_server.

Commands run inside the project directory with a scrubbed environment. Output
streams through the tool context so the iPad sees live terminal output over the
WebSocket. Dev servers are tracked in a process registry keyed by project so
start/stop stay symmetric and no orphaned servers survive a session.
"""
from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from . import (DESTRUCTIVE, ToolContext, ToolError, ToolRegistry,
               ToolResult, ToolSpec)
from ..config import workspace_env

DEFAULT_TIMEOUT = 120
MAX_OUTPUT = 200_000

# Registry of running dev servers: project -> (process, port, started)
SERVERS: dict[str, dict] = {}


def _quote(command: str) -> list[str]:
    """Split a command string without a shell. POSIX uses shlex; Windows uses
    CommandLineToArgvW-style parsing so drive-letter backslashes survive."""
    import shlex
    try:
        if os.name == "nt":
            return _split_windows(command)
        return shlex.split(command)
    except ValueError as error:
        raise ToolError(f"could not parse command: {error}") from error


def _split_windows(command: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    in_quotes = False
    index = 0
    while index < len(command):
        char = command[index]
        if char == '"':
            if in_quotes and index + 1 < len(command) and command[index + 1] == '"':
                current.append('"')  # doubled quote inside quotes = literal quote
                index += 2
                continue
            in_quotes = not in_quotes
            index += 1
            continue
        if not in_quotes and char.isspace():
            if current:
                parts.append("".join(current))
                current = []
            index += 1
            continue
        current.append(char)
        index += 1
    if current:
        parts.append("".join(current))
    return parts


def _check_executable(parts: list[str]) -> list[str]:
    """Refuse obvious process-smuggling in the binary position."""
    binary = Path(parts[0]).name.lower()
    if binary in {"powershell", "pwsh", "cmd"}:
        raise ToolError("running a shell directly is blocked; call the target program instead")
    return parts


async def _stream_run(context: ToolContext, parts: list[str], cwd: Path, timeout: int) -> ToolResult:
    cwd.mkdir(parents=True, exist_ok=True)
    env = workspace_env(cwd)
    started = time.time()
    try:
        process = subprocess.Popen(
            parts, cwd=str(cwd), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, text=True, errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except FileNotFoundError:
        raise ToolError(f"program not found: {parts[0]}")
    except PermissionError as error:
        raise ToolError(f"cannot execute {parts[0]}: {error}")

    chunks: list[str] = []
    killed = {"reason": None}
    deadline = time.time() + timeout

    def drain() -> None:
        assert process.stdout
        for line in iter(process.stdout.readline, ""):
            chunks.append(line)
            if sum(len(c) for c in chunks) > MAX_OUTPUT:
                break

    import threading
    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    while process.poll() is None:
        if time.time() > deadline:
            killed["reason"] = f"timeout after {timeout}s"
            process.kill()
            break
        await context.report({"type": "command_output", "lines": len(chunks)})
        time.sleep(0.2)
    reader.join(timeout=2)
    output = "".join(chunks)[:MAX_OUTPUT]
    code = process.returncode
    await context.report({"type": "command_exit", "code": code, "seconds": round(time.time() - started, 2)})
    header = f"$ {' '.join(parts)}\n"
    if killed["reason"]:
        return ToolResult(False, header + output + f"\n{killed['reason']}")
    if code != 0:
        return ToolResult(False, header + output + f"\nexit code: {code}")
    return ToolResult(True, header + output, data={"exit_code": 0, "seconds": round(time.time() - started, 2)})


def register(registry: ToolRegistry) -> None:
    registry.register(ToolSpec(
        name="run_command",
        description="Run a program with arguments inside the project directory "
                    "(no shell). Example command: 'node build.js'.",
        parameters={"type": "object",
                    "properties": {"command": {"type": "string"},
                                   "timeout_seconds": {"type": "integer"}},
                    "required": ["command"]},
    ), _run_command)

    registry.register(ToolSpec(
        name="run_python",
        description="Run a Python file from the workspace with the host's interpreter.",
        parameters={"type": "object",
                    "properties": {"file": {"type": "string"},
                                   "timeout_seconds": {"type": "integer"}},
                    "required": ["file"]},
    ), _run_python)

    registry.register(ToolSpec(
        name="install_dependencies",
        description="Install project dependencies from requirements.txt (pip) or "
                    "package.json (npm install). Needs approval.",
        parameters={"type": "object", "properties": {}},
        danger=DESTRUCTIVE, needs_approval=True,
    ), _install_dependencies)

    registry.register(ToolSpec(
        name="start_dev_server",
        description="Start a long-running development server for this project and "
                    "wait until its port accepts connections.",
        parameters={"type": "object",
                    "properties": {"command": {"type": "string"},
                                   "port": {"type": "integer"}},
                    "required": ["command"]},
    ), _start_dev_server)

    registry.register(ToolSpec(
        name="stop_dev_server",
        description="Stop this project's running development server.",
        parameters={"type": "object", "properties": {}},
    ), _stop_dev_server)


async def _run_command(context: ToolContext, args: dict) -> ToolResult:
    timeout = min(int(args.get("timeout_seconds", DEFAULT_TIMEOUT)), 600)
    parts = _check_executable(_quote(args["command"]))
    return await _stream_run(context, parts, context.project_dir, timeout)


async def _run_python(context: ToolContext, args: dict) -> ToolResult:
    from .filesystem import resolve_in_workspace
    path = resolve_in_workspace(context, args["file"])
    if not path.exists():
        raise ToolError(f"file not found: {args['file']}")
    timeout = min(int(args.get("timeout_seconds", DEFAULT_TIMEOUT)), 600)
    return await _stream_run(context, [sys.executable, str(path)], context.project_dir, timeout)


async def _install_dependencies(context: ToolContext, _args: dict) -> ToolResult:
    root = context.project_dir
    if (root / "requirements.txt").exists():
        return await _stream_run(context, [sys.executable, "-m", "pip", "install",
                                           "-r", "requirements.txt", "--no-warn-script-location"],
                                 root, 600)
    if (root / "package.json").exists():
        npm = _npm_command()
        return await _stream_run(context, npm + ["install", "--no-audit", "--no-fund"], root, 900)
    raise ToolError("no requirements.txt or package.json in the project")


def _npm_command() -> list[str]:
    for candidate in ("npm", "npm.cmd"):
        path = Path(os.environ.get("NPM_PATH", "")) if os.environ.get("NPM_PATH") else None
        if path and path.exists():
            return [str(path)]
        import shutil
        if shutil.which(candidate):
            return [candidate]
    raise ToolError("npm was not found on this machine; install Node.js LTS first")


async def _start_dev_server(context: ToolContext, args: dict) -> ToolResult:
    if context.project in SERVERS and SERVERS[context.project]["process"].poll() is None:
        existing = SERVERS[context.project]
        return ToolResult(True, f"a dev server is already running on port {existing['port']}")
    port = int(args.get("port", 0))
    parts = _quote(args["command"])
    context.project_dir.mkdir(parents=True, exist_ok=True)
    env = workspace_env(context.project_dir)
    process = subprocess.Popen(
        parts, cwd=str(context.project_dir), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        text=True, errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    deadline = time.time() + 60
    lines: list[str] = []
    detected = port

    import threading
    def drain() -> None:
        assert process.stdout
        for line in iter(process.stdout.readline, ""):
            lines.append(line)

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    while time.time() < deadline:
        if process.poll() is not None:
            output = "".join(lines)[:4000]
            raise ToolError(f"dev server exited immediately:\n{output}")
        if not detected:
            detected = _detect_port("".join(lines)) or _detect_port_from_import(parts)
        if detected and _port_open(detected):
            SERVERS[context.project] = {"process": process, "port": detected,
                                        "command": args["command"]}
            return ToolResult(True, f"dev server started on port {detected}",
                              data={"port": detected})
        time.sleep(0.5)
    process.kill()
    raise ToolError("dev server did not open a port within 60 seconds")


def _detect_port(text: str) -> int | None:
    import re
    match = re.findall(r"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{3,5})", text)
    for port in reversed(match):
        if 1024 <= int(port) <= 65535:
            return int(port)
    return None


def _detect_port_from_import(parts: list[str]) -> int | None:
    """Fallback: a --port flag on the command line."""
    if "--port" in parts:
        try:
            return int(parts[parts.index("--port") + 1])
        except (ValueError, IndexError):
            return None
    return None


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


async def _stop_dev_server(context: ToolContext, _args: dict) -> ToolResult:
    entry = SERVERS.pop(context.project, None)
    if not entry:
        return ToolResult(True, "no dev server is running for this project")
    process: subprocess.Popen = entry["process"]
    try:
        process.terminate()
        process.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        with contextlib_suppress():
            process.kill()
    return ToolResult(True, f"stopped dev server on port {entry['port']}")


class contextlib_suppress:
    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return True
