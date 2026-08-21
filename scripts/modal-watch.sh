#!/usr/bin/env bash
# modal-watch.sh — прожимает модалки Claude Code, на которых висла бы очередь.
#
# Симптом: после /cc model (или обновления) Claude показывает «Switch model?» /
# «Continue?» и ждёт нажатия в терминале, которого в headless-агенте некому
# сделать — бот молчит на всё, пока кто-то не прожмёт. Этот скрипт из крона
# смотрит в tmux-панель и жмёт «1» сам.
#
# Использование: modal-watch.sh <tmux-session>
# Жмёт ТОЛЬКО когда в панели виден известный вопрос — иначе не трогает ничего.
set -euo pipefail

SESSION="${1:?usage: modal-watch.sh <tmux-session>}"
tmux has-session -t "$SESSION" 2>/dev/null || exit 0

pane="$(tmux capture-pane -pt "$SESSION" -S -30 2>/dev/null || true)"
# Известные блокирующие модалки: «Switch model?», «Continue?» с нумерованным
# выбором. Признак живой модалки — маркер выбора «❯» рядом с пунктом 1/2.
if printf '%s' "$pane" | grep -qE 'Switch model\?|Continue\?' \
   && printf '%s' "$pane" | grep -q '❯'; then
  tmux send-keys -t "$SESSION" 1 2>/dev/null || true
  logger -t modal-watch "pressed 1 in $SESSION (blocking modal)" 2>/dev/null || true
fi

# ── Протухший вход в Claude ──────────────────────────────────────────────────
# «Login expired» — модалка, которую нажатием не прожать: нужен полный
# перелогин через /relogin. Бот в этом состоянии молчит, поэтому пишем хозяину
# напрямую через Bot API (токен и chat-id читаем из channel.env, как это
# делает agent-advisor.sh). Антиспам: флаг-файл, не чаще раза в 6 часов.
if printf '%s' "$pane" | grep -qE 'Login expired|Please run /login'; then
  # Крон зовёт нас как «modal-watch.sh channel-<agent>» — имя агента и есть
  # хвост имени сессии; его конфиг лежит в /etc/dashi-plugin/<agent>/.
  AGENT="${SESSION#channel-}"
  ENV_FILE="${DASHI_ENV_FILE:-/etc/dashi-plugin/$AGENT/channel.env}"
  if [[ -r "$ENV_FILE" ]]; then
    TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -1)"
    CHAT="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1 | cut -d, -f1)"
    STATE_DIR="$(sed -n 's/^TELEGRAM_STATE_DIR=//p' "$ENV_FILE" | head -1)"
    [[ -d "${STATE_DIR:-}" ]] || STATE_DIR="${TMPDIR:-/tmp}"
    FLAG="$STATE_DIR/login-expired-alerted"
    # mtime-антиспам: флаг свежее 6 часов (360 минут) — молчим.
    if [[ -n "$TOKEN" && -n "$CHAT" ]] \
       && [[ -z "$(find "$FLAG" -mmin -360 2>/dev/null)" ]]; then
      # -f: HTTP 4xx/5xx = ненулевой exit, иначе touch флага «доставлено»
      # случился бы и при недоставке.
      if curl -sf -m 10 -o /dev/null \
           --data-urlencode "text=Вход в Claude протух — отправь /relogin" \
           -d "chat_id=$CHAT" \
           "https://api.telegram.org/bot$TOKEN/sendMessage"; then
        touch "$FLAG" 2>/dev/null || true
        logger -t modal-watch "login expired in $SESSION — owner alerted" 2>/dev/null || true
      fi
    fi
  fi
fi
exit 0
