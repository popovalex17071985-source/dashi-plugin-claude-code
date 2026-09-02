#!/usr/bin/env bash
# health-check.sh -- VPS health snapshot
# Output: table [Проверка | Статус | Детали]
# Exit codes: 0=all OK, 1=any WARN, 2=any FAIL
# Self-tests: HEALTH_TEST=1 bash health-check.sh

set -uo pipefail

CRED_PATH="${CRED_PATH:-$HOME/.claude/.credentials.json}"
# claude-gateway retired at the plugin cutover (2026-06-14); dropped from monitoring
# 2026-06-18 after a clean run on the plugin — was firing a daily false FAIL.
AGENT="__AGENT__"
WORKSPACE="${WORKSPACE:-__WORKSPACE__}"
# Сервисы агента: свой юнит всегда, ремонтник — если поставлен.
SERVICES=("dashi-$AGENT")
systemctl list-unit-files "claude-repair-$AGENT.service" >/dev/null 2>&1 \
  && SERVICES+=("claude-repair-$AGENT")
HEARTBEAT="${HEARTBEAT:-$WORKSPACE/data/cron-heartbeat}"
BACKUP_DIR="${BACKUP_DIR:-$WORKSPACE/backups}"

# --- Pure functions (tested) ---

# classify_pct VALUE WARN_AT FAIL_AT LABEL -> echoes "STATUS|DETAILS"
classify_pct() {
  local pct="$1" warn="$2" fail="$3" label="$4"
  if [ "$pct" -ge "$fail" ]; then
    printf 'FAIL|%s %s%%\n' "$label" "$pct"
  elif [ "$pct" -ge "$warn" ]; then
    printf 'WARN|%s %s%%\n' "$label" "$pct"
  else
    printf 'OK|%s %s%%\n' "$label" "$pct"
  fi
}

# classify_load LOAD_1M CORES -> echoes "STATUS|DETAILS"
# WARN if load >= cores*0.7, FAIL if load >= cores
classify_load() {
  local load="$1" cores="$2"
  local warn_thr fail_thr
  warn_thr=$(awk "BEGIN{print $cores*0.7}")
  fail_thr="$cores"
  awk -v l="$load" -v w="$warn_thr" -v f="$fail_thr" -v c="$cores" '
    BEGIN {
      if (l+0 >= f+0)      printf "FAIL|load %.2f / %d cores\n", l, c;
      else if (l+0 >= w+0) printf "WARN|load %.2f / %d cores\n", l, c;
      else                 printf "OK|load %.2f / %d cores\n", l, c;
    }'
}

# classify_service NAME ACTIVE_STATE -> echoes "STATUS|DETAILS"
classify_service() {
  local name="$1" state="$2"
  case "$state" in
    active)              printf 'OK|%s: %s\n'   "$name" "$state" ;;
    activating|reloading) printf 'WARN|%s: %s\n' "$name" "$state" ;;
    *)                   printf 'FAIL|%s: %s\n' "$name" "$state" ;;
  esac
}

# classify_credentials PATH -> echoes "STATUS|DETAILS"
classify_credentials() {
  local path="$1"
  if [ ! -e "$path" ]; then
    printf 'FAIL|%s missing\n' "$path"
  elif [ ! -s "$path" ]; then
    printf 'FAIL|%s empty\n' "$path"
  else
    local size
    size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    printf 'OK|%s (%db)\n' "$path" "$size"
  fi
}

# classify_backup AGE_H DETAILS -> echoes "STATUS|DETAILS"
# AGE_H = whole hours since the newest backup archive, or -1 if none exist.
# Daily backup: OK if <26h, WARN 26-47h (a run was likely missed), FAIL >=48h or none.
classify_backup() {
  local age="$1" detail="$2"
  if [ "$age" -lt 0 ]; then
    printf 'FAIL|бэкап: нет архивов\n'
  elif [ "$age" -ge 48 ]; then
    printf 'FAIL|бэкап: %dч назад (>48ч)\n' "$age"
  elif [ "$age" -ge 26 ]; then
    printf 'WARN|бэкап: %dч назад\n' "$age"
  else
    printf 'OK|бэкап: %s\n' "$detail"
  fi
}

