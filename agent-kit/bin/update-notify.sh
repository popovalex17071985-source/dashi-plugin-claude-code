#!/usr/bin/env bash
# Советник по обновлениям: раз в сутки смотрит, вышло ли новое, и САМ пишет
# хозяину, что появилось. Без него агент молчит, пока хозяин не спросит, —
# а он не спросит, потому что не знает, что спрашивать.
#
# Ставится в крон установщиком рядом с утренней сводкой. Дедуп по хешу свежей
# версии: об одном и том же обновлении сообщается один раз.
set -uo pipefail

AGENT="__AGENT__"
WORKSPACE="__WORKSPACE__"
CTL="/usr/local/bin/dashi-ctl-$AGENT"
SEEN="$WORKSPACE/state/update-notified"

[ -x "$CTL" ] || exit 0

LIST="$(sudo -n "$CTL" check 2>/dev/null)" || exit 0
[ -n "$LIST" ] || exit 0

# Хеш списка: тот же список — молчим, иначе будем долбить каждый день.
HASH="$(printf '%s' "$LIST" | cksum | cut -d' ' -f1)"
mkdir -p "$(dirname "$SEEN")"
[ "$(cat "$SEEN" 2>/dev/null || true)" = "$HASH" ] && exit 0

N="$(printf '%s\n' "$LIST" | grep -c .)"
BODY="$(printf '%s\n' "$LIST" | head -15 | sed 's/^[0-9a-f]* /• /')"

/usr/bin/python3 "$WORKSPACE/bin/tg-send.py" "Вышло обновление: $N шт.

$BODY

Поставить — напиши /update. Обновление делает копию и при сбое откатывается." \
  && printf '%s' "$HASH" > "$SEEN"
