#!/usr/bin/env python3
"""Stop hook — каждый ход оставляет на диске состояние, а не в голове сессии.

Сессия обрывается на компакте, рестарте, ночью: всё, что не записано, пропадает
вместе с ней — где остановился, что недоделано, что обещал вернуть. Harness
Engineering, лекция 12 («Why Every Session Must Leave a Clean State»): конец
сессии обязан оставить чистое состояние, иначе следующая начинается с догадок.

Старый handoff.md был логом реплик (обрезанные User/Jarvis), из него не видно
ни что сделано, ни что висит. Здесь handoff собирается из ФАКТОВ хода: какие
файлы правились, какие коммиты легли, что я сам назвал следующим шагом.

Хранится 5 последних ходов; всё пишется временем Перми (сервер живёт в MSK).

Best-effort: любая внутренняя ошибка = ход не трогаем (exit 0).
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path("__WORKSPACE__")
HANDOFF = ROOT / ".claude/core/hot/handoff.md"
PERM = ZoneInfo("Asia/Yekaterinburg")
KEEP = 5
REPLY_TOOL = "mcp__dashi-channel__reply"
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}

# «дальше: X», «жду от тебя Y», «осталось Z» — то, что повиснет, если не записать
TAIL_RX = re.compile(
    r"^\s*(?:дальше|жду|осталось|предлагаю|нужно|надо)\b[^\n]{0,160}", re.IGNORECASE | re.M)
COMMIT_RX = re.compile(r"git\s+commit[^\n]*?-m\s+['\"](.+?)['\"]", re.S)


# Хук-контекст и системные врезки приходят тем же type=="user", что и Саня.
NOISE_RX = re.compile(
    r"^\s*(?:\[SYSTEM\]|Telegram bridge:|<relevant-memories>|\[прошлый ход|"
    r"context-economy|<system-reminder|<command-|Caveat:|This session is being continued)")


def is_prompt(e: dict) -> bool:
    """Настоящий ввод Сани, а не tool_result и не врезка хука.

    Две ловушки транскрипта: type=="user" носят и ответы инструментов (их в 9
    раз больше промптов), а сообщения из телеграма помечены isMeta=true — по
    isMeta их отсекать нельзя, иначе ход схлопывается и хук видит пустоту.
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


def user_ask(entries: list[dict]) -> str:
    """Что просил Саня — без служебной обёртки канала."""
    for e in entries:
        if not is_prompt(e):
            continue
        content = (e.get("message") or {}).get("content")
        text = content if isinstance(content, str) else " ".join(
            b.get("text", "") for b in content or [] if isinstance(b, dict))
        text = re.sub(r"<channel[^>]*>|</channel>", " ", text)
        text = re.sub(r"<media[^>]*/?>|<untrusted_metadata.*?</untrusted_metadata>", " ",
                      text, flags=re.S)
        text = re.sub(r"\s+", " ", text).strip()
        if text:
            return text[:200]
    return ""


def collect(entries: list[dict]) -> dict:
    """Факты хода: правленые файлы, коммиты, последний ответ Сане."""
    files, commits, said = [], [], []
    for e in entries:
        if e.get("type") != "assistant":
            continue
        for block in (e.get("message") or {}).get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name, inp = block.get("name") or "", block.get("input") or {}
            if name in EDIT_TOOLS:
                fp = str(inp.get("file_path", ""))
                if fp:
                    files.append(fp.replace(str(ROOT) + "/", ""))
            elif name == "Bash":
                commits += COMMIT_RX.findall(str(inp.get("command", "")))
            elif name == REPLY_TOOL:
                said.append(str(inp.get("text", "")))
    return {"files": list(dict.fromkeys(files)), "commits": commits,
            "said": said[-1] if said else ""}


def head_sha() -> str:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def block(entries: list[dict]) -> str | None:
    """Запись о ходе; None — если записывать нечего (пустая болтовня)."""
    facts = collect(entries)
    ask = user_ask(entries)
    if not facts["files"] and not facts["commits"] and not facts["said"]:
        return None
    now = datetime.now(PERM).strftime("%Y-%m-%d %H:%M")
    out = [f"### {now} (Пермь)", f"**Просили:** {ask or '—'}"]
    if facts["files"]:
        out.append("**Правил:** " + ", ".join(facts["files"][:8]))
    if facts["commits"]:
        out.append("**Коммиты:** " + " · ".join(facts["commits"][:4])
                   + (f" (HEAD {head_sha()})" if head_sha() else ""))
    tails = TAIL_RX.findall(facts["said"])
    if tails:
        out.append("**Открыто:** " + " · ".join(t.strip() for t in tails[:3]))
    return "\n".join(out) + "\n"


def merge(existing: str, new: str) -> str:
    """Новый блок сверху, хвост — предыдущие KEEP-1."""
    old = [b for b in re.split(r"(?m)^(?=### )", existing) if b.strip().startswith("### ")]
    body = "\n".join([new] + old[:KEEP - 1])
    return ("# handoff — состояние сессии (пишет hooks/session-state.py)\n"
            "# Последние 5 ходов: что просили, что правил, что осталось открытым.\n\n"
            + body)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    tp = data.get("transcript_path")
    if not tp or not Path(tp).exists():
        return 0
    try:
        b = block(turn_entries(Path(tp)))
        if not b:
            return 0
        prev = HANDOFF.read_text() if HANDOFF.exists() else ""
        HANDOFF.parent.mkdir(parents=True, exist_ok=True)
        HANDOFF.write_text(merge(prev, b))
    except Exception:
        return 0
    return 0


def _selfcheck() -> None:
    def call(name, inp):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": name, "input": inp}]}}

    entries = [
        {"type": "user", "message": {"content":
         '<channel source="telegram" chat_id="1"> почини УПД </channel>'}},
        call("Edit", {"file_path": str(ROOT / "bin/invoice/upd_pdf.py")}),
        call("Bash", {"command": "git add -A && git commit -q -m 'УПД: сетка по образцу'"}),
        call(REPLY_TOOL, {"text": "Поправил.\nдальше: гоняем через бота?\nжду токен от тебя"}),
    ]
    b = block(entries)
    assert "почини УПД" in b and "bin/invoice/upd_pdf.py" in b, b
    assert "УПД: сетка по образцу" in b, b
    assert "дальше: гоняем" in b and "жду токен" in b, b
    # Болтовня без правок и ответа — ничего не пишем.
    assert block([{"type": "user", "message": {"content": "привет"}}]) is None
    # Ротация: держим не больше KEEP блоков.
    text = merge("", b)
    for _ in range(7):
        text = merge(text, b)
    assert text.count("### ") == KEEP, text.count("### ")
    print("session-state: selfcheck ok")


if __name__ == "__main__":
    if "--selfcheck" in sys.argv:
        _selfcheck()
    else:
        sys.exit(main())
