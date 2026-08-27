#!/usr/bin/env bash
# PreToolUse -> Write|Edit|MultiEdit. Guards file writes by target path.
#   - Secret files (.env/.key/.pem/secrets/vault/backup-key): HARD block (exit 2).
#   - RED-zone config (CLAUDE.md/rules.md/USER.md): warn to transcript, allow.
# Secrets must never be written by an agent; RED-zone edits flow through the
# operator's approval, so we surface them but don't hard-block his own changes.
set -euo pipefail
input="$(cat)"

# Write uses .file_path; Edit/MultiEdit use .file_path too (tool_input schema).
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

if [[ -z "$path" ]]; then
  exit 0
fi

# --- HARD block: secret-bearing files (extended regex, case-insensitive) ---
secret_patterns=(
  '\.env($|\.)'          # .env, .env.local, .env.prod
  '\.key($|\.)'
  '\.pem($|\.)'
  '(^|/)secrets?/'
  '(^|/)vault/'
  '\.anthropic-backup-key'
  'id_rsa($|\.)'
  '\.p12($|\.)'
)
for pat in "${secret_patterns[@]}"; do
  if echo "$path" | grep -qiE "$pat"; then
    echo "BLOCKED secret-file write: $path (pattern: $pat)" >&2
    echo "Agents must not write secret/key files. If intentional, do it manually." >&2
    exit 2
  fi
done

# --- WARN (allow): RED-zone config files ---
red_patterns=(
  '(^|/)CLAUDE\.md$'
  '(^|/)rules\.md$'
  '(^|/)USER\.md$'
)
for pat in "${red_patterns[@]}"; do
  if echo "$path" | grep -qiE "$pat"; then
    echo "NOTICE: RED-zone config write -> $path (operator approval required)." >&2
    break
  fi
done

exit 0
