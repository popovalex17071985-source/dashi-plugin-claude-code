#!/usr/bin/env bash
# owner-clock.sh -- UserPromptSubmit: часы хозяина в контекст каждого хода.
#
# Любое время, взятое из логов, date или расписания, -- СЕРВЕРНОЕ. Если хозяин
# живёт в другом поясе, оно уезжает в ответ как есть, и он видит чужой час.
# Правило в памяти на этом ходу молчит, а строка контекста -- нет.
# Пояса совпадают -- хук молчит и не тратит ни токена.
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_TZ="$(cat "$CLAUDE_DIR/core/owner-tz" 2>/dev/null || true)"
[[ -n "$OWNER_TZ" ]] || exit 0
SRV_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
[[ "$OWNER_TZ" != "$SRV_TZ" ]] || exit 0

echo "[ВРЕМЯ] У хозяина сейчас $(TZ="$OWNER_TZ" date '+%H:%M %d.%m') ($OWNER_TZ). На сервере $(date '+%H:%M %Z') -- это НЕ его время."
echo "[ВРЕМЯ] Любой час из логов, date и расписания -- серверный. Переведи в пояс хозяина ПЕРЕД тем как назвать."
exit 0