# --- Self-tests ---

run_tests() {
  local fails=0 total=0
  assert() {
    total=$((total + 1))
    local expect="$1" got="$2" name="$3"
    if [ "$expect" = "$got" ]; then
      printf '  OK  %s\n' "$name"
    else
      printf '  FAIL %s\n    expect: %s\n    got:    %s\n' "$name" "$expect" "$got"
      fails=$((fails + 1))
    fi
  }

  echo "== classify_pct =="
  assert "OK|disk 50%"   "$(classify_pct 50 80 90 disk)" "disk 50% -> OK"
  assert "WARN|disk 80%" "$(classify_pct 80 80 90 disk)" "disk 80% (boundary) -> WARN"
  assert "WARN|disk 85%" "$(classify_pct 85 80 90 disk)" "disk 85% -> WARN"
  assert "FAIL|disk 90%" "$(classify_pct 90 80 90 disk)" "disk 90% (boundary) -> FAIL"
  assert "FAIL|disk 95%" "$(classify_pct 95 80 90 disk)" "disk 95% -> FAIL"
  assert "OK|RAM 0%"     "$(classify_pct 0 80 90 RAM)"   "RAM 0% -> OK"

  echo "== classify_load =="
  assert "OK|load 0.50 / 2 cores"   "$(classify_load 0.5 2)" "load 0.5 of 2 -> OK"
  assert "WARN|load 1.40 / 2 cores" "$(classify_load 1.4 2)" "load 1.4 of 2 -> WARN"
  assert "FAIL|load 2.00 / 2 cores" "$(classify_load 2.0 2)" "load 2.0 of 2 -> FAIL"
  assert "FAIL|load 3.50 / 2 cores" "$(classify_load 3.5 2)" "load 3.5 of 2 -> FAIL"

  echo "== classify_service =="
  assert "OK|claude-gateway: active"      "$(classify_service claude-gateway active)"     "active -> OK"
  assert "WARN|claude-gateway: activating" "$(classify_service claude-gateway activating)" "activating -> WARN"
  assert "FAIL|claude-gateway: inactive"   "$(classify_service claude-gateway inactive)"   "inactive -> FAIL"
  assert "FAIL|claude-gateway: failed"     "$(classify_service claude-gateway failed)"     "failed -> FAIL"
  assert "FAIL|claude-gateway: unknown"    "$(classify_service claude-gateway unknown)"    "unknown -> FAIL"

  echo "== classify_credentials =="
  local tmp; tmp=$(mktemp)
  echo '{"token":"x"}' > "$tmp"
  local got_ok; got_ok=$(classify_credentials "$tmp")
  case "$got_ok" in OK\|*) printf '  OK  non-empty file -> OK\n' ;; *) printf '  FAIL non-empty file -> got: %s\n' "$got_ok"; fails=$((fails+1)) ;; esac
  total=$((total+1))
  : > "$tmp"
  assert "FAIL|$tmp empty"   "$(classify_credentials "$tmp")"          "empty file -> FAIL"
  rm -f "$tmp"
  assert "FAIL|$tmp missing" "$(classify_credentials "$tmp")"          "missing file -> FAIL"


  echo "== classify_backup =="
  assert "FAIL|бэкап: нет архивов"        "$(classify_backup -1 '')"  "none -> FAIL"
  assert "OK|бэкап: arch (5 ч)"           "$(classify_backup 5 'arch (5 ч)')" "5h -> OK"
  assert "WARN|бэкап: 30ч назад"          "$(classify_backup 30 'x')" "30h -> WARN"
  assert "FAIL|бэкап: 50ч назад (>48ч)"   "$(classify_backup 50 'x')" "50h -> FAIL"

  echo ""
  echo "Tests: $((total - fails))/$total passed"
  [ "$fails" -eq 0 ]
}

# --- Probes (live system) ---

probe_disk() {
  local pct
  pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  classify_pct "$pct" 80 90 "/"
}

probe_ram() {
  local total used pct
  read -r total used < <(free -m | awk '/^Mem:/ {print $2, $3}')
  if [ "$total" -eq 0 ]; then echo "FAIL|RAM unknown"; return; fi
  pct=$(( used * 100 / total ))
  classify_pct "$pct" 80 90 "RAM (${used}M / ${total}M)"
}

