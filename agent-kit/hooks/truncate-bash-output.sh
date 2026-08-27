#!/usr/bin/env bash
# PostToolUse -> Bash. Keep a runaway stdout from poisoning session context
# (cache = ~82% of Opus spend) WITHOUT losing data: the full output is spilled
# to a file, context gets head+tail + the path. Nothing is lost — read the rest
# with Read offset/limit or grep the file. The PreToolUse nudge only reminds;
# this one acts, but non-destructively.
#
# Mechanism: hookSpecificOutput.updatedToolOutput is the only field that REPLACES
# what the model sees (exit-2/stderr would pile on top = worse).
set -euo pipefail

MAX_LINES=200        # stdout above this gets spilled+trimmed
HEAD_LINES=120
TAIL_LINES=40
SPILL_DIR="/tmp/dashi-bigout"

input="$(cat)"
out="$(printf '%s' "$input" | jq -r '.tool_response.stdout // ""')"
[[ -z "$out" ]] && exit 0

n="$(printf '%s\n' "$out" | wc -l)"
(( n <= MAX_LINES )) && exit 0
cut=$(( n - HEAD_LINES - TAIL_LINES ))
(( cut < 1 )) && exit 0

# Spill the FULL output so nothing is lost. Name by pid+lineno for uniqueness
# (no Date in env here is fine; pid+RANDOM is enough to avoid clobber).
mkdir -p "$SPILL_DIR"
spill="$SPILL_DIR/out-$$-${RANDOM}.txt"
printf '%s\n' "$out" > "$spill"

marker=$(printf '\n…[обрезано %d строк из %d — context-economy. ПОЛНЫЙ вывод сохранён: %s — добери нужное через Read offset/limit или grep по файлу]…\n' "$cut" "$n" "$spill")
trimmed="$(
  printf '%s\n' "$out" | head -n "$HEAD_LINES"
  printf '%s' "$marker"
  printf '%s\n' "$out" | tail -n "$TAIL_LINES"
)"

jq -nc --arg o "$trimmed" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:$o}}'
exit 0
