#!/usr/bin/env bash
# Утренний отчёт о состоянии сервера: диск, память, процессор, сервисы агента,
# вход в Claude, планировщик, бэкап. Шлётся хозяину КАЖДОЕ утро, даже когда всё
# зелено — это единственная строчка, по которой видно, что сервер вообще жив.
#
# Отличие от самопроверки (self-audit-morning.sh): та молчит, когда всё хорошо,
# и следит за внутренностями агента. Эта — про железо и сервисы, и говорит всегда.
set -uo pipefail
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$WORKSPACE/bin/health-check.sh"

OUT=$(bash "$CHECK" 2>&1); EXIT=$?
CLEAN=$(printf '%s\n' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')

case $EXIT in
  0) HEADER="Сервер: всё в порядке" ;;
  1) HEADER="Сервер: есть предупреждения" ;;
  2) HEADER="Сервер: ЕСТЬ ПРОБЛЕМА" ;;
  *) HEADER="Сервер: проверка сама упала (код $EXIT)" ;;
esac

MSG="<b>${HEADER}</b>
host: $(hostname)
ts:   $(date '+%Y-%m-%d %H:%M %Z')

<pre>${CLEAN}</pre>"

[ -n "${DRY:-}" ] && { printf '%s\n' "$MSG"; exit 0; }
/usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "$MSG" --html
