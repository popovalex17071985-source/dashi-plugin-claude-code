#!/usr/bin/env bash
# Долгая команда, которая САМА отчитывается в личку (Саня, 30.07: «ты нихуя не
# доделываешь пока тебя не пнешь»).
#
# Корень проблемы: я запускал долгий прогон и ждал его отдельным «ожидателем».
# Ожидатель мог умереть — и тогда результат не приходил никому, а задача висела
# до тычка. Здесь отчёт привязан к САМОЙ команде: она либо доложила успех, либо
# доложила падение. Третьего состояния «тишина» нет.
#
#   bin/run-and-report.sh "пересборка applefeed" bash bin/gincore/applefeed-refresh.sh
#   TAIL=15 bin/run-and-report.sh "прогон отказников" python3 bin/gincore/refused-daily.py
#   ONLY_FAIL=1 bin/run-and-report.sh "выгрузка в ВК" node bin/vk-export-now.js
set -uo pipefail

ROOT=__WORKSPACE__
TAIL="${TAIL:-8}"
TITLE="${1:?нужно описание задачи}"
shift || true
[ "$#" -gt 0 ] || { echo "нужна команда" >&2; exit 2; }

LOG=$(mktemp /tmp/run-and-report.XXXXXX.log)

# Реестр запущенных задач: строка на старте, отметка на финише. Его читает
# сторож bin/job-watch.py -- задача, у которой процесс умер, а финиша нет,
# больше не превращается в тишину (хозяин 11.09.2026).
JOBS="$ROOT/data/jobs.jsonl"
JOB_ID="$$-$(date +%s)"
python3 - "$JOBS" "$JOB_ID" "$TITLE" "$LOG" <<'PYJOB' 2>/dev/null || true
import json, os, sys, datetime
jobs, jid, title, log = sys.argv[1:5]
os.makedirs(os.path.dirname(jobs), exist_ok=True)
with open(jobs, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"id": jid, "pid": os.getppid(), "title": title, "log": log,
                         "started": datetime.datetime.now().isoformat(timespec="seconds"),
                         "done": None}, ensure_ascii=False) + "\n")
PYJOB
START=$(date +%s)
"$@" >"$LOG" 2>&1
RC=$?
python3 - "$JOBS" "$JOB_ID" <<'PYJOB' 2>/dev/null || true
import json, sys, datetime
jobs, jid = sys.argv[1:3]
with open(jobs, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"id": jid, "done": datetime.datetime.now().isoformat(timespec="seconds")}) + "\n")
PYJOB
MIN=$(( ($(date +%s) - START) / 60 ))

if [ "$RC" -eq 0 ]; then
  MSG="✅ $TITLE — готово за ${MIN} мин.

$(tail -n "$TAIL" "$LOG" | cut -c1-300)"
else
  # В личку уходит СУТЬ, а не питоновский трейс: хозяин 08.09.2026 на хвост
  # «File ... in _call_chain» ответил «это что за хуета?». Строки стека
  # (отступ, File, Traceback, ^^^) режем, берём последние осмысленные.
  KEEP=$(grep -vE '^\s|^Traceback|^\s*\^+$' "$LOG" | tail -n 3 | cut -c1-300)
  FAILLOG="/tmp/bg-fail-$(date +%H%M%S).log"
  cp "$LOG" "$FAILLOG"
  MSG="❌ $TITLE — упало (код $RC) через ${MIN} мин.

${KEEP:-без вывода}

полный лог: $FAILLOG"
fi

# ONLY_FAIL=1 — молчать при успехе (для частых кронов, где успех = шум)
if [ "$RC" -ne 0 ] || [ -z "${ONLY_FAIL:-}" ]; then
  /usr/bin/python3 "$ROOT/bin/tg-send.py" "$MSG" ${CHAT:+--chat "$CHAT"} || true
fi
cat "$LOG"
rm -f "$LOG"
exit "$RC"
