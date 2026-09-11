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

# Крон зовёт нас как «modal-watch.sh channel-<agent>» — имя агента и есть хвост
# имени сессии; его конфиг лежит в /etc/dashi-plugin/<agent>/.
AGENT="${SESSION#channel-}"
ENV_FILE="${DASHI_ENV_FILE:-/etc/dashi-plugin/$AGENT/channel.env}"
TOKEN=""; CHAT=""; STATE_DIR="${TMPDIR:-/tmp}"
if [[ -r "$ENV_FILE" ]]; then
  TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -1)"
  CHAT="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1 | cut -d, -f1)"
  sd="$(sed -n 's/^TELEGRAM_STATE_DIR=//p' "$ENV_FILE" | head -1)"
  [[ -d "${sd:-}" ]] && STATE_DIR="$sd"
fi

# tell <текст> — написать хозяину напрямую через Bot API (бот в залипшем
# состоянии молчит, канал тут не поможет).
tell() {
  [[ -n "$TOKEN" && -n "$CHAT" ]] || return 1
  curl -sf -m 10 -o /dev/null --data-urlencode "text=$1" -d "chat_id=$CHAT" \
    "${TELEGRAM_API_ROOT:-https://api.telegram.org}/bot$TOKEN/sendMessage"
}
# Замок на панель: в неё печатают ДВА автомата -- этот сторож и автосжатие
# (context-autocompact.sh). Между набором «/compact» и Enter есть пауза, и
# чужое нажатие в эту щель уходит не туда: в диалоге «No, exit» так убивает
# Claude, tmux-сессия умирает, systemd поднимает службу заново
# (11.09.2026, gorbot: 15 рестартов за день). Один писатель на панель.
exec 9>"/tmp/dashi-pane-${SESSION//[^a-zA-Z0-9]/_}.lock"
flock -w 3 9 || exit 0

# Известные блокирующие модалки: «Switch model?», «Continue?» с нумерованным
# выбором. Признак живой модалки — маркер выбора «❯» рядом с пунктом 1/2.
if printf '%s' "$pane" | grep -qE 'Switch model\?|Continue\?' \
   && printf '%s' "$pane" | grep -q '❯'; then
  tmux send-keys -t "$SESSION" 1 2>/dev/null || true
  logger -t modal-watch "pressed 1 in $SESSION (blocking modal)" 2>/dev/null || true
fi

# ── Предложение отправить баг-репорт ────────────────────────────────────────
# Claude Code сам предлагает пожаловаться на свою ошибку («Submit feedback /
# bug report», варианты 1 review / 2 send / 0 dismiss) и ждёт нажатия. В
# headless-агенте нажимать некому: очередь встаёт, бот молчит на всё подряд.
# Отправлять отчёт от чужого имени мы не вправе, поэтому закрываем окно -- «0».
# (11.09.2026: чужой агент так провисел, пока владелец не нажал 0 вручную.)
if printf '%s' "$pane" | grep -q 'Submit feedback / bug report' \
   && printf '%s' "$pane" | grep -q 'dismiss'; then
  tmux send-keys -t "$SESSION" 0 2>/dev/null || true
  logger -t modal-watch "pressed 0 in $SESSION (bug-report prompt)" 2>/dev/null || true
fi

# ── Протухший вход в Claude ──────────────────────────────────────────────────
# «Login expired» — модалка, которую нажатием не прожать: нужен полный
# перелогин через /relogin. Бот в этом состоянии молчит, поэтому пишем хозяину
# напрямую через Bot API (токен и chat-id читаем из channel.env, как это
# делает agent-advisor.sh). Антиспам: флаг-файл, не чаще раза в 6 часов.
if printf '%s' "$pane" | grep -qE 'Login expired|Please run /login'; then
  FLAG="$STATE_DIR/login-expired-alerted"
  # mtime-антиспам: флаг свежее 6 часов (360 минут) — молчим.
  if [[ -z "$(find "$FLAG" -mmin -360 2>/dev/null)" ]] \
     && tell "Вход в Claude протух — отправь /relogin"; then
    touch "$FLAG" 2>/dev/null || true
    logger -t modal-watch "login expired in $SESSION — owner alerted" 2>/dev/null || true
  fi
fi

# ── Залипший ввод ────────────────────────────────────────────────────────────
# Канал вставляет сообщение владельца в строку ввода, но Enter не проходит:
# текст висит в «❯ …», ход не начинается, бот молчит на всё. Руками дожать
# нельзя — send-keys Enter текст не отправляет, он возвращается обратно.
# Лечится только перезапуском службы; зависшее сообщение при этом теряется,
# поэтому владельцу пишем, что повторить. (11.09.2026, чужой агент gorbot.)
STUCK="$STATE_DIR/stuck-input"
# Claude Code ставит после «❯» неразрывный пробел (U+00A0), обычный '^❯ ' по
# нему не матчится — залипание проходило мимо (проверено на живой панели).
typed="$(printf '%s\n' "$pane" | grep -a '^❯' | tail -1 | sed 's/^❯//; s/^\(\xc2\xa0\| \)*//; s/\(\xc2\xa0\| \)*$//' || true)"
if [[ -n "$typed" ]] && ! printf '%s' "$pane" | grep -q 'esc to interrupt'; then
  sum="$(printf '%s' "$typed" | md5sum | cut -c1-16)"
  if [[ "$(cat "$STUCK" 2>/dev/null)" != "$sum" ]]; then
    printf '%s' "$sum" > "$STUCK"          # новый текст — засекаем время
    # Сначала просто дожимаем Enter: чаще всего сообщение доехало до строки
    # ввода, а подтверждение потерялось -- тогда ход стартует и перезапуск не
    # нужен. Перезапуск убивает сообщение вместе с сессией, это крайняя мера.
    # (12.09.2026: у агента Гора сообщение хозяина так и висело в строке, а
    # сторож вместо нажатия сразу перезапускал службу -- текст пропадал.)
    ( exec 9>"/tmp/dashi-pane-${SESSION//[^a-zA-Z0-9]/_}.lock"
      flock -w 3 9 || exit 0
      tmux send-keys -t "$SESSION" Enter 2>/dev/null ) || true
    logger -t modal-watch "stuck input in $SESSION — pressed Enter" 2>/dev/null || true
  elif [[ -z "$(find "$STUCK" -mmin -3 2>/dev/null)" ]] \
       && [[ -z "$(find "$STATE_DIR/stuck-restarted" -mmin -15 2>/dev/null)" ]]; then
    # тот же текст висит дольше 3 минут и последний перезапуск был давно
    CTL="/usr/local/bin/dashi-ctl-$AGENT"
    if [[ -x "$CTL" ]] && sudo -n "$CTL" restart >/dev/null 2>&1; then
      touch "$STATE_DIR/stuck-restarted" 2>/dev/null || true
      rm -f "$STUCK" 2>/dev/null || true
      tell "Я завис на твоём сообщении и перезапустил себя. Повтори, пожалуйста: «${typed:0:200}»" || true
      logger -t modal-watch "stuck input in $SESSION — service restarted" 2>/dev/null || true
    fi
  fi
else
  rm -f "$STUCK" 2>/dev/null || true       # ввод пуст или идёт ход — всё в порядке
fi
exit 0
