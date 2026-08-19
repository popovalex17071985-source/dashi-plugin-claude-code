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
apt-get install -y -qq git unzip tmux curl jq

# На 1 ГБ памяти сборка и Claude Code упираются в потолок и падают молча.
# Ставим своп — дешевле, чем объяснять человеку OOM.
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
if (( mem_kb < 1800000 )) && ! swapon --show --noheadings | grep -q .; then
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "своп 2 ГБ (памяти всего $(( mem_kb / 1024 )) МБ)"
fi

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
# Симлинк в /usr/local/bin: скрипты плагина зовут `bun` по имени, а в
# неинтерактивном su его PATH не видит.
if [[ ! -e /usr/local/bin/bun ]]; then
  ln -sf "/home/$SERVICE_USER/.bun/bin/bun" /usr/local/bin/bun
  ok "bun доступен как команду системы"
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

## Команды хозяина в Telegram
/help — список команд, /status — как я себя чувствую, /stop — прервать работу,
/compact — сжать разговор, /new — начать с чистого листа, /mirror — показать
мой терминал, /keys — кнопки для ответа на диалоги, /cc — команды Claude Code.
Спросят «что ты умеешь» — объясняю словами, а не выкладываю список.

## Контекст разговора
Место в разговоре конечно. Приходит напоминание о заполнении — сразу говорю
хозяину простыми словами: «место заканчивается; тема закрыта — /new, надо
продолжить — /compact». Молчать об этом нельзя: со стороны я просто начинаю
тупить, а причина не видна.

## Правила
- Сначала думаю, потом делаю. Длинную работу дроблю на шаги.
- Проверяю по первоисточнику, а не по памяти. Не уверен — говорю «не уверен».
- Необратимое (удаление, деньги, прод) — только с подтверждением.
- Секреты не печатаю и не коммичу.

## Память

| Слой | Где | Когда читаю |
|---|---|---|
| Профиль хозяина | core/USER.md | всегда (подключён ниже) |
| Правила и правки | core/rules.md | всегда (подключён ниже) |
| Итоги сессий | core/hot/handoff.md | возвращаясь к теме |
| Решения (~14 дней) | core/warm/decisions.md | возвращаясь к теме |
| Факты | memory/MEMORY.md + файлы | индекс при старте, факт — по нужде |
| Уроки | core/LEARNINGS.md | после ошибки |

Правила: узнал факт или получил правку — сразу сохраняю файлом и строкой в
индекс, а не держу в голове до конца сессии. Правку хозяина пишу в rules.md.
Память против реальности — реальность выше.

Всегда в контексте только два лёгких файла, остальное читаю по нужде — иначе
каждый запуск жжёт контекст на том, что сегодня не понадобится.

@core/USER.md
@core/rules.md
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
  # Слои заводим сразу пустыми: досыпать структуру в уже живущего агента больно —
  # надо переучивать его правила и переносить накопленное. Пустой скелет ничего
  # не стоит, а место под каждый слой уже размечено.
  as_agent "mkdir -p '$CLAUDE_DIR/memory' '$CLAUDE_DIR/core/hot' '$CLAUDE_DIR/core/warm'"

  as_agent "cat > '$CLAUDE_DIR/memory/MEMORY.md'" <<'EOF'
# Индекс памяти (холодный слой)

Одна строка на факт: `- [Заголовок](файл.md) — короткий хук`.
Сам факт — отдельным файлом рядом. Пусто — значит я ещё ничего не запомнил.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/USER.md'" <<'EOF'
# Хозяин

**Имя:**
**Как обращаться:**
**Часовой пояс:**
**Чем занимается:**

## Как со мной работать
(быстро/подробно, с юмором/сухо, что бесит)

## Сейчас в фокусе
EOF

  as_agent "cat > '$CLAUDE_DIR/core/rules.md'" <<'EOF'
# Правила и правки

Сюда попадает каждая правка хозяина: что я сделал не так и как надо.
Формат: правило одной строкой + почему + как применять.

- Проверяю по первоисточнику, а не по памяти. Не уверен — говорю «не уверен».
- Необратимое (удаление, деньги, прод) — только с подтверждением.
- Задачу закрываю отчётом сам, без напоминаний.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/warm/decisions.md'" <<'EOF'
# Решения (тёплый слой, ~14 дней)

