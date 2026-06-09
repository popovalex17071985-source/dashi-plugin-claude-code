// Permission policy classifier for the Telegram-driven permission gate.
//
// CONTEXT
// -------
// The owner drives a tmux-resident Claude Code session from Telegram and is
// never at the terminal. Interactive permission prompts (Allow/Deny on Bash,
// Edit, …) render only in the pane and wedge the session. The fix is to run
// the session under `--permission-mode bypassPermissions` (no terminal
// prompt ever fires) and put a PreToolUse hook in front of every tool call
// as the *only* gate. This module is that gate's brain: a pure function that
// classifies one tool call into a tier:
//
//   * allow   — run silently, no human in the loop.
//   * deny    — block hard; never reaches the human (catastrophic / secret).
//   * confirm — route an Allow/Deny prompt to Telegram; the hook waits for
//               the owner's tap and maps it back to allow/deny.
//
// SECURITY POSTURE (Codex GPT-5.5 xhigh review, 2026-06-09)
// ---------------------------------------------------------
// Because bypassPermissions makes a policy mistake execute immediately, the
// classifier is hardened independently of the operator-supplied policy:
//   * A built-in hard-deny set always fires (secret files, credential reads,
//     filesystem-wipe / fork-bomb commands) and cannot be relaxed by config.
//   * Bash matching defends against interpreter evasion (curl|sh, bash -c,
//     base64 -d|sh, …), not just literal substrings.
//   * Paths are checked both raw and normalized (../ and trailing-dot
//     evasion) against glob rules; Write/Edit get a separate stricter list.
//   * Precedence is deny > confirm > allow > default_tier, and the whole
//     function is fail-closed: any malformed input degrades to `deny`.
//
// This module is intentionally I/O-free so it can be unit-tested exhaustively
// without spawning a session. The hook wrapper (scripts/permission-gate-hook.ts)
// owns stdin/stdout, the loopback POST, and the bounded-deadline wait.

import { resolve } from 'path'

export type PermissionTier = 'allow' | 'deny' | 'confirm'

export interface PermissionVerdict {
  readonly tier: PermissionTier
  /** Human-readable, safe to surface to the owner / transcript. */
  readonly reason: string
  /** The rule that matched, for audit. `builtin:*` for baked-in rules. */
  readonly matchedRule: string
}

/** One tier's matchers. All fields optional; absent = matches nothing. */
export interface PolicyRules {
  /** fnmatch globs against the tool name (e.g. "mcp__dashi-gbrain-*"). */
  readonly tools?: readonly string[]
  /** fnmatch globs against file_path for Read/Edit/Write/NotebookEdit. */
  readonly read_paths?: readonly string[]
  /** fnmatch globs against file_path for Edit/Write/NotebookEdit only. */
  readonly write_paths?: readonly string[]
  /** substring (default) or fnmatch (when glob meta present) on Bash command. */
  readonly bash_patterns?: readonly string[]
}

export interface PolicyScope {
  readonly deny?: PolicyRules
  readonly confirm?: PolicyRules
  readonly allow?: PolicyRules
}

export interface PermissionPolicy {
  /**
   * Tier for a tool call that matches no deny/confirm/allow rule.
   *   * "allow"   — Variant 1 (recommended): smooth flow, only the explicit
   *                 confirm/deny lists + built-in hard-deny gate the owner.
   *   * "confirm" — Variant 2: every unmatched mutating call asks Telegram;
   *                 read-only tools still auto-allow.
   * Defaults to "confirm" (fail-safe) when omitted or invalid.
   */
  readonly default_tier?: 'allow' | 'confirm'
  /** Global rules applied to every scope. */
  readonly deny?: PolicyRules
  readonly confirm?: PolicyRules
  readonly allow?: PolicyRules
  /** Per-scope (per-chat / "main") overrides, unioned with the globals. */
  readonly scopes?: Readonly<Record<string, PolicyScope>>
}

// Tools that cannot mutate state or exfiltrate data. Under default_tier
// "confirm" these still auto-allow so read-only work never blocks.
const READ_ONLY_TOOLS = new Set<string>([
  'Read',
  'Glob',
  'Grep',
  'LS',
  'NotebookRead',
  'TodoWrite',
  'WebSearch',
])

