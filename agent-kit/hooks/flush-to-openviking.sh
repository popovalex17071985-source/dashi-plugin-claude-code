#!/usr/bin/env bash
# flush-to-openviking.sh -- PreCompact hook
# Syncs HOT+WARM to OpenViking before compaction

LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/logs/flush-to-openviking.log"
mkdir -p "$(dirname "$LOG")"

OV_HOST="${OV_HOST:-http://localhost:1933}"

# Проверяем доступность OpenViking (200 на /health)
if ! curl -sf --connect-timeout 2 "$OV_HOST/health" > /dev/null 2>&1; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) OpenViking недоступен ($OV_HOST), skip" >> "$LOG"
  exit 0
fi

# Если OV доступен — делегируем ov-session-sync.sh
SYNC="$HOME/.claude-lab/jarvis/scripts/ov-session-sync.sh"
if [ -x "$SYNC" ]; then
  AGENT_NAME=jarvis bash "$SYNC" >> "$LOG" 2>&1
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ov-session-sync done" >> "$LOG"
fi

exit 0
