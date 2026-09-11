#!/usr/bin/env python3
"""Stop hook — не отчитываться о правке кода, ничего не прогнав.

Класс ошибки: правлю код и в том же ходе пишу хозяину «поправил / работает», хотя
результат не запускал и не смотрел. 14.08.2026 так вышло три круга правок УПД
подряд: вёрстку подгонял на глаз, границы таблицы «починил» — а вертикали граф
обрывались на первой позиции, увидел это хозяин, не я. Harness Engineering
(лекция 9, «Why Agents Declare Victory Too Early») формулирует лечение так:
решение «готово» нельзя оставлять агенту, его выносят в обвязку — успех
признаётся по признаку прогона, а не по уверенности.

Гейт узкий: блокирует, только когда в ходе (1) правился файл кода, (2) в
сообщении хозяину есть заявление о результате и (3) после последней правки не было
НИ ОДНОГО прогона — ни запуска, ни просмотра рендера. Прогнал что угодно — гейт
молчит.

Best-effort: любая внутренняя ошибка = пропускаем ход (exit 0).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPLY_TOOL = "mcp__dashi-channel__reply"
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
CODE_SUFFIX = (".py", ".js", ".ts", ".mjs", ".cjs", ".sh", ".sql", ".html", ".css")
# Просмотр результата тоже проверка: рендер страницы, скрин, PDF.
LOOK_SUFFIX = (".png", ".jpg", ".jpeg", ".pdf", ".webp")

# Запуск, а не осмотр репозитория: git status/ls/grep кодом не проверяют.
RUN_RX = re.compile(
    r"(?:^|[|;&]\s*|\bcd\s+\S+\s*&&\s*)"
    r"(?:python\d?|\.venv[^\s]*|node|bun|npx|npm|pytest|ruff|bash|sh|make|"
    r"curl|systemctl|pdftoppm|pdfinfo|\./)",
)
# Заявление о результате — то, ради чего гейт и стоит.
CLAIM_RX = re.compile(
    r"\b(?:сделал|готово|поправил|исправил|починил|добавил|переделал|обновил|"
    r"работает|запустил|настроил|внедрил|закоммитил)\b",
    re.IGNORECASE,
)


# Хук-контекст и системные врезки приходят тем же type=="user", что и хозяин.
NOISE_RX = re.compile(
    r"^\s*(?:\[SYSTEM\]|Telegram bridge:|<relevant-memories>|\[прошлый ход|"
    r"context-economy|<system-reminder|<command-|Caveat:|This session is being continued)")


def is_prompt(e: dict) -> bool:
    """Настоящий ввод хозяина: не tool_result и не врезка хука.

    Сообщения из телеграма помечены isMeta=true — отсекать по isMeta нельзя,
    иначе ход схлопывается до последнего вызова и гейт смотрит в пустоту.
    """
    if e.get("type") != "user":
        return False
    c = (e.get("message") or {}).get("content")
    return isinstance(c, str) and bool(c.strip()) and not NOISE_RX.match(c)


def turn_entries(transcript: Path) -> list[dict]:
    """Записи транскрипта ПОСЛЕ последнего сообщения пользователя."""
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
        if is_prompt(e):
            start = i
    return rows[start:]


def scan(entries: list[dict]) -> tuple[str, int, int]:
    """(текст хозяину; позиция последней правки кода; позиция последнего прогона).

    Позиции — порядковые номера вызовов инструментов в ходе; -1 = не было.
    """
    said, last_edit, last_run, n = [], -1, -1, 0
    for e in entries:
        if e.get("type") != "assistant":
            continue
        for block in (e.get("message") or {}).get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name, inp = block.get("name") or "", block.get("input") or {}
            n += 1
            if name == REPLY_TOOL:
                said.append(str(inp.get("text", "")))
            elif name in EDIT_TOOLS:
                if str(inp.get("file_path", "")).endswith(CODE_SUFFIX):
                    last_edit = n
            elif name == "Bash":
                if RUN_RX.search(str(inp.get("command", ""))):
                    last_run = n
            elif name == "Read":
                if str(inp.get("file_path", "")).lower().endswith(LOOK_SUFFIX):
                    last_run = n
            elif name == "Task":          # проверку мог сделать субагент
                last_run = n
    return "\n".join(said), last_edit, last_run


def verdict(text: str, last_edit: int, last_run: int) -> str | None:
    """Причина блокировки или None."""
    if last_edit < 0 or not text or not CLAIM_RX.search(text):
        return None
    if last_run > last_edit:
        return None
    return (
        "Ты правил код и отчитываешься хозяину о результате, но после последней "
        "правки НИЧЕГО не прогнал: ни запуска, ни теста, ни просмотра рендера.\n"
        "Ровно так 14.08 вышло три круга правок УПД — «починил» оказалось "
        "непроверенным, ошибку нашёл хозяин.\n"
        "Прогони то, что правил (тест, скрипт, ридбек, рендер картинкой), "
        "и только потом отчитывайся. Если проверить нечем — скажи это прямо "
        "вместо «сделал»."
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
        why = verdict(*scan(turn_entries(Path(tp))))
    except Exception:
        return 0
    if why:
        print(json.dumps({"decision": "block", "reason": why}))
    return 0


def _selfcheck() -> None:
    def call(name, inp):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": name, "input": inp}]}}

    edit = call("Edit", {"file_path": "/home/x/bin/upd_pdf.py"})
    doc = call("Write", {"file_path": "/home/x/core/LEARNINGS.md"})
    run = call("Bash", {"command": "cd /home/x && .venv-bot/bin/python test_bot.py"})
    git = call("Bash", {"command": "git add -A && git commit -q -m 'фикс'"})
    look = call("Read", {"file_path": "/tmp/render-1.png"})
    done = call(REPLY_TOOL, {"text": "Поправил, границы на месте."})
    chat = call(REPLY_TOOL, {"text": "Принято, смотрю."})

    # Правка кода + отчёт без прогона — блок.
    assert verdict(*scan([edit, done])) is not None
    # git commit прогоном не считается.
    assert verdict(*scan([edit, git, done])) is not None
    # Прогнал тест — пропускаем.
    assert verdict(*scan([edit, run, done])) is None
    # Посмотрел рендер — тоже проверка.
    assert verdict(*scan([edit, look, done])) is None
    # Прогон был ДО правки, а после неё нет — блок.
    assert verdict(*scan([run, edit, done])) is not None
    # Правка без заявления о результате — не трогаем.
    assert verdict(*scan([edit, chat])) is None
    # Правился только документ — гейт не про это.
    assert verdict(*scan([doc, done])) is None
    print("stop-verify-gate: selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
