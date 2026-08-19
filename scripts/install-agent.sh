#!/usr/bin/env bash
# install-agent.sh — разворачивает dashi-агента на чистом сервере одной командой.
#
# Заменяет 14 ручных шагов из artifacts/dashi-agent-guide-v2.md. Скрипт
# идемпотентный: гоняй сколько угодно раз, он доделывает недостающее и не
# трогает готовое. Прерваться на входе в Claude — нормально, запусти снова.
#
# Что человек делает сам (автоматизировать нельзя):
#   1. арендует VPS и заходит на него root'ом
#   2. заводит бота у @BotFather и узнаёт свой id у @userinfobot
#   3. логинится в Claude по ссылке (OAuth) — скрипт останавливается и говорит как
#
# Использование:
#   bash install-agent.sh                      # спросит всё интерактивно
#   bash install-agent.sh --name jarvis --token 123:AA... --user-id 140141496
#
set -euo pipefail

NODE_MAJOR=22
REPO_URL="${DASHI_REPO_URL:-https://github.com/popovalex17071985-source/dashi-plugin-claude-code.git}"
SERVICE_USER="${DASHI_SERVICE_USER:-agent}"

AGENT_NAME=""; BOT_TOKEN=""; USER_ID=""; GROQ_KEY=""; ASSUME_YES=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m· %s (уже сделано)\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      AGENT_NAME="$2"; shift 2 ;;
    --token)     BOT_TOKEN="$2";  shift 2 ;;
    --user-id)   USER_ID="$2";    shift 2 ;;
    --groq-key)  GROQ_KEY="$2";   shift 2 ;;
    --user)      SERVICE_USER="$2"; shift 2 ;;
    --repo)      REPO_URL="$2";   shift 2 ;;
    --yes|-y)    ASSUME_YES=1;    shift ;;
    --help|-h)   usage ;;
    *) die "неизвестный аргумент: $1 (--help для справки)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускай под root: sudo bash $0"

# ─────────────────────────────────────────────────────────────────────────────
# 0. Что за агент
# ─────────────────────────────────────────────────────────────────────────────
ask() {  # ask VAR "приглашение" [обязательность]
  local __var="$1" __prompt="$2" __required="${3:-1}" __val=""
  while :; do
    read -r -p "$__prompt" __val </dev/tty || true
    [[ -n "$__val" || "$__required" -eq 0 ]] && break
    echo "    поле обязательное"
  done
  printf -v "$__var" '%s' "$__val"
}

say "Кого разворачиваем"
[[ -n "$AGENT_NAME" ]] || ask AGENT_NAME "Имя агента (латиницей, напр. jarvis): "
[[ "$AGENT_NAME" =~ ^[a-z][a-z0-9_-]*$ ]] || die "имя только латиницей в нижнем регистре: $AGENT_NAME"

WORKSPACE="/home/$SERVICE_USER/.claude-lab/$AGENT_NAME"
CLAUDE_DIR="$WORKSPACE/.claude"
PLUGIN_DIR="$CLAUDE_DIR/dashi-plugin-claude-code/plugin"
ENV_FILE="/etc/dashi-plugin/$AGENT_NAME/channel.env"
UNIT="dashi-$AGENT_NAME"

