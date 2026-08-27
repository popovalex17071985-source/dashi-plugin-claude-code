#!/usr/bin/env bash
# PostToolUse:Edit|Write|MultiEdit — keep auto-loaded system files in English.
#
# Root cause it fixes (2026-08-27, operator caught it): CLAUDE.md §6 says
# internal files are English because Cyrillic costs 2-3x the tokens, and those
# files reload every session. The rule sat in context and was ignored anyway —
# rules.md had drifted to 26% Cyrillic and LEARNINGS.md to 63%, even though
# LEARNINGS.md's own header shouts "WRITE NEW ENTRIES IN ENGLISH".
# A rule that loses to habit needs a mechanism.
#
# Checks the TEXT BEING WRITTEN, not the whole file — legacy Russian is
# grandfathered, new prose is not. Operator quotes are evidence and stay
# verbatim, hence a 20% tolerance rather than zero.
#
# Exempt: MEMORY.md (index of Russian topic names — translating kills recall)
# and open-threads.md (verbatim operator commitments).
#
# ponytail: char count, no NLP. Never blocks — the write already happened;
# exit 2 only routes the nudge back to the agent.
set -euo pipefail

payload="$(cat)"

read -r file text <<<"$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("tool_input", {})
parts = [d.get("content", ""), d.get("new_string", "")]
parts += [e.get("new_string", "") for e in d.get("edits", [])]
print(d.get("file_path", ""), len("".join(parts)))
' 2>/dev/null || echo " 0")"

case "$file" in
  */MEMORY.md|*/open-threads.md) exit 0 ;;
  */CLAUDE.md|*/.claude/core/*.md|*/.claude/core/*/*.md|*/.claude/rules/*.md) ;;
  *) exit 0 ;;
esac

[ "${text:-0}" -ge 400 ] || exit 0

pct="$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("tool_input", {})
parts = [d.get("content", ""), d.get("new_string", "")]
parts += [e.get("new_string", "") for e in d.get("edits", [])]
s = "".join(parts)
cyr = sum("Ѐ" <= c <= "ӿ" for c in s)
print(round(cyr * 100 / max(len(s), 1)))
')"

[ "$pct" -gt 20 ] || exit 0

cat >&2 <<EOF
CYRILLIC GUARD — you just wrote ~${pct}% Cyrillic into ${file##*/}.

That file reloads into context every session, and Cyrillic costs 2-3x the
tokens for the same meaning (CLAUDE.md §6). Rewrite the prose you just added
in English. Keep verbatim ONLY what is evidence or a proper name: operator
quotes, Russian file/collection/column names, catalog enum values.

If the Russian genuinely is the payload (a quote-heavy entry), say so in your
report — do not silently leave it.
EOF
exit 2
