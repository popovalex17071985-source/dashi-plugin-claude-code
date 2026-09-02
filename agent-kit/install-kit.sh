#!/usr/bin/env bash
# install-kit.sh — lay the discipline layer on top of the bare agent.
#
# install-agent.sh gives a working agent: it starts, talks to its owner, remembers.
# This kit gives it the WAY OF WORKING that Jarvis needed months of operator
# corrections to grow: the constitution, the gate hooks that fire on their own, the
# registries, and the three subagents.
#
# Idempotent: re-running replaces files and never double-registers a hook.
#
# Usage: install-kit.sh --claude-dir DIR [--chat-id ID] [--agent NAME] [--settings FILE] [--tz TZ]
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR=""; CHAT_ID=""; AGENT=""; SETTINGS=""; OWNER_TZ=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
    --chat-id)    CHAT_ID="$2";    shift 2 ;;
    --agent)      AGENT="$2";      shift 2 ;;
    --settings)   SETTINGS="$2";   shift 2 ;;
    --tz)         OWNER_TZ="$2";   shift 2 ;;   # пояс ХОЗЯИНА: сводка в 09:00 по нему
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$CLAUDE_DIR" ]] || { echo "--claude-dir required" >&2; exit 2; }
SETTINGS="${SETTINGS:-$CLAUDE_DIR/settings.json}"
AGENT="${AGENT:-agent}"
WORKSPACE="$(dirname "$CLAUDE_DIR")"

mkdir -p "$CLAUDE_DIR"/{hooks,core,agents} "$WORKSPACE/bin" "$WORKSPACE/logs"

# Placeholders are substituted on copy — the kit itself stays host-agnostic.
# A file that already exists AND differs is copied to .kit-backup/<stamp>/<same
# relative path> first: the kit refreshes hooks/bin/agents/constitution on a
# living agent, and a local tweak lost without a copy is a silent regression.
BACKUP_DIR="$WORKSPACE/.kit-backup/$(date +%Y%m%d-%H%M)"
BACKED=0
render() {
  local tmp; tmp="$(mktemp)"
  sed -e "s|__CLAUDE_DIR__|$CLAUDE_DIR|g" \
      -e "s|__WORKSPACE__|$WORKSPACE|g" \
      -e "s|__CHAT_ID__|$CHAT_ID|g" \
      -e "s|__AGENT__|$AGENT|g" "$1" > "$tmp"
  if [[ -f "$2" ]] && ! cmp -s "$tmp" "$2"; then
    local rel="${2#"$WORKSPACE"/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -p "$2" "$BACKUP_DIR/$rel"
    BACKED=$((BACKED + 1))
  fi
  cat "$tmp" > "$2"; rm -f "$tmp"
}

