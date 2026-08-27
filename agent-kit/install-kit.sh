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
# Usage: install-kit.sh --claude-dir DIR [--chat-id ID] [--agent NAME] [--settings FILE]
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR=""; CHAT_ID=""; AGENT=""; SETTINGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
    --chat-id)    CHAT_ID="$2";    shift 2 ;;
    --agent)      AGENT="$2";      shift 2 ;;
    --settings)   SETTINGS="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$CLAUDE_DIR" ]] || { echo "--claude-dir required" >&2; exit 2; }
SETTINGS="${SETTINGS:-$CLAUDE_DIR/settings.json}"
AGENT="${AGENT:-agent}"
WORKSPACE="$(dirname "$CLAUDE_DIR")"

mkdir -p "$CLAUDE_DIR"/{hooks,core,agents} "$WORKSPACE/bin" "$WORKSPACE/logs"

# Placeholders are substituted on copy — the kit itself stays host-agnostic.
render() {
  sed -e "s|__CLAUDE_DIR__|$CLAUDE_DIR|g" \
      -e "s|__WORKSPACE__|$WORKSPACE|g" \
      -e "s|__CHAT_ID__|$CHAT_ID|g" \
      -e "s|__AGENT__|$AGENT|g" "$1" > "$2"
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

# Советник по обновлениям в кроне. Установщик ставит его при первой установке;
# здесь — чтобы он доехал и до агентов, поднятых раньше: этот скрипт гоняется
# на каждом /update, а шаг установщика — нет. Час берём тот же, что у утренней
# сводки (он уже посчитан по поясу хозяина), иначе 07:00 по серверу.
# KIT_NO_CRON=1 — раскладка без правки крона (песочница, тесты): иначе прогон
# теста переписал бы боевой крон пользователя.
CRON_NOW="$(crontab -l 2>/dev/null || true)"
[ -n "${KIT_NO_CRON:-}" ] && CRON_NOW="update-notify (пропущено: KIT_NO_CRON)"
case "$CRON_NOW" in
  *update-notify*) ;;
  *)
    H="$(printf '%s\n' "$CRON_NOW" | sed -n 's/^0 \([0-9]*\) .*open-threads-digest.*/\1/p' | head -1)"
    case "$H" in ''|*[!0-9]*) H=7 ;; esac
    CT_TMP="$(mktemp)"
    printf '%s\n10 %s * * * /bin/bash %s/bin/update-notify.sh >> %s/logs/update-notify.log 2>&1\n' \
      "$CRON_NOW" "$H" "$WORKSPACE" "$WORKSPACE" > "$CT_TMP"
    if crontab "$CT_TMP"; then
      echo "  советник по обновлениям в кроне (${H}:10 по серверу)"
    else
      echo "  крон советника прописать не смог — поставь руками"
    fi
    rm -f "$CT_TMP" ;;
esac

echo "  комплект разложен в $CLAUDE_DIR"
