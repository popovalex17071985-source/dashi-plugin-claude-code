#!/usr/bin/env bash
# install-codex.sh — разворачивает Codex-агента в Telegram на чистом сервере
# одной командой. Аналог install-agent.sh, но для Codex (подписка ChatGPT).
#
# Заменяет ручные части 2–8 из artifacts/codex-agent-guide-vps.md. Скрипт
# идемпотентный: гоняй сколько угодно раз, он доделывает недостающее и не
# трогает готовое. Прерваться на входе в ChatGPT — нормально, запусти снова.
#
# Что человек делает сам (автоматизировать нельзя):
#   1. арендует VPS и заходит на него root'ом
#   2. заводит ДВУХ ботов у @BotFather и узнаёт свой id у @userinfobot
#   3. логинится в ChatGPT по ссылке (codex login) — скрипт остановится и скажет как
#   4. правит характер агента в ~/.codex/AGENTS.md (шаблон скрипт положит сам)
#
# Использование:
#   bash install-codex.sh                 # спросит всё интерактивно
#   bash install-codex.sh --token 123:AA... --watchdog-token 456:BB... --chat-id 140141496
#
set -euo pipefail

MAIN_DIR=/root/agent-main
WATCH_DIR=/root/agent-watchdog
CODEX_HOME=/root/.codex

BOT_TOKEN=""; WATCH_TOKEN=""; CHAT_ID=""; GROQ_KEY=""; ASSUME_YES=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m· %s (уже сделано)\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)          BOT_TOKEN="$2";   shift 2 ;;
    --watchdog-token) WATCH_TOKEN="$2"; shift 2 ;;
    --chat-id)        CHAT_ID="$2";     shift 2 ;;
    --groq-key)       GROQ_KEY="$2";    shift 2 ;;
    --yes|-y)         ASSUME_YES=1;     shift ;;
    --help|-h)        usage ;;
    *) die "неизвестный аргумент: $1 (--help для справки)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0"

ask() {  # ask VAR "приглашение"
  local __var="$1" __prompt="$2" __val=""
  while :; do
    read -r -p "$__prompt" __val </dev/tty || true
    [[ -n "$__val" ]] && break
    echo "    поле обязательное"
  done
  printf -v "$__var" '%s' "$__val"
}

