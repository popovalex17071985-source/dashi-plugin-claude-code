#!/usr/bin/env python3
"""Сторож фоновых задач: ни одна не пропадает молча.

Дыра, которую он закрывает: задача запущена, процесс умер (кривой запуск,
OOM, убитый ssh), отчёта нет — и она «идёт» только у меня в голове. Реестр
`data/jobs.jsonl` ведёт bin/run-and-report.sh: строка на старте, отметка на
финише. Здесь ищем старты без финиша, у которых процесс уже мёртв, и пишем
о них хозяину. (Требование хозяина 11.09.2026: чтобы ни одна задача не терялась молча.)

Крон: раз в 2 минуты. Про каждую задачу говорим один раз.
"""
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path("__WORKSPACE__")
JOBS = ROOT / "data" / "jobs.jsonl"
TOLD = ROOT / "data" / "jobs-reported.json"
GRACE_SEC = 30          # задаче дают родиться, прежде чем считать её мёртвой


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def load_jobs() -> dict[str, dict]:
    """id -> запись; закрывающая строка гасит стартовую."""
    jobs: dict[str, dict] = {}
    if not JOBS.exists():
        return jobs
    for line in JOBS.read_text(encoding="utf-8").splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        jid = rec.get("id")
        if not jid:
            continue
        if rec.get("done"):
            jobs.pop(jid, None)         # финиш пришёл — задача закрыта
        else:
            jobs[jid] = rec
    return jobs


def main() -> int:
    told = set(json.loads(TOLD.read_text()) if TOLD.exists() else [])
    dead = []
    for jid, rec in load_jobs().items():
        if jid in told:
            continue
        started = datetime.fromisoformat(rec["started"])
        if (datetime.now() - started).total_seconds() < GRACE_SEC:
            continue
        if alive(int(rec.get("pid") or 0)):
            continue
        tail = ""
        log = rec.get("log")
        if log and Path(log).is_file():
            tail = "\n".join(Path(log).read_text(errors="ignore").splitlines()[-3:])[:300]
        dead.append((jid, rec["title"], started, tail))

    for jid, title, started, tail in dead:
        mins = int((datetime.now() - started).total_seconds() // 60)
        msg = (f"Задача «{title}» умерла и отчёта не будет: процесс пропал, "
               f"запущена {mins} мин назад.")
        if tail:
            msg += f"\n\nПоследнее из лога:\n{tail}"
        msg += "\n\nБерусь разбираться, скажу что было."
        subprocess.run([sys.executable, str(ROOT / "bin" / "tg-send.py"), msg], check=False)
        told.add(jid)

    if dead:
        TOLD.write_text(json.dumps(sorted(told)), encoding="utf-8")
    print(f"живых задач: {len(load_jobs())} | сообщено о мёртвых: {len(dead)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
