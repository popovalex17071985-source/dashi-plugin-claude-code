#!/usr/bin/env bash
# Смоук комплекта дисциплины: раскатываем в песочницу и проверяем, что гейты
# ЖИВЫЕ, а не просто скопированы. Хук, который ни разу не сработал, — не механизм.
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)/agent-kit"
INSTALLER="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-agent.sh"
fail() { echo "✗ $1" >&2; exit 1; }

bash -n "$KIT/install-kit.sh" || fail "синтаксис install-kit.sh"
grep -q "install-kit.sh" "$INSTALLER" || fail "установщик не зовёт комплект"
# Кроны сводки и будильника ставит сам комплект (f7e3907), не установщик
grep -q "open-threads-digest.py --send" "$KIT/install-kit.sh" || fail "утренняя сводка не в кроне"
grep -q "promise-sweeper.py" "$KIT/install-kit.sh" || fail "будильник по срокам не в кроне"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/core"
# crontab — подменный: комплект пишет в крон, а тест не должен трогать живой
# крон того, кто его гоняет (раньше спасало только то, что строки уже стояли)
mkdir -p "$T/shim"; export CRONTAB_FILE="$T/crontab.txt"
cat > "$T/shim/crontab" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -l) cat "$CRONTAB_FILE" 2>/dev/null ;;
  -)  cat > "$CRONTAB_FILE" ;;
  *)  echo "shim: unsupported $*" >&2; exit 1 ;;
esac
SH
chmod +x "$T/shim/crontab"; export PATH="$T/shim:$PATH"
# Чужая строка в кроне (другой агент) — комплект обязан её не трогать
echo "30 7 * * * /usr/bin/python3 /srv/other/bin/promise-sweeper.py" > "$CRONTAB_FILE"
printf '# Агент\n\n@core/rules.md\n' > "$T/.claude/CLAUDE.md"
printf '# Правила и правки\n- правка хозяина\n' > "$T/.claude/core/rules.md"

bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke >/dev/null \
  || fail "install-kit упал"

# Личные правки хозяина комплект не трогает
grep -q "правка хозяина" "$T/.claude/core/rules.md" || fail "затёр core/rules.md хозяина"
[[ -s "$T/.claude/core/constitution.md" ]] || fail "нет конституции"
grep -q "core/constitution.md" "$T/.claude/CLAUDE.md" || fail "конституция не подключена в CLAUDE.md"

# Плейсхолдеры обязаны быть подставлены — иначе хук молча смотрит в никуда
! grep -rq "__CLAUDE_DIR__\|__CHAT_ID__\|__AGENT__" "$T" || fail "остались плейсхолдеры"

n=$(python3 -c "
import json;d=json.load(open('$T/.claude/settings.json'))
print(sum(len(e['hooks']) for a in d['hooks'].values() for e in a))")
[[ "$n" == 9 ]] || fail "зарегистрировано хуков: $n (ждём 9)"

H="$T/.claude/hooks"
# 1. опасная команда
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /var/data"}}' \
  | "$H/block-dangerous.sh" >/dev/null 2>&1 && fail "опасная команда прошла"
# 2. запись секрета
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x/api.key"}}' \
  | "$H/block-red-zone.sh" >/dev/null 2>&1 && fail "запись секрета прошла"
# 3. ждун, матчащий сам себя
echo '{"tool_name":"Bash","tool_input":{"command":"until pgrep -f job; do sleep 60; done"}}' \
  | "$H/block-selfmatching-pgrep.sh" | grep -q "\"permissionDecision\": \"deny\"" \
  || fail "самоматчащийся pgrep не отклонён"
# 4. кириллица в конституции
python3 -c "
import json;print(json.dumps({'tool_input':{'file_path':'$T/.claude/core/constitution.md','new_string':'Это длинное русское правило про источники. '*12}}))" \
  | "$H/cyrillic-guard.sh" >/dev/null 2>&1 && fail "кириллица в конституции прошла"
# 5. урок без механизма
echo "{\"tool_input\":{\"file_path\":\"$T/.claude/core/LEARNINGS.md\"}}" \
  | "$H/lesson-needs-mechanism.sh" >/dev/null 2>&1 && fail "урок без механизма прошёл"
# 6. отказ без перебора путей
J="$T/t.jsonl"; python3 - "$J" <<'PY'
import json, sys
rows = [{"type": "user", "message": {"content": "посмотри почему не работает"}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use",
         "name": "mcp__dashi-channel__reply",
         "input": {"text": "Не могу — нет доступа, жду от тебя логин."}}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
PY
echo "{\"transcript_path\":\"$J\",\"session_id\":\"s\"}" \
  | python3 "$H/stop-blocker-gate.py" | grep -q '"decision": "block"' \
  || fail "отказ без перебора не заблокирован"

# Самопроверки перенесённых скриптов
python3 "$T/bin/promise-sweeper.py" --selfcheck >/dev/null || fail "будильник по срокам"
python3 "$T/bin/open-threads-digest.py" --selfcheck >/dev/null || fail "утренняя сводка"

# Кроны: свои строки поставлены, чужая цела
[[ "$(grep -c "$T/bin/promise-sweeper.py" "$CRONTAB_FILE")" == 1 ]] || fail "будильник не в кроне"
[[ "$(grep -c "$T/bin/open-threads-digest.py --send" "$CRONTAB_FILE")" == 1 ]] || fail "сводка не в кроне"
grep -q "/srv/other/bin/promise-sweeper.py" "$CRONTAB_FILE" || fail "затёр чужую строку крона"

# Повторный прогон ничего не задваивает
bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke >/dev/null
n2=$(python3 -c "
import json;d=json.load(open('$T/.claude/settings.json'))
print(sum(len(e['hooks']) for a in d['hooks'].values() for e in a))")
[[ "$n2" == 9 ]] || fail "повторный прогон задвоил хуки: $n2"
[[ "$(grep -c 'core/constitution.md' "$T/.claude/CLAUDE.md")" == 1 ]] || fail "задвоил @include"
[[ "$(grep -c "$T/bin/" "$CRONTAB_FILE")" == 2 ]] || fail "повторный прогон задвоил крон"

# Смена --tz переписывает СВОИ строки (час меняется), а не пропускает их
bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke --tz Asia/Yekaterinburg >/dev/null
h1="$(grep "$T/bin/open-threads-digest.py" "$CRONTAB_FILE" | awk '{print $2}')"
bash "$KIT/install-kit.sh" --claude-dir "$T/.claude" --chat-id 42 --agent smoke --tz Europe/Moscow >/dev/null
h2="$(grep "$T/bin/open-threads-digest.py" "$CRONTAB_FILE" | awk '{print $2}')"
[[ "$h1" =~ ^[0-9]+$ && "$h2" =~ ^[0-9]+$ && "$h1" != "$h2" ]] || fail "смена --tz не переписала час крона ($h1 -> $h2)"
[[ "$(grep -c "$T/bin/" "$CRONTAB_FILE")" == 2 ]] || fail "смена --tz задвоила крон"
grep -q "/srv/other/bin/promise-sweeper.py" "$CRONTAB_FILE" || fail "смена --tz затёрла чужую строку"

echo "✓ agent-kit smoke ok (9 хуков, 6 гейтов сработали, идемпотентно)"
