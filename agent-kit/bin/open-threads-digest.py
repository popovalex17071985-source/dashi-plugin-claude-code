#!/usr/bin/env python3
"""Утренняя сводка незакрытых тредов: что висит на мне, что на оператор (30.07).

Гейт на завершение хода ловит «сделал и не сказал» внутри одного хода. А тред,
который тянется днями и ждёт чужого действия, не ловит ничто — он просто тихо
лежит в `core/open-threads.md`, пока оператор о нём не вспомнит. Эта сводка и есть
недостающий уровень: раз в день вслух проговариваем, кто кого ждёт.

Разделение простое: пункт помечен ожиданием оператор (ЖДЁМ/ЖДУ ФОТО/PENDING НА САНЕ/
напомнить оператор) — значит мяч у него, иначе у меня.

  python3 bin/open-threads-digest.py           # показать
  python3 bin/open-threads-digest.py --send
"""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LEDGER = ROOT / ".claude/core/open-threads.md"
TG = ROOT / "bin/tg-send.py"
MAX_ITEMS = 200        # оператор 27.08: показывать ВСЕ пункты, не сводку
FRESH_DAYS = 21        # реестр append-only и распух: старьё в сводку не тащим,
                       # оно требует ручной чистки, а не ежедневного напоминания
WIDTH = 400            # полный текст пункта; обрезаем только совсем длинные

DATE_RE = re.compile(r"(20\d{2})-(\d{2})-(\d{2})|\b(\d{2})\.(\d{2})(?:\.(20\d{2}))?\b")

ON_SANYA = re.compile(r"ЖД[ЁЕ]М|ЖДУ|PENDING|напомнить\s+хозяину|"
                      r"ждём\s+(?:от\s+)?Сан|решени[ея]\s+оператор|за\s+Саней", re.IGNORECASE)


def items() -> list[tuple[str, bool]]:
    """Незакрытые пункты реестра: (текст с переносами, лежит ли в секции «Ждут хозяина»)."""
    out, cur, on_sanya = [], None, False
    for ln in LEDGER.read_text().splitlines():
        if ln.startswith("## Архив"):
            break          # свёрнутое старьё в сводку не тянем
        if ln.startswith("## "):
            on_sanya = "Ждут хозяина" in ln
            cur = None
            continue
        if ln.startswith("- [ ]"):
            cur = ln[5:].strip()
            out.append((cur, on_sanya))
        elif ln.startswith("- [x]") or ln.startswith("#"):
            cur = None
        elif cur is not None and ln.startswith("  ") and ln.strip():
            out[-1] = (out[-1][0] + " " + ln.strip(), out[-1][1])
    return out


def fresh(rows: list[tuple[str, bool]], today: dt.date) -> tuple[list[tuple[str, bool]], int]:
    """Пункты свежее FRESH_DAYS. Без даты — оставляем: молчать о них опаснее."""
    keep, old = [], 0
    for r in rows:
        m = DATE_RE.search(r[0][:40])
        if not m:
            keep.append(r)
            continue
        try:
            d = (dt.date(int(m[1]), int(m[2]), int(m[3])) if m[1]
                 else dt.date(int(m[6] or today.year), int(m[5]), int(m[4])))
        except ValueError:
            keep.append(r)
            continue
        if (today - d).days <= FRESH_DAYS:
            keep.append(r)
        else:
            old += 1
    return keep, old


DEADLINE_RE = re.compile(r"срок\s+(?:до\s+)?(\d{2})\.(\d{2})(?:\.(20\d{2}))?"
                         r"|срок\s+(?:до\s+)?(20\d{2})-(\d{2})-(\d{2})", re.I)


def deadline(row: str, today: dt.date) -> dt.date | None:
    """Дата из «срок 05.08» — год подставляем текущий, если не написан."""
    m = DEADLINE_RE.search(row)
    if not m:
        return None
    d, mo, y, y2, mo2, d2 = m.groups()
    try:
        return (dt.date(int(y2), int(mo2), int(d2)) if y2
                else dt.date(int(y or today.year), int(mo), int(d)))
    except ValueError:
        return None


