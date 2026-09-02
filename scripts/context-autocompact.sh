#!/usr/bin/env bash
# context-autocompact.sh — Stop-хук: когда контекст сессии заполнен на HIGH% и больше,
# сам набирает /compact в tmux-пане этой сессии, чтобы не упереться в потолок посреди
# задачи (Саня 01.09.2026: «автоматически подрезать при 85%»).
#
# Почему Stop, а не UserPromptSubmit: на Stop Claude свободен, /compact выполняется
# сразу и чисто; посреди хода команда встала бы в очередь и порвала бы задачу.
# Никогда не блокирует ход: любая ошибка = молча выходим с кодом 0.
# ponytail: считаем расход так же, как context-watch.sh (последний usage в транскрипте).
WINDOW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-200000}"
HIGH="${CONTEXT_AUTOCOMPACT_PCT:-85}"
COOLDOWN=600   # секунд между двумя авто-сжатиями одной сессии
input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
tp="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
[[ -f "$tp" ]] || exit 0
used="$(tail -n 400 "$tp" 2>/dev/null | jq -s '
  [ .[] | select(.message.usage != null) | .message.usage ] | last
  | if . == null then 0
    else (.input_tokens // 0) + (.cache_read_input_tokens // 0)
         + (.cache_creation_input_tokens // 0) end' 2>/dev/null)"
[[ "$used" =~ ^[0-9]+$ ]] && (( used > 0 )) || exit 0
pct=$(( used * 100 / WINDOW ))
(( pct >= HIGH )) || exit 0
state="${XDG_CACHE_HOME:-$HOME/.cache}/context-watch"
mkdir -p "$state" 2>/dev/null || exit 0
mark="$state/$sid.autocompact"
now=$(date +%s)
if [[ -f "$mark" ]] && (( now - $(cat "$mark" 2>/dev/null || echo 0) < COOLDOWN )); then exit 0; fi
printf '%s' "$now" > "$mark"
if [[ -n "${CONTEXT_AUTOCOMPACT_DRY_RUN:-}" ]]; then echo "would /compact: ${pct}% of ${WINDOW}"; exit 0; fi
[[ -n "${TMUX_PANE:-}" ]] || exit 0
# Enter отдельным нажатием и с паузой: Claude дочитывает команду, потом подтверждает.
tmux send-keys -t "$TMUX_PANE" -l "/compact" 2>/dev/null && sleep 1 && tmux send-keys -t "$TMUX_PANE" Enter 2>/dev/null
exit 0
