"""Filesystem tools: list, read, write, patch, delete, mkdir.

All paths resolve inside the project workspace. Absolute paths, '..' escapes and
symlink escapes are rejected before any I/O happens.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

from . import ToolContext, ToolError, ToolRegistry, ToolResult, ToolSpec, SAFE, DESTRUCTIVE

MAX_READ_BYTES = 512 * 1024
MAX_WRITE_BYTES = 4 * 1024 * 1024
MAX_LIST_ENTRIES = 2000


def resolve_in_workspace(context: ToolContext, relative: str) -> Path:
    if not isinstance(relative, str) or not relative.strip():
        raise ToolError("path must be a non-empty string")
    candidate = Path(relative)
    if candidate.is_absolute() or relative.startswith(("/", "\\")) or (len(relative) > 1 and relative[1] == ":"):
        raise ToolError(f"absolute paths are not allowed inside the workspace: {relative}")
    root = context.project_dir.resolve()
    target = (root / candidate).resolve()
    if target != root and not target.is_relative_to(root):
        raise ToolError(f"path escapes the project workspace: {relative}")
    # A symlink inside the workspace may still point outside.
    if target.is_symlink() or (target.exists() and os.path.realpath(target) != str(target)):
        real = Path(os.path.realpath(target))
        if not real.is_relative_to(root):
            raise ToolError(f"symlink escapes the project workspace: {relative}")
    return target


def _listing(root: Path) -> list[dict]:
    entries: list[dict] = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".git")][:200]
        current_path = Path(current)
        for name in files[:MAX_LIST_ENTRIES]:
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            try:
                entries.append({"path": rel, "bytes": path.stat().st_size})
            except OSError:
                entries.append({"path": rel, "bytes": None})
            if len(entries) >= MAX_LIST_ENTRIES:
                return entries
    return entries


def register(registry: ToolRegistry) -> None:
    registry.register(ToolSpec(
        name="list_files",
        description="List files in the project workspace with sizes.",
        parameters={"type": "object", "properties": {}},
    ), _list_files)

    registry.register(ToolSpec(
        name="read_file",
        description="Read a text file from the workspace (UTF-8, first 512 KB).",
        parameters={"type": "object",
                    "properties": {"path": {"type": "string", "description": "workspace-relative path"}},
                    "required": ["path"]},
    ), _read_file)

    registry.register(ToolSpec(
        name="write_file",
        description="Create or overwrite a file with the given content (max 4 MB).",
        parameters={"type": "object",
                    "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                    "required": ["path", "content"]},
    ), _write_file)

    registry.register(ToolSpec(
        name="patch_file",
        description="Replace exact text in a file. Provide the old text and the new text; "
                    "the old text must match exactly once unless replace_all is true.",
        parameters={"type": "object",
                    "properties": {"path": {"type": "string"}, "old": {"type": "string"},
                                   "new": {"type": "string"}, "replace_all": {"type": "boolean"}},
                    "required": ["path", "old", "new"]},
    ), _patch_file)

    registry.register(ToolSpec(
        name="delete_file",
        description="Delete a file (or empty directory) from the workspace.",
        parameters={"type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"]},
        danger=DESTRUCTIVE, needs_approval=False,
    ), _delete_file)

    registry.register(ToolSpec(
        name="create_directory",
        description="Create a directory inside the workspace (parents allowed).",
        parameters={"type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"]},
    ), _create_directory)


async def _list_files(context: ToolContext, _args: dict) -> ToolResult:
    root = context.project_dir
    if not root.exists():
        root.mkdir(parents=True, exist_ok=True)
    entries = _listing(root)
    if not entries:
        return ToolResult(True, "The workspace is empty.")
    lines = "\n".join(f"{e['path']} ({e['bytes']} bytes)" for e in entries[:200])
    extra = f"\n… and {len(entries) - 200} more" if len(entries) > 200 else ""
    return ToolResult(True, f"{len(entries)} files:\n{lines}{extra}",
                      data={"files": entries})


async def _read_file(context: ToolContext, args: dict) -> ToolResult:
    path = resolve_in_workspace(context, args["path"])
    if not path.exists() or not path.is_file():
        raise ToolError(f"file not found: {args['path']}")
    data = path.read_bytes()[:MAX_READ_BYTES]
    text = data.decode("utf-8", errors="replace")
    truncated = "… [truncated at 512 KB]" if len(path.read_bytes()) > MAX_READ_BYTES else ""
    return ToolResult(True, text + truncated, data={"path": args["path"], "bytes": len(data)})


async def _write_file(context: ToolContext, args: dict) -> ToolResult:
    content = args["content"]
    if len(content.encode("utf-8")) > MAX_WRITE_BYTES:
        raise ToolError("content exceeds the 4 MB write limit")
    path = resolve_in_workspace(context, args["path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    if path.exists():
        backup = _backup(context, path)
    path.write_text(content, "utf-8")
    note = f" (previous version backed up to {backup.name})" if backup else ""
    await context.report({"type": "file_written", "path": args["path"], "bytes": len(content.encode('utf-8'))})
    return ToolResult(True, f"wrote {args['path']} ({len(content.encode('utf-8'))} bytes){note}",
                      data={"path": args["path"], "backup": str(backup) if backup else None})


def _backup(context: ToolContext, path: Path) -> Path:
    backups = context.layout.backups / context.project
    backups.mkdir(parents=True, exist_ok=True)
    target = backups / f"{path.name}.bak"
    shutil.copy2(path, target)
    return target


async def _patch_file(context: ToolContext, args: dict) -> ToolResult:
    path = resolve_in_workspace(context, args["path"])
    if not path.exists():
        raise ToolError(f"file not found: {args['path']}")
    text = path.read_text("utf-8")
    old, new = args["old"], args["new"]
    if old not in text:
        raise ToolError("the old text was not found in the file; read the file again and patch an exact match")
    count = text.count(old)
    if count > 1 and not args.get("replace_all", False):
        raise ToolError(f"the old text appears {count} times; pass replace_all=true or include more context")
    replacement = text.replace(old, new) if args.get("replace_all") else text.replace(old, new, 1)
    _backup(context, path)
    path.write_text(replacement, "utf-8")
    await context.report({"type": "file_patched", "path": args["path"]})
    return ToolResult(True, f"patched {args['path']} ({count if args.get('replace_all') else 1} replacement(s))")


async def _delete_file(context: ToolContext, args: dict) -> ToolResult:
    path = resolve_in_workspace(context, args["path"])
    if path == context.project_dir.resolve():
        raise ToolError("refusing to delete the project root")
    if not path.exists():
        raise ToolError(f"file not found: {args['path']}")
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
    return ToolResult(True, f"deleted {args['path']}")


async def _create_directory(context: ToolContext, args: dict) -> ToolResult:
    path = resolve_in_workspace(context, args["path"])
    path.mkdir(parents=True, exist_ok=True)
    return ToolResult(True, f"created directory {args['path']}")
