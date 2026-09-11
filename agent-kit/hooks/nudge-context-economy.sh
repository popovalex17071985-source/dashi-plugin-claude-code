#!/usr/bin/env bash
# PreToolUse -> Read|Bash. Non-blocking context-economy nudge.
# Cache (read+creation) is ~82% of Opus 4.8 spend; the controllable driver is
# per-turn context growth. This hook nudges (does NOT block) when a call is about
# to pull a large blob into context without a limiter. Exit 0 always; the nudge
# is fed to the model via hookSpecificOutput.additionalContext.
set -euo pipefail

LARGE_LINES=1500     # Read without limit above this -> nudge
LARGE_BYTES=60000    # ~15k tokens

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"

nudge() {
  # Emit non-blocking additionalContext, then allow the call.
  jq -nc --arg msg "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$msg}}'
  exit 0
}

case "$tool" in
  Skill)
    skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // .tool_input.name // ""')"
    case "$skill" in
      claude-api)
        nudge "context-economy: скилл '$skill' грузит ~40K токенов и потом перечитывается каждый ход. Цены/ID моделей есть в shared/models.md (Read с limit). Зови полный скилл только если нужны SDK-паттерны/код, не ради одной цифры." ;;
    esac
    ;;
  Read)
    fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
    limit="$(printf '%s' "$input" | jq -r '.tool_input.limit // ""')"
    [[ -z "$fp" || ! -f "$fp" ]] && exit 0
    [[ -n "$limit" ]] && exit 0   # already chunked -> fine
    bytes="$(wc -c <"$fp" 2>/dev/null || echo 0)"
    lines="$(wc -l <"$fp" 2>/dev/null || echo 0)"
    if (( bytes > LARGE_BYTES || lines > LARGE_LINES )); then
      nudge "context-economy: $fp ~${lines} строк/${bytes}B. Каждый токен осядет в кэш и будет перечитываться каждый ход (~82% счёта). Читай с limit/offset, grep по нужному, или Explore-субагентом — если не нужен весь файл целиком."
    fi
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
    [[ -z "$cmd" ]] && exit 0
    # Raw whole-file/dir dumps with no limiter (head/tail/wc/grep/jq/less/-n).
    if echo "$cmd" | grep -qiE '(^|[;&|][[:space:]]*)(cat|less|more)[[:space:]]+[^|]+$' \
       && ! echo "$cmd" | grep -qiE '\|[[:space:]]*(head|tail|wc|grep|jq|sed|awk)'; then
      nudge "context-economy: сырой дамп файла в контекст. Пропусти через head/tail/wc/grep, чтобы не раздувать кэш (~82% счёта Opus 4.8)."
    fi
    ;;
esac

exit 0