def overdue(rows: list[str], today: dt.date) -> list[tuple[int, str]]:
    """Обещания с наступившим сроком — [(на сколько дней просрочено, строка)].

    Без этого обещание со сроком лежит рядовой строкой в списке из двадцати и
    молчит. Так сгорело демо контент-завода: срок 05.08, оператор узнал 06.08 сам.
    """
    out = []
    for r in rows:
        d = deadline(r[0] if isinstance(r, tuple) else r, today)
        if d and d <= today:
            out.append(((today - d).days, r[0] if isinstance(r, tuple) else r))
    return sorted(out, reverse=True)


def split(rows: list[tuple[str, bool]]) -> tuple[list[str], list[str]]:
    """Секция «## Ждут хозяина» — источник истины; без секций — старый regex-фолбэк."""
    if any(f for _, f in rows):
        return [r for r, f in rows if not f], [r for r, f in rows if f]
    return ([r for r, _ in rows if not ON_SANYA.search(r)],
            [r for r, _ in rows if ON_SANYA.search(r)])


def short(s: str) -> str:
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= WIDTH else s[:WIDTH - 1] + "…"


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _section(title: str, rows: list[str], start_no: int,
             prefix=lambda r: "") -> tuple[str, int]:
    """One section rendered as its own message: header + expandable list."""
    n = start_no
    lines = []
    for r in rows[:MAX_ITEMS]:
        n += 1
        lines.append(esc(f"{n}. {prefix(r)}{short(r if isinstance(r, str) else r[1])}"))
    if len(rows) > MAX_ITEMS:
        lines.append(f"…и ещё {len(rows) - MAX_ITEMS}")
    head = f"{title} — <b>{len(rows)}</b>"
    return head + "\n<blockquote expandable>" + "\n".join(lines) + "</blockquote>", n


def messages(mine: list[str], sanya: list[str],
             late: list[tuple[int, str]] | None = None) -> list[str]:
    """Separate message per section (operator 2026-08-27), numbered straight through.

    Each section is chunked on its own if it exceeds the Telegram limit, so a
    section never leaks into a neighbour's message.
    """
    if not mine and not sanya:
        return ["Открытых дел нет — всё закрыто."]

    out, n = [], 0
    if late:
        rows = [f"[{'+' + str(d) + ' дн' if d else 'срок сегодня'}] {r}" for d, r in late]
        block, n = _section("🔴 <b>Просрочено</b>", rows, n)
        out.append(block)
    if sanya:
        block, n = _section("📋 <b>Ждут тебя</b>", sanya, n)
        out.append(block)
    if mine:
        block, n = _section("🔧 <b>На мне</b>", mine, n)
        out.append(block + "\nЗакрыть — напиши «закрой 3, 12» по номерам из этого списка.")
    return [part for block in out for part in chunks(block)]


TG_LIMIT = 3800        # 4096 minus room for the blockquote wrapper


