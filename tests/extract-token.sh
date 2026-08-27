#!/usr/bin/env bash
# Токен на экране setup-token переносится посреди строки — экстрактор обязан
# склеить и не прихватить следующий за ним текст (27.08.2026: установка встала).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(awk '/^strip_ws\(\)/{print} /^extract_token\(\)/,/^\}$/{print}' "$HERE/../scripts/install-agent.sh")"

TOK="sk-ant-oat01-$(printf 'A%.0s' {1..60})-$(printf 'b%.0s' {1..40})CgAA"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
{ echo "Welcome to Claude Code v2.1.247"
  echo "Your OAuth token (valid for 1 year):"
  echo "${TOK:0:78}"; echo "${TOK:78}"          # перенос ровно посреди токена
  echo "Store this token securely. You won't be able to see it again."
} > "$LOG"

GOT="$(extract_token "$LOG")"
[[ "$GOT" == "$TOK" ]] || { echo "FAIL: выловил «$GOT», ждал «$TOK»" >&2; exit 1; }
[[ "$(strip_ws "  ${TOK:0:40}
${TOK:40}  ")" == "$TOK" ]] || { echo "FAIL: strip_ws не склеил двустрочную вставку" >&2; exit 1; }
echo "extract-token OK (${#GOT} знаков, перенос склеен, хвост не прилип)"
