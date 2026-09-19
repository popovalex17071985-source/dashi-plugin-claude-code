#!/usr/bin/env bash
# flush-to-openviking.sh -- PreCompact hook: syncs HOT+WARM into long memory
# before the context is compacted, so the session's substance survives.
#
# 19.09.2026: the kit set the memory SERVER up (scripts/setup-memory.sh) but
# never shipped this hook, and setup-memory.sh only rewrote it «if [ -f ]».
# A fresh agent therefore got a healthy OpenViking with nothing writing to it,
# while the coordinator's own copy pointed at the coordinator's folder -- which
# is how another agent's memory ended up flushing into ours.
# __WORKSPACE__ and __AGENT__ are substituted per agent by install-kit.sh.
set -uo pipefail

WORKSPACE="__WORKSPACE__"
AGENT_NAME="__AGENT__"
LOG="$WORKSPACE/logs/flush-to-openviking.log"
mkdir -p "$(dirname "$LOG")"

OV_HOST="${OV_HOST:-http://127.0.0.1:1933}"
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if ! curl -sf --connect-timeout 2 "$OV_HOST/health" > /dev/null 2>&1; then
  echo "$(stamp) OpenViking недоступен ($OV_HOST), пропускаю" >> "$LOG"
  exit 0
fi

SYNC="$WORKSPACE/scripts/ov-session-sync.sh"
if [ ! -x "$SYNC" ]; then
  echo "$(stamp) нет $SYNC -- слить нечем, память не пишется" >> "$LOG"
  exit 0
fi

AGENT_NAME="$AGENT_NAME" bash "$SYNC" >> "$LOG" 2>&1
echo "$(stamp) ov-session-sync выполнен ($AGENT_NAME)" >> "$LOG"
exit 0
