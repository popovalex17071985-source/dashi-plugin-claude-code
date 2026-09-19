#!/usr/bin/env bash
# auth-alive-watch.sh -- does my own login still work?
#
# The Claude refresh token has a hard TTL and nothing renews it: when it expires
# the agent simply stops answering, and the owner learns it from silence. A tiny
# probe every few hours turns that silence into one message.
#
# Usage: auth-alive-watch.sh [workspace]
set -uo pipefail

WORKSPACE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="$WORKSPACE/logs/auth-alive-watch.log"
STATE="$WORKSPACE/data/auth-alive.state"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")"
touch "$LOG"

notify() {
  [ -f "$WORKSPACE/bin/tg-send.py" ] && /usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "$1" || true
}

if timeout 120 "$CLAUDE_BIN" -p "ответь одним словом: пинг" >/dev/null 2>&1; then
  # Recovered after a failure -- say so once, then stay quiet.
  if [ "$(cat "$STATE" 2>/dev/null)" = "fail" ]; then
    notify "Вход в Claude снова работает -- фоновые задачи поехали."
    echo "$(date -Is) вход восстановлен" >> "$LOG"
  fi
  echo ok > "$STATE"
  exit 0
fi

echo "$(date -Is) пробный вызов не прошёл" >> "$LOG"
# One message per outage, not one per probe.
if [ "$(cat "$STATE" 2>/dev/null)" != "fail" ]; then
  notify "Мой вход в Claude не работает: пробный запрос не прошёл. Фоновые задачи стоят, нужен повторный вход (claude /login на сервере). Живая сессия может ещё отвечать, но расписание уже нет."
fi
echo fail > "$STATE"
