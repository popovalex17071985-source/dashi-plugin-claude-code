#!/usr/bin/env bash
# Смоук: сторож контекста молчит на пустяке, предупреждает на 70%+ и 85%+,
# и не повторяет одно и то же предупреждение дважды за сессию.
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/context-watch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000

transcript() {  # transcript <токенов>
  printf '{"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$1" > "$TMP/t.jsonl"
}
run() {  # run <session_id> -> stdout хука
  jq -nc --arg t "$TMP/t.jsonl" --arg s "$1" '{transcript_path:$t,session_id:$s}' | bash "$HOOK"
}
fail() { echo "FAIL: $1" >&2; exit 1; }

transcript 40000   # 20%
[[ -z "$(run s1)" ]] || fail "на 20% должен молчать"

transcript 150000  # 75%
out="$(run s1)"; [[ "$out" == *compact* ]] || fail "на 75% нет подсказки про /compact"
[[ -z "$(run s1)" ]] || fail "повтор того же порога в одной сессии"

transcript 180000  # 90%
out="$(run s1)"; [[ "$out" == *"/new"* ]] || fail "на 90% нет подсказки про /new"

transcript 150000
[[ -n "$(run s2)" ]] || fail "новая сессия должна получить предупреждение"

echo '{"session_id":"s3"}' | bash "$HOOK" >/dev/null || fail "без транскрипта должен выходить тихо и с нулём"

grep -q context-watch.sh "$(dirname "$HOOK")/install-agent.sh" || fail "установщик не прописывает сторож"
echo "OK: context-watch"
