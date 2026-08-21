#!/usr/bin/env bash
# agent-advisor.sh — предохранитель: сам пишет хозяину, когда агенту пора
# что-то поменять, и объясняет почему.
#
# Смысл: человек не знает, в какой момент память перерастёт файловый поиск, а
# лог начнёт врать про падения. Раз в неделю смотрим на цифры и, если порог
# перейдён, шлём в Telegram одно сообщение «пора вот это, потому что вот это».
#
# Каждый совет уходит один раз в COOLDOWN_DAYS — иначе это превращается в шум,
# который перестают читать.
#
# Ставится установщиком в крон. Запуск руками: bash agent-advisor.sh [--dry-run]
set -euo pipefail

AGENT="${1:-${DASHI_AGENT:-}}"
[[ "${AGENT:-}" == --* ]] && AGENT=""
DRY=0; for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY=1; done

# Имя не передали — берём единственного агента, если он один
if [[ -z "$AGENT" && -z "${DASHI_ENV_FILE:-}" ]]; then
  mapfile -t found < <(ls -1 /etc/dashi-plugin 2>/dev/null || true)
  [[ ${#found[@]} -eq 1 ]] || { echo "укажи имя агента: bash $0 <имя>"; exit 1; }
  AGENT="${found[0]}"
fi

ENV_FILE="${DASHI_ENV_FILE:-/etc/dashi-plugin/$AGENT/channel.env}"
[[ -r "$ENV_FILE" ]] || { echo "нет доступа к $ENV_FILE"; exit 1; }

TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | head -1)"
CHAT="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -1 | cut -d, -f1)"
WS="$(sed -n 's/^TELEGRAM_WORKSPACE_ROOT=//p' "$ENV_FILE" | head -1)"
[[ -n "$TOKEN" && -n "$CHAT" && -d "$WS" ]] || { echo "конфиг неполный"; exit 1; }

# cwd от вызывающего (root: /root) ломает find у агента («Failed to restore initial
# working directory») — под set -e это тихая смерть всего советника.
cd "$WS"
STATE="$WS/.advisor-state"
COOLDOWN_DAYS=30
touch "$STATE"

# Совет уже уходил недавно? Молчим — повтор превращает предохранитель в шум.
recently_sent() {
  local key="$1" last
  last="$(sed -n "s/^$key //p" "$STATE" | head -1)"
  [[ -n "$last" ]] && (( ($(date +%s) - last) < COOLDOWN_DAYS * 86400 ))
}

mark_sent() {
  local key="$1"
  sed -i "/^$key /d" "$STATE"
  echo "$key $(date +%s)" >> "$STATE"
}

advise() {  # advise <ключ> <текст>
  local key="$1" text="$2"
  recently_sent "$key" && return 0
  if [[ $DRY -eq 1 ]]; then
    echo "--- [$key]"; echo "$text"; return 0
  fi
  curl -s -o /dev/null --data-urlencode "text=$text" \
    -d "chat_id=$CHAT" -d "parse_mode=HTML" \
    "https://api.telegram.org/bot$TOKEN/sendMessage" || return 0
  mark_sent "$key"
}

# ── 1. Память переросла файловый поиск ───────────────────────────────────────
facts=$(find "$WS/memory" -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l)
if (( facts >= 150 )); then
  advise memory-semantic "Братан, пора подключать семантическую память.

Фактов накопилось $facts — по индексу я их уже нахожу через раз: он ищет по
словам, а не по смыслу. Спроси про «доставку» — факт, записанный как «отгрузка»,
я не найду.

Лечится OpenViking: он ищет по смыслу и подключается сбоку, ничего не ломая.
Две команды и докер — в гайде, раздел «Что дальше». Скажи, и я поставлю."
fi

# ── 2. Тёплый слой зарос ─────────────────────────────────────────────────────
dec="$WS/core/warm/decisions.md"
if [[ -f "$dec" ]] && (( $(wc -l < "$dec") > 400 )); then
  advise warm-bloat "Братан, надо почистить решения.

В core/warm/decisions.md уже $(wc -l < "$dec") строк, а слой рассчитан
примерно на две недели. Разросшийся тёплый слой я перечитываю дольше и чаще
цепляюсь за устаревшее.

Скажи «почисти decisions» — вынесу актуальное наверх, остальное в архив."
fi

# ── 3. Постоянный контекст раздулся ──────────────────────────────────────────
# Всё, что подключено через @include, читается при КАЖДОМ запуске.
always=0
for f in "$WS/CLAUDE.md" "$WS/core/USER.md" "$WS/core/rules.md"; do
  [[ -f "$f" ]] && always=$(( always + $(wc -c < "$f") ))
done
if (( always > 60000 )); then
  advise context-bloat "Братан, я жру контекст на старте.

Файлы, которые читаются при каждом запуске, разрослись до $(( always / 1024 )) КБ.
Это уходит в каждый мой запуск — и в счёт тоже.

Лечится за десять минут: вынести из постоянных файлов то, что нужно не всегда,
и читать по требованию. Скажи — разберу."
fi

# ── 4. Сервис падает ─────────────────────────────────────────────────────────
restarts=$(journalctl -u "dashi-$AGENT" --since "7 days ago" 2>/dev/null \
           | grep -c "Scheduled restart\|Failed with result" || true)
if (( restarts >= 10 )); then
  advise restarts "Братан, я падаю чаще обычного.

За неделю $restarts перезапусков. Обычно это протухший вход в Claude, кончившееся
место на диске или память.

Посмотри: journalctl -u dashi-$AGENT -n 50
Если там про вход — просто перелогинься: su - agent, потом claude."
fi

# ── 5. Диск ──────────────────────────────────────────────────────────────────
used=$(df --output=pcent "$WS" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$used" ]] && (( used >= 85 )); then
  advise disk "Братан, кончается диск — занято ${used}%.

Когда упрётся в сотню, я перестану писать память и логи, причём молча.
Обычно жрут логи: journalctl --vacuum-time=7d освобождает прилично."
fi

# ── 6. Памяти нет вообще ─────────────────────────────────────────────────────
# Агент живёт больше двух недель, а фактов ноль — значит человек не знает, что
# память надо наполнять словами «запомни, что…».
age_days=$(( ( $(date +%s) - $(stat -c %Y "$WS/CLAUDE.md" 2>/dev/null || date +%s) ) / 86400 ))
if (( facts == 0 && age_days >= 14 )); then
  advise memory-empty "Братан, я до сих пор ничего о тебе не помню.

Работаю уже $age_days дней, а память пустая — каждый раз начинаю с чистого листа.
Заполняется просто: скажи «запомни, что…» — и я сохраню. Или «проведи со мной
интервью и заполни профиль», и я спрошу сам."
fi

# ── Вышло обновление моста? Хозяин решает сам: поставить — /update, нет — игнор.
# Ключ с sha: новое письмо только когда в origin появились новые коммиты.
REPO="$WS/dashi-plugin-claude-code"
if [[ -d "$REPO/.git" ]] && git -C "$REPO" fetch -q --depth 30 origin main 2>/dev/null; then
  newlog="$(git -C "$REPO" log --oneline HEAD..FETCH_HEAD 2>/dev/null | head -15)"
  if [[ -n "$newlog" ]]; then
    sha="$(git -C "$REPO" rev-parse --short FETCH_HEAD)"
    n="$(git -C "$REPO" rev-list --count HEAD..FETCH_HEAD)"
    body="$(echo "$newlog" | sed -E 's/^[0-9a-f]+ /• /' | sed 's/&/\&amp;/g; s/</\&lt;/g')"
    advise "plugin-update-$sha" "🔄 Вышло обновление моста ($n коммит.):
$body

Ставить не обязательно. Хочешь — ответь <code>/update</code>: сделаю бэкап, обновлюсь и перезапущусь (при сбое откачусь сам)."
  fi
fi

[[ $DRY -eq 1 ]] && echo "(dry-run: ничего не отправлено)"
exit 0
