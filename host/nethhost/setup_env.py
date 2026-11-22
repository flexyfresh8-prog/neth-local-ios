"""First-launch setup: idempotent, incremental, repairable.

Every step records its version in install-state.json so rerunning NethHost.exe
skips finished work (the spec's installer-idempotency requirement) and a failed
step can be retried alone. Setup never installs system-wide software and never
needs administrator rights: it creates the folder layout, initializes the SQLite
databases, generates the API key, and reports which optional toolchain pieces
(git, node, Playwright) are present.
"""
from __future__ import annotations

import shutil
import sys
import time

from . import __version__
from .config import Config, InstallState
from .database import Database
from .paths import Layout


def bootstrap(layout: Layout, config: Config, state: InstallState) -> dict:
    report: dict = {"version": __version__, "root": str(layout.root), "steps": []}

    def step(name: str, func) -> None:
        if state.done(name, __version__):
            report["steps"].append({"name": name, "status": "cached"})
            return
        detail = func()
        state.mark(name, __version__, detail or "")
        report["steps"].append({"name": name, "status": "done", "detail": detail})

    step("folders", lambda: (_create_folders(layout), str(layout.root))[1])
    step("config", lambda: (_load_config(config), "api key ready")[1])
    step("databases", lambda: (_init_databases(layout), "sqlite ready")[1])
    step("toolchain", lambda: _check_toolchain(state, layout))

    return report


def _create_folders(layout: Layout) -> str:
    layout.create()
    return str(layout.root)


def _load_config(config: Config) -> None:
    config.load()


def _init_databases(layout: Layout) -> str:
    Database(layout.memory)
    return "conversations.db, summaries.db, projects.db"


def _check_toolchain(state: InstallState, layout: Layout) -> str:
    checks = {
        "python": sys.version.split()[0],
        "git": shutil.which("git") or "not installed",
        "node": shutil.which("node") or shutil.which("node.exe") or "not installed (only needed for JS projects)",
        "npm": shutil.which("npm") or shutil.which("npm.cmd") or "not installed",
        "playwright": "installed" if _playwright_present() else "not installed (browser checks disabled)",
    }
    layout.logs.mkdir(parents=True, exist_ok=True)
    with layout.log_file.open("a", encoding="utf-8") as log:
        log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} toolchain: {checks}\n")
    return ", ".join(f"{k}={v}" for k, v in checks.items())


def _playwright_present() -> bool:
    try:
        import playwright  # noqa: F401
        return True
    except ImportError:
        return False


def repair(layout: Layout, state: InstallState, step: str) -> None:
    """Reset one setup step so the next launch redoes it."""
    state.reset_step(step)
