#!/usr/bin/env bash
# pane-send.sh -- единственный правильный способ впечатать текст в панель
# Claude из своего скрипта.
#
# В панель пишут несколько автоматов сразу: сторож диалогов, автосжатие
# контекста и скрипты агента. Между набором текста и Enter есть окно, и
# чужое нажатие в него подтверждает не ту строку: на диалоге с «No, exit»
# это просто выход из Claude (11.09.2026, агент Гора: 15 смертей сессии за
# день). Поэтому набор и подтверждение держим под общим замком панели.
#
# Использование:  pane-send.sh <tmux-session> "<текст промпта>"
set -uo pipefail
SESSION="${1:?usage: pane-send.sh <session> <text>}"
TEXT="${2:?usage: pane-send.sh <session> <text>}"

( exec 9>"/tmp/dashi-pane-${SESSION//[^a-zA-Z0-9]/_}.lock"
  flock -w 10 9 || { echo "панель занята другим писателем, не лезу" >&2; exit 1; }
  # Строку чистим: в ней мог остаться чужой недобитый текст, иначе промпт
  # склеится с ним и уедет хозяину мусором.
  tmux send-keys -t "$SESSION" C-u 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$SESSION" -l "$TEXT" 2>/dev/null || exit 1
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter 2>/dev/null || exit 1
)
