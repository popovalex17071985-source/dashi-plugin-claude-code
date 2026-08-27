#!/usr/bin/env python3
"""Stop hook — capture forward commitments so multi-session promises don't evaporate.

Root cause it fixes (2026-07-02, Avito-autoload thread): a promise like «вернусь
с разведкой на днях» lived only in session context and was lost on compact/new
session. This hook greps the agent's LAST assistant message for commitment
phrases and appends a dated line to core/open-threads.md (append-only ledger,
loaded via PROJECTS.md). Best-effort: never blocks, always exits 0.

ponytail: substring-dedup against the ledger, no DB; snapshot ledger if it grows.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path

LEDGER = Path("__CLAUDE_DIR__/core/open-threads.md")

# First-person forward commitments / parked topics. Tight enough to avoid most
# chatter, loose enough that a missed promise is the rare case (operator's ask).
COMMIT_RE = re.compile(
    r"(вернусь\s+(?:с|к|за)\b|на\s+днях\b|сделаю\s+(?:позже|потом|завтра)|"
    r"позже\s+сделаю|разведаю\b|гляну\s+(?:на\s+днях|позже|завтра)|"
    r"вернёмся\s+к\b|отложим\b|PoC\b|\bTODO\b|напомню\s+(?:позже|завтра))",
    re.IGNORECASE,
)
# Sentence splitter — keep the clause carrying the commitment as the ledger note.
SENT_RE = re.compile(r"[^.!?\n]*[.!?\n]")


def last_assistant_text(transcript: Path) -> str:
    """Concatenated text blocks of the LAST assistant entry in the transcript."""
    text = ""
    for line in transcript.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = entry.get("message", {}).get("content")
        if isinstance(content, list):
            text = " ".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
    return text.strip()


def commitment_sentences(text: str) -> list[str]:
    out: list[str] = []
    for sent in SENT_RE.findall(text):
        s = sent.strip()
        if s and COMMIT_RE.search(s):
            out.append(re.sub(r"\s+", " ", s))
    return out


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0
    tpath = payload.get("transcript_path")
    if not tpath or not Path(tpath).exists():
        return 0

    sentences = commitment_sentences(last_assistant_text(Path(tpath)))
    if not sentences:
        return 0

    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    existing = LEDGER.read_text() if LEDGER.exists() else ""
    if not existing:
        existing = "# Open threads — forward commitments (auto-captured)\n\n"
        LEDGER.write_text(existing)

    today = datetime.now().strftime("%Y-%m-%d")
    new_lines = []
    for s in sentences:
        note = s[:180]
        # substring-dedup: skip if this clause is already logged
        if note[:60] in existing or note[:60] in "\n".join(new_lines):
            continue
        new_lines.append(f"- [ ] {today} — {note}")
    if new_lines:
        with LEDGER.open("a") as f:
            f.write("\n".join(new_lines) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # ponytail: a capture hook must never break the turn
