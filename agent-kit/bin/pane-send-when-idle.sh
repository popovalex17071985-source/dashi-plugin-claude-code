#!/usr/bin/env bash
# pane-send-when-idle.sh -- inject a scheduled prompt ONLY when the agent is idle.
#
# Why: a cron prompt typed into a busy pane merges with the human's message into
# one turn. The turn's leading prompt is then the cron text, the Telegram
# envelope is no longer leading, and the fallback hook cannot tell which chat to
# answer -- the human's answer is composed and then dropped (gorbot, 19.09.2026:
# three questions from the group answered into the void).
#
# Usage: pane-send-when-idle.sh <tmux-session> <prompt> [max-wait-seconds]
set -euo pipefail

SESSION="${1:?нужна tmux-сессия}"
PROMPT="${2:?нужен текст промпта}"
MAX_WAIT="${3:-600}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP=30
WAITED=0

busy() {
  # Claude Code prints this footer only while a turn is running.
  tmux capture-pane -p -t "$SESSION" 2>/dev/null | tail -3 | grep -q "esc to interrupt"
}

while busy; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "$(date '+%F %T') агент занят ${MAX_WAIT}s -- служебный ход пропущен" >&2
    exit 0
  fi
  sleep "$STEP"
  WAITED=$((WAITED + STEP))
done

[ "$WAITED" -gt 0 ] && echo "$(date '+%F %T') подождал ${WAITED}s, панель освободилась" >&2
exec "$HERE/pane-send.sh" "$SESSION" "$PROMPT"
