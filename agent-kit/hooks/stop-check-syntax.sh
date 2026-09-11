#!/usr/bin/env bash
# stop-check-syntax.sh -- Stop hook: py_compile changed .py files this turn.
# Reads transcript_path from JSON stdin, finds Edit/Write tool calls with .py
# file_paths, runs syntax check. On failure: stderr + exit 2 so Claude sees
# the error in its next turn and patches.
# Pytest: not run here. Add later if needed; py_compile catches 90% of breaks.

LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/logs/stop-check-syntax.log"
mkdir -p "$(dirname "$LOG")"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "$TS no transcript_path, skip" >> "$LOG"
  exit 0
fi

# Find the last user message line — only check files edited AFTER it
# (avoid re-running on files patched in earlier turns that already compile).
LAST_USER_LINE=$(grep -n '"type":"user"\|"role":"user"' "$TRANSCRIPT" | tail -1 | cut -d: -f1)
[ -z "$LAST_USER_LINE" ] && LAST_USER_LINE=1

FILES=$(tail -n +"$LAST_USER_LINE" "$TRANSCRIPT" | jq -r '
  select(.message.content // empty | type == "array") |
  .message.content[] |
  select(.type == "tool_use") |
  select(.name == "Edit" or .name == "Write") |
  .input.file_path // empty
' 2>/dev/null | grep '\.py$' | sort -u)

if [ -z "$FILES" ]; then
  echo "$TS no .py edits this turn" >> "$LOG"
  exit 0
fi

PYTHON="/home/edgelab/claude-gateway/.venv/bin/python"
[ -x "$PYTHON" ] || PYTHON=python3

ERRORS=""
OK_COUNT=0
TOTAL=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$f" ]; then
    continue  # file may have been deleted intentionally
  fi
  if out=$("$PYTHON" -m py_compile "$f" 2>&1); then
    OK_COUNT=$((OK_COUNT + 1))
  else
    ERRORS+="$f:"$'\n'"$out"$'\n\n'
  fi
done <<< "$FILES"

if [ -n "$ERRORS" ]; then
  echo "$TS SYNTAX FAIL ($OK_COUNT/$TOTAL OK):" >> "$LOG"
  echo "$ERRORS" >> "$LOG"
  >&2 echo "❌ Stop-hook caught syntax errors in files you just edited:"
  >&2 echo ""
  >&2 echo "$ERRORS"
  >&2 echo "Fix syntax then continue. ($OK_COUNT/$TOTAL files compile clean)"
  exit 2
fi

echo "$TS OK: $OK_COUNT/$TOTAL .py files compile clean" >> "$LOG"
exit 0
