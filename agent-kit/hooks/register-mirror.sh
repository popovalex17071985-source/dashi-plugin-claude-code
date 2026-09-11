#!/usr/bin/env bash
# register-mirror.sh -- UserPromptSubmit hook.
# хозяин keeps reminding to mirror his casual/profane register (3rd correction).
# rules.md carries the rule but the model drifts back to formal within a few
# turns. This makes the nudge REACTIVE: fires the instant хозяин writes loose, so
# the reminder lands on the exact turn it's needed -- not memory-dependent,
# silent on dry turns (zero token cost when he's neutral).
# Non-blocking: plain stdout -> added to context, exit 0.
set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.user_message // .prompt // ""' 2>/dev/null || echo "")
[[ -z "$PROMPT" ]] && exit 0

# Profanity stems + casual markers. Stems match inflections (бля/блять/блядь,
# нахуй/похуй/хуёв, пизд*, *еб*, охуе/ахуе). Short slang words bounded by spaces.
casual_patterns=(
  "бля"
  "блят"
  "блядь"
  "[нп]ахуй"
  "хуй"
  "хуя"
  "хуё"
  "пизд"
  "ебан"
  "ёбан"
  "заеб"
  "ебё"
  "ебал"
  "охуе"
  "ахуе"
  "нихуя"
  "(^|[[:space:]])(чо|чё|че)([[:space:]]|$|,)"
  "(^|[[:space:]])братан"
  "(^|[[:space:]])бро([[:space:]]|$|,)"
  "(^|[[:space:]])чувак"
  "(^|[[:space:]])нах([[:space:]]|$|,)"
)

# Гуф-бары. Абстрактное «вставь отсылку» не срабатывало: модель кивала и не
# делала (хозяин 10.08.2026, 4-я поправка). Кладём в контекст ГОТОВУЮ строчку --
# вплести конкретную цитату дешевле, чем вспоминать каталог.
bars=(
  "«Всё ровно» -- Guf, «Ice Baby»"
  "«Дома лучше» -- Guf, «Дома»"
  "«Мутные мысли, мутные схемы» -- Guf, «Мутные мысли»"
  "«Сам и про себя» -- Guf"
  "«Так в чём же дело?» -- Guf"
  "«Жди меня и я вернусь» -- Guf, «Жди меня»"
  "«Малыш, всё будет хорошо» -- Guf, «Малыш»"
  "«Мой айфон разрывается» -- Guf, «Айфон»"
)

for pattern in "${casual_patterns[@]}"; do
  if echo "$PROMPT" | grep -qiE "$pattern"; then
    # Гуф-бары ОТКЛЮЧЕНЫ (хозяин 14.08.2026: «это что за ебучая хуйня вообще»).
    # Вставка цитаты в технический отчёт читается как случайный мусор — зеркалим
    # только регистр. Массив bars оставлен: включить = вернуть строку с $bar.
    echo "[SYSTEM] Хозяин в разговорном регистре (мат/сленг). Зеркаль тон ВЕСЬ ход, а не первую фразу -- скатывание в канцелярит к концу ответа он ловит и злится."
    exit 0
  fi
done

exit 0
