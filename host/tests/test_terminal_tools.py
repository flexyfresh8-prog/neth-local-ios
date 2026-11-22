"""Terminal, process and git tools."""
from __future__ import annotations

import subprocess
import sys
import time

import pytest

from nethhost.tools import ToolError


async def test_run_command_captures_output(registry, tool_context):
    result = await registry.execute(
        "run_command", {"command": f"{sys.executable} -c \"print('streamed-ok')\""}, tool_context)
    assert result.ok, result.output
    assert "streamed-ok" in result.output


async def test_run_command_reports_failure(registry, tool_context):
    result = await registry.execute(
        "run_command", {"command": f"{sys.executable} -c \"import sys; sys.exit(3)\""}, tool_context)
    assert not result.ok and "exit code: 3" in result.output


async def test_run_command_timeout(registry, tool_context):
    started = time.time()
    result = await registry.execute(
        "run_command",
        {"command": f"{sys.executable} -c \"import time; time.sleep(30)\"",
         "timeout_seconds": 1}, tool_context)
    elapsed = time.time() - started
    assert not result.ok and "timeout" in result.output
    assert elapsed < 15


async def test_run_command_blocks_shell(registry, tool_context):
    result = await registry.execute("run_command", {"command": "powershell -Command x"}, tool_context)
    assert not result.ok and "blocked" in result.output


async def test_run_python(registry, tool_context):
    await registry.execute("write_file", {"path": "script.py", "content": "print('py-ok')"},
                           tool_context)
    result = await registry.execute("run_python", {"file": "script.py"}, tool_context)
    assert result.ok and "py-ok" in result.output


async def test_run_python_rejects_escape(registry, tool_context):
    result = await registry.execute("run_python", {"file": "../hostile.py"}, tool_context)
    assert not result.ok and "escapes" in result.output


async def test_start_stop_dev_server(registry, tool_context):
    port = 8677
    result = await registry.execute(
        "start_dev_server",
        {"command": f"{sys.executable} -m http.server {port} --bind 127.0.0.1",
         "port": port}, tool_context)
    assert result.ok, result.output
    entry = await registry.execute("stop_dev_server", {}, tool_context)
    assert entry.ok and "stopped" in entry.output


async def test_install_dependencies_requires_approval(registry, tool_context):
    tool_context.approved = False
    result = await registry.execute("install_dependencies", {}, tool_context)
    assert not result.ok and "approval required" in result.output


def _git_available():
    try:
        subprocess.run(["git", "--version"], capture_output=True, timeout=10)
        return True
    except OSError:
        return False


@pytest.mark.skipif(not _git_available(), reason="git not installed")
async def test_git_flow(registry, tool_context):
    tool_context.project_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=tool_context.project_dir, timeout=30)
    await registry.execute("write_file", {"path": "index.html", "content": "<h1>ok</h1>"},
                           tool_context)
    status = await registry.execute("git_status", {}, tool_context)
    assert status.ok and "index.html" in status.output
    subprocess.run(["git", "-C", str(tool_context.project_dir), "add", "-A"],
                   cwd=tool_context.project_dir, timeout=30)
    diff = await registry.execute("git_diff", {}, tool_context)
    assert diff.ok and "index.html" in diff.output
    commit = await registry.execute("git_commit", {"message": "first site"}, tool_context)
    assert commit.ok and ("committed" in commit.output or "commit" in commit.output.lower())
    clean = await registry.execute("git_status", {}, tool_context)
    assert clean.ok and "clean" in clean.output.lower()


@pytest.mark.skipif(not _git_available(), reason="git not installed")
async def test_git_commit_empty_rejected(registry, tool_context):
    tool_context.project_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=tool_context.project_dir, timeout=30)
    subprocess.run(["git", "-C", str(tool_context.project_dir), "commit", "--allow-empty",
                    "-q", "-m", "base"], capture_output=True, timeout=30)
    result = await registry.execute("git_commit", {"message": "nothing"}, tool_context)
    assert not result.ok and "nothing to commit" in result.output
