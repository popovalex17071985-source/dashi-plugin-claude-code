#!/usr/bin/env python3
"""Stop hook — не дать сдать «не могу / нужны права / нет данных» без перебора.

оператор, 2026-07-31 (голосом, зло): «Сначала ты не смог выявить завершённые заказы,
потом смог. Потом не смог найти менеджера, потом смог. И так в каждой задаче —
сначала на отъебись, потом нормально. Что заложить, чтобы ты пробовал ВСЕ
способы без моих пинков?»

Разбор в тот же день: оба провала — один сценарий. Упёрся в первый отказ (401 на
справочнике; поле с подходящим именем) и объявил это выводом, хотя проверил один
путь из пяти. Правило «перепробуй методы» в памяти есть с июня и не срабатывает:
правило вспоминается ПОСЛЕ пинка, потому что в момент отправки я уверен, что уже
всё выяснил. Уверенность правилами не лечится — только гейтом.

Гейт: если в сообщении оператору есть отказная формулировка («не могу», «закрыто
правами», «нет доступа», «недоступно», «жду от тебя», «блокер»), ход
блокируется, пока в ЭТОМ же ходе нет обоих признаков реального перебора:
  1. хотя бы MIN_PROBES исследовательских вызовов (Bash/Read/Grep/Glob/WebFetch);
  2. в самом тексте перечислено, что именно пробовал и чем это кончилось.

Отказ, переживший оба условия, — это уже вывод, а не капитуляция.

Best-effort: любая внутренняя ошибка = пропускаем ход (exit 0).
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
PROBE_TOOLS = {"Bash", "Read", "Grep", "Glob", "WebFetch", "WebSearch"}
MIN_PROBES = 6

# Формулировки, которыми я перекладываю задачу обратно на оператора.
BLOCKER = re.compile(
    r"не мог[ую]\b|невозможно|нельзя\s+(?:достать|получить|вытащить)|"
    r"закрыт[аоы]?\s+прав|нет\s+(?:доступа|прав|данных|такого поля)|недоступ|"
    r"упира(?:ю|е)тся\s+в\s+прав|нужно\s+открыть\s+на\s+стороне|"
    r"жду\s+от\s+тебя|блокер|разреза\s+.{0,20}нет",
    re.IGNORECASE,
)
# Вердикт «система сломана» по показанию СВОЕГО пробника (6 раз за 17–20.08:
# 2ГИС 401 из консоли, attr-cache по mtime, «кнопка работает» по соседям…).
# Режим WARN первую неделю (оператор 23.08): пишем в лог + systemMessage, не блокируем.
BROKEN = re.compile(
    r"\b(?:умер|умерла|сломан[аоы]?|не\s+работает|перестал[аио]?\s+работать|"
    r"отвалил[аио]?с[ья]|закрыли\s+доступ|конвейера\s+нет|не\s+отправля[её]тся)\b",
    re.IGNORECASE,
)
SECOND_CHECK = re.compile(
    r"проверил\s+(?:вторым|другим|ещё одним)\s+(?:путём|способом|инструментом)|"
    r"перепроверил|подтвердил\s+(?:через|по)\s+|из\s+(?:двух|2)\s+источник",
    re.IGNORECASE,
)
BROKEN_MIN_PROBES = 2
BROKEN_MODE = "warn"          # "warn" → лог + systemMessage; "block" → как BLOCKER
BROKEN_LOG = Path("__WORKSPACE__/logs/stop-gate-broken.log")

# Следы предъявленного перебора: что пробовал и почему не вышло.
TRIED = re.compile(
    r"пробовал|перебрал|проверил\s+(?:все|оба|три|\d)|"
    r"не\s+сработал|отда[её]т\s+40\d|вернул\s+40\d|"
    r"путь\s+\d|вариант\s+\d|способ\s+\d",
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


def scan(entries: list[dict]) -> tuple[str, int]:
    """(текст, отправленный оператору; число исследовательских вызовов)."""
    said, probes = [], 0
    for e in entries:
        if e.get("type") != "assistant":
            continue
        for block in (e.get("message") or {}).get("content") or []:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name") or ""
            if name == REPLY_TOOL:
                said.append(str((block.get("input") or {}).get("text", "")))
            elif name in PROBE_TOOLS:
                probes += 1
    return "\n".join(said), probes


def verdict(text: str, probes: int) -> str | None:
    """Причина блокировки или None, если отказ обоснован."""
    if not text or not BLOCKER.search(text):
        return None
    if probes >= MIN_PROBES and TRIED.search(text):
        return None
    return (
        "Ты сдаёшь оператору отказ («не могу / закрыто правами / жду от тебя»), "
        f"а перебора не видно: исследовательских проб в ходе {probes} "
        f"(нужно >= {MIN_PROBES}), перечня попыток в тексте "
        f"{'нет' if not TRIED.search(text) else 'да'}.\n"
        "Прежде чем отдавать задачу обратно: тот же объект под другим именем; "
        "соседний справочник/эндпоинт; $expand или вложенные поля документа; "
        "вычислить признак из уже доступных данных; посмотреть, что видит "
        "оператор в интерфейсе, и искать ИМЕННО это поле. "
        "Не вышло — в ответе перечисли, что пробовал и чем кончилось."
    )


def broken_verdict(text: str, probes: int) -> str | None:
    """«Сломано/не работает» без второй проверки — причина или None."""
    if not text or not BROKEN.search(text):
        return None
    if probes >= BROKEN_MIN_PROBES and SECOND_CHECK.search(text):
        return None
    return (
        "Ты объявляешь систему сломанной («умер / не работает / закрыли доступ»), "
        f"а второй проверки не видно: проб {probes} (нужно >= {BROKEN_MIN_PROBES}), "
        "фразы «проверил вторым путём: …» в тексте "
        f"{'нет' if not SECOND_CHECK.search(text) else 'да'}. "
        "Показание своего пробника ≠ состояние системы: перепроверь другим инструментом "
        "(curl вместо playwright, API вместо UI, соседний эндпоинт) и назови его в ответе."
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
    try:
        text, probes = scan(turn_entries(Path(tp)))
        bw = broken_verdict(text, probes)
    except Exception:
        return 0
    if bw:
        if BROKEN_MODE == "block":
            print(json.dumps({"decision": "block", "reason": bw}))
        else:
            import datetime as _dt
            with BROKEN_LOG.open("a") as f:
                f.write(f"{_dt.datetime.now().isoformat(timespec='seconds')} probes={probes} "
                        f"match={BROKEN.search(text).group(0)!r} text={text[:160]!r}\n")
            print(json.dumps({"systemMessage": "stop-gate [warn]: " + bw[:200]}))
    return 0


def _selfcheck() -> None:
    def reply(text):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": REPLY_TOOL, "input": {"text": text}}]}}

    def probe():
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}}

    # отказ без перебора — блокируем
    assert verdict("Справочник закрыт правами, нужно открыть на стороне 1С", 2)
    # отказ после честного перебора и с перечнем попыток — пропускаем
    ok = ("Не могу достать: пробовал прямой справочник (401), $expand (401), "
          "соседний Catalog_Сотрудники — не сработал, вариант 3 тоже.")
    assert verdict(ok, 9) is None, "честный перебор не должен блокироваться"
    # много проб, но без перечня — всё равно блок: оператор должен видеть, что искал
    assert verdict("Нет доступа к справочнику.", 20)
    # обычный отчёт без отказа — не наше дело
    assert verdict("Готово, отчёт собран, маржа 27 252.", 1) is None
    assert verdict("", 0) is None
    text, probes = scan([reply("нет прав"), probe(), probe()])
    assert text == "нет прав" and probes == 2, (text, probes)
    print("selfcheck ok")


if __name__ == "__main__":
    sys.exit(_selfcheck() if "--selfcheck" in sys.argv else main())
