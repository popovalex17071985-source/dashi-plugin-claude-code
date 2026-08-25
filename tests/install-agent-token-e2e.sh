#!/usr/bin/env bash
# E2E install-agent.sh с годовым токеном (--claude-token) на «чистом сервере» =
# systemd-контейнер ubuntu:22.04. Проверяет главное обещание фичи: установка
# проходит ОДНИМ прогоном без остановки «войди в Claude и перезапусти», токен
# ложится в channel.env и доезжает до окружения сервиса. Сам вход в Anthropic
# headless не проверить (токен фейковый) — живой Claude тут не критерий.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
C=install-e2e-$$
AGENT=testbot
# 2000 байт: tr -dc выбрасывает ~3/4 байтов, из 200 выходило ~75 знаков — короче
# валидатора {100,}, и установщик честно отбивал «токен»
FAKE_TOKEN="sk-ant-oat01-$(head -c 2000 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 120)"
ok(){ echo "✓ $1"; }
fail(){ echo "✗ $1" >&2; exit 1; }

# 1. Чистый systemd-контейнер (как в restore-agent-e2e.sh).
docker run -d --name "$C" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
  ubuntu:22.04 bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv git curl sudo >/dev/null 2>&1; exec /lib/systemd/systemd" \
  >/dev/null || fail "контейнер не стартовал"
for i in $(seq 1 90); do docker exec "$C" systemctl is-system-running >/dev/null 2>&1 && break; sleep 2; done
docker exec "$C" test -d /run/systemd/system || fail "systemd в контейнере не поднялся"
ok "контейнер с systemd поднят"

docker cp "$PLUGIN" "$C:/opt/plugin" >/dev/null
ok "плагин внесён"

# 2. ГЛАВНОЕ: установка одним прогоном, без tty, с готовым годовым токеном.
echo "--- install-agent.sh (несколько минут: node/bun/claude) ---"
docker exec "$C" bash /opt/plugin/scripts/install-agent.sh \
  --name "$AGENT" --token "123456:AAFakeTokenForE2ETestOnly_abcDEF" --user-id 140141496 \
  --claude-token "$FAKE_TOKEN" \
  --repo /opt/plugin --branch "$(cd "$PLUGIN" && git branch --show-current)" --yes 2>&1 | tail -30
rc=${PIPESTATUS[0]}

echo "--- проверки ---"
# Установщик не должен ни упасть, ни выйти на «осталось войти в Claude».
[[ $rc -eq 0 ]] || fail "install-agent.sh завершился с кодом $rc"
ok "прошёл одним прогоном (rc=0)"

docker exec "$C" grep -q "^CLAUDE_CODE_OAUTH_TOKEN=$FAKE_TOKEN$" "/etc/dashi-plugin/$AGENT/channel.env" \
  || fail "токен не записан в channel.env"
ok "годовой токен в channel.env"

docker exec "$C" grep -q "EnvironmentFile=/etc/dashi-plugin/$AGENT/channel.env" \
  "/etc/systemd/system/dashi-$AGENT.service" || fail "юнит не читает channel.env"
ok "юнит подхватывает channel.env (токен доедет до Claude)"

docker exec "$C" systemctl is-enabled --quiet "dashi-$AGENT" || fail "сервис не включён в автозапуск"
ok "сервис включён"

# Токен фейковый — живого ответа Claude не ждём; но окружение tmux-сессии
# должно нести токен (значит, настоящий залогинит без диалога).
sleep 10
if docker exec "$C" su - agent -c "tmux has-session -t channel-$AGENT" 2>/dev/null; then
  docker exec "$C" bash -c "tr '\0' '\n' < /proc/\$(pgrep -u agent -f 'claude' | head -1)/environ 2>/dev/null | grep -q '^CLAUDE_CODE_OAUTH_TOKEN='" \
    && ok "токен виден в окружении процесса Claude" \
    || echo "· окружение процесса не проверить (claude ещё не поднялся) — не критерий"
fi

docker rm -f "$C" >/dev/null 2>&1
echo "✓ install-agent token e2e ok"
