"""Configuration and install state.

config.json carries the user's backend endpoint, API keys and workspace
settings. install-state.json records which setup steps finished so first launch
is idempotent and repairable. API keys never go into logs or source control.
"""
from __future__ import annotations

import json
import os
import secrets
import stat
import threading
from pathlib import Path

from .paths import Layout

_LOCK = threading.Lock()

DEFAULT_BACKEND_MODEL = "gpt-oss-20b"


class Config:
    def __init__(self, layout: Layout) -> None:
        self.layout = layout
        self.data: dict = {}

    def load(self) -> "Config":
        if self.layout.config_file.exists():
            try:
                self.data = json.loads(self.layout.config_file.read_text("utf-8"))
            except (json.JSONDecodeError, OSError):
                self.data = {}
        self.data.setdefault("api_key", "nh-" + secrets.token_urlsafe(24))
        self.data.setdefault("backend", {"url": "", "api_key": "", "model": DEFAULT_BACKEND_MODEL})
        self.data.setdefault("context", {"model_limit": 32768, "reserve_output": 4096, "compact_at": 0.72})
        self.data.setdefault("security", {"require_approval_outside_workspace": True})
        self.save()
        return self

    def save(self) -> None:
        with _LOCK:
            self.layout.config_file.parent.mkdir(parents=True, exist_ok=True)
            text = json.dumps(self.data, indent=2)
            self.layout.config_file.write_text(text, "utf-8")
            try:  # best-effort: restrict to the current user on POSIX
                self.layout.config_file.chmod(stat.S_IRUSR | stat.S_IWUSR)
            except OSError:
                pass

    # --- backend ----------------------------------------------------------
    def set_backend(self, url: str, api_key: str, model: str | None = None) -> None:
        self.data["backend"]["url"] = url.rstrip("/")
        self.data["backend"]["api_key"] = api_key
        if model:
            self.data["backend"]["model"] = model
        self.save()

    @property
    def backend(self) -> dict:
        return self.data["backend"]

    @property
    def api_key(self) -> str:
        return self.data["api_key"]


class InstallState:
    """Idempotent first-launch setup. Each step records its version and time."""

    def __init__(self, layout: Layout) -> None:
        self.path = layout.state_file
        self.data: dict = {}
        if self.path.exists():
            try:
                self.data = json.loads(self.path.read_text("utf-8"))
            except (json.JSONDecodeError, OSError):
                self.data = {}

    def done(self, step: str, version: str) -> bool:
        entry = self.data.get("steps", {}).get(step)
        return bool(entry and entry.get("version") == version)

    def mark(self, step: str, version: str, detail: str = "") -> None:
        self.data.setdefault("steps", {})[step] = {"version": version, "detail": detail}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=2), "utf-8")

    def reset_step(self, step: str) -> None:
        self.data.get("steps", {}).pop(step, None)
        self.path.write_text(json.dumps(self.data, indent=2), "utf-8")


def workspace_env(project_dir: Path) -> dict:
    """Child-process environment: keep PATH, strip anything credential-shaped."""
    env = {k: v for k, v in os.environ.items() if not any(
        s in k.upper() for s in ("TOKEN", "SECRET", "PASSWORD", "KEY"))}
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env["NETH_PROJECT"] = str(project_dir)
    return env
