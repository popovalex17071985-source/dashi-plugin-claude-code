#!/usr/bin/env bash
# UserPromptSubmit. Surfaces the PREVIOUS turn's cost back to the model when it
# was expensive, so context-economy pressure is constant (not memory-dependent).
# Silent on cheap turns. Non-blocking: emits additionalContext, exit 0.
set -euo pipefail

# overridable so hook-probe can drive it with a synthetic fat turn
CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE="${USAGE_FILE:-$CLAUDE_DIR/core/usage.jsonl}"
FAT_CREATION=60000   # cache_creation tokens
FAT_COST=1.00        # $

[[ -f "$USAGE" ]] || exit 0

# Предохранитель по дню (Саня 05.09.2026): отчёт постфактум не удерживает, сигнал
# нужен ВНУТРИ хода. Считаем расчётную стоимость за пермские сутки и с порога
# давим на экономию. Пороги переопределяются DAY_SOFT_USD / DAY_HARD_USD.
budget_msg="$(DAY_SOFT="${DAY_SOFT_USD:-250}" DAY_HARD="${DAY_HARD_USD:-400}" \
  USAGE="$USAGE" python3 - <<'PYEOF' 2>/dev/null || true
import json, os
from datetime import datetime, timedelta, timezone
PERM = timezone(timedelta(hours=5))
today = datetime.now(PERM).date()
spent = 0.0
try:
    lines = open(os.environ["USAGE"], encoding="utf-8").readlines()[-400:]
except OSError:
    lines = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
        ts = datetime.fromisoformat(str(r.get("ts", "")).replace("Z", "+00:00"))
    except Exception:
        continue
    if ts.astimezone(PERM).date() == today:
        spent += float(r.get("cost_usd") or 0)
soft, hard = float(os.environ["DAY_SOFT"]), float(os.environ["DAY_HARD"])
if spent > hard:
    print(f" [БЮДЖЕТ ДНЯ ПРЕВЫШЕН: ${spent:.0f} при потолке ${hard:.0f}. Режим жёсткой "
          f"экономии: без субагентов и широких grep, делать только прямо запрошенное, "
          f"ответ максимально коротким. Крупную работу предложить перенести.]", end="")
elif spent > soft:
    print(f" [за сутки уже ${spent:.0f}, мягкий потолок ${soft:.0f}. Экономь: без "
          f"субагентов, Read с limit, короткий ответ.]", end="")
PYEOF
)"
last="$(tail -n 1 "$USAGE" 2>/dev/null || true)"
[[ -z "$last" ]] && exit 0

read -r cc cost < <(printf '%s' "$last" \
  | jq -r '"\(.cache_creation // 0) \(.cost_usd // 0)"' 2>/dev/null || echo "0 0")

# Numeric comparison ($cost is float -> use awk).
fat="$(awk -v cc="$cc" -v cost="$cost" -v fc="$FAT_CREATION" -v fco="$FAT_COST" \
  'BEGIN{print (cc>fc || cost>fco) ? 1 : 0}')"
if [[ "$fat" != "1" ]]; then
  # Дешёвый ход — молчим, но превышение дня доложить обязаны.
  [[ -z "$budget_msg" ]] && exit 0
  jq -nc --arg m "${budget_msg# }" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'
  exit 0
fi

cck=$(( cc / 1000 ))
msg="[прошлый ход дорогой: cache_creation ~${cck}K, \$$(printf '%.2f' "$cost"). 82% счёта — кэш. Держи этот ход тоньше: Read с limit, не тащи лишнее в контекст, короче ответ.]${budget_msg}"
jq -nc --arg m "$msg" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'
exit 0
