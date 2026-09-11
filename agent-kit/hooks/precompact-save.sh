#!/usr/bin/env bash
# precompact-save.sh -- PreCompact: сохранить нить на диск ДО сжатия разговора.
#
# Сжатие режет разговор, и всё, что не легло в файл, исчезает. Хвост дословного
# журнала (core/hot/recent.md его пишет канал) переносим в handoff.md -- после
# сжатия агент читает его и понимает, на чём остановился. Дёшево и без сети.
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECENT="$CLAUDE_DIR/core/hot/recent.md"
HANDOFF="$CLAUDE_DIR/core/hot/handoff.md"
[[ -s "$RECENT" ]] || exit 0

mkdir -p "$(dirname "$HANDOFF")"
{
  printf '\n## Перед сжатием %s\n\n' "$(date '+%d.%m %H:%M')"
  tail -n 80 "$RECENT"
} >> "$HANDOFF"

# Файл не должен расти бесконечно: держим последние 600 строк.
if [[ "$(wc -l < "$HANDOFF")" -gt 600 ]]; then
  tail -n 600 "$HANDOFF" > "$HANDOFF.tmp" && mv "$HANDOFF.tmp" "$HANDOFF"
fi
exit 0