# Токен и id спрашиваем, только если конфига ещё нет — на повторном прогоне не дёргаем.
if [[ ! -f "$ENV_FILE" ]]; then
  [[ -n "$BOT_TOKEN" ]] || ask BOT_TOKEN "Токен бота от @BotFather: "
  [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "токен не похож на настоящий (ожидаю 123456:AA...)"
  [[ -n "$USER_ID" ]] || ask USER_ID "Твой Telegram id от @userinfobot: "
  [[ "$USER_ID" =~ ^-?[0-9]+$ ]] || die "id должен быть числом: $USER_ID"
  [[ -n "$GROQ_KEY" ]] || ask GROQ_KEY "Ключ Groq для голосовых (Enter — пропустить): " 0
else
  # Повторный прогон: id нужен ниже для хуков, берём из готового конфига,
  # иначе хуки встанут с пустым chat-id и прогресс-пузырёк уедет в никуда.
  USER_ID="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1)"
  [[ -n "$USER_ID" ]] || die "в $ENV_FILE нет TELEGRAM_ALLOWED_USER_IDS — почини файл или удали его и запусти снова"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  cat <<EOF

  агент:        $AGENT_NAME
  пользователь: $SERVICE_USER
  workspace:    $WORKSPACE
  сервис:       $UNIT

EOF
  read -r -p "Поехали? [Y/n] " a </dev/tty || true
  [[ -z "${a:-}" || "$a" =~ ^[YyДд] ]] || die "отменено"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Система: Node.js, Claude Code, tmux
# ─────────────────────────────────────────────────────────────────────────────
say "Система и Claude Code"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if ! command -v node >/dev/null || [[ "$(node -v | cut -c2- | cut -d. -f1)" -lt "$NODE_MAJOR" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs
  ok "Node.js $(node -v)"
else
  skip "Node.js $(node -v)"
fi
# unzip нужен установщику Bun — без него тот падает уже после скачивания;
# tmux держит интерактивную сессию Claude под systemd
apt-get install -y -qq git unzip tmux curl

if ! command -v claude >/dev/null; then
  npm install -g @anthropic-ai/claude-code >/dev/null
  ok "Claude Code $(claude --version 2>/dev/null || echo установлен)"
else
  skip "Claude Code $(claude --version 2>/dev/null || true)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Отдельный пользователь
# ─────────────────────────────────────────────────────────────────────────────
# Под root Claude отказывается работать без подтверждений (--dangerously-skip-
# permissions «cannot be used with root»), а systemd на этом молча зацикливается.
# Поэтому агент живёт под обычным пользователем с самого начала.
say "Пользователь $SERVICE_USER"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  skip "пользователь $SERVICE_USER"
else
  adduser --disabled-password --gecos "" "$SERVICE_USER" >/dev/null
  ok "создан $SERVICE_USER"
fi
HOME_DIR="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"

as_agent() { su - "$SERVICE_USER" -c "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 3. Bun
# ─────────────────────────────────────────────────────────────────────────────
say "Bun"
if as_agent 'test -x ~/.bun/bin/bun'; then
  skip "bun $(as_agent '~/.bun/bin/bun --version')"
else
  as_agent 'curl -fsSL https://bun.sh/install | bash' >/dev/null
  as_agent 'test -x ~/.bun/bin/bun' || die "bun не встал — проверь, что unzip на месте"
  ok "bun $(as_agent '~/.bun/bin/bun --version')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Workspace и плагин
# ─────────────────────────────────────────────────────────────────────────────
# Плагин обязан лежать ВНУТРИ .claude workspace'а: Claude Code ищет CLAUDE.md
# вверх по дереву от рабочей папки, а MCP-сервер — относительным путём. Отсюда
# «no MCP server configured with that name» у всех, кто положил его рядом.
say "Workspace $WORKSPACE"
as_agent "mkdir -p '$CLAUDE_DIR' '$WORKSPACE/secrets' && chmod 700 '$WORKSPACE/secrets'"

if [[ -d "$CLAUDE_DIR/dashi-plugin-claude-code/.git" ]]; then
  skip "плагин склонирован"
else
  as_agent "git clone --depth 1 '$REPO_URL' '$CLAUDE_DIR/dashi-plugin-claude-code'" >/dev/null 2>&1 \
    || die "не удалось склонировать $REPO_URL"
  ok "плагин склонирован"
fi

say "Зависимости плагина"
as_agent "cd '$PLUGIN_DIR' && ~/.bun/bin/bun install --silent" >/dev/null 2>&1 || die "bun install упал"
ok "зависимости на месте"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Характер агента
# ─────────────────────────────────────────────────────────────────────────────
say "Характер (CLAUDE.md)"
if [[ -s "$CLAUDE_DIR/CLAUDE.md" ]]; then
  skip "CLAUDE.md уже написан"
else
  as_agent "cat > '$CLAUDE_DIR/CLAUDE.md'" <<EOF
# $AGENT_NAME

## Кто я
Личный ассистент. Отвечаю по-русски, коротко, суть вперёд, без воды и извинений.

## ГЛАВНОЕ ПРАВИЛО КАНАЛА
Я общаюсь через Telegram, а не через терминал. Пользователь НЕ видит мой
терминал. Каждый ответ, вопрос, подтверждение и итог я отправляю инструментом
reply — иначе человек не увидит ничего.

## Правила
- Сначала думаю, потом делаю. Длинную работу дроблю на шаги.
- Проверяю по первоисточнику, а не по памяти. Не уверен — говорю «не уверен».
- Необратимое (удаление, деньги, прод) — только с подтверждением.
- Секреты не печатаю и не коммичу.

## Память
При старте читаю memory/MEMORY.md. Узнал важный факт или получил правку —
сохраняю в memory/ и добавляю строку в индекс. Память против реальности —
реальность выше.
EOF
  ok "болванка характера создана — потом попроси агента переписать её под себя"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5b. Память между сессиями
# ─────────────────────────────────────────────────────────────────────────────
# Без этого агент забывает всё при каждом рестарте, а завести память «потом»
# люди забывают. Скелет создаём сразу — дальше агент наполняет его сам.
say "Память"
if [[ -s "$CLAUDE_DIR/memory/MEMORY.md" ]]; then
  skip "память заведена"
else
  as_agent "mkdir -p '$CLAUDE_DIR/memory'"
  as_agent "cat > '$CLAUDE_DIR/memory/MEMORY.md'" <<'EOF'
# Индекс памяти

Одна строка на факт: `- [Заголовок](файл.md) — короткий хук`.
Пусто — значит я ещё ничего не запомнил. Скажи «запомни, что…» — появится.
EOF
  ok "скелет памяти создан"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Конфиг канала
# ─────────────────────────────────────────────────────────────────────────────
say "Конфиг $ENV_FILE"
if [[ -f "$ENV_FILE" ]]; then
  skip "конфиг на месте"
else
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# dashi-channel · $AGENT_NAME — создан install-agent.sh
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_EXPECTED_BOT_ID=${BOT_TOKEN%%:*}
TELEGRAM_ALLOWED_USER_IDS=$USER_ID
TELEGRAM_ALLOWED_CHAT_IDS=$USER_ID
TELEGRAM_WORKSPACE_ROOT=$CLAUDE_DIR
AGENT_ID=$AGENT_NAME
GROQ_API_KEY=$GROQ_KEY
EOF
  chown "root:$SERVICE_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "конфиг записан (640 root:$SERVICE_USER)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Hooks
# ─────────────────────────────────────────────────────────────────────────────
say "Hooks"
if as_agent "grep -q dashi-channel ~/.claude/settings.json 2>/dev/null"; then
  skip "хуки прописаны"
else
  as_agent "cd '$PLUGIN_DIR' && bash scripts/install-hooks.sh \
      --settings ~/.claude/settings.json \
      --chat-id '$USER_ID' \
      --webhook-url http://127.0.0.1:8089/hooks/agent \
      --agent-id dashi-channel" >/dev/null || die "install-hooks.sh упал"
  ok "хуки установлены"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. systemd
# ─────────────────────────────────────────────────────────────────────────────
say "Автозапуск ($UNIT)"
cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Dashi channel for $AGENT_NAME (Telegram -> Claude Code)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$PLUGIN_DIR
EnvironmentFile=$ENV_FILE
Environment=HOME=$HOME_DIR
Environment=PATH=$HOME_DIR/.bun/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=LANG=en_US.UTF-8

# Claude Code интерактивный — держим в tmux, иначе нет TTY
Type=forking
ExecStart=/usr/bin/tmux new-session -d -s channel-$AGENT_NAME \\
  claude --dangerously-skip-permissions --dangerously-load-development-channels server:dashi-channel
# Первый запуск спрашивает про внешние импорты и dev-каналы — прожимаем Enter
ExecStartPost=/bin/sh -c 'sleep 6 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Enter && sleep 2 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Enter'
ExecStop=/usr/bin/tmux kill-session -t channel-$AGENT_NAME

# on-failure, а не always: иначе welcome-промт крутит перезапуск по кругу
Restart=on-failure
RestartSec=15s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "юнит записан"

# ─────────────────────────────────────────────────────────────────────────────
# 9. Вход в Claude — единственное, что нельзя сделать за человека
# ─────────────────────────────────────────────────────────────────────────────
logged_in() { as_agent 'test -s ~/.claude/.credentials.json' 2>/dev/null; }

if ! logged_in; then
  cat <<EOF

──────────────────────────────────────────────────────────────
  Осталось войти в Claude — руками, за тебя это никто не сделает.

  1) su - $SERVICE_USER
  2) claude
  3) выбери «Claude account» (НЕ «API key»)
  4) открой показанную ссылку в браузере, войди, скопируй код обратно
  5) Ctrl+C, exit
  6) снова: sudo bash $0 --name $AGENT_NAME

  Шестой пункт доделает остальное — повторный запуск ничего не сломает.
