"""Filesystem tools end to end."""
from __future__ import annotations

import pytest

from nethhost.tools import ToolError


async def test_write_read_roundtrip(registry, tool_context):
    result = await registry.execute("write_file", {"path": "src/app.py", "content": "print('hi')\n"},
                                    tool_context)
    assert result.ok, result.output
    assert (tool_context.project_dir / "src" / "app.py").read_text() == "print('hi')\n"
    read = await registry.execute("read_file", {"path": "src/app.py"}, tool_context)
    assert read.ok and "print('hi')" in read.output


async def test_write_creates_backups(registry, tool_context):
    await registry.execute("write_file", {"path": "a.txt", "content": "v1"}, tool_context)
    result = await registry.execute("write_file", {"path": "a.txt", "content": "v2"}, tool_context)
    assert result.ok and "backed up" in result.output
    backups = list((tool_context.layout.backups / "demo").glob("a.txt.bak"))
    assert backups and backups[0].read_text() == "v1"


async def test_patch_exact_match(registry, tool_context):
    await registry.execute("write_file", {"path": "f.txt", "content": "hello world"}, tool_context)
    result = await registry.execute("patch_file",
                                    {"path": "f.txt", "old": "world", "new": "Neth"}, tool_context)
    assert result.ok
    assert (tool_context.project_dir / "f.txt").read_text() == "hello Neth"


async def test_patch_rejects_ambiguous(registry, tool_context):
    await registry.execute("write_file", {"path": "f.txt", "content": "aa aa"}, tool_context)
    result = await registry.execute("patch_file",
                                    {"path": "f.txt", "old": "aa", "new": "b"}, tool_context)
    assert not result.ok and "replace_all" in result.output


async def test_patch_missing_text_fails_cleanly(registry, tool_context):
    await registry.execute("write_file", {"path": "f.txt", "content": "abc"}, tool_context)
    result = await registry.execute("patch_file",
                                    {"path": "f.txt", "old": "zzz", "new": "b"}, tool_context)
    assert not result.ok and "not found" in result.output


async def test_delete_file(registry, tool_context):
    await registry.execute("write_file", {"path": "gone.txt", "content": "x"}, tool_context)
    result = await registry.execute("delete_file", {"path": "gone.txt"}, tool_context)
    assert result.ok
    assert not (tool_context.project_dir / "gone.txt").exists()


async def test_delete_project_root_refused(registry, tool_context):
    result = await registry.execute("delete_file", {"path": "."}, tool_context)
    assert not result.ok and "root" in result.output


async def test_create_directory_and_list(registry, tool_context):
    await registry.execute("create_directory", {"path": "assets/css"}, tool_context)
    await registry.execute("write_file", {"path": "assets/css/site.css", "content": "body{}"}, tool_context)
    result = await registry.execute("list_files", {}, tool_context)
    assert result.ok and "assets/css/site.css" in result.output


async def test_unknown_tool_rejected(registry, tool_context):
    result = await registry.execute("format_c_drive", {}, tool_context)
    assert not result.ok and "unknown tool" in result.output


async def test_invalid_arguments_rejected(registry, tool_context):
    result = await registry.execute("read_file", {"bogus": 1}, tool_context)
    assert not result.ok and "missing required argument" in result.output
    result = await registry.execute("read_file", {"path": "x.txt", "bogus": 1}, tool_context)
    assert not result.ok and "unexpected argument" in result.output
    result = await registry.execute("read_file", {}, tool_context)
    assert not result.ok and "missing required argument" in result.output
    result = await registry.execute("read_file", {"path": 123}, tool_context)
    assert not result.ok and "must be a string" in result.output
