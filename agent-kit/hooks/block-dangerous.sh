#!/usr/bin/env bash
# PreToolUse → Bash. Exit 2 blocks the command.
set -euo pipefail
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

if [[ -z "$cmd" ]]; then
  exit 0
fi

# Dangerous patterns (extended regex). Each is matched case-insensitively.
patterns=(
  # Filesystem catastrophes
  'rm[[:space:]]+(-[a-zA-Z]*[rRfF][a-zA-Z]*[[:space:]]+)+/([[:space:]]|$)'
  'rm[[:space:]]+(-[a-zA-Z]*[rRfF][a-zA-Z]*[[:space:]]+)+/\*'
  # Рекурсивный снос рабочих каталогов: ловилось только «rm -rf /», а «rm -rf
  # /srv/data» проходило молча (проверено стендом hook-probe 14.08.2026).
  # /tmp и scratchpad намеренно свободны — там чистка идёт каждый день.
  # (^|;|&&|\||do) перед rm — иначе паттерн ловит собственный текст внутри
  # heredoc или строкового литерала и блокирует безобидную правку скрипта.
  '(^|[;&|]|&&|[[:space:]]do)[[:space:]]*rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)+[^[:space:]]*(/home/edgelab|\.claude|\.secrets|/data|/logs|/state|/hooks|/bin)([[:space:]/]|$)'
  'chmod[[:space:]]+(-R[[:space:]]+)?[0-7]*777[[:space:]]+/([[:space:]]|$)'
  'mkfs\.'
  ':\(\)\{[[:space:]]*:\|:&[[:space:]]*\};:'

  # Remote code execution
  'curl[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba|s)?sh'
  'wget[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba|s)?sh'

  # Database destruction
  'DROP[[:space:]]+TABLE'
  'DROP[[:space:]]+DATABASE'

  # Git: force-push / direct push to main
  'git[[:space:]]+push[[:space:]].*--force'
  'git[[:space:]]+push[[:space:]].*-f([[:space:]]|$)'
  'git[[:space:]]+push[[:space:]].*(origin|upstream)[[:space:]]+(main|master)([[:space:]]|$)'

  # Git: history rewrites
  'git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+(origin|upstream)/'
  'git[[:space:]]+rebase[[:space:]]+(-i|--interactive)'
  'git[[:space:]]+filter-branch'

  # Git: deleting REMOTE branch (local -D excluded: case-insensitive match would
  # also block harmless -d; reflog protects local for 90 days anyway).
  'git[[:space:]]+push[[:space:]].*--delete'
  'git[[:space:]]+push[[:space:]].*(origin|upstream)[[:space:]]+:'

  # Git: bypassing hooks (meta-safety)
  'git[[:space:]]+(push|commit)[[:space:]].*--no-verify'

  # crontab wipe: piping a filter's output into `crontab -` can silently blank the
  # whole crontab if the filter fails (empty stdin overwrites). Caught 2026-07-14:
  # sed failed → 145 lines zeroed. Direct `crontab file` / `crontab -l` untouched.
  '(sed|awk|grep)[[:space:]].*\|[[:space:]]*crontab[[:space:]]+-([[:space:]]|$)'
)

for pat in "${patterns[@]}"; do
  if [[ "$cmd" =~ $pat ]] || echo "$cmd" | grep -qiE "$pat"; then
    echo "BLOCKED dangerous pattern: $pat" >&2
    echo "Command: $cmd" >&2
    exit 2
  fi
done

exit 0
