#!/usr/bin/env bash
# Токен на экране setup-token переносится посреди строки — экстрактор обязан
# склеить и не прихватить следующий за ним текст (27.08.2026: установка встала).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(awk '/^strip_ws\(\)/{print} /^extract_token\(\)/,/^\}$/{print}' "$HERE/../scripts/install-agent.sh")"

TOK="sk-ant-oat01-$(printf 'A%.0s' {1..60})-$(printf 'b%.0s' {1..40})CgAA"
LOG="$(mktemp)"
{ echo "Welcome to Claude Code v2.1.247"
  echo "Your OAuth token (valid for 1 year):"
  echo "${TOK:0:78}"; echo "${TOK:78}"          # перенос ровно посреди токена
  echo "Store this token securely. You won't be able to see it again."
} > "$LOG"

GOT="$(extract_token "$LOG")"
[[ "$GOT" == "$TOK" ]] || { echo "FAIL: выловил «$GOT», ждал «$TOK»" >&2; exit 1; }
[[ "$(strip_ws "  ${TOK:0:40}
${TOK:40}  ")" == "$TOK" ]] || { echo "FAIL: strip_ws не склеил двустрочную вставку" >&2; exit 1; }
# Токен на экране ПОКРАШЕН: перенос строки несёт цветовые коды прямо внутри
# токена. До 06.09.2026 экстрактор на этом сдавался и вываливал человека в
# ручной ввод.
ANSI="$(mktemp)"; trap 'rm -f "$LOG" "$ANSI"' EXIT
{ echo "Your OAuth token (valid for 1 year):"
  printf '\033[38;5;209m%s\033[39m\r\n' "${TOK:0:78}"
  printf '\033[38;5;209m%s\033[39m\r\n' "${TOK:78}"
  echo "Store this token securely."
} > "$ANSI"
GOT_A="$(extract_token "$ANSI")"
[[ "$GOT_A" == "$TOK" ]] || { echo "FAIL: цветной токен -- выловил «$GOT_A»" >&2; exit 1; }

# Первым куском вставляют код авторизации со страницы; накопитель обязан
# сбросить мусор, иначе все попытки сгорают (живая установка 06.09.2026).
SANITIZE="$(grep -F 'CLAUDE_TOKEN="sk-ant-${CLAUDE_TOKEN##*sk-ant-}"' "$HERE/../scripts/install-agent.sh")"
CLAUDE_TOKEN="cQk51bNAs4HZP1OOCy70iFG2#I7Ot8wp${TOK:0:78}"; eval "$SANITIZE"
CLAUDE_TOKEN="$CLAUDE_TOKEN${TOK:78}"; eval "$SANITIZE"
[[ "$CLAUDE_TOKEN" == "$TOK" ]] || { echo "FAIL: мусорный первый кусок отравил накопитель: «$CLAUDE_TOKEN»" >&2; exit 1; }

echo "extract-token OK (${#GOT} знаков, цвет снят, мусор сброшен)"
