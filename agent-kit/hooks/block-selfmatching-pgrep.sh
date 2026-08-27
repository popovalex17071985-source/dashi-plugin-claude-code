#!/usr/bin/env bash
# `pgrep -f foo` matches the very shell that runs it — its own cmdline contains
# "foo". In a wait-loop that means "still running" forever while the real job is
# long dead (28.07.2026: reported a finished run as in-progress for 40 minutes).
# Gate: any pgrep/pkill -f whose pattern has no bracket class is refused.
set -euo pipefail

cmd=$(jq -r '.tool_input.command // ""')

# Pattern right after -f, up to the first space/quote. A bracket class anywhere
# in it ("aksy_squar[e]") makes the cmdline unable to match itself — that's the fix.
if grep -qE "\bp(grep|kill)\s+(-[a-zA-Z]+\s+)*-f" <<<"$cmd"; then
  pat=$(grep -oE "\bp(grep|kill)\s+(-[a-zA-Z]+\s+)*-f\s+('[^']*'|\"[^\"]*\"|[^ ]+)" <<<"$cmd" | head -1)
  if ! grep -q '\[' <<<"$pat"; then
    jq -n --arg r "pgrep/pkill -f ловит собственную командную строку — жди по pid (kill -0 \$PID) или ставь bracket-класс в шаблон: aksy_photo_squar[e].py. Состояние фонового процесса читай у первоисточника (живой pid + рост лога), а не по имени в ps." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
fi
exit 0
