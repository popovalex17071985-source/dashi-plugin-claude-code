#!/usr/bin/env python3
"""Сколько на самом деле идёт задача — по факту прошлых прогонов, не по памяти.

    timing.py start <job>            -> печатает метку старта (ISO)
    timing.py end <job> [--note ...] -> закрывает последний открытый старт
    timing.py eta <job>              -> «обычно N мин (от A до B), замеров: K»
    timing.py add <job> <секунд>     -> вписать уже известный прогон

Причина: я называл сроки из головы, и они каждый раз врали (Саня, 28.08.2026).
Теперь срок = медиана реальных замеров или честное «не знаю, замеров нет».
"""
import json
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

PERM = timezone(timedelta(hours=5))
LOG = Path(__file__).resolve().parent.parent / "data" / "timings.jsonl"
OPEN = Path(__file__).resolve().parent.parent / "data" / "timings-open.json"


def _rows(job: str) -> list[float]:
    if not LOG.exists():
        return []
    out = []
    for line in LOG.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("job") == job and r.get("sec"):
            out.append(float(r["sec"]))
    return out


def _now() -> datetime:
    return datetime.now(PERM)


def record(job: str, sec: float, note: str = "") -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"job": job, "sec": round(sec, 1), "note": note,
                            "at": _now().isoformat(timespec="seconds")},
                           ensure_ascii=False) + "\n")


def eta(job: str) -> str:
    rows = _rows(job)
    if not rows:
        return f"«{job}»: замеров нет — срок назвать не могу, скажу по факту"
    med = statistics.median(rows) / 60
    lo, hi = min(rows) / 60, max(rows) / 60
    if len(rows) == 1:
        return f"«{job}»: один замер — {med:.0f} мин"
    return (f"«{job}»: обычно {med:.0f} мин "
            f"(от {lo:.0f} до {hi:.0f}), замеров: {len(rows)}")


def _open_load() -> dict:
    try:
        return json.loads(OPEN.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, job = sys.argv[1], sys.argv[2]
    if cmd == "start":
        d = _open_load()
        d[job] = _now().isoformat(timespec="seconds")
        OPEN.parent.mkdir(parents=True, exist_ok=True)
        OPEN.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        print(d[job])
    elif cmd == "end":
        d = _open_load()
        if job not in d:
            print(f"нет открытого старта для «{job}»", file=sys.stderr)
            return 1
        sec = (_now() - datetime.fromisoformat(d.pop(job))).total_seconds()
        note = " ".join(sys.argv[4:]) if "--note" in sys.argv else ""
        record(job, sec, note)
        OPEN.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
        print(f"{job}: {sec / 60:.1f} мин")
    elif cmd == "eta":
        print(eta(job))
    elif cmd == "add":
        record(job, float(sys.argv[3]), "внесено вручную")
        print(eta(job))
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


def demo() -> None:
    global LOG, OPEN
    import tempfile
    tmp = Path(tempfile.mkdtemp())
    LOG, OPEN = tmp / "t.jsonl", tmp / "o.json"
    assert "замеров нет" in eta("пусто")
    record("x", 1200)
    assert "один замер — 20 мин" in eta("x"), eta("x")
    record("x", 600)
    record("x", 1800)
    got = eta("x")
    assert "обычно 20 мин" in got and "от 10 до 30" in got and "замеров: 3" in got, got
    print("timing self-check ok")


if __name__ == "__main__":
    sys.exit(demo() if "--self-check" in sys.argv else main())
