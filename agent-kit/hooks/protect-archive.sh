#!/bin/bash
set -euo pipefail

# protect-archive.sh -- PreToolUse:Write|MultiEdit guard for COLD archive files.
#
# Root cause it defends against: an unattended `claude -p /mem` compact once
# REGENERATED core/archive/2026-05.md via a full Write and dropped earlier
# month sections (data loss, recovered only because git HEAD still had them).
#
# Strategy (constitution global.md §8 -- backup before any prod write):
#   1. Always snapshot the existing archive file before it is overwritten, so
#      any loss is reversible (snapshots in core/archive/.bak/, gitignored).
#   2. If the new content has FEWER `## ` section headers than the old file,
#      emit a non-blocking warning to stderr -- visible to the agent/logs,
#      but does NOT block (legitimate splits move sections to another file).
#
# Non-blocking by design: exit 0 always. The backup is the real protection.

INPUT="$(cat)"

# jq is the gateway's standard JSON tool; fall back to a no-op if absent.
command -v jq >/dev/null 2>&1 || exit 0

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
[ -z "$FILE" ] && exit 0

# Only guard COLD archive markdown.
case "$FILE" in
    */core/archive/*.md) ;;
    *) exit 0 ;;
esac

# New file -> nothing to lose, allow.
[ ! -f "$FILE" ] && exit 0

BAK_DIR="$(dirname "$FILE")/.bak"
mkdir -p "$BAK_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
cp "$FILE" "$BAK_DIR/$(basename "$FILE").$TS"

# Soft check: section count must not shrink silently.
NEW_CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')"
if [ -n "$NEW_CONTENT" ]; then
    OLD_N="$(grep -c '^## ' "$FILE" || true)"
    NEW_N="$(printf '%s' "$NEW_CONTENT" | grep -c '^## ' || true)"
    if [ "${NEW_N:-0}" -lt "${OLD_N:-0}" ]; then
        echo "protect-archive: $(basename "$FILE") теряет секции ($OLD_N -> $NEW_N). Бэкап в $BAK_DIR. Убедись, что они перенесены, а не затёрты." >&2
    fi
fi

exit 0
