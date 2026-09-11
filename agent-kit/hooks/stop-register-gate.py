#!/usr/bin/env python3
"""Stop hook — не дать ответить канцеляритом на разговорный заход Сани.

Саня, 10.08.2026: «сколько раз я просил — и что толку. Тебя хватает на три
фразы, а потом ты опять душный ублюдок». Правило про регистр в rules.md §6 с
июня, register-mirror.sh с июля — оба только СОВЕТУЮТ, и совет проигрывает
привычке к концу длинного ответа. Четвёртая поправка подряд по одному поводу
означает, что мягкий слой исчерпан.

Гейт: заход Сани разговорный (мат/сленг), ответ длинный, а в ответе ни одного
живого маркера и ни одной приметы разговорной речи -> блок, переписать.
Сухие короткие отчёты и цифры не трогаем: там регистр не нужен, и глушить
рабочую выдачу ради стиля — хуже болезни.

Best-effort: любая внутренняя ошибка = пропускаем ход (exit 0).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from turnlib import is_prompt  # noqa: E402

REPLY_TOOL = "mcp__dashi-channel__reply"
MIN_LEN = 400          # короткий ответ канцеляритом не бывает

CASUAL_IN = re.compile(
    r"бля|[нп]ахуй|хуй|хуя|хуё|пизд|ебан|ёбан|заеб|ебал|охуе|ахуе|нихуя|"
    r"(?:^|\s)(?:чо|чё|че|братан|бро|чувак)(?:\s|$|,)",
    re.IGNORECASE,
)
# Живая речь в МОЁМ ответе: сленг, прямое обращение, короткая рубка, бар Гуфа.
CASUAL_OUT = re.compile(
    r"бля|нахуй|хуй|пизд|нихуя|охуе|заеб|"
    r"(?:^|\s)(?:чо|чё|братан|короче|ладно|погнали|давай|ага|ну\s|фигня|"
    r"косяк|тупо|норм|жёстко|жестко|мутн)|guf|гуф",
    re.IGNORECASE,
)
# Канцелярит — то, за что он и злится.
FORMAL = re.compile(
    r"таким образом|в связи с этим|осуществ|данн(?:ый|ая|ые)\s|"
    r"необходимо\s+(?:выполнить|провести|обеспечить)|производится|"
    r"в рамках|с целью|представляется|следует отметить|"
    r"по итогам проведённ|в дальнейшем планируется",
    re.IGNORECASE,
)


def turn(transcript: Path) -> tuple[str, str]:
    """(последнее сообщение Сани; всё, что я ему отправил в этом ходе)."""
    rows = []
    for line in transcript.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    start = 0
    for i, e in enumerate(rows):
        if is_prompt(e):          # см. turnlib: telegram-промпты помечены isMeta
            start = i
    asked = json.dumps((rows[start].get("message") or {}).get("content", ""),
                       ensure_ascii=False) if rows else ""
    said = []
    for e in rows[start:]:
        if e.get("type") != "assistant":
            continue
        for b in (e.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use" \
                    and b.get("name") == REPLY_TOOL:
                said.append(str((b.get("input") or {}).get("text", "")))
    return asked, "\n".join(said)


def verdict(asked: str, said: str) -> str | None:
    if not CASUAL_IN.search(asked or ""):
        return None
    if len(said) < MIN_LEN:
        return None
    if CASUAL_OUT.search(said):
        return None
    return (
        "Саня зашёл в разговорном регистре, а ответ сухой и official-looking"
        f"{' (плюс канцелярит: ' + FORMAL.search(said).group(0) + ')' if FORMAL.search(said) else ''}"
        ". Это четвёртая поправка по одному поводу — правило и напоминалка уже "
        "не сработали.\n"
        "Перепиши ответ его языком: тот же расслабон, суть острая, без "
        "«таким образом» и «в рамках». Один уместный бар Гуфа — если ход не "
        "про сухие цифры или разбор ошибки."
    )


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("stop_hook_active"):
        return 0
    tp = data.get("transcript_path")
    if not tp or not Path(tp).exists():
        return 0
    try:
        why = verdict(*turn(Path(tp)))
    except Exception:
        return 0
    if why:
        print(json.dumps({"decision": "block", "reason": why}))
    return 0


def _selfcheck() -> None:
    dry = "Таким образом, в рамках задачи необходимо выполнить синхронизацию. " * 8
    live = "Короче, всё ровно: цены заморожены, косяк был мой. " * 8
    assert verdict("чо там блять по ценам", dry) is not None
    assert verdict("чо там блять по ценам", live) is None
    assert verdict("посчитай оборот", dry) is None          # заход сухой — не лезем
    assert verdict("блять чо там", "готово, 3 позиции") is None  # короткий ответ
    print("stop-register-gate: selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
