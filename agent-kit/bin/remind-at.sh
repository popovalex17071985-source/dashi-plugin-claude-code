#!/usr/bin/env bash
# Напоминание самому себе, которое переживает рестарт.
#
# Будильник внутри разговора (CronCreate) умирает вместе с сессией: 12.09.2026
# у агента так слетел назначенный ретест, и заметил это хозяин, а не агент.
# Здесь строка ложится в машинный крон, в назначенное время будит живую панель
# через pane-send.sh и снимает сама себя.
#
#   bin/remind-at.sh "13.09 12:07" "прогони ретест фото и отчитайся"
#   bin/remind-at.sh --list
#
# Время ВСЕГДА пермское (Asia/Yekaterinburg): Debian cron про часовые пояса не
# знает, поэтому переводим в локальное время машины сами.
set -euo pipefail

WORKSPACE="__WORKSPACE__"
OWNER_TZ="Asia/Yekaterinburg"

session() {
  if [[ -n "${DASHI_TMUX_SESSION:-}" ]]; then echo "$DASHI_TMUX_SESSION"; return; fi
  local live; live="$(tmux ls -F '#{session_name}' 2>/dev/null || true)"
  local hit;  hit="$(grep -m1 '__AGENT__' <<<"$live" || true)"
  echo "${hit:-$(head -n1 <<<"$live")}"
}

case "${1:-}" in
  --fire)
    shift
    id="$1"; shift
    "$WORKSPACE/bin/pane-send-when-idle.sh" "$(session)" "$*" || true
    crontab -l 2>/dev/null | grep -v "remind:$id\$" | crontab - || true
    ;;
  --list)
    crontab -l 2>/dev/null | grep "remind:" || echo "напоминаний нет"
    ;;
  "")
    echo "как звать: $0 \"13.09 12:07\" \"текст напоминания\"" >&2
    exit 2
    ;;
  *)
    when="$1"; text="${2:?нужен текст напоминания}"
    day="${when%% *}"; clock="${when##* }"
    dd="${day%%.*}"; mm="${day##*.}"
    stamp="$(TZ="$OWNER_TZ" date -d "$(date +%Y)-$mm-$dd $clock" +%s)"
    line="$(date -d "@$stamp" +%-M) $(date -d "@$stamp" +%-H) $(date -d "@$stamp" +%-d) $(date -d "@$stamp" +%-m) *"
    id="$(date +%s)$$"
    line="$line $WORKSPACE/bin/remind-at.sh --fire $id \"$text\" >> $WORKSPACE/logs/remind-at.log 2>&1 # remind:$id"
    ( crontab -l 2>/dev/null; echo "$line" ) | crontab -
    echo "напомню $day в $clock по Перми (здесь это $(date -d "@$stamp" '+%d.%m %H:%M')): $text"
    ;;
esac
