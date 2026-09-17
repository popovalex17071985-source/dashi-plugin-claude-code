#!/usr/bin/env python3
"""Держит индекс памяти в пределах лимита -- сам, без напоминаний.

MEMORY.md подгружается в КАЖДУЮ сессию целиком. Перерастёт лимит -- обрезается
на входе молча, и агент теряет часть собственной памяти, не зная об этом
(Jarvis, 17.09.2026: 34,8 КБ при потолке 24,4, хвост индекса не доезжал).

Что делает: длинные строки ужимает до `LINE_MAX` байт (имя и ссылка остаются,
режется только хвост-пояснение -- подробности живут в самом файле памяти).
Если и этого мало, самые старые пункты уезжают в MEMORY-archive.md. Ссылки при
этом не теряются: те, что срезало вместе с хвостом, дописываются отдельным
блоком в конце.

  python3 bin/memory-index-trim.py            # проверить и доложить
  python3 bin/memory-index-trim.py --apply    # ужать
"""
from __future__ import annotations

import pathlib
import re
import sys

LIMIT = 24 * 1024        # потолок, после которого индекс режется на входе
TARGET = 21 * 1024       # до чего ужимаем: запас и на новые записи, и на блок ссылок
LINE_MAX = 140           # байт на строку индекса: имя, ссылка, короткий хвост
ARCH_STEP = 10           # сколько пунктов уносим в архив за один заход

LINK = re.compile(r"\(([A-Za-z0-9_\-]+\.md)\)")
TAIL = re.compile(r"^(.*?)( — | -- )(.*)$")


def size(text: str) -> int:
    return len(text.encode("utf-8"))


def squeeze(line: str, limit: int = LINE_MAX) -> str:
    if not line.startswith("- ") or size(line) <= limit:
        return line
    m = TAIL.match(line)
    if not m:
        return line
    head, sep, tail = m.groups()
    room = limit - size(head) - size(sep)
    if room < 25:
        return head
    out: list[str] = []
    for w in tail.split():
        if size(" ".join(out + [w])) > room:
            break
        out.append(w)
    return head + sep + " ".join(out) + "…" if out else head


def indexes() -> list[pathlib.Path]:
    root = pathlib.Path.home() / ".claude" / "projects"
    return sorted(root.glob("*/memory/MEMORY.md")) if root.exists() else []


def trim(path: pathlib.Path, apply: bool) -> str:
    text = path.read_text(encoding="utf-8")
    before = size(text)
    if before <= LIMIT:
        return f"{path.parent.parent.name}: {before} Б -- в норме"

    lines = text.splitlines()
    kept = [squeeze(x) for x in lines]
    arch = path.with_name("MEMORY-archive.md")
    moved: list[str] = []
    # Ужимки не хватило -- уносим хвост списка (самое старое) в архив.
    while size("\n".join(kept)) > TARGET and sum(1 for x in kept if x.startswith("- ")) > 40:
        for i in range(len(kept) - 1, -1, -1):
            if kept[i].startswith("- "):
                moved.append(kept.pop(i))
                break
        if len(moved) % ARCH_STEP == 0 and size("\n".join(kept)) <= TARGET:
            break

    # Ссылка не должна пропасть вместе с обрезанным хвостом.
    had = set(LINK.findall(text))
    now = set(LINK.findall("\n".join(kept))) | set(LINK.findall("\n".join(moved)))
    lost = sorted(had - now)
    if lost:
        kept.append("")
        kept.append("## Ещё по темам (ссылки без описания)")
        row = " · ".join(f"[{n[:14]}]({n})" for n in lost)
        kept.append(f"- {row}")

    out = "\n".join(kept).rstrip() + "\n"
    report = (f"{path.parent.parent.name}: {before} Б -> {size(out)} Б, "
              f"в архив {len(moved)}, ссылок спасено {len(lost)}")
    if not apply:
        return report + " (ничего не менял, нужен --apply)"

    if moved:
        old = arch.read_text(encoding="utf-8").rstrip() if arch.exists() else "# Memory archive"
        arch.write_text(old + "\n\n## Снято с активного индекса\n" + "\n".join(moved) + "\n",
                        encoding="utf-8")
    path.write_text(out, encoding="utf-8")
    return report


def main() -> int:
    apply = "--apply" in sys.argv
    found = indexes()
    if not found:
        print("индекса памяти нет -- нечего проверять")
        return 0
    for p in found:
        print(trim(p, apply))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
