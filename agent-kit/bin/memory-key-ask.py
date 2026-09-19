#!/usr/bin/env python3
"""Память просит ключ у владельца САМА -- когда ей уже есть что помнить.

Саня 19.09.2026: «Надо чтобы он сам написал владельцу что нужен ключ
долговременной памяти» -- и тут же напомнил, что включать это решили не сразу, а
когда «память начнёт копиться и набирать вес». Поэтому сторож молчит, пока
копить нечего, и пишет владельцу только когда накопленное реально ждёт слива.

Порог -- вес горячей памяти (recent.md + handoff.md) и число пропущенных сливов.
Просьба уходит раз в неделю, не чаще: это просьба, а не сигнализация.

  memory-key-ask.py            # показать, что решил, ничего не отправляя
  memory-key-ask.py --send     # отправить владельцу, если пора
  memory-key-ask.py --selftest
"""
from __future__ import annotations

import json
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent
OV_HEALTH = "http://127.0.0.1:1933/health"
HOT = WORKSPACE / ".claude" / "core" / "hot"
FLUSH_LOG = WORKSPACE / "logs" / "flush-to-openviking.log"
STATE = WORKSPACE / "state" / "memory-key-ask.json"
MIN_HOT_LINES = 150      # меньше -- копить ещё нечего, молчим
MIN_SKIPPED = 3          # сколько раз слив уже не прошёл
ASK_EVERY_DAYS = 7


def memory_alive() -> bool:
    try:
        with urllib.request.urlopen(OV_HEALTH, timeout=3) as resp:
            return resp.status == 200
    except (urllib.error.URLError, OSError, ValueError):
        return False


def hot_lines() -> int:
    total = 0
    for name in ("recent.md", "handoff.md"):
        path = HOT / name
        if path.exists():
            total += len(path.read_text(encoding="utf-8").splitlines())
    return total


def skipped_flushes() -> int:
    if not FLUSH_LOG.exists():
        return 0
    return sum(1 for line in FLUSH_LOG.read_text(encoding="utf-8").splitlines()
               if "недоступен" in line)


def _state() -> dict:
    if STATE.exists():
        try:
            return json.loads(STATE.read_text(encoding="utf-8"))
        except ValueError:
            return {}
    return {}


def asked_recently() -> bool:
    at = _state().get("asked_at")
    if not at:
        return False
    try:
        when = datetime.fromisoformat(at)
    except ValueError:
        return False
    return when > datetime.now(timezone.utc) - timedelta(days=ASK_EVERY_DAYS)


def text() -> str:
    return (
        "Долговременная память у меня не работает: сервер памяти на этой машине не "
        "поднимается без ключа для эмбеддингов.\n\n"
        f"Накопилось уже {hot_lines()} строк рабочих заметок, которые я не могу "
        "перенести в долгую память -- значит после сброса разговора они пропадут.\n\n"
        "Нужен ключ OpenAI. Положи его сюда: ~/.openviking/ov.conf, блок embedding:\n"
        '{ "server": { "host": "127.0.0.1", "port": 1933 },\n'
        '  "embedding": { "dense": { "provider": "openai",\n'
        '    "api_base": "https://api.openai.com/v1", "api_key": "СЮДА_КЛЮЧ",\n'
        '    "model": "text-embedding-3-small", "dimension": 1536 } } }\n\n'
        "Дальше я поднимаю сервер памяти сам. Расход -- только эмбеддинги заметок."
    )


def should_ask() -> tuple[bool, str]:
    if memory_alive():
        return False, "память жива -- просить нечего"
    if asked_recently():
        return False, f"уже просил, жду {ASK_EVERY_DAYS} дней"
    lines, skipped = hot_lines(), skipped_flushes()
    if lines < MIN_HOT_LINES and skipped < MIN_SKIPPED:
        return False, f"копить пока нечего: {lines} строк, пропущено сливов {skipped}"
    return True, f"{lines} строк ждут слива, пропущено сливов {skipped}"


def _selftest() -> None:
    assert "ov.conf" in text() and "api_key" in text()
    ok, why = should_ask()
    assert isinstance(ok, bool) and why
    print("selftest ok")


def main() -> int:
    if "--selftest" in sys.argv:
        _selftest()
        return 0
    ask, why = should_ask()
    print(("просим: " if ask else "молчим: ") + why)
    if not ask or "--send" not in sys.argv:
        return 0
    send = WORKSPACE / "bin" / "tg-send.py"
    if not send.exists():
        print("нет bin/tg-send.py -- некому отдать сообщение")
        return 1
    res = subprocess.run([sys.executable, str(send), text()], capture_output=True, text=True)
    if res.returncode != 0:
        print("не отправилось:", (res.stderr or res.stdout)[:200])
        return 1
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"asked_at": datetime.now(timezone.utc).isoformat()},
                                ensure_ascii=False) + "\n", encoding="utf-8")
    print("отправлено владельцу")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
