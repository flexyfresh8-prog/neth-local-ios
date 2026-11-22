"""SQLite persistence: conversations, messages, summaries, projects, events.

Three database files under memory/ (conversations, summaries, projects) mirror
the on-disk layout the app expects. Connections are per-call: SQLite handles
concurrent readers, and a busy timeout covers the rare write overlap.
"""
from __future__ import annotations

import json
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

SCHEMA = {
    "conversations.db": [
        "CREATE TABLE IF NOT EXISTS conversations ("
        " id TEXT PRIMARY KEY, title TEXT, project TEXT, created REAL)",
        "CREATE TABLE IF NOT EXISTS messages ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " conversation_id TEXT NOT NULL,"
        " role TEXT NOT NULL,"            # user | assistant | system | tool | summary | note
        " content TEXT NOT NULL,"
        " tool_name TEXT,"                # populated for role=tool
        " tool_call_id TEXT,"
        " tokens INTEGER,"
        " pinned INTEGER DEFAULT 0,"      # preserved by compression
        " created REAL)",
        "CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, id)",
        "CREATE TABLE IF NOT EXISTS compression_events ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " conversation_id TEXT NOT NULL,"
        " kind TEXT NOT NULL,"            # proactive | emergency | manual | failed
        " compacted_from INTEGER,"
        " compacted_to INTEGER,"
        " detail TEXT,"
        " created REAL)",
    ],
    "summaries.db": [
        "CREATE TABLE IF NOT EXISTS summaries ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " conversation_id TEXT NOT NULL,"
        " up_to_message_id INTEGER NOT NULL,"
        " summary TEXT NOT NULL,"
        " tokens INTEGER,"
        " created REAL)"
    ],
    "projects.db": [
        "CREATE TABLE IF NOT EXISTS projects ("
        " id TEXT PRIMARY KEY,"
        " name TEXT NOT NULL,"
        " path TEXT NOT NULL,"
        " created REAL)",
        "CREATE TABLE IF NOT EXISTS events ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " kind TEXT NOT NULL,"
        " payload TEXT,"
        " created REAL)"
    ],
}


class Database:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        for name, statements in SCHEMA.items():
            with self.connect(name) as db:
                for statement in statements:
                    db.execute(statement)

    @contextmanager
    def connect(self, name: str) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.root / name, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        finally:
            db.close()

    # --- conversations ----------------------------------------------------
    def create_conversation(self, conv_id: str, title: str, project: str) -> None:
        with self.connect("conversations.db") as db:
            db.execute("INSERT OR IGNORE INTO conversations VALUES (?,?,?,?)",
                       (conv_id, title, project, time.time()))

    def add_message(self, conv_id: str, role: str, content: str, *,
                    tool_name: str | None = None, tool_call_id: str | None = None,
                    tokens: int = 0, pinned: bool = False) -> int:
        if not tokens:
            from .tokens import estimate_tokens
            tokens = estimate_tokens(content)
        with self.connect("conversations.db") as db:
            cursor = db.execute(
                "INSERT INTO messages (conversation_id, role, content, tool_name,"
                " tool_call_id, tokens, pinned, created) VALUES (?,?,?,?,?,?,?,?)",
                (conv_id, role, content, tool_name, tool_call_id, tokens,
                 1 if pinned else 0, time.time()))
            return int(cursor.lastrowid)

    def messages(self, conv_id: str, after: int = 0) -> list[dict[str, Any]]:
        with self.connect("conversations.db") as db:
            rows = db.execute(
                "SELECT * FROM messages WHERE conversation_id=? AND id>? ORDER BY id",
                (conv_id, after)).fetchall()
            return [dict(row) for row in rows]

    def log_compression(self, conv_id: str, kind: str, before: int, after: int,
                        detail: str = "") -> None:
        with self.connect("conversations.db") as db:
            db.execute(
                "INSERT INTO compression_events (conversation_id, kind, compacted_from,"
                " compacted_to, detail, created) VALUES (?,?,?,?,?,?)",
                (conv_id, kind, before, after, detail, time.time()))

    def compression_events(self, conv_id: str) -> list[dict[str, Any]]:
        with self.connect("conversations.db") as db:
            rows = db.execute(
                "SELECT * FROM compression_events WHERE conversation_id=? ORDER BY id DESC LIMIT 50",
                (conv_id,)).fetchall()
            return [dict(row) for row in rows]

    def context_stats(self, conv_id: str, usable: int) -> dict[str, Any]:
        messages = self.messages(conv_id)
        total = sum(m["tokens"] or 0 for m in messages)
        latest = self.compression_events(conv_id)[:1]
        return {
            "messages": len(messages),
            "estimated_tokens": total,
            "usable_tokens": usable,
            "usage": round(total / usable, 3) if usable else 0.0,
            "last_compression": latest[0] if latest else None,
        }

    # --- summaries ---------------------------------------------------------
    def add_summary(self, conv_id: str, up_to: int, summary: str, tokens: int) -> None:
        with self.connect("summaries.db") as db:
            db.execute("DELETE FROM summaries WHERE conversation_id=? AND up_to_message_id<=?",
                       (conv_id, up_to))
            db.execute("INSERT INTO summaries (conversation_id, up_to_message_id, summary,"
                       " tokens, created) VALUES (?,?,?,?,?)",
                       (conv_id, up_to, summary, tokens, time.time()))

    def latest_summary(self, conv_id: str) -> dict[str, Any] | None:
        with self.connect("summaries.db") as db:
            row = db.execute(
                "SELECT * FROM summaries WHERE conversation_id=? ORDER BY up_to_message_id DESC LIMIT 1",
                (conv_id,)).fetchone()
            return dict(row) if row else None

    # --- projects -----------------------------------------------------------
    def add_project(self, project_id: str, name: str, path: str) -> None:
        with self.connect("projects.db") as db:
            db.execute("INSERT OR REPLACE INTO projects VALUES (?,?,?,?)",
                       (project_id, name, path, time.time()))

    def projects(self) -> list[dict[str, Any]]:
        with self.connect("projects.db") as db:
            rows = db.execute("SELECT * FROM projects ORDER BY created DESC").fetchall()
            return [dict(row) for row in rows]

    def log_event(self, kind: str, payload: dict[str, Any] | None = None) -> None:
        with self.connect("projects.db") as db:
            db.execute("INSERT INTO events (kind, payload, created) VALUES (?,?,?)",
                       (kind, json.dumps(payload or {}), time.time()))
