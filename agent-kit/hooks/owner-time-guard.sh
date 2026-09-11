#!/usr/bin/env bash
# owner-time-guard.sh -- PreToolUse на отправку сообщения хозяину.
#
# Логи и journalctl отдают СЕРВЕРНОЕ время, и оно уезжает в ответ как есть:
# «упал в 09:22 UTC», хотя у хозяина на часах другое. Правило «время в поясе
# хозяина» лежит в памяти и молчит ровно в тот момент, когда цифра копируется
# из вывода команды. Гейт: чужая зона рядом со временем в тексте не проходит.
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_TZ="$(cat "$CLAUDE_DIR/core/owner-tz" 2>/dev/null || true)"
[[ -n "$OWNER_TZ" ]] || exit 0
SRV_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
[[ "$OWNER_TZ" != "$SRV_TZ" ]] || exit 0

txt=$(jq -r '.tool_input.text // ""')
grep -qiE "[0-9]{1,2}:[0-9]{2}[^.]{0,20}(MSK|UTC|GMT|по москв)|(MSK|UTC|GMT)[^.]{0,20}[0-9]{1,2}:[0-9]{2}" <<<"$txt" || exit 0

jq -n --arg r "В тексте для хозяина время в чужой зоне. Он живёт в $OWNER_TZ, сервер -- в $SRV_TZ. Переведи ПЕРЕД вставкой (TZ=$OWNER_TZ date -d '<время>') и пиши голую цифру его времени, без суффикса зоны." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
