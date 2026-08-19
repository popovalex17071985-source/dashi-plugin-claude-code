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

# Секреты закрыты, и restart не «always» — иначе welcome-промт зациклит сервис
grep -q 'chmod 640 "\$ENV_FILE"' "$S" || fail "конфиг с секретами не закрыт"
grep -q 'Restart=on-failure'      "$S" || fail "Restart должен быть on-failure"

echo "✓ install-agent smoke ok"