probe_cpu() {
  local load cores
  load=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc)
  classify_load "$load" "$cores"
}

probe_service() {
  local name="$1" state
  state=$(systemctl is-active "$name" 2>/dev/null || true)
  [ -z "$state" ] && state="unknown"
  classify_service "$name" "$state"
}

probe_credentials() {
  classify_credentials "$CRED_PATH"
}

probe_cron() {
  # Канарейка: минутная крон-задача трогает файл. Протух — планировщик НЕ
  # выполняет задачи агента, какой бы ни была причина (27.08.2026: шесть часов
  # простоя из-за лишней жёсткой ссылки на файле расписания).
  if [ ! -f "$HEARTBEAT" ]; then
    echo "FAIL|крон: канарейка ни разу не отметилась"
    return
  fi
  local age_m
  age_m=$(( ( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ) / 60 ))
  if [ "$age_m" -le 5 ]; then echo "OK|крон: канарейка свежая (${age_m} мин)"
  elif [ "$age_m" -le 15 ]; then echo "WARN|крон: канарейка молчит ${age_m} мин"
  else echo "FAIL|крон НЕ ВЫПОЛНЯЕТ ЗАДАЧИ: канарейка молчит ${age_m} мин"; fi
}

probe_backup() {
  local latest age_s age_h
  latest=$(ls -1t "$BACKUP_DIR"/*.tar.gz* "$BACKUP_DIR"/*.tgz 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    # Бэкап — отдельная настройка хозяина (нужен свой вход в облако). Его
    # отсутствие не поломка агента, врать красным не будем.
    echo "WARN|бэкап не настроен ($BACKUP_DIR)"
    return
  fi
  age_s=$(( $(date +%s) - $(stat -c %Y "$latest") ))
  age_h=$(( age_s / 3600 ))
  classify_backup "$age_h" "$(basename "$latest") (${age_h}ч)"
}

# --- Renderer ---

# render_row "Проверка" "STATUS|Детали"
render_row() {
  local check="$1" payload="$2"
  local status="${payload%%|*}"
  local detail="${payload#*|}"
  local color reset
  if [ -t 1 ]; then
    case "$status" in
      OK)   color="\033[32m" ;;
      WARN) color="\033[33m" ;;
      FAIL) color="\033[31m" ;;
      *)    color="" ;;
    esac
    reset="\033[0m"
  else
    color=""; reset=""
  fi
  printf '| %-20s | %b%-4s%b | %s\n' "$check" "$color" "$status" "$reset" "$detail"
}

main() {
  declare -A results

  results[Disk]=$(probe_disk)
  results[RAM]=$(probe_ram)
  results[CPU_load]=$(probe_cpu)
  results[Agent]=$(probe_service "dashi-$AGENT")
  results[OAuth]=$(probe_credentials)
  results[Cron]=$(probe_cron)
  results[Backup]=$(probe_backup)

  local sep="+----------------------+------+-----------------------------------------"
  echo "$sep"
  printf '| %-20s | %-4s | %s\n' "Проверка" "Стат" "Детали"
  echo "$sep"
  render_row "Диск /"          "${results[Disk]}"
  render_row "RAM"             "${results[RAM]}"
  render_row "CPU load (1m)"   "${results[CPU_load]}"
  render_row "Агент"           "${results[Agent]}"
  render_row "OAuth creds"     "${results[OAuth]}"
  render_row "Планировщик"     "${results[Cron]}"
  render_row "Бэкап"           "${results[Backup]}"
  echo "$sep"

  local worst=0
  for key in "${!results[@]}"; do
    local s="${results[$key]%%|*}"
    case "$s" in
      WARN) [ "$worst" -lt 1 ] && worst=1 ;;
      FAIL) worst=2 ;;
    esac
  done
  echo ""
  case "$worst" in
    0) echo "Verdict: OK" ;;
    1) echo "Verdict: WARN" ;;
    2) echo "Verdict: FAIL" ;;
  esac
  exit "$worst"
}

if [ "${HEALTH_TEST:-0}" = "1" ]; then
  run_tests
  exit $?
fi

main "$@"
