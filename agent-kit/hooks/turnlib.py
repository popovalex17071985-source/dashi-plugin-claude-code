"""Общая нарезка транскрипта на ходы для Stop-хуков.

Каждый гейт нарезал транскрипт сам условием `type=="user" and not isMeta` — и
все шесть промахивались одинаково: ответы инструментов приходят тем же
type=="user" (их в 9 раз больше промптов) и isMeta у них нет, а настоящие
сообщения из телеграма, наоборот, помечены isMeta=true. Итог: «ходом» гейт
считал 1-3 записи после последнего tool_result, текста для оператора там уже нет —
и ни один гейт не срабатывал (проверено на живом транскрипте 14.08.2026).
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# Хук-контекст и системные врезки приходят тем же type=="user", что и оператор.
NOISE_RX = re.compile(
    r"^\s*(?:\[SYSTEM\]|Telegram bridge:|<relevant-memories>|\[прошлый ход|"
    r"context-economy|<system-reminder|<command-|Caveat:|This session is being continued)")


def is_prompt(e: dict) -> bool:
    """Настоящий ввод оператора: не tool_result и не врезка хука."""
    if e.get("type") != "user":
        return False
    c = (e.get("message") or {}).get("content")
    return isinstance(c, str) and bool(c.strip()) and not NOISE_RX.match(c)


def turn_entries(transcript: Path) -> list[dict]:
    """Записи транскрипта ПОСЛЕ последнего сообщения пользователя."""
    rows = []
    for line in Path(transcript).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    start = 0
    for i, e in enumerate(rows):
        if is_prompt(e):
            start = i
    return rows[start:]


def _selfcheck() -> None:
    tg = {"type": "user", "isMeta": True,
          "message": {"content": '<channel source="telegram"> Делаем </channel>'}}
    noise = {"type": "user", "isMeta": True,
             "message": {"content": "Telegram bridge: the sender reads Telegram"}}
    result = {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}}
    assert is_prompt(tg), "сообщение из телеграма — это промпт, несмотря на isMeta"
    assert not is_prompt(noise) and not is_prompt(result)
    print("turnlib: selfcheck ok")


if __name__ == "__main__":
    _selfcheck()
