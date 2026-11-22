"""Filesystem layout for the Neth Local host.

Windows first-launch creates D:\\NethLocal when that drive exists with enough
free space; otherwise the user picks another directory (largest fixed drive or
%LOCALAPPDATA%). Development and tests run anywhere via NETHLOCAL_HOME.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

MIN_FREE_BYTES = 5 * 1024 ** 3  # 5 GB: room for projects, runtimes and logs

FOLDER_LAYOUT = (
    "app",
    "app/agent",
    "app/context",
    "app/tools",
    "app/api",
    "workspace/projects",
    "memory",
    "runtime/python",
    "runtime/node",
    "runtime/browser",
    "runtime/temp",
    "previews",
    "logs",
    "backups",
    "config",
)


def base_dir() -> Path:
    """Resolve the NethLocal root: env override > D:\\NethLocal > best drive."""
    override = os.environ.get("NETHLOCAL_HOME")
    if override:
        return Path(override).expanduser().resolve()

    if sys.platform.startswith("win"):
        preferred = Path("D:/NethLocal")
        if _usable(preferred.anchor):
            return preferred
        fallback = pick_drive()
        if fallback:
            return fallback / "NethLocal"
        local = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "NethLocal"
        return local

    return Path.home() / "NethLocal"


def pick_drive() -> Path | None:
    """Largest fixed drive with enough space, excluding the Windows drive."""
    best: tuple[int, Path] | None = None
    for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
        root = Path(f"{letter}:/")
        if not root.is_dir():
            continue
        if letter.upper() == "C":
            continue  # system drive only as last resort
        if not _usable(str(root)):
            continue
        free = shutil.disk_usage(str(root)).free
        if best is None or free > best[0]:
            best = (free, root)
    return best[1] if best else None


def _usable(anchor: str) -> bool:
    try:
        if not Path(anchor).is_dir():
            return False
        return shutil.disk_usage(anchor).free >= MIN_FREE_BYTES
    except OSError:
        return False


class Layout:
    """All well-known paths inside the NethLocal root."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.app = root / "app"
        self.workspace = root / "workspace" / "projects"
        self.memory = root / "memory"
        self.runtime = root / "runtime"
        self.temp = root / "runtime" / "temp"
        self.previews = root / "previews"
        self.logs = root / "logs"
        self.backups = root / "backups"
        self.config = root / "config"
        self.db_conversations = root / "memory" / "conversations.db"
        self.db_summaries = root / "memory" / "summaries.db"
        self.db_projects = root / "memory" / "projects.db"
        self.config_file = root / "config" / "config.json"
        self.state_file = root / "config" / "install-state.json"
        self.log_file = root / "logs" / "nethhost.log"

    def create(self) -> None:
        for folder in FOLDER_LAYOUT:
            (self.root / folder).mkdir(parents=True, exist_ok=True)

    def project(self, name: str) -> Path:
        return self.workspace / safe_name(name)


def safe_name(name: str) -> str:
    """A project name that is a single safe path segment."""
    cleaned = "".join(ch if ch.isalnum() or ch in "-_ ." else "-" for ch in name).strip(" .")
    return cleaned or "project"


def layout() -> Layout:
    return Layout(base_dir())
