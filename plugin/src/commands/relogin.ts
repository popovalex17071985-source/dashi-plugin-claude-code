// /relogin — monthly Claude re-login driven entirely from Telegram.
//
// Problem (operator, 2026-08): Claude Code's OAuth session expires every ~30
// days. When it does, the agent's pane sits on «Login expired · Please run
// /login» and the bot goes silent — the operator had to SSH in, run /login in
// tmux, open the URL, paste the code back. This module closes the loop from
// chat:
//
//   1. /relogin (OOB, oob.ts) → ack, then type `/login` into the pane
//      (C-u / literal text / Enter — the BLIND 3-shot on purpose: the pane is
//      typically stuck on the login-expired screen, which classifyPane cannot
//      call idle, so the state-aware sender would refuse exactly when we need
//      it most).
//   2. Poll `capture-pane -pJ -S -200` up to ~40s for the OAuth URL and send
//      it to the owner as an HTML hyperlink (the channel mangles bare URLs —
//      memory: channel-mangles-urls-send-as-markdown-link). Arm the
//      `relogin-pending` state flag (file in TELEGRAM_STATE_DIR, 15-min TTL).
//   3. While the flag is live, handlers.ts intercepts an inbound message that
//      LOOKS like an OAuth code (one long token, no spaces, usually with `#`)
//      and types it into the pane literally instead of waking Claude — Claude
//      is mid-login and could not act on it anyway.
//   4. Poll for «Login successful» / «Logged in», confirm to the owner, clear
//      the flag. On timeout send the screen tail (code redacted).
//
// SECURITY: the OAuth code is a live credential. It is NEVER logged and NEVER
// echoed back into chat — the failure tail is scrubbed via redactSecret.

import { readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import type { Logger } from '../log.js'
import type { TelegramApi } from '../channel/tools.js'
import {
  capturePaneHistory,
  sendKeys,
  sendSlashCommand,
  type KeysCaptureExec,
  type KeysExec,
  type TmuxKeysTarget,
} from './keys.js'

// ─────────────────────────────────────────────────────────────────────
// OAuth artefact recognition. Pure functions — unit-tested directly.
// ─────────────────────────────────────────────────────────────────────

// Claude Code's /login prints a long authorize URL on claude.ai containing
// `/oauth` in its path. `\S+` swallows the query string; capture-pane is run
// with -J so a soft-wrapped URL is re-joined into one line before matching.
export const OAUTH_URL_RE = /https:\/\/[^\s"'<>]*claude\.ai\/oauth[^\s"'<>]*/

export function findOauthUrl(text: string): string | undefined {
  const m = OAUTH_URL_RE.exec(text)
  return m ? m[0] : undefined
}

// An OAuth authorization code as pasted by the operator: a single token,
// longer than 20 chars, no whitespace, base64url-ish charset WITH the `#`
// separator Claude's code page always uses (`code#state`) — a token without
// `#` is not a Claude code, so requiring it keeps ordinary long identifiers
// (git hashes, UUID-ish strings) flowing to Claude even while the relogin
// flag is armed. Pure-hex strings are rejected explicitly on top (belt and
// braces against commit hashes), as are URLs (`://`, dots) and Cyrillic —
// they all fall outside the charset.
export function looksLikeOauthCode(text: string): boolean {
  const t = text.trim()
  if (t.length <= 20) return false
  if (t.startsWith('/')) return false // never swallow a slash command
  if (!t.includes('#')) return false // Claude codes are always `code#state`
  if (/^[0-9a-f]+$/i.test(t)) return false // a bare git/hex hash, not a code
  return /^[A-Za-z0-9_#-]+$/.test(t)
}

// ─────────────────────────────────────────────────────────────────────
// relogin-pending state flag. A plain file in TELEGRAM_STATE_DIR whose
// mtime is the arm timestamp; freshness (15-min TTL) is judged by mtime
// so a stale flag from a crashed flow can never intercept forever.
// ─────────────────────────────────────────────────────────────────────

export const RELOGIN_PENDING_TTL_MS = 15 * 60_000
const RELOGIN_FLAG_FILE = 'relogin-pending'

export function armReloginPending(stateDir: string): void {
  // Content is informational (debugging); the TTL contract lives in mtime.
  writeFileSync(join(stateDir, RELOGIN_FLAG_FILE), `${new Date().toISOString()}\n`, 'utf8')
}

export function clearReloginPending(stateDir: string): void {
  try {
    rmSync(join(stateDir, RELOGIN_FLAG_FILE))
  } catch {
    // Already gone — clearing is idempotent.
  }
}

export function isReloginPending(stateDir: string, now: number = Date.now()): boolean {
  return reloginPendingRemainingMs(stateDir, now) !== undefined
}

// Milliseconds until the armed flag expires, or undefined when no live flag.
// Used by the /relogin double-invocation guard to tell the owner how long
// the current code window still lasts.
export function reloginPendingRemainingMs(
  stateDir: string,
  now: number = Date.now(),
): number | undefined {
  try {
    const st = statSync(join(stateDir, RELOGIN_FLAG_FILE))
    const left = RELOGIN_PENDING_TTL_MS - (now - st.mtimeMs)
    return left > 0 ? left : undefined
  } catch {
    return undefined
  }
}

// Exposed for tests/debugging — reads the armed-at line, never throws.
export function readReloginFlag(stateDir: string): string | undefined {
  try {
    return readFileSync(join(stateDir, RELOGIN_FLAG_FILE), 'utf8').trim()
  } catch {
    return undefined
  }
}

// ─────────────────────────────────────────────────────────────────────
// Shared plumbing.
// ─────────────────────────────────────────────────────────────────────

const realSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms))

function escapeHtml(s: string): string {
  return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

// Last N non-empty-tail lines of a pane capture, for the «no URL / no
// confirmation» failure replies. Trailing blank rows are dropped so the tail
// shows actual content, not the empty bottom of the terminal.
export function paneTail(text: string, lines: number = 15): string {
  const rows = text.split('\n')
  let end = rows.length
  while (end > 0 && rows[end - 1]!.trim().length === 0) end--
  return rows.slice(Math.max(0, end - lines), end).join('\n')
}

// Scrub a secret out of a screen tail before it is sent to chat. The pasted
// OAuth code is echoed in the composer box, so an un-scrubbed failure tail
// would leak a live credential into Telegram history.
export function redactSecret(text: string, secret: string): string {
  if (secret.length === 0) return text
  return text.split(secret).join('•••')
}

export interface ReloginIo {
  target: TmuxKeysTarget
  chatId: string
  stateDir: string
  telegramApi: TelegramApi
  log: Logger
  // Test seams — production uses the real tmux execs and timer.
  exec?: KeysExec
  captureExec?: KeysCaptureExec
  sleep?: (ms: number) => Promise<void>
}

// How far back to capture. 200 history lines comfortably span the /login
// banner + URL even after further output; -J re-joins wrapped lines so the
// URL regex sees it whole.
const CAPTURE_HISTORY_LINES = 200

// Best-effort Telegram send — a delivery failure must never crash the poller
// loop that hosts this background flow. Returns whether the send actually
// landed: callers whose NEXT step depends on the owner having seen the
// message (arming the code-interception flag) must check it.
async function sendHtml(io: ReloginIo, text: string): Promise<boolean> {
  try {
    await io.telegramApi.sendMessage(io.chatId, text, { parse_mode: 'HTML' })
    return true
  } catch (err) {
    io.log.warn('relogin: telegram send failed', {
      chat_id: io.chatId,
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 1 — /relogin: type /login, hunt for the OAuth URL, deliver it.
// Runs DETACHED from the OOB dispatcher (fire-and-forget) so the ack
// reply reaches the owner immediately; every outcome is reported via
// its own Telegram message. Never throws.
// ─────────────────────────────────────────────────────────────────────

export async function runReloginFlow(
  io: ReloginIo,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<void> {
  const sleep = io.sleep ?? realSleep
  const timeoutMs = opts.timeoutMs ?? 40_000
  const intervalMs = opts.intervalMs ?? 2_000
  try {
    // Deliberate BLIND 3-shot (C-u → literal `/login` → Enter) via
    // sendSlashCommand: the login-expired screen does not classify as idle,
    // so the state-aware sendControlCommand would refuse exactly when the
    // relogin is needed. C-u first makes the Enter safe against drafts.
    const sent = await sendSlashCommand(io.target, { name: 'login', rest: '' }, io.exec)
    if (!sent.ok) {
      await sendHtml(
        io,
        `<b>перелогин</b> — не смог набрать /login в сессию: <code>${escapeHtml(sent.error)}</code>`,
      )
      return
    }

    const deadline = Date.now() + timeoutMs
    let lastCapture = ''
    let url: string | undefined
    for (;;) {
      await sleep(intervalMs)
      lastCapture = await capturePaneHistory(io.target, CAPTURE_HISTORY_LINES, io.captureExec)
      url = findOauthUrl(lastCapture)
      if (url !== undefined || Date.now() >= deadline) break
    }

    if (url === undefined) {
      await sendHtml(
        io,
        '<b>перелогин</b> — ссылка не появилась за 40 сек. Хвост экрана:\n'
          + `<pre>${escapeHtml(paneTail(lastCapture))}</pre>\n`
          + 'Можно дожать диалог через /keys и повторить /relogin.',
      )
      return
    }

    // Hyperlink, NEVER a bare URL — the channel mangles bare URLs (memory:
    // channel-mangles-urls-send-as-markdown-link). HTML anchor == the
    // markdown link once rendered; HTML is the plugin's send format.
    //
    // ORDER IS LOAD-BEARING: the flag is armed only AFTER the link send
    // succeeded. Arming first would leave a live 15-minute interception
    // window with no link in the owner's hands — any code-shaped message
    // would silently go to tmux instead of Claude.
    const delivered = await sendHtml(
      io,
      `<b>перелогин</b> — <a href="${escapeHtml(url)}">Войти в Claude</a>\n\n`
        + 'После входа пришли сюда код со страницы — вставлю его в сессию сам '
        + '(жду 15 минут).',
    )
    if (!delivered) return // logged inside sendHtml; flag stays un-armed
    armReloginPending(io.stateDir)
    io.log.info('relogin: oauth url delivered, flag armed', { chat_id: io.chatId })
  } catch (err) {
    io.log.warn('relogin flow failed', {
      chat_id: io.chatId,
      error: err instanceof Error ? err.message : String(err),
    })
    await sendHtml(io, '<b>перелогин</b> — внутренняя ошибка, смотри логи плагина.')
  }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 2 — the pasted OAuth code. Typed into the pane literally
// (send-keys -l) + Enter, then poll for the success banner. The code is
// never logged and never echoed back; the failure tail is scrubbed.
// ─────────────────────────────────────────────────────────────────────

const LOGIN_SUCCESS_RE = /Login successful|Logged in/

function countMatches(re: RegExp, text: string): number {
  const global = new RegExp(re.source, 'g')
  return text.match(global)?.length ?? 0
}

export async function submitReloginCode(
  io: ReloginIo,
  code: string,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<void> {
  const sleep = io.sleep ?? realSleep
  const timeoutMs = opts.timeoutMs ?? 20_000
  const intervalMs = opts.intervalMs ?? 2_000
  try {
    // Baseline BEFORE typing: a «Login successful» left in scrollback from a
    // previous month must not certify this attempt — success is a FRESH
    // occurrence (same increase-vs-baseline principle as keys.ts confirmedFired).
    const baseline = await capturePaneHistory(io.target, CAPTURE_HISTORY_LINES, io.captureExec)
    const baseCount = countMatches(LOGIN_SUCCESS_RE, baseline)

    // C-u (clear any draft) → literal code → Enter, mirroring
    // sendSlashCommand's hygiene. A code with a leading `-` is safe because
    // sendKeys emits `-l --` for literal steps — the `--` option terminator
    // (added in keys.ts) is what stops tmux reading the text as a flag.
    const typed = await sendKeys(
      io.target,
      {
        steps: [
          { literal: false, key: 'C-u' },
          { literal: true, key: code },
          { literal: false, key: 'Enter' },
        ],
      },
      io.exec,
    )
    if (!typed.ok) {
      await sendHtml(
        io,
        `<b>перелогин</b> — не смог ввести код в сессию: <code>${escapeHtml(typed.error)}</code>`,
      )
      return
    }

    const deadline = Date.now() + timeoutMs
    let lastCapture = ''
    let confirmed = false
    for (;;) {
      await sleep(intervalMs)
      lastCapture = await capturePaneHistory(io.target, CAPTURE_HISTORY_LINES, io.captureExec)
      if (countMatches(LOGIN_SUCCESS_RE, lastCapture) > baseCount) {
        confirmed = true
        break
      }
      if (Date.now() >= deadline) break
    }

    if (confirmed) {
      clearReloginPending(io.stateDir)
      io.log.info('relogin: login confirmed', { chat_id: io.chatId })
      await sendHtml(io, '<b>перелогин</b> — вход обновлён.')
      return
    }

    await sendHtml(
      io,
      '<b>перелогин</b> — подтверждение входа не увидел за 20 сек. Хвост экрана:\n'
        + `<pre>${escapeHtml(redactSecret(paneTail(lastCapture), code))}</pre>`,
    )
  } catch (err) {
    io.log.warn('relogin code submit failed', {
      chat_id: io.chatId,
      error: err instanceof Error ? err.message : String(err),
    })
    await sendHtml(io, '<b>перелогин</b> — внутренняя ошибка при вводе кода, смотри логи.')
  }
}