// Tools that take a filesystem path we must policy-check.
const READ_PATH_TOOLS = new Set<string>(['Read', 'NotebookRead'])
const WRITE_PATH_TOOLS = new Set<string>(['Edit', 'Write', 'NotebookEdit', 'MultiEdit'])

// ── Built-in hard rules (operator cannot relax) ─────────────────────────
//
// These fire before any operator policy. Secret/credential reads and writes,
// and catastrophic shell commands, are denied unconditionally.

const BUILTIN_DENY_PATHS: readonly string[] = [
  '**/.env',
  '**/.env.*',
  '**/*.pem',
  '**/*.key',
  '**/.secrets/**',
  '**/secrets/**',
  '**/id_rsa*',
  '**/id_ed25519*',
  '**/.ssh/**',
  '**/.aws/**',
  '**/.config/gcloud/**',
  '**/.claude/.credentials*',
  '**/.codex/auth*',
  '/proc/*/environ',
  '/proc/*/cmdline',
]

// Catastrophic / unrecoverable shell — denied even under confirm-everything.
// These match via substring (lowercased) OR glob when meta present.
const BUILTIN_DENY_BASH: readonly string[] = [
  'rm -rf /',
  'rm -rf /*',
  'rm -rf ~',
  'rm -fr /',
  ':(){ :|:& };:', // fork bomb
  'mkfs',
  'dd if=*of=/dev/sd*',
  '> /dev/sda',
  'chmod -R 777 /',
  'chown -R * /',
]

// Risky-but-legitimate shell that must reach the owner as a confirm when the
// operator policy hasn't already classified it. Interpreter/exfil evasion
// vectors live here so a clever command can't silently auto-allow under
// default_tier "allow".
const BUILTIN_CONFIRM_BASH: readonly string[] = [
  'sudo ',
  'rm -rf ',
  'rm -fr ',
  'git push',
  'git reset --hard',
  'git clean -',
  'curl * | sh',
  'curl * | bash',
  'wget * | sh',
  'wget * | bash',
  'base64 -d* | sh',
  'base64 -d* | bash',
  'chmod -R',
  'chown -R',
  'systemctl',
  'kill ',
  'pkill',
  'docker ',
  'npm publish',
  'pip install',
  'apt install',
  'apt-get install',
]

/**
 * Minimal glob matcher supporting `*`, `?`, and `**`.
 *   * `**` matches across path separators (any chars incl. `/`).
 *   * `*` matches any chars except `/`.
 *   * `?` matches a single non-`/` char.
 * Anchored full-string match. Used for both path and tool-name rules.
 */
export function globMatch(pattern: string, value: string): boolean {
  let re = '^'
  for (let i = 0; i < pattern.length; i += 1) {
    const ch = pattern[i]
    if (ch === undefined) continue
    if (ch === '*') {
      if (pattern[i + 1] === '*') {
        // `**/` matches zero or more leading directories (so `**/.env`
        // also matches a bare `.env`); a trailing `**` matches anything.
        if (pattern[i + 2] === '/') {
          re += '(?:.*/)?'
          i += 2
        } else {
          re += '.*'
          i += 1
        }
      } else {
        re += '[^/]*'
      }
    } else if (ch === '?') {
      re += '[^/]'
    } else {
      re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&')
    }
  }
  re += '$'
  try {
    return new RegExp(re).test(value)
  } catch {
    return false
  }
}

