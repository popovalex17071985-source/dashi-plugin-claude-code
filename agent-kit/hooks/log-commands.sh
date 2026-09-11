#!/usr/bin/env bash
# PostToolUse → Bash. Append timestamped command to log. Never blocks.
set -euo pipefail
LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs/command-log.txt"
mkdir -p "$(dirname "$LOG")"
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
status="$(printf '%s' "$input" | jq -r '.tool_response.status // .tool_response.exit_code // "?"' 2>/dev/null || echo "?")"
ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
if [[ -n "$cmd" ]]; then
  printf '%s\t%s\t%s\n' "$ts" "$status" "$cmd" >> "$LOG"
fi
exit 0
