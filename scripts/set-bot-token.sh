#!/usr/bin/env bash
# Сменить токен бота у уже установленного агента, не редактируя конфиг руками.
# Зачем отдельный скрипт: Telegram-канал калечит команды с именем переменной
# TELEGRAM_EXPECTED_BOT_ID (маскирует как секрет), и скопированный из чата sed
# падает. Скрипт качается на сервер целиком — калечить нечего.
#
#   bash set-bot-token.sh <имя-агента>
# Токен спрашивается интерактивно (read -rs) — в историю/ps не попадает.
set -euo pipefail

AGENT="${1:?usage: set-bot-token.sh <agent-name>}"
ENV_FILE="/etc/dashi-plugin/$AGENT/channel.env"
UNIT="dashi-$AGENT"
[[ -f "$ENV_FILE" ]] || { echo "нет конфига $ENV_FILE — имя агента верное?" >&2; exit 1; }

read -rsp "Новый токен бота от @BotFather: " TOKEN; echo
[[ "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "не похоже на токен (жду 123456:AA...)" >&2; exit 1; }
BOT_ID="${TOKEN%%:*}"

# Обновляем обе строки; если строки нет — дописываем.
tmp="$(mktemp)"
awk -v tok="$TOKEN" -v bid="$BOT_ID" '
  /^TELEGRAM_BOT_TOKEN=/        { print "TELEGRAM_BOT_TOKEN=" tok; seen_tok=1; next }
  /^TELEGRAM_EXPECTED_BOT_ID=/  { print "TELEGRAM_EXPECTED_BOT_ID=" bid; seen_bid=1; next }
  { print }
  END {
    if (!seen_tok) print "TELEGRAM_BOT_TOKEN=" tok
    if (!seen_bid) print "TELEGRAM_EXPECTED_BOT_ID=" bid
  }
' "$ENV_FILE" > "$tmp"

# Права как у оригинала (660 root:agent), затем подменяем содержимое на месте.
cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"
echo "токен обновлён в $ENV_FILE (bot id $BOT_ID)"

systemctl restart "$UNIT"
echo "OK — $UNIT перезапущен, напиши боту через минуту"
