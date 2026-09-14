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
import subprocess
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path

LEDGER = Path("__WORKSPACE__/.claude/core/open-threads.md")

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


# --- закрытие ---------------------------------------------------------------
# 13.09.2026 (Саня: «почему в леджере столько задач и они не закрываются?»):
# леджер был append-only -- строки копил хук, а снимал их только я по памяти,
# поэтому за всё время не закрылось НИ ОДНОЙ. Здесь вторая половина: сказал
# «готово» -- хук ищет похожую открытую строку и не даёт закончить ход, пока
# я её не закрою. Одно срабатывание на строку (штамп), иначе ход зациклится.
DONE_RE = re.compile(r"\b(готово|сделано|сделал|закрыл|доделал|раскатал|"
                     r"проверено и работает)\b", re.IGNORECASE)
FIRED = Path("__WORKSPACE__/logs/.ledger-close-asked")
STOP_WORDS = {"саня", "сани", "сане", "надо", "нужно", "чтобы", "можно", "будет",
              "этого", "этой", "теперь", "после", "через", "перед", "потом"}


def _words(text):
    return {w for w in re.findall(r"[а-яёa-z0-9]{5,}", text.lower())
            if w not in STOP_WORDS}


def close_candidates(message, ledger_text):
    """Открытые строки леджера, сильнее всего похожие на сказанное «готово»."""
    said = _words(message)
    hits = []
    for line in ledger_text.splitlines():
        if not line.startswith("- [ ]"):
            continue
        common = said & _words(line)
        if len(common) >= 3:
            hits.append((len(common), line.strip()[:150]))
    return [h[1] for h in sorted(hits, reverse=True)[:3]]


def _set_alarm(note):
    """Обещание без будильника = обещание без исполнителя (Саня 13.09.2026).

    Сторож обещаний будит меня только по строкам с ДАТОЙ («к 22.08»), а
    «возьмусь сразу после» даты не несёт -- такие задачи ждали, пока хозяин
    не пнёт. Здесь обещание сразу превращается в машинный будильник через
    полтора часа: он в кроне и переживает рестарт сессии.
    """
    remind = Path("__WORKSPACE__/bin/remind-at.sh")
    if not remind.exists():
        return
    when = datetime.now(ZoneInfo("Asia/Yekaterinburg")) + timedelta(minutes=90)
    text = re.sub(r"^- \[ \] \S+ — ", "", note)[:120]
    subprocess.run([str(remind), when.strftime("%d.%m %H:%M"),
                    f"обещал и не сделал: {text} -- доделай и отчитайся"],
                   capture_output=True, timeout=20, check=False)


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

    said = last_assistant_text(Path(tpath))

    # сначала закрытие: «готово» без снятой строки -- и есть корень вечного леджера
    if DONE_RE.search(said) and LEDGER.exists():
        cands = close_candidates(said, LEDGER.read_text())
        asked = FIRED.read_text().splitlines() if FIRED.exists() else []
        fresh = [c for c in cands if c[:60] not in asked]
        if fresh:
            FIRED.parent.mkdir(parents=True, exist_ok=True)
            with FIRED.open("a") as f:
                f.write("\n".join(c[:60] for c in fresh) + "\n")
            print("ЛЕДЖЕР: ты сказал «готово». Похоже, закрылись эти строки "
                  "core/open-threads.md -- сними [ ] -> [x] или объясни, почему нет:\n"
                  + "\n".join(f"  {c}" for c in fresh), file=sys.stderr)
            return 2

    sentences = commitment_sentences(said)
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
        _set_alarm(new_lines[0])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # ponytail: a capture hook must never break the turn
