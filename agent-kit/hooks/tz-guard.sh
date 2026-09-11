#!/usr/bin/env bash
# tz-guard.sh -- PreToolUse:Bash. Расписание без явной таймзоны не ставится.
#
# Сервер и хозяин часто живут в разных поясах, и разница съедается молча:
# напоминание «в 10 утра» приезжает на два часа позже, а видно это только когда
# оно не сработало. Ловим постановку расписания и требуем явную зону в самой
# команде -- её нельзя забыть посчитать в уме. Пояса совпадают -- гейт молчит.
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_TZ="$(cat "$CLAUDE_DIR/core/owner-tz" 2>/dev/null || true)"
[[ -n "$OWNER_TZ" ]] || exit 0
SRV_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
[[ "$OWNER_TZ" != "$SRV_TZ" ]] || exit 0        # один пояс -- расходиться нечему

cmd=$(jq -r '.tool_input.command // ""')
grep -qE "crontab|systemd-run|OnCalendar=|\bat\s+[0-9]{1,2}:" <<<"$cmd" || exit 0
# `crontab -l | ... | crontab -` -- это ЗАПИСЬ с чтением в одной строке.
if ! grep -qE "\|\s*crontab\s+-\s*($|&&|;)|\|\s*crontab\s+-[^a-zA-Z]" <<<"$cmd"; then
  grep -qE "crontab\s+-l|systemctl.*list-timers" <<<"$cmd" && exit 0
fi
grep -qE "$OWNER_TZ|--timezone|Timezone=" <<<"$cmd" && exit 0

off="$(TZ="$OWNER_TZ" date +%z)"; soff="$(date +%z)"
jq -n --arg r "Ставишь расписание без явной таймзоны. Хозяин в $OWNER_TZ ($off), сервер в $SRV_TZ ($soff) -- разъедется, и заметишь только по несработавшему напоминанию. Внимание: CRON_TZ и TZ= внутри crontab расписание НЕ двигают (Debian cron их не знает). Два рабочих пути: писать час уже в серверном поясе и подписать это комментарием, либо systemd-таймер с зоной прямо в календаре: OnCalendar='*-*-* 09:00:00 $OWNER_TZ'." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
