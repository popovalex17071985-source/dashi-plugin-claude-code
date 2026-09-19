#!/usr/bin/env bash
# multichat-nudge.sh -- do not let a group question rot in the inbox.
#
# A group message is dropped into a per-chat inbox and waits for the session to
# free up. 29.08.2026 on the coordinator a question sat there for an hour and a
# half while the session was busy, and the owner noticed the silence first.
# We do not parse the json -- we nudge the session, it reads its own inbox.
#
# Usage: multichat-nudge.sh [workspace]   env: AGE_MIN (default 3), DRY=1
set -euo pipefail

WORKSPACE="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHATS="${MULTICHAT_CHATS:-$WORKSPACE/.claude/state/multichat/chats}"
SEEN="$WORKSPACE/data/multichat-nudged.txt"
AGE_MIN="${AGE_MIN:-3}"
[ -d "$CHATS" ] || exit 0
mkdir -p "$(dirname "$SEEN")"; touch "$SEEN"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF "$f" "$SEEN" && continue
  chat="$(basename "$(dirname "$(dirname "$f")")")"
  echo "$f" >> "$SEEN"
  [ "${DRY:-0}" = 1 ] && { echo "толкнул бы: $chat <- $(basename "$f")"; continue; }
  "$WORKSPACE/bin/pane-send-when-idle.sh" "${DASHI_TMUX_SESSION:-channel-$(basename "$WORKSPACE")}" \
    "В групповом чате $chat лежит непрочитанное сообщение (висит больше $AGE_MIN мин). Прочитай его inbox, ответь через reply с chat_id $chat и перенеси файл в inbox/.processed/." || true
done < <(find "$CHATS" -path '*/inbox/*.json' -not -path '*/.processed/*' -mmin "+$AGE_MIN" 2>/dev/null)

# keep the seen-list bounded
tail -n 500 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