def chunks(msg: str) -> list[str]:
    """Split a long digest into whole-line parts, each its own expandable block.

    Telegram caps a message at 4096 chars and the full ledger is ~12K — without
    this the tail is silently dropped, which is exactly the "show me everything"
    the operator asked for going missing.
    """
    if len(msg) <= TG_LIMIT:
        return [msg]
    head, rest = msg.split("<blockquote expandable>", 1)
    body, tail = rest.rsplit("</blockquote>", 1)
    parts, cur = [], []
    size = 0
    for line in body.split("\n"):
        if size + len(line) + 1 > TG_LIMIT - len(head) - 60 and cur:
            parts.append(cur)
            cur, size = [], 0
        cur.append(line)
        size += len(line) + 1
    if cur:
        parts.append(cur)
    out = []
    for i, chunk in enumerate(parts, 1):
        mark = f" ({i}/{len(parts)})" if len(parts) > 1 else ""
        out.append(head.rstrip() + mark + "\n<blockquote expandable>"
                   + "\n".join(chunk).strip() + "</blockquote>")
    out[-1] += tail
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--send", action="store_true")
    a = ap.parse_args()
    today = dt.date.today()
    all_rows = items()
    rows, old = fresh(all_rows, today)
    mine, sanya = split(rows)
    # просрочку ищем по ВСЕМУ реестру: обещание могло быть дано месяц назад,
    # и фильтр «свежие» его как раз выкидывает.
    msgs = messages(mine, sanya, overdue(all_rows, today))
    if old:
        msgs[-1] += f"\nСтарше {FRESH_DAYS} дней и не разобрано: {old} — нужна чистка реестра."
    print("\n\n--- следующее сообщение ---\n\n".join(msgs))
    if a.send:
        for part in msgs:
            subprocess.run([sys.executable, str(TG), part, "--html"], check=False)
    return 0


def _selfcheck() -> None:
    rows = [("28.07 АКСЕССУАРЫ — ЖДЁМ ФОТО ОТ САНИ на 19 карточек", False),
            ("Б/У чистка: нужен разовый добор реестра", False),
            ("PENDING НА САНЕ: отозвать ключ OpenAI", False)]
    mine, sanya = split(rows)   # без секций — regex-фолбэк
    assert len(sanya) == 2 and len(mine) == 1, (mine, sanya)
    mine2, sanya2 = split([("на мне", False), ("ждёт оператор по секции", True)])
    assert sanya2 == ["ждёт оператор по секции"] and mine2 == ["на мне"], (mine2, sanya2)
    ms = messages(mine, sanya)
    assert len(ms) == 2, ms                      # две секции — два сообщения
    assert "Ждут тебя</b> — <b>2" in ms[0] and "На мне</b> — <b>1" in ms[1]
    assert ms[0].count("<blockquote expandable>") == 1
    assert "1. " in ms[0] and "3. " in ms[1], "сквозная нумерация не проставилась"
    assert "&lt;" in messages(["<script> в тексте"], [])[0]  # HTML экранируется
    assert "нет" in messages([], [])[0]
    assert short("x" * (WIDTH + 70)).endswith("…") and len(short("x" * (WIDTH + 70))) == WIDTH
    keep, old = fresh([("2026-01-01 древний", False), ("2026-07-29 свежий", False),
                       ("без даты", False)], dt.date(2026, 7, 30))
    assert keep == [("2026-07-29 свежий", False), ("без даты", False)] and old == 1, (keep, old)
    # Before installation the ledger lives elsewhere — skip, don't fail the check.
    if LEDGER.exists():
        assert items(), "реестр найден, но пуст"
    t = dt.date(2026, 8, 6)
    assert deadline("НА МНЕ, срок 05.08: демо", t) == dt.date(2026, 8, 5)
    assert deadline("срок 2026-09-01: X", t) == dt.date(2026, 9, 1)
    assert deadline("срок 31.02: битая дата", t) is None
    assert deadline("без срока", t) is None
    late = overdue(["срок 05.08: вчера", "срок 06.08: сегодня", "срок 09.08: потом"], t)
    assert [d for d, _ in late] == [1, 0], late
    assert "Просрочено" in messages(["a"], [], [(3, "срок 03.08: X")])[0]
    big = messages(["x" * 300] * 40, ["y" * 300] * 10)
    assert all(len(c) <= 4096 for c in big), [len(c) for c in big]
    assert sum(c.count("<blockquote") for c in big) == len(big)  # блок в каждой части
    assert chunks("short") == ["short"]
    print("selfcheck ok")


if __name__ == "__main__":
    sys.exit(_selfcheck() if "--selfcheck" in sys.argv else main())
