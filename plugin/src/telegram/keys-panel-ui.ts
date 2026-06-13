// /keys panel — one-tap inline-button keypad for answering Claude Code's
// NATIVE terminal dialogs (permission rules, model switch, trust prompts)
// from Telegram. The buttons are a graphical front-end to the SAME
// keystroke injection that `/key` performs: a tap presses ONE whitelisted
// key in the agent's tmux pane.
//
// Callback data uses the `kkey:` prefix so it never collides with the other
// inline flows sharing bot.on('callback_query:data'):
//   * `pgate:*` — permission-gate Allow/Deny (telegram/permission-gate-ui.ts)
//   * `ask:*`   — AskUserQuestion (telegram/ask-user-question.ts)
//   * `perm:*`  — headless MCP permission relay (channel/permissions.ts)
//
//   kkey:<token>   where <token> is ONE entry of the /key whitelist.
//
// Security: a tap is honoured ONLY for a user id in the same allow-list that
// guards the sibling `/key` OOB command (config.allowed_user_ids). Anyone
// else gets an answerCallbackQuery toast and NO keystroke is sent. The token
// set is the exact keys.ts whitelist — there is no way to inject arbitrary
// text into the pane (so a pane that dropped to a shell can't be driven to
// run a command). See server.ts bot.on('callback_query:data') for the wiring.

import {
  LITERAL_TOKENS,
  NAMED_TOKENS,
  parseKeyTokens,
  sendKeys,
  type KeysExec,
  type TmuxKeysTarget,
} from '../commands/keys.js'
import type { InlineKeyboardLike } from '../channel/tools.js'
import type { Logger } from '../log.js'

// The callback prefix. Distinct from pgate:/ask:/perm: by construction.
export const KKEY_PREFIX = 'kkey:'

// The closed set of tokens a `kkey:` callback may carry === the keys.ts
// whitelist (digits 0-9, y, n, enter, esc/escape, tab, space, arrows).
// Reusing keys.ts's sets keeps a single source of truth: extending the
// whitelist there extends what the panel accepts, no duplicate list.
const ALLOWED_TOKENS: ReadonlySet<string> = new Set<string>([
  ...LITERAL_TOKENS,
  ...Object.keys(NAMED_TOKENS),
])

// Parse a `kkey:<token>` callback_data string. Returns the validated token
// (lower-cased, single entry of the whitelist) or null for anything else —
// a non-kkey prefix, an empty token, a multi-token payload, or a token
// outside the whitelist. Null callers answer the callback with a toast and
// send NO keystroke (fail-closed).
export function parseKkeyCallback(data: string): string | null {
  if (typeof data !== 'string') return null
  if (!data.startsWith(KKEY_PREFIX)) return null
  const token = data.slice(KKEY_PREFIX.length)
  // Single token only — reject embedded separators / whitespace / sequences
  // (e.g. `1;2`, `1 enter`). The pane-injection layer takes one key per tap.
  if (token.length === 0) return null
  if (!ALLOWED_TOKENS.has(token)) return null
  return token
}

// Build the 3-row keypad. Labels are human-friendly (✓ y, ⏎ enter, arrows);
// callback_data carries the raw whitelist token the handler injects.
//
// Row1: dialog option selectors 1-5
// Row2: yes/no + confirm/cancel
// Row3: arrow navigation
export function buildKeysKeyboard(): InlineKeyboardLike {
  return {
    inline_keyboard: [
      [
        { text: '1', callback_data: `${KKEY_PREFIX}1` },
        { text: '2', callback_data: `${KKEY_PREFIX}2` },
        { text: '3', callback_data: `${KKEY_PREFIX}3` },
        { text: '4', callback_data: `${KKEY_PREFIX}4` },
        { text: '5', callback_data: `${KKEY_PREFIX}5` },
      ],
      [
        { text: '✓ y', callback_data: `${KKEY_PREFIX}y` },
        { text: '✗ n', callback_data: `${KKEY_PREFIX}n` },
        { text: '⏎ enter', callback_data: `${KKEY_PREFIX}enter` },
        { text: '⎋ esc', callback_data: `${KKEY_PREFIX}esc` },
      ],
      [
        { text: '↑ up', callback_data: `${KKEY_PREFIX}up` },
        { text: '↓ down', callback_data: `${KKEY_PREFIX}down` },
        { text: '← left', callback_data: `${KKEY_PREFIX}left` },
        { text: '→ right', callback_data: `${KKEY_PREFIX}right` },
      ],
    ],
  }
}

