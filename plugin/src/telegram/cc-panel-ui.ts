// /cc panel — one-tap inline-button keypad for running the MOST COMMON
// Claude Code slash commands (/compact, /clear, /model, …) in the agent's
// tmux pane from Telegram. It is the graphical front-end to the SAME
// passthrough `/cc <command>` performs: a tap types `/<name>` into the pane
// and submits with Enter (via sendSlashCommand, which C-u clears the input
// line first so a leftover draft can't corrupt the command).
//
// Callback data uses the `ccmd:` prefix so it never collides with the other
// inline flows sharing bot.on('callback_query:data'):
//   * `kkey:*`  — /keys keystroke keypad (telegram/keys-panel-ui.ts)
//   * `pgate:*` — permission-gate Allow/Deny
//   * `ask:*`   — AskUserQuestion
//   * `perm:*`  — headless MCP permission relay
//
//   ccmd:<name>   where <name> is ONE entry of the CLOSED command whitelist
//                 below (argless, popular Claude Code commands only).
//
// Security: a tap is honoured ONLY for a user id in the same allow-list that
// guards the sibling `/cc` OOB command (config.allowed_user_ids). Anyone else
// gets an answerCallbackQuery toast and NOTHING is typed. The command set is a
// FROZEN whitelist — there is no way to type arbitrary text into the pane, so
// a pane that dropped to a shell can't be driven to run a shell command.

import {
  capturePane,
  classifyPane,
  sendControlCommand,
  sendSlashCommand,
  type ControlCommandOpts,
  type KeysCaptureExec,
  type KeysExec,
  type TmuxKeysTarget,
} from '../commands/keys.js'
import {
  captureCleanPane,
  type CapturePaneTarget,
} from '../status/tmux-mirror.js'
import { buildNewConfirmCard } from './newq-confirm-ui.js'
import type { InlineKeyboardLike } from '../channel/tools.js'
import type { Logger } from '../log.js'

// The callback prefix. Distinct from kkey:/pgate:/ask:/perm: by construction.
export const CCMD_PREFIX = 'ccmd:'

// `compact` needs to interrupt a busy pane first, so it is routed through the
// state-aware `sendControlCommand` (probe → interrupt-if-busy → send → confirm)
// — but it is non-destructive, so it stays one-tap. `clear` is DESTRUCTIVE
// (wipes the context) so FIX-7 routes it through the SAME /new confirm card as
// /new and hud:new — never a one-tap clear from the panel. Every other panel
// command is safe to type into the composer via `sendSlashCommand` (e.g.
// `model` opens a picker, `context`/`cost`/`status` are read-only).
const RELIABLE_CCMD: ReadonlySet<string> = new Set(['compact'])

// Closed, frozen whitelist of the popular Claude Code slash commands the panel
// exposes. name = the command typed (no leading slash, no args); label = the
// button text; desc = one-line explanation rendered in the header. Argless on
// purpose: a tap is a fixed command, not a macro. `model` opens Claude Code's
// interactive model picker — drive the selection afterwards with the /keys
// arrows + ⏎. Object.freeze (deep) so the set can't be widened at runtime.
export interface CcCommandSpec {
  readonly name: string
  readonly label: string
  readonly desc: string
  // When true, after the command is typed into the pane we snapshot the pane,
  // clean it, and forward the rendered output to the originating Telegram chat
  // (so the device pings with the actual answer, not just a toast). Set true
  // for read-only commands that render a clean text block (context/cost/
  // status/resume/export); false for commands that mutate TUI state or open an
  // interactive picker (compact/clear/model) where a captured frame is
  // meaningless — those keep the toast-only behaviour.
  readonly forwardOutput: boolean
}
export const CC_PANEL_COMMANDS: readonly CcCommandSpec[] = Object.freeze([
  Object.freeze({ name: 'compact', label: '🗜 compact', desc: 'сжать контекст (освободить место)', forwardOutput: false }),
  Object.freeze({ name: 'context', label: '📊 context', desc: 'показать расход контекста', forwardOutput: true }),
  Object.freeze({ name: 'cost', label: '💰 cost', desc: 'стоимость токенов сессии', forwardOutput: true }),
  Object.freeze({ name: 'status', label: 'ℹ️ status', desc: 'статус Claude Code', forwardOutput: true }),
  Object.freeze({ name: 'model', label: '🧠 model', desc: 'выбрать модель (дальше стрелки /keys + ⏎)', forwardOutput: false }),
  Object.freeze({ name: 'resume', label: '⏯ resume', desc: 'список/возобновить сессии', forwardOutput: true }),
  Object.freeze({ name: 'export', label: '📤 export', desc: 'экспорт диалога', forwardOutput: true }),
  Object.freeze({ name: 'clear', label: '🧹 clear', desc: 'очистить диалог — НОВЫЙ контекст (необратимо)', forwardOutput: false }),
] as const)

