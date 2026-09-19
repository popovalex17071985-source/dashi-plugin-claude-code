#!/usr/bin/env bash
# fallback-reply-sweeper.sh -- catch answers the Stop hook dropped.
#
# The Stop hook reads the turn from the transcript. On a long-lived session the
# final text is sometimes not flushed yet when the hook runs (gorbot 19.09.2026:
# a 30 MB transcript, three answers composed and never delivered; the SAME hook
# re-run by hand a minute later delivered them). Re-running it later is safe:
# the hook's own dedup state means an already-delivered turn is skipped, and a
# turn that ended with an explicit reply call is skipped too.
#
# Usage: fallback-reply-sweeper.sh <workspace> <agent>
set -euo pipefail

WORKSPACE="${1:?нужен каталог агента}"
AGENT="${2:?нужно имя агента}"
ENV_FILE="/etc/dashi-plugin/$AGENT/channel.env"
HOOK="$WORKSPACE/.claude/dashi-plugin-claude-code/plugin/scripts/fallback-reply-hook.ts"
PROJECTS="$HOME/.claude/projects"

[ -f "$ENV_FILE" ] && [ -f "$HOOK" ] || exit 0
command -v bun >/dev/null 2>&1 || exit 0

# The live session is the most recently written transcript, and only while it is
# fresh: an abandoned session must not be re-delivered hours later.
TRANSCRIPT="$(find "$PROJECTS" -name '*.jsonl' -mmin -5 -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "$TRANSCRIPT" ] || exit 0

SESSION_ID="$(basename "$TRANSCRIPT" .jsonl)"
printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}\n' \
  "$SESSION_ID" "$TRANSCRIPT" \
  | TELEGRAM_CHANNEL_ENV_FILE="$ENV_FILE" bun "$HOOK" 2>&1 | tail -3