function bashMatch(pattern: string, commandLower: string): boolean {
  const pat = pattern.toLowerCase()
  const hasMeta = pat.includes('*') || pat.includes('?')
  if (!hasMeta) {
    return commandLower.includes(pat)
  }
  // Bash commands routinely contain slashes (paths, URLs), so `*` must cross
  // `/` here — unlike path globs. Build an unanchored regex: `*`→`.*`,
  // `?`→`.`, everything else literal. Match anywhere in the command.
  let re = ''
  for (const ch of pat) {
    if (ch === '*') re += '.*'
    else if (ch === '?') re += '.'
    else re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  try {
    return new RegExp(re).test(commandLower)
  } catch {
    return false
  }
}

/**
 * Candidate path forms to test: the raw string, and the form resolved
 * against `/` so `../` and `./` collapse. Both are matched so a glob rule
 * ending in `.env` catches `../../app/.env` regardless of how Claude
 * phrased the path.
 */
function pathCandidates(raw: string): string[] {
  const out = [raw]
  try {
    // resolve() against a fixed root normalizes ../ without touching disk.
    const normalized = resolve('/__root__', raw)
    if (normalized !== raw) out.push(normalized)
  } catch {
    /* keep raw only */
  }
  return out
}

function matchPathRules(rules: readonly string[] | undefined, candidates: string[]): string | undefined {
  if (!rules) return undefined
  for (const rule of rules) {
    if (typeof rule !== 'string') continue
    for (const cand of candidates) {
      if (globMatch(rule, cand)) return rule
    }
  }
  return undefined
}

function matchToolRules(rules: readonly string[] | undefined, toolName: string): string | undefined {
  if (!rules) return undefined
  for (const rule of rules) {
    if (typeof rule === 'string' && globMatch(rule, toolName)) return rule
  }
  return undefined
}

function matchBashRules(rules: readonly string[] | undefined, commandLower: string): string | undefined {
  if (!rules) return undefined
  for (const rule of rules) {
    if (typeof rule === 'string' && bashMatch(rule, commandLower)) return rule
  }
  return undefined
}

/** Merge global + scope rules for one tier (scope rules are additive). */
function mergeRules(global: PolicyRules | undefined, scope: PolicyRules | undefined): PolicyRules {
  return {
    tools: [...(global?.tools ?? []), ...(scope?.tools ?? [])],
    read_paths: [...(global?.read_paths ?? []), ...(scope?.read_paths ?? [])],
    write_paths: [...(global?.write_paths ?? []), ...(scope?.write_paths ?? [])],
    bash_patterns: [...(global?.bash_patterns ?? []), ...(scope?.bash_patterns ?? [])],
  }
}

/**
 * Does `rules` match this tool call? Returns the matched rule string, or
 * undefined. Path rules apply to path tools; write_paths only to write tools;
 * bash_patterns only to Bash; tools to everything.
 */
function rulesMatch(
  rules: PolicyRules,
  toolName: string,
  pathCands: string[] | undefined,
  commandLower: string | undefined,
): string | undefined {
  const tool = matchToolRules(rules.tools, toolName)
  if (tool) return `tools:${tool}`

  if (pathCands) {
    if (READ_PATH_TOOLS.has(toolName) || WRITE_PATH_TOOLS.has(toolName)) {
      const rp = matchPathRules(rules.read_paths, pathCands)
      if (rp) return `read_paths:${rp}`
    }
    if (WRITE_PATH_TOOLS.has(toolName)) {
      const wp = matchPathRules(rules.write_paths, pathCands)
      if (wp) return `write_paths:${wp}`
    }
  }

  if (commandLower !== undefined) {
    const bp = matchBashRules(rules.bash_patterns, commandLower)
    if (bp) return `bash_patterns:${bp}`
  }
  return undefined
}

function extractPath(toolInput: Record<string, unknown>): string | undefined {
  const fp = toolInput.file_path ?? toolInput.notebook_path
  return typeof fp === 'string' && fp.length > 0 ? fp : undefined
}

function extractCommand(toolName: string, toolInput: Record<string, unknown>): string | undefined {
  if (toolName !== 'Bash') return undefined
  const cmd = toolInput.command
  return typeof cmd === 'string' ? cmd : ''
}

const MAX_COMMAND_LEN = 100_000

export interface ClassifyInput {
  readonly toolName: unknown
  readonly toolInput: unknown
  readonly policy: PermissionPolicy
  /** Scope id (e.g. "main" or a chat id). Looked up in policy.scopes. */
  readonly scope?: string
}

/**
 * Classify one tool call. Pure, fail-closed.
 *
 * Order:
 *   1. Validate shape — malformed → deny.
 *   2. Built-in hard-deny (paths + bash) — operator cannot relax.
 *   3. Operator deny (global ∪ scope).
 *   4. Built-in confirm bash (interpreter/exfil/destructive) unless operator
 *      already allowed it.
 *   5. Operator confirm.
 *   6. Operator allow.
 *   7. default_tier (read-only tools always allow).
 */
export function classifyToolCall(input: ClassifyInput): PermissionVerdict {
  const { toolName, toolInput, policy, scope } = input

  if (typeof toolName !== 'string' || toolName.length === 0) {
    return { tier: 'deny', reason: 'malformed tool call: missing tool_name', matchedRule: 'builtin:malformed' }
  }
  const ti: Record<string, unknown> =
    toolInput !== null && typeof toolInput === 'object' && !Array.isArray(toolInput)
      ? (toolInput as Record<string, unknown>)
      : {}

  const rawPath = extractPath(ti)
  const pathCands = rawPath !== undefined ? pathCandidates(rawPath) : undefined
  const rawCommand = extractCommand(toolName, ti)
  if (rawCommand !== undefined && rawCommand.length > MAX_COMMAND_LEN) {
    return { tier: 'deny', reason: 'bash command exceeds size cap', matchedRule: 'builtin:command-too-long' }
  }
  const commandLower = rawCommand !== undefined ? rawCommand.toLowerCase() : undefined

  // 2. Built-in hard-deny — paths (read & write tools) + catastrophic bash.
  if (pathCands && (READ_PATH_TOOLS.has(toolName) || WRITE_PATH_TOOLS.has(toolName))) {
    const hit = matchPathRules(BUILTIN_DENY_PATHS, pathCands)
    if (hit) {
      return { tier: 'deny', reason: `secret/credential path blocked: ${hit}`, matchedRule: `builtin:deny_path:${hit}` }
    }
  }
  if (commandLower !== undefined) {
    const hit = matchBashRules(BUILTIN_DENY_BASH, commandLower)
    if (hit) {
      return { tier: 'deny', reason: `catastrophic command blocked: ${hit}`, matchedRule: `builtin:deny_bash:${hit}` }
    }
  }

  const scopeCfg = scope && policy.scopes ? policy.scopes[scope] : undefined
  const denyRules = mergeRules(policy.deny, scopeCfg?.deny)
  const confirmRules = mergeRules(policy.confirm, scopeCfg?.confirm)
  const allowRules = mergeRules(policy.allow, scopeCfg?.allow)

  // 3. Operator deny.
  const denyHit = rulesMatch(denyRules, toolName, pathCands, commandLower)
  if (denyHit) {
    return { tier: 'deny', reason: `policy deny (${denyHit})`, matchedRule: `deny:${denyHit}` }
  }

  // An explicit operator allow can short-circuit built-in confirm bash
  // (e.g. operator allow-lists `git push` to a known repo). Compute it now.
  const allowHit = rulesMatch(allowRules, toolName, pathCands, commandLower)

  // 4. Built-in confirm bash — unless the operator explicitly allowed it.
  if (commandLower !== undefined && !allowHit) {
    const hit = matchBashRules(BUILTIN_CONFIRM_BASH, commandLower)
    if (hit) {
      return { tier: 'confirm', reason: `risky command needs confirmation: ${hit}`, matchedRule: `builtin:confirm_bash:${hit}` }
    }
  }

  // 5. Operator confirm.
  const confirmHit = rulesMatch(confirmRules, toolName, pathCands, commandLower)
  if (confirmHit) {
    return { tier: 'confirm', reason: `policy confirm (${confirmHit})`, matchedRule: `confirm:${confirmHit}` }
  }

  // 6. Operator allow.
  if (allowHit) {
    return { tier: 'allow', reason: `policy allow (${allowHit})`, matchedRule: `allow:${allowHit}` }
  }

  // 7. Default. Read-only tools always auto-allow.
  if (READ_ONLY_TOOLS.has(toolName)) {
    return { tier: 'allow', reason: 'read-only tool', matchedRule: 'builtin:read_only' }
  }
  const def: PermissionTier = policy.default_tier === 'allow' ? 'allow' : 'confirm'
  return {
    tier: def,
    reason: def === 'allow' ? 'default_tier allow' : 'default_tier confirm (unmatched mutating tool)',
    matchedRule: `default:${def}`,
  }
}