// Header text rendered above the keypad. HTML parse mode.
export const KEYS_PANEL_HEADER =
  '<b>Управление сессией</b> — тап = нажатие в моей сессии. '
  + 'Для диалога Claude Code: 1/2/3 = выбор пункта, y/n = да/нет, '
  + '⏎ подтвердить, ⎋ отмена.'

// ─────────────────────────────────────────────────────────────────────
// Callback handler (extracted from server.ts so it is unit-testable in
// isolation, mirroring permission-gate-ui.ts's handlePgateCallback). The
// security model is the same: parse → fail-closed auth → pane check →
// inject. A reject at ANY step toasts and sends NO keystroke.
// ─────────────────────────────────────────────────────────────────────

// Structural subset of grammY's callback_query Context the handler needs.
export interface KkeyCallbackContext {
  callbackQuery: { data: string }
  from: { id: number }
  answerCallbackQuery(arg: { text: string }): Promise<void>
}

export interface KkeyCallbackDeps {
  // The SAME allowlist that guards the sibling `/key` OOB text command
  // (config.allowed_user_ids). A tap is honoured only for a user id in
  // this set — fail-closed for everyone else.
  allowedUserIds: readonly number[]
  // The resolved agent pane. Undefined when the plugin can't resolve a
  // pane (no tmux config / no $TMUX env) — a tap then toasts «pane
  // недоступен» and sends nothing.
  tmuxKeysTarget?: TmuxKeysTarget
  log: Logger
  // Injected for tests; defaults to the real tmux exec inside sendKeys.
  exec?: KeysExec
}

// Dispatch a `kkey:*` callback. Always answers the callback query (so the
// Telegram spinner clears) and returns true when it consumed the event.
// NEVER injects a keystroke for a non-allowed user id (the warchief's hard
// requirement). Does NOT mutate the keyboard message — the warchief taps it
// repeatedly across a multi-step dialog.
export async function handleKkeyCallback(
  ctx: KkeyCallbackContext,
  deps: KkeyCallbackDeps,
): Promise<boolean> {
  const token = parseKkeyCallback(ctx.callbackQuery.data)
  if (token === null) {
    await ctx.answerCallbackQuery({ text: 'неизвестная клавиша' })
    return true
  }
  // Fail-closed auth: only an allowed user id may drive the session.
  if (!deps.allowedUserIds.includes(ctx.from.id)) {
    deps.log.warn('kkey unauthorized tap', { user_id: ctx.from.id, token })
    await ctx.answerCallbackQuery({ text: 'не авторизовано' })
    return true
  }
  if (deps.tmuxKeysTarget === undefined) {
    await ctx.answerCallbackQuery({ text: 'pane недоступен' })
    return true
  }
  const parsedKeys = parseKeyTokens(token)
  if ('error' in parsedKeys) {
    // Unreachable: parseKkeyCallback already validated the token against the
    // same whitelist. Handle defensively so an unexpected reject toasts and
    // still sends nothing.
    await ctx.answerCallbackQuery({ text: 'неизвестная клавиша' })
    return true
  }
  const sent = await sendKeys(deps.tmuxKeysTarget, parsedKeys, deps.exec)
  if (sent.ok) {
    await ctx.answerCallbackQuery({ text: `нажато: ${token}` })
  } else {
    await ctx.answerCallbackQuery({ text: `ошибка: ${sent.error.slice(0, 180)}` })
  }
  return true
}
