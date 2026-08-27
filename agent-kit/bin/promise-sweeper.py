#!/usr/bin/env python3
"""Turn dated promises in core/open-threads.md into a wake-up for the live session.

Runs daily from cron. Every open entry (`- [ ]`) whose due date (`→ пн 24.08`,
`к 22.08`, `до 22.08`) is today (Asia/Yekaterinburg) is injected into the
dashi-live tmux session as a task, so the agent acts on it without being poked.
# ponytail: date-only match, fires once per due date; overdue items stay in the
# 09:00 digest to Sanya — add "overdue" sweep if promises start slipping past.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

LEDGER = Path(__file__).resolve().parents[1] / ".claude/core/open-threads.md"
SESSION = os.environ.get("DASHI_TMUX_SESSION", "dashi-__AGENT__")
CHAT_ID = os.environ.get("DASHI_CHAT_ID", "__CHAT_ID__")
TZ = ZoneInfo("Asia/Yekaterinburg")
# 2026-08-27: the old pattern demanded a «→/к/до» marker, so my own ledger line
# «Разбор показать в ЧТ 28.08» never fired and the operator had to ask why.
# Two shapes now match: a weekday+date (marker optional), or a marker+date.
DUE_RE = re.compile(
    r"(?:(?:→|\bк|\bдо|\bв|\bна)\s*)?(?:пн|вт|ср|чт|пт|сб|вс)\s*(\d{1,2})\.(\d{2})"
    r"|(?:→|\bк|\bдо|\bв|\bна)\s+(\d{1,2})\.(\d{2})"
    # a bare date opening the item: «- [ ] 01.09: собрать лист»
    r"|^- \[ \]\s*(\d{1,2})\.(\d{2})",
    re.IGNORECASE,
)
WEEKDAYS = ("пн", "вт", "ср", "чт", "пт", "сб", "вс")
WD_RE = re.compile(r"\b(пн|вт|ср|чт|пт|сб|вс)\s*(\d{1,2})\.(\d{2})", re.IGNORECASE)


def due_today(lines: list[str], today: datetime) -> list[str]:
    """Return open ledger lines whose due date equals `today` (day.month)."""
    hits = []
    for line in lines:
        if not line.startswith("- [ ]"):
            continue
        for groups in DUE_RE.findall(line):
            pairs = [(groups[i], groups[i + 1]) for i in (0, 2, 4)]
            day, month = next(p for p in pairs if p[0])
            if int(day) == today.day and int(month) == today.month:
                hits.append(line.strip())
                break
    return hits


def weekday_mismatch(lines: list[str], year: int) -> list[str]:
    """Ledger lines whose «чт 28.08» names a weekday the date does not fall on."""
    bad = []
    for line in lines:
        if not line.startswith("- [ ]"):
            continue
        for wd, day, month in WD_RE.findall(line):
            try:
                d = datetime(year, int(month), int(day), tzinfo=TZ)
            except ValueError:
                continue
            if WEEKDAYS[d.weekday()] != wd.lower():
                bad.append(f"{wd} {day}.{month} -> на самом деле {WEEKDAYS[d.weekday()]}")
    return bad


def inject(prompt: str) -> None:
    subprocess.run(["tmux", "send-keys", "-t", SESSION, "-l", prompt], check=True)
    for _ in range(3):
        subprocess.run(["tmux", "send-keys", "-t", SESSION, "Enter"], check=False)
        subprocess.run(["sleep", "0.6"], check=False)


def main() -> int:
    today = datetime.now(TZ)
    lines = LEDGER.read_text(encoding="utf-8").splitlines()
    hits = due_today(lines, today)
    stamp = today.isoformat(timespec="seconds")
    # A wrong weekday means a promise is filed under a date nobody expects it on.
    for bad in weekday_mismatch(lines, today.year):
        print(f"{stamp} WEEKDAY MISMATCH: {bad}")
    if not hits:
        print(f"{stamp} nothing due")
        return 0
    body = "\n".join(f"• {h}" for h in hits)
    prompt = (
        f"[ОБЕЩАНИЯ НА СЕГОДНЯ {today:%d.%m}] В core/open-threads.md есть треды со "
        f"сроком сегодня. Выполни каждый и отчитайся оператор в чат {CHAT_ID} одним "
        f"сообщением на тред; закрыть [ ]→[x]. Не спрашивай, делай:\n{body}"
    )
    inject(prompt)
    print(f"{stamp} injected {len(hits)} promise(s)")
    return 0


def _selfcheck() -> None:
    t = datetime(2026, 8, 22, tzinfo=TZ)
    lines = [
        "- [ ] 2026-08-21 цифру оператор к 22.08 по токенам",
        "- [ ] 2026-08-21 → пт 28.08: итог пилота",
        "- [x] 2026-08-21 → сб 22.08: уже закрыт",
        "- [ ] 2026-08-21 → пн 24.08 (обзор): перемерить; к 22.08 тоже",
    ]
    got = due_today(lines, t)
    assert len(got) == 2 and got[0].endswith("по токенам") and "24.08" in got[1], got

    # the 2026-08-27 miss: a bare «в ЧТ 28.08» with no →/к/до marker
    t28 = datetime(2026, 8, 28, tzinfo=TZ)
    assert due_today(["- [ ] показать оператор в ЧТ 28.08"], t28), "bare weekday form missed"
    assert due_today(["- [ ] пт 28.08: витрина"], t28), "leading weekday form missed"
    assert not due_today(["- [ ] пт 28.08: витрина"], t), "fired on the wrong day"
    t19 = datetime(2026, 9, 1, tzinfo=TZ)
    assert due_today(["- [ ] 01.09: собрать лист продаж"], t19), "bare leading date missed"

    # 28.08.2026 is a Friday, so «чт 28.08» is a typo the sweeper should flag
    assert weekday_mismatch(["- [ ] показать в ЧТ 28.08"], 2026), "mismatch not caught"
    assert not weekday_mismatch(["- [ ] пт 28.08: витрина"], 2026), "false mismatch"
    print("selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
