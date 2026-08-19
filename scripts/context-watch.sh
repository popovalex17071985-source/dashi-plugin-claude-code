#!/usr/bin/env bash
# context-watch.sh — UserPromptSubmit-хук: следит, насколько заполнен контекст
# сессии, и подсказывает агенту сказать об этом хозяину человеческим языком.
#
# Зачем: человек не видит, что «память разговора» подходит к концу. Агент
# начинает тупить и терять нить, а причина невидима. Хук читает расход токенов
# из транскрипта сессии и на 70% / 85% один раз подсовывает агенту напоминание
# «скажи хозяину: /compact или /new».
#
# Никогда не блокирует ход: любая ошибка = молча выходим с кодом 0.
set -uo pipefail

WINDOW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-200000}"
WARN=70   # процент — «пора сжимать»
HIGH=85   # процент — «пора начинать заново»

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tp="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
[[ -f "$tp" ]] || exit 0

# Последний ход с usage: input + оба кэша = сколько сейчас занято в окне.
used="$(tail -n 400 "$tp" 2>/dev/null | jq -s '
  [ .[] | select(.message.usage != null) | .message.usage ] | last
  | if . == null then 0
    else (.input_tokens // 0) + (.cache_read_input_tokens // 0)
         + (.cache_creation_input_tokens // 0) end' 2>/dev/null)"
[[ "$used" =~ ^[0-9]+$ ]] && (( used > 0 )) || exit 0

pct=$(( used * 100 / WINDOW ))
(( pct >= WARN )) || exit 0
band=$(( pct >= HIGH ? HIGH : WARN ))

# Одно напоминание на порог на сессию — иначе это шум каждый ход.
state="${XDG_CACHE_HOME:-$HOME/.cache}/context-watch"
mkdir -p "$state" 2>/dev/null || exit 0
mark="$state/$sid.$band"
[[ -e "$mark" ]] && exit 0
: > "$mark"

if (( band >= HIGH )); then
  msg="Контекст сессии заполнен на ${pct}%. ПЕРВЫМ ДЕЛОМ скажи хозяину через reply, своими словами и без терминов: память разговора почти кончилась, дальше начну терять детали. Если тема закрыта — /new (чистый лист), если её надо продолжить — /compact (сожму, суть останется). Потом отвечай на сам вопрос."
else
  msg="Контекст сессии заполнен на ${pct}%. Скажи об этом хозяину одной строкой в конце ответа, простыми словами: место в разговоре заканчивается, /compact сожмёт и продолжит, /new начнёт с чистого листа. Не паникуй и не повторяй это каждый ход."
fi

jq -nc --arg m "$msg" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'
exit 0
