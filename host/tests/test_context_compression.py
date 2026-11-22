"""Context compression: thresholds, preservation, persistence, emergencies."""
from __future__ import annotations

import pytest

from nethhost.context_manager import ContextManager, preserved_notes, _looks_like_overflow
from nethhost.database import Database


class ScriptedSummarizer:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.received: list[str] = []

    async def summarize(self, text: str) -> str:
        self.received.append(text)
        if self.fail:
            return ""
        return "digest of older turns"


def make_manager(db: Database, summarizer, **kwargs) -> ContextManager:
    return ContextManager(db, summarizer, model_limit=kwargs.pop("model_limit", 1000),
                          reserve_output=kwargs.pop("reserve_output", 100), **kwargs)


async def test_proactive_compaction_at_threshold(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer, compact_at=0.5, recent_keep=4)
    db.create_conversation("c1", "t", "p")
    for i in range(12):
        db.add_message("c1", "user", "message " + str(i) + " " + "word " * 60)
    usage_before = manager.usage("c1")
    assert usage_before > 0.5
    build = await manager.build_prompt("c1", "system prompt")
    assert build.compacted
    assert len(build.messages) <= 1 + 1 + 1 + 4 + 1  # system + memory? + summary + recent
    events = db.compression_events("c1")
    assert events and events[0]["kind"] == "proactive"
    # originals persist
    assert len(db.messages("c1")) == 12
    # a summary exists
    assert db.latest_summary("c1") is not None


async def test_recent_messages_stay_verbatim(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer, compact_at=0.5, recent_keep=3)
    db.create_conversation("c2", "t", "p")
    for i in range(10):
        db.add_message("c2", "user", f"unique message {i} " + "pad " * 80)
    build = await manager.build_prompt("c2", "")
    contents = [m["content"] for m in build.messages]
    assert "unique message 9 " + "pad " * 80 in contents
    assert all("unique message 0 " not in c for c in contents)


async def test_preserved_notes_keep_errors_and_paths(db):
    older = [
        {"role": "user", "content": "The build failed with ERROR in src/main.py\nand the requirement is dark mode"},
        {"role": "assistant", "content": "Fixed the path issue in assets/app.css"},
    ]
    notes = preserved_notes(older)
    assert "ERROR" in notes
    assert "requirement" in notes.lower()
    assert "src/main.py" in notes or "assets/app.css" in notes


async def test_failed_summary_keeps_originals(db):
    summarizer = ScriptedSummarizer(fail=True)
    manager = make_manager(db, summarizer, compact_at=0.5, recent_keep=2)
    db.create_conversation("c3", "t", "p")
    for i in range(8):
        db.add_message("c3", "user", "filler " + "x " * 120)
    ok = await manager.compact("c3")
    assert ok is False
    assert db.latest_summary("c3") is None
    assert len(db.messages("c3")) == 8  # nothing lost
    events = db.compression_events("c3")
    assert events and events[0]["kind"] == "failed"


async def test_recursion_guard(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer, compact_at=0.5)
    db.create_conversation("c4", "t", "p")
    db.add_message("c4", "user", "hello world")
    manager.compacting = True
    ok = await manager.compact("c4")
    assert ok is False


async def test_emergency_compaction(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer, compact_at=0.9, recent_keep=8)
    db.create_conversation("c5", "t", "p")
    for i in range(10):
        db.add_message("c5", "user", "err " + "y " * 200)
    done = await manager.emergency("c5", "context overflow: prompt exceeds maximum context length")
    assert done
    assert db.compression_events("c5")[0]["kind"] == "emergency"


async def test_emergency_ignores_unrelated_errors(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer)
    db.create_conversation("c6", "t", "p")
    db.add_message("c6", "user", "hello")
    assert await manager.emergency("c6", "HTTP 500: CUDA error") is False


def test_overflow_detection():
    assert _looks_like_overflow("maximum context length exceeded")
    assert _looks_like_overflow("prompt is too long: 40000 tokens > 32768")
    assert _looks_like_overflow("context window is full")
    assert not _looks_like_overflow("invalid api key")
    assert not _looks_like_overflow("connection reset")


async def test_manual_compaction_and_stats(db):
    summarizer = ScriptedSummarizer()
    manager = make_manager(db, summarizer, compact_at=0.95, recent_keep=3)
    db.create_conversation("c7", "t", "p")
    for i in range(8):
        db.add_message("c7", "user", "m " + "z " * 300)
    stats_before = db.context_stats("c7", manager.usable)
    assert stats_before["messages"] == 8
    done = await manager.compact("c7", reason="manual")
    assert done
    stats = db.context_stats("c7", manager.usable)
    assert stats["messages"] == 8  # messages persist; summaries reduce the prompt
    assert stats["last_compression"]["kind"] == "manual"
