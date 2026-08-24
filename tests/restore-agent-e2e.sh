#!/usr/bin/env bash
# E2E restore-agent.sh на «чистом сервере» = systemd-контейнер ubuntu:22.04.
# Проверяет полный путь: краш VPS → новый сервер → одна команда → агент восстановлен.
# Успех = restore дошёл до входа в Claude, при этом на месте: workspace с памятью,
# /etc/dashi-plugin/<agent>/channel.env (токен), systemd-юнит. Вход (OAuth) —
# единственное, что headless не проверить, как и в install-смоуке.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
C=restore-e2e-$$
AGENT=testbot
RUSER=agent   # restore-agent.sh по умолчанию ставит агента под юзера 'agent' (как install-agent)
PASS=e2epass123
WORK=/tmp/restore-e2e-$$
# При обрыве контейнер НЕ трогаем (для разбора); чистим только временное.
# Успешный конец удалит контейнер сам (в самом низу).
trap 'rm -rf "$WORK"' EXIT
ok(){ echo "✓ $1"; }
fail(){ echo "✗ $1" >&2; exit 1; }

# 1. Craft реалистичный архив, как его делает agent-backup.sh.
mkdir -p "$WORK/ws/.claude/memory" "$WORK/ws/secrets" "$WORK/ws/deploy" "$WORK/ws/state/telegram"
echo "# Индекс памяти: факт про оператора" > "$WORK/ws/.claude/memory/MEMORY.md"
echo "# characterX агента" > "$WORK/ws/.claude/CLAUDE.md"
echo "SUPPLIER_TOKEN=restore-secret-xyz" > "$WORK/ws/secrets/api.token"
cat > "$WORK/ws/deploy/channel.env" <<EOF
TELEGRAM_BOT_TOKEN=123456:AAFakeTokenForE2ETestOnly_abcDEF
TELEGRAM_ALLOWED_USER_IDS=140141496
TELEGRAM_WORKSPACE_ROOT=/home/agent/.claude-lab/$AGENT/.claude
EOF
echo '{"webhook":{"enabled":true}}' > "$WORK/ws/state/telegram/config.json"
echo "$PASS" > "$WORK/pass"
(cd "$WORK/ws" && tar czf - .claude secrets deploy state) \
  | gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "$WORK/pass" -o "$WORK/arch.tar.gz.gpg"
ok "архив собран ($(du -h "$WORK/arch.tar.gz.gpg"|cut -f1))"

# 2. Чистый systemd-контейнер. Голый ubuntu:22.04 без systemd — ставим его и
#    запускаем как PID1 (иначе systemctl в install-agent не сработает).
docker run -d --name "$C" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
  ubuntu:22.04 bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv git curl sudo >/dev/null 2>&1; exec /lib/systemd/systemd" \
  >/dev/null || fail "контейнер не стартовал"
for i in $(seq 1 90); do docker exec "$C" systemctl is-system-running >/dev/null 2>&1 && break; sleep 2; done
docker exec "$C" systemctl is-system-running >/dev/null 2>&1 || docker exec "$C" test -d /run/systemd/system \
  || fail "systemd в контейнере не поднялся"
ok "контейнер с systemd поднят"

# 3. Внести плагин, архив, пароль (git/curl/sudo уже поставлены выше).
docker cp "$PLUGIN" "$C:/opt/plugin" >/dev/null
docker cp "$WORK/arch.tar.gz.gpg" "$C:/root/arch.tar.gz.gpg" >/dev/null
ok "плагин и архив внесены"

# 4. ГЛАВНОЕ: одна команда восстановления.
echo "--- restore-agent.sh (может занять несколько минут: node/bun/claude) ---"
docker exec "$C" bash /opt/plugin/scripts/restore-agent.sh \
  --name "$AGENT" --archive /root/arch.tar.gz.gpg --pass "$PASS" \
  --repo /opt/plugin --branch "$(cd "$PLUGIN" && git branch --show-current)" --yes 2>&1 | tail -40
rc=${PIPESTATUS[0]}

# 5. Проверки инвариантов восстановления (вход не проверяем — headless).
echo "--- проверки ---"
docker exec "$C" test -f /home/$RUSER/.claude-lab/$AGENT/.claude/memory/MEMORY.md \
  && ok "память восстановлена" || fail "нет памяти после restore"
docker exec "$C" grep -q "SUPPLIER_TOKEN=restore-secret-xyz" /home/$RUSER/.claude-lab/$AGENT/secrets/api.token \
  && ok "секреты восстановлены" || fail "секреты не восстановлены"
docker exec "$C" grep -q "AAFakeTokenForE2ETestOnly" /etc/dashi-plugin/$AGENT/channel.env \
  && ok "channel.env (токен бота) возвращён в /etc" || fail "channel.env не восстановлен"
docker exec "$C" test -f /etc/systemd/system/dashi-$AGENT.service \
  && ok "systemd-юнит на месте" || fail "нет юнита сервиса"
docker exec "$C" bash -c "command -v claude >/dev/null" \
  && ok "Claude Code установлен" || fail "claude не встал"

echo
[[ $rc -eq 0 ]] && echo "✓✓ restore e2e ПРОЙДЕН (до входа в Claude)" \
  || echo "⚠ restore завершился с rc=$rc, но инварианты выше проверены — см. хвост лога"

echo "--- cleanup контейнера (успех) ---"
docker rm -f "$C" >/dev/null 2>&1 || true
