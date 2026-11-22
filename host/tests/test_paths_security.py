"""Path safety: the workspace is the security boundary."""
from __future__ import annotations

import os

import pytest

from nethhost.paths import Layout, base_dir, safe_name
from nethhost.tools.filesystem import resolve_in_workspace
from nethhost.tools import ToolContext, ToolError


def test_base_dir_honours_env(isolated_home):
    assert base_dir() == isolated_home.resolve()


def test_layout_creates_full_structure(layout):
    expected = ["app", "workspace/projects", "memory", "runtime", "previews", "logs",
                "backups", "config"]
    for folder in expected:
        assert (layout.root / folder).is_dir(), folder
    assert (layout.root / "memory" / "conversations.db").exists() is False  # created by Database


def test_safe_name_rejects_traversal():
    assert safe_name("../../etc") == "..-..-etc" or "/" not in safe_name("../../etc")
    name = safe_name("my project <3")
    assert all(ch.isalnum() or ch in "-_ ." for ch in name)
    assert safe_name("") == "project"


def test_absolute_path_rejected(tool_context):
    with pytest.raises(ToolError):
        resolve_in_workspace(tool_context, "C:/Windows/system32/config")


@pytest.mark.skipif(os.name != "posix", reason="POSIX absolute path form")
def test_posix_absolute_path_rejected(tool_context):
    with pytest.raises(ToolError):
        resolve_in_workspace(tool_context, "/etc/passwd")


def test_parent_escape_rejected(tool_context):
    with pytest.raises(ToolError):
        resolve_in_workspace(tool_context, "../outside.txt")


def test_deeper_parent_escape_rejected(tool_context):
    with pytest.raises(ToolError):
        resolve_in_workspace(tool_context, "sub/../../outside.txt")


def test_inside_paths_resolve(tool_context):
    target = resolve_in_workspace(tool_context, "src/main.py")
    assert target == (tool_context.project_dir / "src" / "main.py").resolve()


def test_symlink_escape_rejected(tool_context):
    outside = tool_context.layout.root / "secret.txt"
    outside.write_text("secret")
    link = tool_context.project_dir / "innocent.txt"
    os.symlink(outside, link)
    with pytest.raises(ToolError):
        resolve_in_workspace(tool_context, "innocent.txt")


def test_symlink_inside_allowed(tool_context):
    real = tool_context.project_dir / "data.txt"
    real.write_text("ok")
    link = tool_context.project_dir / "alias.txt"
    os.symlink(real, link)
    assert resolve_in_workspace(tool_context, "alias.txt").exists()