for f in "$KIT"/hooks/*; do render "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"; done
for f in "$KIT"/bin/*;   do render "$f" "$WORKSPACE/bin/$(basename "$f")"; done
for f in "$KIT"/agents/*; do render "$f" "$CLAUDE_DIR/agents/$(basename "$f")"; done
chmod +x "$CLAUDE_DIR"/hooks/* "$WORKSPACE"/bin/* 2>/dev/null || true

# Registries: never clobber a ledger the agent has already been writing into.
# The constitution is ours and is refreshed with the kit; core/rules.md is the
# owner's own log of corrections and must never be clobbered.
render "$KIT/core/constitution.md" "$CLAUDE_DIR/core/constitution.md"
if [[ -s "$CLAUDE_DIR/CLAUDE.md" ]] && ! grep -q "core/constitution.md" "$CLAUDE_DIR/CLAUDE.md"; then
  printf '\n@core/constitution.md\n' >> "$CLAUDE_DIR/CLAUDE.md"
  echo "  + @core/constitution.md подключён в CLAUDE.md"
fi
for f in SOURCES.md open-threads.md; do
  if [[ -s "$CLAUDE_DIR/core/$f" ]]; then
    echo "  = core/$f уже есть, не трогаю"
  else
    render "$KIT/core/$f" "$CLAUDE_DIR/core/$f"
  fi
done
mkdir -p "$CLAUDE_DIR/docs"
render "$KIT/docs/agent-self-audit.md" "$CLAUDE_DIR/docs/agent-self-audit.md"
(( BACKED == 0 )) || echo "  сохранил $BACKED старых файлов в $BACKUP_DIR"

# Hook registration. Matchers mirror what the gates actually intercept.
python3 - "$SETTINGS" "$CLAUDE_DIR" <<'PY'
import json, pathlib, sys

settings, claude_dir = pathlib.Path(sys.argv[1]), sys.argv[2]
data = json.loads(settings.read_text()) if settings.exists() else {}
hooks = data.setdefault("hooks", {})

WIRING = [
    ("PreToolUse",  "Bash",                 "block-dangerous.sh",        5),
    ("PreToolUse",  "Bash",                 "block-selfmatching-pgrep.sh", 5),
    ("PreToolUse",  "Write|Edit|MultiEdit", "block-red-zone.sh",         5),
    ("PostToolUse", "Bash",                 "truncate-bash-output.sh",   5),
    ("PostToolUse", "Edit|Write|MultiEdit", "lesson-needs-mechanism.sh", 5),
    ("PostToolUse", "Edit|Write|MultiEdit", "cyrillic-guard.sh",         5),
    ("Stop",        "",                     "capture-open-threads.py",  10),
    ("Stop",        "",                     "stop-closeout-gate.py",    10),
    ("Stop",        "",                     "stop-blocker-gate.py",     10),
]

added = 0
for event, matcher, name, timeout in WIRING:
    path = f"{claude_dir}/hooks/{name}"
    cmd = path if name.endswith(".sh") else f"/usr/bin/python3 {path}"
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == cmd for e in entries for h in e.get("hooks", [])):
        continue
    slot = next((e for e in entries if e.get("matcher", "") == matcher), None)
    if slot is None:
        slot = {"matcher": matcher, "hooks": []}
        entries.append(slot)
    slot["hooks"].append({"type": "command", "command": cmd, "timeout": timeout})
    added += 1

settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"  хуков зарегистрировано: {added} (уже стояло: {len(WIRING) - added})")
PY

# Будильник по срокам + утренняя сводка леджера. Раньше эти кроны ставил только
# полный install-agent.sh — агент, обновлённый по гайду «Update плагина», получал
# леджер-файлы, но сводка ему молчала (Саня 31.08). Теперь кроны — часть комплекта.
# Крон живёт по часам СЕРВЕРА, сводку читает хозяин — считаем час под его 09:00.
OWNER_TZ="${OWNER_TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"
# python3 -c, не heredoc: вложенный heredoc внутри $( ) вешал установку на stdin.
DIG_H="$(OWNER_TZ="$OWNER_TZ" python3 -c 'import os,datetime as dt,zoneinfo; own=zoneinfo.ZoneInfo(os.environ["OWNER_TZ"]); srv=dt.datetime.now().astimezone().tzinfo; print(dt.datetime.now(own).replace(hour=9,minute=0,second=0,microsecond=0).astimezone(srv).hour)' 2>/dev/null || true)"
[[ -n "$DIG_H" ]] || { DIG_H=7; echo "  ! не смог посчитать пояс ($OWNER_TZ, нет tzdata?) — сводка в 07:00 по серверу"; }
SWEEP="30 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/promise-sweeper.py >> $WORKSPACE/logs/promise-sweeper.log 2>&1"
DIGEST="0 $DIG_H * * * /usr/bin/python3 $WORKSPACE/bin/open-threads-digest.py --send >> $WORKSPACE/logs/open-threads-digest.log 2>&1"
# Смотрим ТОЛЬКО на строки этого workspace: у второго агента под тем же
# пользователем свои строки, чужие не трогаем. Час мог измениться (--tz) —
# тогда свои строки переписываем, а не пропускаем.
CUR="$(crontab -l 2>/dev/null || true)"
if grep -qxF "$SWEEP" <<<"$CUR" && grep -qxF "$DIGEST" <<<"$CUR"; then
  echo "  будильник и сводка уже в кроне: 09:00 по $OWNER_TZ (на сервере $DIG_H:00)"
else
  if grep -qF "$WORKSPACE/bin/promise-sweeper.py" <<<"$CUR"; then verb="перенесены на"; else verb="в кроне:"; fi
  { grep -vF -e "$WORKSPACE/bin/promise-sweeper.py" -e "$WORKSPACE/bin/open-threads-digest.py" <<<"$CUR" || true
    echo "$SWEEP"; echo "$DIGEST"; } | crontab - \
    && echo "  будильник и сводка $verb 09:00 по $OWNER_TZ (на сервере $DIG_H:00)" \
    || echo "  ! не смог прописать крон — поставь руками"
fi

echo "  комплект разложен в $CLAUDE_DIR"
