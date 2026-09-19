#!/usr/bin/env bash
# claude-link-guard.sh -- repair the `claude` launcher after an auto-update.
#
# 29.08.2026 on the coordinator: an auto-update left ~/.local/bin/claude pointing
# at a RELATIVE path, the symlink closed on itself ("Too many levels of symbolic
# links"), and every background script that shells out to claude died silently.
# The live session has its own check; the schedule had none.
#
# Fixes instead of diagnosing: relink to the newest installed version.
# Usage: claude-link-guard.sh [workspace]   (default: two levels up from bin/)
set -uo pipefail

WORKSPACE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LINK="${CLAUDE_LINK:-$HOME/.local/bin/claude}"
VERSIONS="${CLAUDE_VERSIONS:-$HOME/.local/share/claude/versions}"
LOG="$WORKSPACE/logs/claude-link-guard.log"
mkdir -p "$(dirname "$LOG")"
# A trace of life: the guard stays silent while the link is fine, and the morning
# self-audit judges it by the log's mtime -- an empty file with a fresh timestamp
# still says "I ran".
touch "$LOG"

"$LINK" --version >/dev/null 2>&1 && exit 0

NEWEST="$(ls -1 "$VERSIONS" 2>/dev/null | sort -V | tail -1)"
[ -n "$NEWEST" ] || { echo "$(date -Is) нет установленных версий в $VERSIONS" >> "$LOG"; exit 1; }
ln -sfn "$VERSIONS/$NEWEST" "$LINK"
if "$LINK" --version >/dev/null 2>&1; then
  echo "$(date -Is) починил ярлык -> $NEWEST" >> "$LOG"
  [ -x "$WORKSPACE/bin/tg-send.py" ] && /usr/bin/python3 "$WORKSPACE/bin/tg-send.py" \
    "Ярлык Claude был битый после обновления -- переставил на $NEWEST, фоновые задачи снова работают." || true
else
  echo "$(date -Is) ярлык всё ещё битый после починки на $NEWEST" >> "$LOG"
  [ -x "$WORKSPACE/bin/tg-send.py" ] && /usr/bin/python3 "$WORKSPACE/bin/tg-send.py" \
    "Ярлык Claude битый, починить не смог: версия $NEWEST не запускается. Фоновые задачи стоят." || true
fi
