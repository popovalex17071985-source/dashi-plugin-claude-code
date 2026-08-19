#!/usr/bin/env bash
# modal-watch.sh — прожимает модалки Claude Code, на которых висла бы очередь.
#
# Симптом: после /cc model (или обновления) Claude показывает «Switch model?» /
# «Continue?» и ждёт нажатия в терминале, которого в headless-агенте некому
# сделать — бот молчит на всё, пока кто-то не прожмёт. Этот скрипт из крона
# смотрит в tmux-панель и жмёт «1» сам.
#
# Использование: modal-watch.sh <tmux-session>
# Жмёт ТОЛЬКО когда в панели виден известный вопрос — иначе не трогает ничего.
set -euo pipefail

SESSION="${1:?usage: modal-watch.sh <tmux-session>}"
tmux has-session -t "$SESSION" 2>/dev/null || exit 0

pane="$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)"
# Известные блокирующие модалки: «Switch model?», «Continue?» с нумерованным
# выбором. Признак живой модалки — маркер выбора «❯» рядом с пунктом 1/2.
if printf '%s' "$pane" | grep -qE 'Switch model\?|Continue\?' \
   && printf '%s' "$pane" | grep -q '❯'; then
  tmux send-keys -t "$SESSION" 1 2>/dev/null || true
  logger -t modal-watch "pressed 1 in $SESSION (blocking modal)" 2>/dev/null || true
fi
exit 0
