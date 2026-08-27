#!/usr/bin/env python3
"""Stop hook — не дать закончить ход, где что-то СДЕЛАНО, но оператору не доложено.

оператор, 2026-07-30: «Ты не доводишь информацию что сделано получилось вот это вот.
Каждый раз приходится спрашивать». Правило про close-out в rules.md §3 есть с
23.07 и всё равно протекает: правило живёт в контексте, а контекст плывёт.
Поэтому — механизм: если в ходе были ИЗМЕНЯЮЩИЕ действия (Write/Edit, git commit,
--apply/--send, systemctl, crontab), а вызова reply не было, ход блокируется с
требованием доложить.

Терминальный текст оператор не видит: он читает Telegram. «Написал в терминал» —
это и есть та самая тишина, на которую он жалуется.

Best-effort: любая внутренняя ошибка = пропускаем ход (exit 0), гейт никогда не
должен стать причиной затыка.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent))
from turnlib import is_prompt  # noqa: E402

REPLY_TOOL = "mcp__dashi-channel__reply"
WRITE_TOOLS = {"Write", "Edit", "NotebookEdit"}
# Изменяющая команда в Bash: пишем в прод/репозиторий/расписание.
MUTATING_BASH = re.compile(
    r"git\s+(commit|push|tag)|--apply\b|--send\b|systemctl|crontab|"
    r"\bcp\b.*\.env|tee\s+/etc|insales|gws\s+(sheets|drive)",
    re.IGNORECASE,
)


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
        if is_prompt(e):          # см. turnlib: telegram-промпты помечены isMeta
            start = i
    return rows[start:]


def scan(entries: list[dict]) -> tuple[bool, bool]:
    """(были ли изменяющие действия, был ли reply)."""
    mutated = replied = False
    for e in entries:
        if e.get("type") != "assistant":
            continue
        for block in (e.get("message") or {}).get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name") or ""
            if name == REPLY_TOOL:
                replied = True
            elif name in WRITE_TOOLS:
                mutated = True
            elif name == "Bash" and MUTATING_BASH.search(
                    str((block.get("input") or {}).get("command", ""))):
                mutated = True
    return mutated, replied


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    # Повторный вызов после блокировки — не зацикливаемся.
    if data.get("stop_hook_active"):
        return 0
    tp = data.get("transcript_path")
    if not tp or not Path(tp).exists():
        return 0
    try:
        mutated, replied = scan(turn_entries(Path(tp)))
    except Exception:
        return 0
    if mutated and not replied:
        print(json.dumps({
            "decision": "block",
            "reason": "В этом ходе ты что-то изменил (правки/коммит/--apply/крон), "
                      "но не вызвал mcp__dashi-channel__reply. оператор читает Telegram, "
                      "терминал он не видит. Доложи одним сообщением: что сделано, "
                      "что проверено, и предложи следующий шаг.",
        }))
    return 0


def _selfcheck() -> None:
    def a(name, inp=None):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": name, "input": inp or {}}]}}
    assert scan([a("Edit")]) == (True, False)
    assert scan([a("Edit"), a(REPLY_TOOL)]) == (True, True)
    assert scan([a("Read"), a("Grep")]) == (False, False)
    assert scan([a("Bash", {"command": "git commit -m x"})]) == (True, False)
    assert scan([a("Bash", {"command": "ls -l"})]) == (False, False)
    assert scan([a("Bash", {"command": "python3 bin/x.py --send"})]) == (True, False)
    print("selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