Что решили и почему. Старое вычищаю, чтобы не разрасталось.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/hot/handoff.md'" <<'EOF'
# Итоги последних сессий (горячий слой, последние 5)

Чем закончили, что висит, с чего продолжать.
EOF

  as_agent "cat > '$CLAUDE_DIR/core/LEARNINGS.md'" <<'EOF'
# Уроки

Ошибка → что из неё следует. Урок без изменения в правилах или в коде
не работает: он не всплывёт в нужный момент. Поэтому каждый урок доводим
до правки в rules.md или до проверки в скрипте.
EOF
  ok "слои памяти созданы (hot / warm / cold + профиль и правила)"
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
TELEGRAM_STATE_DIR=$WORKSPACE/state/telegram
AGENT_ID=$AGENT_NAME
GROQ_API_KEY=$GROQ_KEY
EOF
  chown "root:$SERVICE_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ok "конфиг записан (640 root:$SERVICE_USER)"
fi

# Живая карточка «работаю…» в Telegram: в плагине выключена по умолчанию.
if as_agent "test -s '$WORKSPACE/state/telegram/config.json'"; then
  skip "карточка прогресса настроена"
else
  as_agent "mkdir -p '$WORKSPACE/state/telegram' && printf '%s\\n' '{ \"progress\": { \"enabled\": true } }' > '$WORKSPACE/state/telegram/config.json'"
  ok "карточка прогресса включена"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Hooks
# ─────────────────────────────────────────────────────────────────────────────
say "Hooks"
if as_agent "grep -q dashi-channel ~/.claude/settings.json 2>/dev/null"; then
  skip "хуки прописаны"
else
  # install-hooks.sh зовёт `bun` по имени, а в неинтерактивном su его нет в PATH.
  as_agent "export PATH=\$HOME/.bun/bin:\$PATH; cd '$PLUGIN_DIR' && bash scripts/install-hooks.sh \
      --settings ~/.claude/settings.json \
      --chat-id '$USER_ID' \
      --webhook-url http://127.0.0.1:8089/hooks/agent \
      --agent-id dashi-channel" >/dev/null || die "install-hooks.sh упал"
  ok "хуки установлены"
fi

# Сторож контекста: раз в сессию напоминает агенту сказать хозяину, что
# «память разговора» заполняется и пора /compact или /new.
WATCH="$CLAUDE_DIR/dashi-plugin-claude-code/scripts/context-watch.sh"
if as_agent "grep -q context-watch.sh ~/.claude/settings.json 2>/dev/null"; then
  skip "сторож контекста прописан"
else
  as_agent "jq --arg c '$WATCH' '.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{matcher:\"\",hooks:[{type:\"command\",command:\$c}]}])' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json" \
    || die "не смог прописать сторож контекста в settings.json"
  ok "сторож контекста включён"
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
# Первый запуск спрашивает: сначала «Bypass Permissions» (по умолчанию выбрано
# «No, exit» — надо стрелка вниз + Enter, иначе Claude просто выходит), потом
# внешние импорты и dev-каналы — там достаточно Enter.
ExecStartPost=/bin/sh -c 'sleep 6 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Down && sleep 1 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Enter && sleep 3 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Enter && sleep 2 && /usr/bin/tmux send-keys -t channel-$AGENT_NAME Enter'
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
# 8b. Предохранитель
# ─────────────────────────────────────────────────────────────────────────────
# Раз в неделю смотрит на цифры (объём памяти, падения, диск) и, если что-то
# переросло текущую схему, сам пишет хозяину — что пора сделать и почему.
# Без этого человек узнаёт о проблеме, только когда она уже мешает.
say "Предохранитель"
cat > "/etc/cron.d/dashi-$AGENT_NAME-advisor" <<EOF
# Советы по обслуживанию агента $AGENT_NAME — понедельник, 10:00
SHELL=/bin/bash
0 10 * * 1 root /bin/bash $CLAUDE_DIR/dashi-plugin-claude-code/scripts/agent-advisor.sh $AGENT_NAME >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/dashi-$AGENT_NAME-advisor"
ok "советник включён (по понедельникам в 10:00)"

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
