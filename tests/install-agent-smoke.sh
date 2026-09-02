#!/usr/bin/env bash
# Смоук установщика. Полный прогон требует чистого сервера и root, поэтому здесь
# проверяем то, что проверяемо без них: синтаксис, отказ не-root, справку и
# инварианты, потеря которых стоила нам дня при ручной установке.
set -euo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-agent.sh"
fail() { echo "✗ $1" >&2; exit 1; }

bash -n "$S" || fail "синтаксис"

bash "$S" --help | grep -q "install-agent.sh" || fail "--help молчит"

# Под обычным юзером обязан отказаться, а не наломать дров
if [[ $EUID -ne 0 ]]; then
  out="$(bash "$S" --name test --yes 2>&1 || true)"
  grep -q "под root" <<<"$out" || fail "нет гейта на root"
fi

# Агент НЕ под root: иначе Claude не запускается без подтверждений
grep -q 'adduser --disabled-password' "$S" || fail "не заводит отдельного пользователя"
grep -q 'User=\$SERVICE_USER'          "$S" || fail "юнит крутится не под service-юзером"

# Плагин строго внутри .claude — иначе «no MCP server configured with that name»
grep -q 'PLUGIN_DIR="\$CLAUDE_DIR/dashi-plugin-claude-code/plugin"' "$S" \
  || fail "плагин кладётся мимо workspace"

# Секреты закрыты от посторонних (660 root:agent — агент правит конфиг сам)
grep -q 'chmod 660 "\$ENV_FILE"' "$S" || fail "конфиг с секретами не закрыт"
# Restart=always безопасен с тех пор, как диалоги жмёт dashi-press-dialogs
grep -q 'Restart=always'          "$S" || fail "сервис должен подниматься сам (Restart=always)"

# Годовой токен вместо 30-дневного логина: setup-token + запись в channel.env
grep -q 'claude setup-token'          "$S" || fail "нет входа через setup-token (годовой токен)"
grep -q 'CLAUDE_CODE_OAUTH_TOKEN='    "$S" || fail "токен не пишется в channel.env"
grep -q -- '--claude-token'           "$S" || fail "нет флага --claude-token для готового токена"

# Модель агента: флаг --model → DASHI_MODEL в channel.env → --model у claude в tmux
grep -q -- '--model)'                 "$S" || fail "нет флага --model"
grep -q 'DASHI_MODEL=\$MODEL'         "$S" || fail "модель не пишется в channel.env"
grep -q 'claude \${DASHI_MODEL:+--model \$DASHI_MODEL}' "$S" || fail "dashi-run не передаёт модель claude"

# Ремонтник-страховка: отдельный бот, отдельный юнит, не под root
grep -q -- '--repair-token'           "$S" || fail "нет флага --repair-token (бот-страховка)"
grep -q 'claude-code-telegram'        "$S" || fail "ремонтник не ставит claude-code-telegram"

echo "✓ install-agent smoke ok"

# 02.09.2026: `read -p ... 2>/dev/null` глотал сам ВОПРОС (bash печатает prompt в stderr) —
# живой прогон на Смите молча висел на «Имя агента». Приглашение обязано доходить до экрана.
grep -qE 'read -r -p "\$__prompt" __val </dev/tty 2>/dev/null' "$INSTALLER" 2>/dev/null \
  && fail "ask(): stderr read'а уведён в /dev/null — приглашение не видно" || true
