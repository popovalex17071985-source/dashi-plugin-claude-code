#!/usr/bin/env bash
# PostToolUse → Edit|Write|MultiEdit. Lints freshly written .py for real bugs
# (pyflakes F + syntax E9: fabricated imports, undefined names, broken syntax).
# Silent when clean. On findings: exit 2 + stderr, fed back to the agent for
# self-correction before claiming "done". Style nags are intentionally excluded
# to keep token-economy: context only grows when a real bug is caught.
set -euo pipefail

ruff_bin="$(command -v ruff || true)"
[[ -z "$ruff_bin" && -x "$HOME/.local/bin/ruff" ]] && ruff_bin="$HOME/.local/bin/ruff"
[[ -z "$ruff_bin" ]] && exit 0   # ruff absent → no-op, never block on tooling gap

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

[[ "$file" == *.py ]] || exit 0
[[ -f "$file" ]] || exit 0

out="$("$ruff_bin" check --select F,E9 --quiet "$file" 2>&1)" && exit 0

printf 'ruff caught issues in %s — fix before reporting done:\n%s\n' "$file" "$out" >&2
exit 2