// O(1) lookup of the per-command forward flag, keyed by the frozen specs.
const FORWARD_OUTPUT: ReadonlyMap<string, boolean> = new Map<string, boolean>(
  CC_PANEL_COMMANDS.map((c) => [c.name, c.forwardOutput]),
)

// Membership lookup built from the frozen specs — single source of truth.
const ALLOWED_CCMD: ReadonlySet<string> = new Set<string>(
  CC_PANEL_COMMANDS.map((c) => c.name),
)

// Parse a `ccmd:<name>` callback_data string. Returns the validated command
// name (one entry of the frozen whitelist) or null for anything else — a
// non-ccmd prefix, an empty name, or a name outside the whitelist. Null
// callers answer the callback with a toast and type NOTHING (fail-closed).
export function parseCcmdCallback(data: string): string | null {
  if (typeof data !== 'string') return null
  if (!data.startsWith(CCMD_PREFIX)) return null
  const name = data.slice(CCMD_PREFIX.length)
  if (name.length === 0) return null
  if (!ALLOWED_CCMD.has(name)) return null
  return name
}

// Build the keypad: two commands per row, in the CC_PANEL_COMMANDS order.
export function buildCcKeyboard(): InlineKeyboardLike {
  const rows: Array<Array<{ text: string; callback_data: string }>> = []
  for (let i = 0; i < CC_PANEL_COMMANDS.length; i += 2) {
    const row = CC_PANEL_COMMANDS.slice(i, i + 2).map((c) => ({
      text: c.label,
      callback_data: `${CCMD_PREFIX}${c.name}`,
    }))
    rows.push(row)
  }
  return { inline_keyboard: rows }
}

// Header text rendered above the keypad. HTML parse mode. Lists each command
// with its explanation so the warchief knows what every button does.
export const CC_PANEL_HEADER =
  '<b>Команды Claude Code</b> — тап = выполнить в моей сессии.\n'
  + CC_PANEL_COMMANDS.map((c) => `<code>/${c.name}</code> — ${c.desc}`).join('\n')

// ─────────────────────────────────────────────────────────────────────
// Callback handler — mirrors handleKkeyCallback. Security model: fail-closed
// auth FIRST → parse name → pane check → run. A reject at ANY step toasts and
// types NOTHING. Auth precedes parsing so a non-allowed caller can never learn
// which commands are valid.
// ─────────────────────────────────────────────────────────────────────

// ── Output-forwarding timing (TUI render is async after Enter) ──────────
// After the command is submitted the TUI needs a beat to render. We poll
// capture-pane until two consecutive snapshots are identical (the frame
// stabilized) OR the overall budget runs out, then forward whatever is there.
// Constants, not magic numbers — different commands render at different
// speeds and `compact`-class work can lag, so the cap is the safety net.
const FORWARD_INITIAL_DELAY_MS = 600 // let the TUI start drawing before the first capture
const FORWARD_POLL_INTERVAL_MS = 350 // gap between stability snapshots
const FORWARD_MAX_WAIT_MS = 3000 // hard cap — forward whatever is rendered by now
// Telegram-safe slice of the forwarded text (the hard sendMessage cap is 4096;
// stay well under it after the <pre> wrapper + HTML escaping).
const FORWARD_MAX_CHARS = 3500
// How many pane lines to capture for the snapshot — enough to hold a /context
// or /cost panel without dragging in stale scrollback.
const FORWARD_CAPTURE_LINES = 200

