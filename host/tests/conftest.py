"""Shared fixtures: every test runs against an isolated NETHLOCAL_HOME."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

HOST_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HOST_ROOT))


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("NETHLOCAL_HOME", str(tmp_path / "NethLocal"))
    os.environ["NETHLOCAL_HOME"] = str(tmp_path / "NethLocal")
    yield tmp_path / "NethLocal"


@pytest.fixture()
def layout(isolated_home):
    from nethhost.paths import Layout, base_dir
    built = Layout(base_dir())
    built.create()
    return built


@pytest.fixture()
def config(layout):
    from nethhost.config import Config
    return Config(layout).load()


@pytest.fixture()
def db(layout):
    from nethhost.database import Database
    return Database(layout.memory)


@pytest.fixture()
def registry():
    from nethhost.tools import build_registry
    return build_registry()


@pytest.fixture()
def tool_context(layout):
    from nethhost.tools import ToolContext
    project_dir = layout.project("demo")
    project_dir.mkdir(parents=True, exist_ok=True)
    return ToolContext(layout=layout, project="demo",
                       project_dir=project_dir, approved=True)
