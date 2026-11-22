"""Automatic context compression.

Budget model (v2.0.0):
    usable = model_limit - reserve_output
    proactive compaction when estimated usage crosses compact_at (default 0.72,
    i.e. the 70-75% band the product spec asks for)

Compaction keeps the most recent messages verbatim and replaces older turns
with a model-written digest stored in summaries.db (originals stay in
conversations.db). A preserved-notes block carries the things that must never
be compressed away: current objectives, user requirements, file paths,
outstanding errors and important decisions. Emergency compaction runs once,
with a smaller verbatim window, when the backend reports a context overflow.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable, Protocol

from .database import Database
from .tokens import estimate_tokens

PRESERVE_LINE = re.compile(
    r"(error|traceback|exception|failed|must|requirement|goal|objective|path|"
    r"决定|错误|要求|目标|路径)", re.IGNORECASE)


class Summarizer(Protocol):
    async def summarize(self, text: str) -> str: ...


@dataclass
class PromptBuild:
    messages: list[dict] = field(default_factory=list)
    compacted: bool = False
    estimated_tokens: int = 0
    usage: float = 0.0


def preserved_notes(messages: list[dict]) -> str:
    """Heuristic extraction of must-keep facts from the turns being compacted."""
    notes: list[str] = []
    for message in messages:
        for line in message["content"].splitlines():
            line = line.strip()
            if line and PRESERVE_LINE.search(line) and len(line) < 400:
                notes.append(f"- {line}")
    seen: set[str] = set()
    unique: list[str] = []
    for note in notes[-40:]:
        if note not in seen:
            seen.add(note)
            unique.append(note)
    return "\n".join(unique)


class ContextManager:
    def __init__(self, db: Database, summarizer: Summarizer, *, model_limit: int = 32768,
                 reserve_output: int = 4096, compact_at: float = 0.72,
                 recent_keep: int = 12) -> None:
        self.db = db
        self.summarizer = summarizer
        self.model_limit = model_limit
        self.reserve_output = reserve_output
        self.compact_at = compact_at
        self.recent_keep = recent_keep
        self.compacting = False  # guards against recursive compression loops

    @property
    def usable(self) -> int:
        return max(1024, self.model_limit - self.reserve_output)

    def usage(self, conv_id: str) -> float:
        total = sum(m["tokens"] or 0 for m in self.db.messages(conv_id))
        return total / self.usable if self.usable else 0.0

    async def build_prompt(self, conv_id: str, system: str,
                           project_memory: str = "") -> PromptBuild:
        """Proactively compact, then assemble [system, memory, summary, recent]."""
        build = PromptBuild()
        if not self.compacting and self.usage(conv_id) >= self.compact_at:
            await self.compact(conv_id, reason="proactive")
            build.compacted = True

        summary = self.db.latest_summary(conv_id)
        all_messages = self.db.messages(conv_id)
        recent: list[dict] = []
        if summary:
            recent = [m for m in all_messages if m["id"] > summary["up_to_message_id"]]
        elif len(all_messages) > self.recent_keep:
            recent = all_messages[-self.recent_keep:]
        else:
            recent = all_messages

        if summary:
            build.messages.append({"role": "system", "content": summary["summary"]})
        if project_memory:
            build.messages.append({"role": "system", "content": project_memory})
        for message in recent:
            build.messages.append({"role": message["role"], "content": message["content"]})

        if system:
            build.messages.insert(0, {"role": "system", "content": system})
        build.estimated_tokens = sum(estimate_tokens(str(m["content"])) for m in build.messages)
        build.usage = build.estimated_tokens / self.usable if self.usable else 0.0
        return build

    async def compact(self, conv_id: str, reason: str = "proactive",
                      recent_keep: int | None = None) -> bool:
        """Summarize older turns. Returns False when there is nothing to do or
        the summarizer failed (originals are never destroyed)."""
        if self.compacting:
            return False  # recursion guard
        self.compacting = True
        try:
            keep = self.recent_keep if recent_keep is None else recent_keep
            summary_row = self.db.latest_summary(conv_id)
            all_messages = self.db.messages(conv_id)
            frontier = summary_row["up_to_message_id"] if summary_row else 0
            # Everything outside the verbatim window gets compacted.
            if keep and len(all_messages) > keep:
                cut = all_messages[-keep]["id"]
                older = [m for m in all_messages if frontier < m["id"] <= cut]
            else:
                older = [m for m in all_messages if m["id"] > frontier]
            if not older:
                return False
            before = sum(m["tokens"] or 0 for m in all_messages)

            notes = preserved_notes(older)
            transcript = "\n\n".join(
                f"{m['role']}: {m['content'][:2000]}" for m in older[-60:])
            digest = await self.summarizer.summarize(transcript)
            if not digest or not digest.strip():
                self.db.log_compression(conv_id, "failed", before, before,
                                        "summarizer returned empty output")
                return False
            if notes:
                digest = f"{digest.strip()}\n\nPreserved notes:\n{notes}"
            tokens = estimate_tokens(digest)
            up_to = older[-1]["id"]
            self.db.add_summary(conv_id, up_to, digest, tokens)
            after = sum(m["tokens"] or 0 for m in self.db.messages(conv_id)) - \
                sum(m["tokens"] or 0 for m in older) + tokens
            self.db.log_compression(conv_id, reason, before, after,
                                    f"compacted {len(older)} messages up to #{up_to}")
            return True
        finally:
            self.compacting = False

    async def emergency(self, conv_id: str, error_text: str) -> bool:
        """Called when the backend reports a context overflow; single retry."""
        if not _looks_like_overflow(error_text):
            return False
        return await self.compact(conv_id, reason="emergency", recent_keep=4)


def looks_like_overflow(error_text: str) -> bool:
    low = error_text.lower()
    return any(marker in low for marker in (
        "context overflow", "maximum context length", "context window",
        "too many tokens", "prompt is too long", "n_ctx", "token limit"))


# Back-compat alias used by older imports.
_looks_like_overflow = looks_like_overflow
