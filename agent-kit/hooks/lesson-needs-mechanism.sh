#!/usr/bin/env bash
# PostToolUse hook — a LEARNINGS entry is a diary, not a fix.
#
# Root cause it fixes (2026-07-24, Avito iPad Model): the same class of mistake
# ("guessed instead of reading the reference") was written to LEARNINGS.md three
# times in one day and repeated anyway — that tier is read on demand and never
# fires mid-task. This hook fires the moment a lesson is filed and demands it be
# closed one tier up: SOURCES.md, rules.md, or a script/validator gate.
#
# Silent for every other file. Never blocks real work — the write already
# happened; exit 2 only routes the reminder back to the agent.
#
# ponytail: path match, no session state. If it nags on trivial entries,
# gate it on the diff adding a dated "- 20xx-" line.
set -euo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)"

[[ "$file" == *LEARNINGS.md ]] || exit 0

cat >&2 <<'EOF'
LEARNINGS entry filed — that is the diary, not the fix. This lesson is NOT
closed until the class of mistake is blocked one tier up. Pick one now:

  1. core/SOURCES.md   — the mistake was "didn't know the primary source
                         existed" -> register domain -> source -> how to read it.
  2. core/rules.md     — a judgement call that must be in context every task
                         (keep it general; a per-case rule is another diary line).
  3. a script/gate     — best: make the mistake mechanically impossible
                         (validator that fails before the push, hook, assert).

State which one you chose in your report to the operator. If you genuinely
believe none applies, say so explicitly and why — do not skip silently.
EOF
exit 2
