#!/usr/bin/env bash
# PreToolUse -> Write|Edit|MultiEdit. Guards file writes by target path.
#   - Secret files (.env/.key/.pem/.ssh/secrets/vault/backup-key): HARD block (exit 2).
#   - The agent's OWN workspace secrets/ dir is the one exception: storing a key
#     the owner hands over IS the agent's job (installer CLAUDE.md template says
#     "put it in secrets/, chmod 600"). Only the directory rule is lifted there;
#     .env / *.key / *.pem etc. inside it stay blocked, as does any other secrets/.
#   - RED-zone config (CLAUDE.md/rules.md/USER.md): warn to transcript, allow.
# RED-zone edits flow through the operator's approval, so we surface them but
# don't hard-block his own changes.
set -euo pipefail
input="$(cat)"

# Write uses .file_path; Edit/MultiEdit use .file_path too (tool_input schema).
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

if [[ -z "$path" ]]; then
  exit 0
fi

# --- HARD block: secret-bearing files (extended regex, case-insensitive) ---
SECRETS_DIR_PAT='(^|/)secrets?/'
secret_patterns=(
  '\.env($|\.)'          # .env, .env.local, .env.prod
  '\.key($|\.)'
  '\.pem($|\.)'
  "$SECRETS_DIR_PAT"
  '(^|/)vault/'
  '(^|/)\.ssh/'
  '\.anthropic-backup-key'
  'id_rsa($|\.)'
  '\.p12($|\.)'
)
# Own workspace secrets/ (rendered by install-kit; unrendered kit never matches).
# Plain files directly inside it only: no `..`, no nested dirs.
own_secrets=0
if [[ "$path" == "__WORKSPACE__/secrets/"* && "${path#__WORKSPACE__/secrets/}" != */* ]]; then
  own_secrets=1
fi
for pat in "${secret_patterns[@]}"; do
  if (( own_secrets )) && [[ "$pat" == "$SECRETS_DIR_PAT" ]]; then
    continue
  fi
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