# ─────────────────────────────────────────────────────────────────────────────
# 0. Секреты: спрашиваем только то, чего ещё нет
# ─────────────────────────────────────────────────────────────────────────────
say "Секреты"
if [[ ! -f "$MAIN_DIR/.env" ]]; then
  [[ -n "$BOT_TOKEN" ]] || ask BOT_TOKEN "Токен ОСНОВНОГО бота от @BotFather: "
  [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен не похож на настоящий (ожидаю 123456:AA...)"
fi
if [[ ! -f "$WATCH_DIR/.env" ]]; then
  [[ -n "$WATCH_TOKEN" ]] || ask WATCH_TOKEN "Токен бота-РЕМОНТНИКА от @BotFather: "
  [[ "$WATCH_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен ремонтника не похож на настоящий"
fi
if [[ ! -f "$MAIN_DIR/.env" || ! -f "$WATCH_DIR/.env" ]]; then
  [[ -n "$CHAT_ID" ]] || ask CHAT_ID "Твой Telegram id от @userinfobot: "
  [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || die "id должен быть числом: $CHAT_ID"
  if [[ -z "$GROQ_KEY" ]]; then
    read -r -p "Ключ Groq для голосовых (Enter — пропустить): " GROQ_KEY </dev/tty || true
  fi
fi
[[ -f "$MAIN_DIR/.env" && -f "$WATCH_DIR/.env" ]] && skip "оба .env на месте"

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Ставим Codex-агента (основной + ремонтник)? [Y/n] " a </dev/tty || true
  [[ -z "${a:-}" || "$a" =~ ^[YyДд] ]] || die "отменено"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Система: пакеты и своп
# ─────────────────────────────────────────────────────────────────────────────
say "Система"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq nano

# На 1 ГБ памяти Codex упирается в потолок и падает молча.
# Своп дешевле, чем объяснять человеку OOM.
if ! swapon --show --noheadings | grep -q . && [[ "$(free -m | awk '/^Mem:/{print $2}')" -lt 1900 ]]; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "своп 2 ГБ включён"
else
  skip "своп/память в порядке"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Codex CLI
# ─────────────────────────────────────────────────────────────────────────────
say "Codex"
export PATH="$HOME/.local/bin:$PATH"
if command -v codex >/dev/null; then
  skip "codex $(codex --version 2>/dev/null | head -1)"
else
  # </dev/null: установщик Codex спрашивает «Start Codex now?» — глушим stdin,
  # чтобы он не запускал интерактивный Codex и не ронял скрипт (set -e)
  curl -fsSL https://chatgpt.com/codex/install.sh | sh </dev/null || true
  command -v codex >/dev/null || die "codex не встал — прогони установку руками: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
  ok "codex $(codex --version 2>/dev/null | head -1)"
fi
CODEX_BIN="$(command -v codex)"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Конфиг и характер
# ─────────────────────────────────────────────────────────────────────────────
say "Конфиг Codex"
mkdir -p "$CODEX_HOME"
if [[ -f "$CODEX_HOME/config.toml" ]]; then
  skip "config.toml на месте"
else
  cat > "$CODEX_HOME/config.toml" <<'EOF'
# Модель — свежая, оставь как есть
model = "gpt-5.5"

# "never" = агент не переспрашивает на каждом шаге (нужно для автономной работы)
approval_policy = "never"

# Песочница: агент пишет только в рабочей папке — безопасный режим
sandbox_mode = "workspace-write"
EOF
  ok "config.toml записан"
fi

if [[ -f "$CODEX_HOME/AGENTS.md" ]]; then
  skip "AGENTS.md на месте (характер не трогаю)"
else
  cat > "$CODEX_HOME/AGENTS.md" <<'EOF'
# Кто ты

Ты — мой личный ассистент. Общаешься со мной в Telegram. Я читаю Telegram,
а не терминал — поэтому весь ответ пиши как сообщение в чат.

# Как ты общаешься
- Язык: русский.
- Коротко и по делу, без воды и извинений.
- Сначала — суть или результат, потом пояснения.
- Задача непонятна — задай уточняющий вопрос, не выдумывай.

# Правила безопасности (красные линии)
- Никогда не удаляй файлы и данные без моей явной просьбы.
- Никогда не показывай пароли, токены и ключи.
- Не пиши никому от моего имени без разрешения.
- Сомневаешься в опасном/необратимом действии — сначала спроси меня.
EOF
  ok "AGENTS.md записан (шаблон — потом отредактируй под себя: nano $CODEX_HOME/AGENTS.md)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Основной агент: .env + мост Telegram ↔ Codex
# ─────────────────────────────────────────────────────────────────────────────
say "Основной агент (мост)"
mkdir -p "$MAIN_DIR/workspace"
if [[ ! -f "$MAIN_DIR/.env" ]]; then
  cat > "$MAIN_DIR/.env" <<EOF
TELEGRAM_TOKEN=$BOT_TOKEN
TELEGRAM_CHAT_ID=$CHAT_ID
GROQ_API_KEY=$GROQ_KEY
EOF
  chmod 600 "$MAIN_DIR/.env"
  ok ".env записан"
else
  # дозапись ключа голосовых в существующий конфиг
  if [[ -n "$GROQ_KEY" ]] && ! grep -q '^GROQ_API_KEY=' "$MAIN_DIR/.env"; then
    echo "GROQ_API_KEY=$GROQ_KEY" >> "$MAIN_DIR/.env"
    ok "ключ Groq дописан в .env"
  else
    skip ".env на месте"
  fi
fi

# Мост пишем сами, детерминированно — а не просим Codex сгенерировать:
# у ста человек получится один и тот же проверенный код, а не сто вариантов.
cat > "$MAIN_DIR/bridge.sh" <<BRIDGE
#!/usr/bin/env bash
# Мост Telegram ↔ Codex: long-polling, одно сообщение = один codex exec.
# ponytail: без памяти диалога — каждый вопрос Codex видит с чистого листа;
# контекст держи в сообщении или проси его читать файлы в workspace/.
set -u
cd "\$(dirname "\$0")"
. ./.env
API="https://api.telegram.org/bot\$TELEGRAM_TOKEN"
CODEX=$CODEX_BIN
WORKDIR="\$(pwd)/workspace"
OFFSET=\$(cat .offset 2>/dev/null || echo 0)

log() { printf '%s %s\n' "\$(date '+%F %T')" "\$*" >> err.log; }

send() {  # режем на куски ≤4000, Telegram больше не принимает
  local text="\$1" chunk
  while [ -n "\$text" ]; do
    chunk="\${text:0:4000}"; text="\${text:4000}"
    curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="\$chunk" >/dev/null || log "sendMessage не ушёл"
  done
}

while :; do
  UPDATES=\$(curl -s --max-time 40 "\$API/getUpdates?timeout=30&offset=\$OFFSET") || { log "getUpdates: сеть"; sleep 5; continue; }
  [ "\$(printf '%s' "\$UPDATES" | jq -r .ok 2>/dev/null)" = "true" ] || { log "getUpdates: \$UPDATES"; sleep 5; continue; }
  for row in \$(printf '%s' "\$UPDATES" | jq -r '.result[] | @base64'); do
    upd() { printf '%s' "\$row" | base64 -d | jq -r "\$1"; }
    OFFSET=\$(( \$(upd .update_id) + 1 )); printf '%s' "\$OFFSET" > .offset
    FROM=\$(upd '.message.chat.id // empty'); TEXT=\$(upd '.message.text // empty')
    [ "\$FROM" = "\$TELEGRAM_CHAT_ID" ] || continue
    VOICE=\$(upd '.message.voice.file_id // empty')
    if [ -z "\$TEXT" ] && [ -n "\$VOICE" ] && [ -n "\${GROQ_API_KEY:-}" ]; then
      # голосовое -> текст через Groq Whisper
      FP=\$(curl -s "\$API/getFile?file_id=\$VOICE" | jq -r '.result.file_path // empty')
      if [ -n "\$FP" ]; then
        curl -s -o voice.ogg "https://api.telegram.org/file/bot\$TELEGRAM_TOKEN/\$FP"
        TEXT=\$(curl -s https://api.groq.com/openai/v1/audio/transcriptions \
          -H "Authorization: Bearer \$GROQ_API_KEY" \
          -F "file=@voice.ogg" -F "model=whisper-large-v3" | jq -r '.text // empty')
        rm -f voice.ogg
        [ -z "\$TEXT" ] && log "распознавание голосового не вернуло текст"
      fi
    fi
    if [ -z "\$TEXT" ]; then
      if [ -n "\$VOICE" ]; then send "Не разобрал голосовое. Голосовые работают при заданном ключе Groq (см. гайд, раздел про голосовые)."
      else send "Понимаю только текст и голосовые."; fi
      continue
    fi
    # Живой прогресс: статус-сообщение в чате обновляется последней строкой работы
    # Codex каждые 5 сек — видно, что агент не завис.
    MSGID=\$(curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="⏳ Работаю..." | jq -r '.result.message_id // empty')
    OUT=\$(mktemp); : > task.log
    timeout 600 "\$CODEX" exec --skip-git-repo-check --cd "\$WORKDIR" --output-last-message "\$OUT" "\$TEXT" > task.log 2>&1 &
    PID=\$!
    PREV=""; START=\$(date +%s)
    while kill -0 "\$PID" 2>/dev/null; do
      sleep 5
      # Карточка как у dashi: «работаю — Nс» + последние шаги, текущий со стрелкой
      STEPS=\$(grep -v '^[[:space:]]*\$' task.log | tail -3 | cut -c1-120)
      N=\$(printf '%s\n' "\$STEPS" | wc -l)
      CARD="⏳ Работаю — \$(( \$(date +%s) - START ))с"
      i=0
      while IFS= read -r st; do
        i=\$((i+1))
        [ -z "\$st" ] && continue
        if [ "\$i" -eq "\$N" ]; then CARD="\$CARD
→ \$st"; else CARD="\$CARD
✓ \$st"; fi
      done <<STEPS_EOF
\$STEPS
STEPS_EOF
      if [ -n "\$MSGID" ] && [ "\$CARD" != "\$PREV" ]; then
        curl -s -X POST "\$API/editMessageText" \
          --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
          -d message_id="\$MSGID" \
          --data-urlencode text="\$CARD" >/dev/null
        PREV="\$CARD"
      fi
    done
    wait "\$PID"; RC=\$?
    cat task.log >> codex.log
    [ -n "\$MSGID" ] && curl -s -X POST "\$API/deleteMessage" \
      -d chat_id="\$TELEGRAM_CHAT_ID" -d message_id="\$MSGID" >/dev/null
    ANSWER=\$(cat "\$OUT" 2>/dev/null); rm -f "\$OUT"
    if [ -z "\$ANSWER" ]; then
      if [ \$RC -eq 124 ]; then
        ANSWER="Codex думал дольше 10 минут — оборвал. Попробуй задачу помельче."
        log "codex exec timeout"
      elif [ \$RC -ne 0 ]; then
        ANSWER="Codex споткнулся (код \$RC). Хвост лога:
\$(tail -5 codex.log)"
        log "codex exec rc=\$RC"
      else
        ANSWER="(Codex вернул пустой ответ — смотри codex.log на сервере)"
      fi
    fi
    send "\$ANSWER"
  done
done
BRIDGE
chmod +x "$MAIN_DIR/bridge.sh"
ok "bridge.sh записан"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Ремонтник: .env + watchdog
# ─────────────────────────────────────────────────────────────────────────────
say "Ремонтник"
mkdir -p "$WATCH_DIR/workspace"
if [[ ! -f "$WATCH_DIR/.env" ]]; then
  cat > "$WATCH_DIR/.env" <<EOF
TELEGRAM_TOKEN=$WATCH_TOKEN
TELEGRAM_CHAT_ID=$CHAT_ID
EOF
  chmod 600 "$WATCH_DIR/.env"
  ok ".env записан"
else
  skip ".env на месте"
fi

cat > "$WATCH_DIR/watchdog.sh" <<WATCHDOG
#!/usr/bin/env bash
# Ремонтник: следит за agent-main, перезапускает упавшего, отвечает в свой чат.
# ponytail: детект только через systemctl is-active; зависание живого процесса
# ловится командой «перезапусти» руками.
set -u
cd "\$(dirname "\$0")"
. ./.env
API="https://api.telegram.org/bot\$TELEGRAM_TOKEN"
CODEX=$CODEX_BIN
WORKDIR="\$(pwd)/workspace"
OFFSET=\$(cat .offset 2>/dev/null || echo 0)

log() { printf '%s %s\n' "\$(date '+%F %T')" "\$*" >> err.log; }
send() {
  local text="\$1" chunk
  while [ -n "\$text" ]; do
    chunk="\${text:0:4000}"; text="\${text:4000}"
    curl -s -X POST "\$API/sendMessage" \
      --data-urlencode chat_id="\$TELEGRAM_CHAT_ID" \
      --data-urlencode text="\$chunk" >/dev/null || log "sendMessage не ушёл"
  done
}

# Фоновая проверка раз в 60 сек: основной лежит — поднять и доложить.
(
  while :; do
    if ! systemctl is-active --quiet agent-main; then
      systemctl restart agent-main
      sleep 10
      send "Основной агент падал — перезапустил. Хвост его лога:
\$(tail -3 /root/agent-main/err.log 2>/dev/null || echo нет)"
    fi
    sleep 60
  done
) &

status_text() {
  printf 'agent-main: %s\nХвост err.log:\n%s' \
    "\$(systemctl is-active agent-main)" \
    "\$(tail -3 /root/agent-main/err.log 2>/dev/null || echo 'пусто')"
}

while :; do
  UPDATES=\$(curl -s --max-time 40 "\$API/getUpdates?timeout=30&offset=\$OFFSET") || { log "getUpdates: сеть"; sleep 5; continue; }
  [ "\$(printf '%s' "\$UPDATES" | jq -r .ok 2>/dev/null)" = "true" ] || { log "getUpdates: \$UPDATES"; sleep 5; continue; }
  for row in \$(printf '%s' "\$UPDATES" | jq -r '.result[] | @base64'); do
    upd() { printf '%s' "\$row" | base64 -d | jq -r "\$1"; }
    OFFSET=\$(( \$(upd .update_id) + 1 )); printf '%s' "\$OFFSET" > .offset
    FROM=\$(upd '.message.chat.id // empty'); TEXT=\$(upd '.message.text // empty')
    [ "\$FROM" = "\$TELEGRAM_CHAT_ID" ] || continue
    [ -n "\$TEXT" ] || continue
    LOWER=\$(printf '%s' "\$TEXT" | tr '[:upper:]' '[:lower:]')
    case "\$LOWER" in
      *перезапус*|*restart*)
        systemctl restart agent-main; sleep 5
        send "Перезапустил основного. Сейчас он: \$(systemctl is-active agent-main)" ;;
      *статус*|*status*|*"как там"*)
        send "\$(status_text)" ;;
      *)
        curl -s "\$API/sendChatAction" -d chat_id="\$TELEGRAM_CHAT_ID" -d action=typing >/dev/null
        OUT=\$(mktemp)
        timeout 300 "\$CODEX" exec --skip-git-repo-check --cd "\$WORKDIR" --output-last-message "\$OUT" \
          "Ты — агент-ремонтник на сервере. Состояние основного агента: \$(status_text). Вопрос хозяина: \$TEXT" >> codex.log 2>&1
        ANSWER=\$(cat "\$OUT" 2>/dev/null); rm -f "\$OUT"
        send "\${ANSWER:-Не смог ответить — смотри codex.log ремонтника}" ;;
    esac
  done
done
WATCHDOG
chmod +x "$WATCH_DIR/watchdog.sh"
ok "watchdog.sh записан"

# ─────────────────────────────────────────────────────────────────────────────
# 6. systemd: оба сервиса
# ─────────────────────────────────────────────────────────────────────────────
say "Автозапуск (systemd)"
for pair in "agent-main:$MAIN_DIR/bridge.sh" "agent-watchdog:$WATCH_DIR/watchdog.sh"; do
  name="${pair%%:*}"; script="${pair#*:}"
  cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$name (Codex Telegram agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$(dirname "$script")
ExecStart=$script
Restart=always
RestartSec=5
Environment=PATH=$(dirname "$CODEX_BIN"):/usr/local/bin:/usr/bin:/bin
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
ok "юниты записаны"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Вход в ChatGPT — единственное, что нельзя сделать за человека
# ─────────────────────────────────────────────────────────────────────────────
# Проверяем файл с токенами, а не `codex login status`: у части версий CLI такой
# подкоманды нет, и её ошибка неотличима от «не залогинен» — путь к вечному циклу.
if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
  cat <<EOF

──────────────────────────────────────────────────────────────
  Осталось войти в ChatGPT — руками, за тебя это никто не сделает.

  1) $CODEX_BIN login --device-auth
  2) Codex покажет КОРОТКИЙ КОД и адрес — открой адрес в браузере
     на любом устройстве, войди в аккаунт ChatGPT (тот, где оплачена
     подписка) и введи код.
  3) В консоли появится «signed in».
  4) Снова: bash $0

  Запасной путь (если device-auth не сработал): с компьютера
  «ssh -L 1455:localhost:1455 root@$(hostname -I 2>/dev/null | awk '{print $1}')»,
  там «$CODEX_BIN login», ссылку склеить в одну строку и открыть
  в браузере ТОГО ЖЕ компьютера.

  Пятый пункт доделает остальное — повторный запуск ничего не сломает.
──────────────────────────────────────────────────────────────
EOF
  exit 0
fi
ok "вход в ChatGPT выполнен"

# ─────────────────────────────────────────────────────────────────────────────
# 8. Поднимаем
# ─────────────────────────────────────────────────────────────────────────────
say "Запуск"
systemctl enable --now agent-main agent-watchdog >/dev/null 2>&1 || true
sleep 5

if systemctl is-active --quiet agent-main && systemctl is-active --quiet agent-watchdog; then
  cat <<EOF

  ✓ Готово. Оба агента подняты и стартуют сами после перезагрузки.

  Напиши ОСНОВНОМУ боту в Telegram «привет, ты живой?» — ответит за 5–20 сек.
  Ремонтнику напиши «статус» — покажет состояние основного.

  Характер агента:  nano /root/.codex/AGENTS.md  (потом: systemctl restart agent-main)
  Логи основного:   journalctl -u agent-main -n 50
  Перезапуск:       systemctl restart agent-main

EOF
else
  die "какой-то сервис не поднялся. Смотри: systemctl status agent-main agent-watchdog"
fi