// A sleep that does not depend on the test clock — the poll loop's real-time
// backstop. Tests inject `sleep: () => Promise.resolve()` to skip the waits.
function defaultSleep(ms: number): Promise<void> {
  return new Promise<void>((r) => setTimeout(r, ms))
}

// Escape the three characters Telegram's HTML parser cares about so the
// forwarded pane text can't break the `<pre>` wrapper.
function htmlEscape(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

// Trim TUI chrome and size the captured pane down to a Telegram-safe `<pre>`
// block. Drops trailing blank lines and the trailing input-prompt / footer
// lines (the `>`-prefixed input box and `? for shortcuts`-style hints), then
// caps to the last FORWARD_MAX_CHARS so the most recent output survives.
// Returns null when nothing meaningful remains (caller keeps the toast).
export function buildForwardHtml(rawCleanedPane: string, name: string): string | null {
  let lines = rawCleanedPane.replace(/\r/g, '').split('\n')
  // Strip trailing blank lines.
  while (lines.length > 0 && lines[lines.length - 1]!.trim() === '') lines.pop()
  // Strip trailing TUI chrome: the input prompt line (`>`), shortcut/footer
  // hints, and bare prompt scaffolding. Conservative — only the tail, only
  // recognizably-chrome lines, so real output is never eaten.
  const isChrome = (l: string): boolean => {
    const t = l.trim()
    if (t === '') return true
    if (t === '>' || /^>\s*$/.test(t)) return true
    if (/shortcuts|bypass permissions|auto-accept|^\?\s/i.test(t)) return true
    return false
  }
  while (lines.length > 0 && isChrome(lines[lines.length - 1]!)) lines.pop()
  let body = lines.join('\n').trimEnd()
  if (body.trim() === '') return null
  let truncated = false
  if (body.length > FORWARD_MAX_CHARS) {
    body = body.slice(body.length - FORWARD_MAX_CHARS)
    const nl = body.indexOf('\n')
    if (nl >= 0 && nl < 200) body = body.slice(nl + 1)
    truncated = true
  }
  const prefix = truncated ? '… [truncated]\n' : ''
  const header = `<b>/${htmlEscape(name)}</b>\n`
  return `${header}<pre>${prefix}${htmlEscape(body)}</pre>`
}

export interface CcmdCallbackContext {
  callbackQuery: { data: string }
  from?: { id?: number | undefined }
  // The chat the tap came from — where the /new confirm card is posted for the
  // destructive `clear` button (FIX-7). Optional for source-compat with older
  // test stubs.
  chatId?: string
  answerCallbackQuery(arg: { text: string }): Promise<void>
}

export interface CcmdCallbackDeps {
  allowedUserIds: readonly number[]
  tmuxKeysTarget?: TmuxKeysTarget
  log: Logger
  exec?: KeysExec
  // Output forwarding (optional — when any piece is missing the handler keeps
  // the existing toast-only behaviour, never throws):
  //   captureExec  — tmux driver for capture-pane. Also reused by the reliable
  //                  path (compact) and the pre-send idle probe — same shape
  //                  as KeysCaptureExec, so one seam covers both call sites.
  //   sendMessage  — deliver the forwarded `<pre>` HTML to the user's chat.
  //   chatId       — the originating chat (from the callback) the output goes
  //                  to, and where the /new confirm card (below) gets posted.
  captureExec?: KeysCaptureExec
  sendMessage?: (chatId: string, htmlText: string) => Promise<void>
  chatId?: string
  // Test seam: override the inter-capture sleep so the poll loop runs
  // instantly. Shared by the output-forward poll and the reliable path.
  sleep?: (ms: number) => Promise<void>
  // FIX-7: post the /new confirm card (buildNewConfirmCard) as a FRESH message
  // for the destructive `clear` button. Wired in server.ts to the safe-wrapped
  // api. When absent, `clear` refuses (fail-closed — never a one-tap clear).
  sendConfirmCard?: (chatId: string, text: string, keyboard: InlineKeyboardLike) => Promise<void>
}

// Poll the pane until two consecutive captures match (frame stabilized) or the
// time budget is exhausted, then forward the cleaned output to the chat. Never
// throws — any failure is logged and the caller's toast still stands. Returns
// true when a message was actually sent.
async function forwardCommandOutput(
  name: string,
  target: CapturePaneTarget,
  deps: Required<Pick<CcmdCallbackDeps, 'captureExec' | 'sendMessage' | 'chatId'>>
    & Pick<CcmdCallbackDeps, 'log'>,
  sleep: (ms: number) => Promise<void>,
): Promise<boolean> {
  try {
    await sleep(FORWARD_INITIAL_DELAY_MS)
    const start = Date.now()
    let prev: string | null = null
    let latest = ''
    // Bounded stability poll. We always keep the most recent successful
    // capture so the cap path forwards SOMETHING even if it never stabilizes.
    for (;;) {
      const cap = await captureCleanPane(target, deps.captureExec, {
        lineCount: FORWARD_CAPTURE_LINES,
        stripBoxDrawing: true,
      })
      if (cap.ok) {
        latest = cap.text
        if (prev !== null && prev === latest) break // two identical frames → stable
        prev = latest
      }
      if (Date.now() - start >= FORWARD_MAX_WAIT_MS) break
      await sleep(FORWARD_POLL_INTERVAL_MS)
    }
    const html = buildForwardHtml(latest, name)
    if (html === null) return false
    await deps.sendMessage(deps.chatId, html)
    return true
  } catch (err) {
    deps.log.warn('ccmd output forward failed (ignored)', {
      command: name,
      error: err instanceof Error ? err.message : String(err),
    })
    return false
  }
}

// Dispatch a `ccmd:*` callback. Always answers the callback query and returns
// true when it consumed the event. NEVER types a command for a non-allowed
// user id. Does NOT mutate the keyboard message (the warchief taps it
// repeatedly).
export async function handleCcmdCallback(
  ctx: CcmdCallbackContext,
  deps: CcmdCallbackDeps,
): Promise<boolean> {
  // AUTH FIRST — before parsing the name or touching the pane. A non-allowed
  // (or missing/non-number id) caller gets ONLY «не авторизовано» and learns
  // nothing about command validity or pane state.
  const fromId = ctx.from?.id
  if (typeof fromId !== 'number' || !deps.allowedUserIds.includes(fromId)) {
    deps.log.warn('ccmd unauthorized tap', {
      user_id: fromId,
      data: ctx.callbackQuery.data,
    })
    await ctx.answerCallbackQuery({ text: 'не авторизовано' })
    return true
  }
  const name = parseCcmdCallback(ctx.callbackQuery.data)
  if (name === null) {
    await ctx.answerCallbackQuery({ text: 'неизвестная команда' })
    return true
  }
  // FIX-7: `clear` is destructive → route through the SAME /new confirm card as
  // /new and hud:new. Never a one-tap clear from the panel. Handled BEFORE the
  // pane check because posting a card needs no pane.
  if (name === 'clear') {
    if (deps.sendConfirmCard === undefined || ctx.chatId === undefined || ctx.chatId.length === 0) {
      // Fail-closed: without a way to post the confirm card we refuse rather
      // than fall back to a one-tap destructive clear.
      await ctx.answerCallbackQuery({ text: 'недоступно' })
      return true
    }
    const card = buildNewConfirmCard()
    try {
      await deps.sendConfirmCard(ctx.chatId, card.text, card.inlineKeyboard)
    } catch (err) {
      deps.log.warn('ccmd clear confirm-card send failed', {
        chat_id: ctx.chatId,
        error: err instanceof Error ? err.message : String(err),
      })
      // L12: the card never posted → do NOT claim «подтвердите очистку» (that
      // would tell the warchief to look for a card that isn't there). Report the
      // failure instead.
      await ctx.answerCallbackQuery({ text: 'не удалось показать подтверждение' })
      return true
    }
    await ctx.answerCallbackQuery({ text: 'подтвердите очистку' })
    return true
  }
  if (deps.tmuxKeysTarget === undefined) {
    await ctx.answerCallbackQuery({ text: 'pane недоступен' })
    return true
  }
  // compact → reliable state-aware injection (probe, interrupt-if-busy,
  // confirm-fire) so a busy pane or an open dialog can never eat the command.
  if (RELIABLE_CCMD.has(name)) {
    const opts: ControlCommandOpts = { interruptIfBusy: true }
    if (deps.exec) opts.exec = deps.exec
    if (deps.captureExec) opts.captureExec = deps.captureExec
    if (deps.sleep) opts.sleep = deps.sleep
    const res = await sendControlCommand(deps.tmuxKeysTarget, name, opts)
    if (res.ok) {
      await ctx.answerCallbackQuery({ text: `выполнено: /${name}` })
    } else {
      await ctx.answerCallbackQuery({ text: `не выполнено: ${res.reason}` })
    }
    return true
  }
  // IT2-1: the read-only / picker commands (context/cost/status/model/resume/
  // export) previously blind-fired via sendSlashCommand — but a trailing Enter
  // into an OPEN dialog APPROVES it, and into a BUSY pane the command is queued.
  // Gate on a POSITIVE idle exactly like the /cc TEXT path (FIX-6): probe the
  // pane, refuse with a toast when it is not idle, send only when idle.
  const state = classifyPane(await capturePane(deps.tmuxKeysTarget, deps.captureExec))
  if (state !== 'idle') {
    await ctx.answerCallbackQuery({ text: `сессия не готова (${state})` })
    return true
  }
  // rest is always '' — the panel runs argless commands only.
  const sent = await sendSlashCommand(deps.tmuxKeysTarget, { name, rest: '' }, deps.exec)
  if (!sent.ok) {
    await ctx.answerCallbackQuery({ text: `ошибка: ${sent.error.slice(0, 180)}` })
    return true
  }
  await ctx.answerCallbackQuery({ text: `выполнено: /${name}` })

  // Output forwarding: only for commands flagged worth-sending AND only when
  // all forward deps are wired. compact/clear/model (forwardOutput=false) keep
  // the toast-only behaviour — they mutate TUI state / open a picker, so a
  // captured frame is meaningless. Best-effort: a forward failure never
  // changes the toast already shown and never throws (auth/security paths
  // above are untouched). The capture addresses the SAME socket+pane the
  // command was typed into (derived from tmuxKeysTarget).
  if (
    FORWARD_OUTPUT.get(name) === true &&
    deps.captureExec !== undefined &&
    deps.sendMessage !== undefined &&
    deps.chatId !== undefined
  ) {
    const target: CapturePaneTarget = {
      paneTarget: deps.tmuxKeysTarget.paneTarget,
      ...(deps.tmuxKeysTarget.socketPath !== undefined
        ? { socketPath: deps.tmuxKeysTarget.socketPath }
        : {}),
      ...(deps.tmuxKeysTarget.socketName !== undefined
        ? { socketName: deps.tmuxKeysTarget.socketName }
        : {}),
    }
    await forwardCommandOutput(
      name,
      target,
      {
        captureExec: deps.captureExec,
        sendMessage: deps.sendMessage,
        chatId: deps.chatId,
        log: deps.log,
      },
      deps.sleep ?? defaultSleep,
    )
  }
  return true
}
