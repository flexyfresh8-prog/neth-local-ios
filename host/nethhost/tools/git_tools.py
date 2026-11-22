"""Git tools: status, diff, commit. Push is intentionally not exposed.

Commits run with the project as the work tree and are rejected when nothing
changed or when git reports a dirty index conflict. Git pushes and credential
access are never offered as tools — the spec gates those behind explicit human
action outside the agent loop.
"""
from __future__ import annotations

import subprocess

from . import DESTRUCTIVE, ToolContext, ToolError, ToolRegistry, ToolResult, ToolSpec


def _git(context: ToolContext, *args: str) -> str:
    process = subprocess.run(
        ["git", "-C", str(context.project_dir), *args],
        capture_output=True, text=True, timeout=60,
        env=_git_env(context), encoding="utf-8", errors="replace")
    if process.returncode != 0:
        raise ToolError(f"git {args[0]} failed: {process.stderr.strip() or process.stdout.strip()}")
    return process.stdout


def _git_env(context: ToolContext) -> dict:
    from ..config import workspace_env
    env = workspace_env(context.project_dir)
    # Deterministic commits regardless of the machine's global git identity.
    env.setdefault("GIT_AUTHOR_NAME", "NethHost Agent")
    env.setdefault("GIT_AUTHOR_EMAIL", "agent@neth.local")
    env.setdefault("GIT_COMMITTER_NAME", "NethHost Agent")
    env.setdefault("GIT_COMMITTER_EMAIL", "agent@neth.local")
    return env


def register(registry: ToolRegistry) -> None:
    registry.register(ToolSpec(
        name="git_status",
        description="Show git status (porcelain) for the project.",
        parameters={"type": "object", "properties": {}},
    ), _git_status)

    registry.register(ToolSpec(
        name="git_diff",
        description="Show the unstaged diff for the project.",
        parameters={"type": "object", "properties": {}},
    ), _git_diff)

    registry.register(ToolSpec(
        name="git_commit",
        description="Stage all changes and create a commit with the given message.",
        parameters={"type": "object",
                    "properties": {"message": {"type": "string"}},
                    "required": ["message"]},
        danger=DESTRUCTIVE,
    ), _git_commit)


async def _git_status(context: ToolContext, _args: dict) -> ToolResult:
    out = _git(context, "status", "--porcelain")
    if not out.strip():
        return ToolResult(True, "Working tree clean.")
    return ToolResult(True, out.strip(), data={"raw": out})


async def _git_diff(context: ToolContext, _args: dict) -> ToolResult:
    out = _git(context, "diff")
    staged = _git(context, "diff", "--cached")
    combined = (out + "\n" + staged).strip()
    if not combined:
        return ToolResult(True, "No unstaged or staged changes.")
    return ToolResult(True, combined[:100_000])


async def _git_commit(context: ToolContext, args: dict) -> ToolResult:
    message = args["message"].strip()
    if not message or len(message) > 600:
        raise ToolError("commit message must be 1-600 characters")
    if not _has_commits(context):
        _git(context, "add", "-A")
        _git(context, "commit", "-m", message,
             "--author", "NethHost Agent <agent@neth.local>")
        return ToolResult(True, f"initial commit created: {message}")
    status = _git(context, "status", "--porcelain")
    if not status.strip():
        raise ToolError("nothing to commit: the working tree is clean")
    _git(context, "add", "-A")
    out = _git(context, "commit", "-m", message,
               "--author", "NethHost Agent <agent@neth.local>")
    return ToolResult(True, out.strip() or f"committed: {message}")


def _has_commits(context: ToolContext) -> bool:
    process = subprocess.run(
        ["git", "-C", str(context.project_dir), "rev-parse", "--verify", "HEAD"],
        capture_output=True, text=True, timeout=30)
    return process.returncode == 0
