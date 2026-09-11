#!/usr/bin/env bash
# correction-detector.sh -- UserPromptSubmit hook
# Детектирует фразы-поправки и напоминает сохранить learning
# stdout добавляется в контекст Claude (exit 0)

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_message // .prompt // ""' 2>/dev/null || echo "")

correction_patterns=(
  "не так\b"
  "неправильно"
  "не то\b"
  "ошибся"
  "я же сказал"
  "wrong"
  "not like that"
  "исправь себя"
  "запомни это"
  "добавь в learnings"
)

for pattern in "${correction_patterns[@]}"; do
  if echo "$PROMPT" | grep -qiE "$pattern"; then
    echo "[SYSTEM] Хозяин тебя поправил. После ответа запиши это в $CLAUDE_DIR/core/LEARNINGS.md строкой «- ГГГГ-ММ-ДД: <что исправлено>», а если это правило на будущее -- в core/rules.md. Иначе правка умрёт в переписке."
    exit 0
  fi
done

exit 0
