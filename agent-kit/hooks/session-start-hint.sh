#!/usr/bin/env bash
# session-start-hint.sh -- SessionStart: одна строка про нить прошлой сессии.
#
# Полный бутстрап (вливать handoff в контекст) обходится в десятки тысяч
# токенов на каждый запуск и всё равно протухает. Поэтому не вливаем, а
# показываем ОДНУ строку -- где лежит нить и насколько она свежая. Нити нет --
# молчим и не тратим ничего.
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOFF="$CLAUDE_DIR/core/hot/handoff.md"
[[ -s "$HANDOFF" ]] || exit 0

age="$(date -r "$HANDOFF" '+%d.%m %H:%M' 2>/dev/null || echo "?")"
echo "[НИТЬ] Прошлая сессия записана в core/hot/handoff.md (обновлена $age). Возвращаешься к старой теме -- открой его, не переспрашивай хозяина."
exit 0