──────────────────────────────────────────────────────────────
EOF
  exit 0
fi
ok "вход в Claude выполнен"

# ─────────────────────────────────────────────────────────────────────────────
# 5c. Superpowers (навыки: планирование, отладка, ревью)
# ─────────────────────────────────────────────────────────────────────────────
say "Superpowers"
if as_agent 'test -d ~/.claude/plugins/marketplaces/superpowers-dev'; then
  skip "superpowers на месте"
elif as_agent 'claude plugin marketplace add obra/superpowers >/dev/null 2>&1 &&
               claude plugin install superpowers@superpowers-dev >/dev/null 2>&1'; then
  ok "superpowers установлены"
else
  # Не критично: агент работает и без них, поэтому не роняем всю установку
  printf '    \033[33m!\033[0m superpowers не встали — поставь потом вручную:\n'
  printf '      claude plugin marketplace add obra/superpowers\n'
  printf '      claude plugin install superpowers@superpowers-dev\n'
fi


# ─────────────────────────────────────────────────────────────────────────────
# 10. Поднимаем
# ─────────────────────────────────────────────────────────────────────────────
say "Запуск"
systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
sleep 8

if systemctl is-active --quiet "$UNIT"; then
  cat <<EOF

  ✓ Готово. Агент $AGENT_NAME поднят и стартует сам после перезагрузки.

  Напиши своему боту в Telegram — он ответит.
  Не ответил:  journalctl -u $UNIT -n 50 --no-pager
               su - $SERVICE_USER -c 'tmux attach -t channel-$AGENT_NAME'
  Перезапуск:  systemctl restart $UNIT

EOF
else
  die "сервис не поднялся. Смотри: journalctl -u $UNIT -n 50 --no-pager"
fi
