// Out-of-band (OOB) commands handled by the plugin BEFORE a channel
// notification is sent to Claude. Mirrors gateway.py:_OOB_COMMANDS +
// _handle_oob_command + handle_command (status/help/reset/new branches).
//
// Scope A commands: /help, /status, /stop, /reset, /new.
// Explicitly NOT included: /compact, /halt (Scope B per PLAN.md T10).
//
// Parsing rules (gateway.py:3037-3046 + 3366-3370):
//   - Must start with `/`.
//   - Optional `@botname` suffix is stripped when it matches our bot's
//     username (case-insensitive).
//   - Command word is lowercased.
//   - Trailing `force` token in args sets hasForceFlag (for /reset force,
//     /new force).
//
// Handling notes:
//   - /help and /status reply directly to Telegram and DO NOT wake Claude
//     (no channel notification). Status is a snapshot of plugin-side state
//     only — Claude session lives in the host process and we don't poke it.
//   - /stop, /reset force, /new force ack the user AND emit a channel
//     notification with meta.command=<name>. The plugin can't truly
//     interrupt Claude (no public API for that yet); /help documents this
//     limitation.
//   - /reset and /new without `force` return a short reply asking for the
//     flag, no channel notification.

import { readFileSync } from 'node:fs'
import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'
import type { TelegramApi, InlineKeyboardLike } from '../channel/tools.js'
import { sendChannelNotification, type ChannelEvent } from '../channel/notify.js'
import type { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { parseCcCommand, sendSlashCommand, sendNamedKey, type KeysExec, type TmuxKeysTarget } from './keys.js'
import { buildKeysKeyboard, KEYS_PANEL_HEADER } from '../telegram/keys-panel-ui.js'
import { buildCcKeyboard, CC_PANEL_HEADER } from '../telegram/cc-panel-ui.js'

export type OobCommandName = 'help' | 'status' | 'stop' | 'reset' | 'new' | 'mirror' | 'keys' | 'cc'

const KNOWN_COMMANDS = new Set<OobCommandName>([
  'help',
  'status',
  'stop',
  'reset',
  'new',
  'mirror',
  'keys',
  'cc',
])

// Sub-actions for /mirror. We accept the bare command (= same as `status`),
// plus on/off/status explicit args. Unknown sub-actions render the help line.
export type MirrorAction = 'on' | 'off' | 'status'

export interface ParsedOobCommand {
  name: OobCommandName
  rawText: string
  args: string
  hasForceFlag: boolean
}

// Parse a leading `/cmd[@botname] args...` token. Returns null if the text
// is not an OOB command (plain text, unknown command, no leading slash).
export function parseOobCommand(
  text: string,
  botUsername?: string,
): ParsedOobCommand | null {
  if (typeof text !== 'string' || text.length === 0) return null
  const trimmed = text.replace(/^\s+/, '')
  if (!trimmed.startsWith('/')) return null

  // Split on first whitespace run. parts[0] = "/word[@bot]", rest = args.
  const wsIdx = trimmed.search(/\s/)
  const head = wsIdx === -1 ? trimmed : trimmed.slice(0, wsIdx)
  const args = wsIdx === -1 ? '' : trimmed.slice(wsIdx + 1).trim()

  // Strip leading slash, optional @botname suffix.
  let word = head.slice(1)
  const atIdx = word.indexOf('@')
  if (atIdx !== -1) {
    const suffix = word.slice(atIdx + 1)
    word = word.slice(0, atIdx)
    // gateway.py strips ANY @suffix without verifying the bot identity, so we
    // mirror that here. botUsername is accepted for future tightening, but
    // not enforced — stripping any suffix matches gateway.py:3044-3045.
    void suffix
    void botUsername
  }

  const lower = word.toLowerCase() as OobCommandName
  if (!KNOWN_COMMANDS.has(lower)) return null

  const hasForceFlag = /^\s*force\s*$/i.test(args)

  return {
    name: lower,
    rawText: text,
    args,
    hasForceFlag,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Handler context and result shape.
// ─────────────────────────────────────────────────────────────────────

// Minimal surface of TmuxMirror that the OOB layer needs. Decoupled from
// the concrete class so tests don't need to spin up the full mirror.
//
// `bump` is optional because it's used by the inbound-message handler
// (not by /mirror commands) — keeping it optional avoids forcing every
// OOB unit test to stub a method it never exercises.
export interface TmuxMirrorControl {
  start(): Promise<void>
  stop(): Promise<void>
  bump?(): Promise<void>
  // MED-A #2: recovery from a permanent Telegram error (403 / parse)
  // that flipped `disabled=true`. /mirror on calls reset() before
  // start() so the warchief never has to restart the plugin.
  // Optional for source-compat with existing test stubs.
  reset?(): void
  status(): {
    enabled: boolean
    messageId?: number
    lastError?: string
    lastPollAt?: number
  }
}

export interface OobContext {
  chatId: string
  senderId: string
  config: AppConfig
  telegramApi: TelegramApi
  log: Logger
  // For /status, pulled lazily so handler stays decoupled from the
  // status manager (T11) and poller/webhook plumbing (T13).
  pollerStatus?: () => { offset: number | undefined; lastError?: string }
  statusManager?: {
    isActive: (chatId: string) => boolean
    cancel: (chatId: string, reason: string) => Promise<void>
  }
  webhookStatus?: () => { enabled: boolean; port: number }
  // /mirror control — undefined when tmux_mirror.enabled=false at startup.
  // The handler then replies «mirror disabled in config».
  tmuxMirror?: TmuxMirrorControl
  // /keys target — the pane of the agent's Claude session. Undefined when the
  // plugin can't resolve a pane (no tmux config); the handler then explains.
  tmuxKeys?: { target: TmuxKeysTarget; exec?: KeysExec }
  // Identity bits surfaced by /status.
  botId?: number
  stateDir?: string
}

export interface OobResult {
  handled: true
  command: OobCommandName
  notifyChannel?: { content: string; meta: Record<string, string> }
  // `inlineKeyboard` (optional, additive) attaches a reply_markup keypad to
  // the Telegram reply — used by /keys to render the tap panel. Mirrors how
  // the permission gate sends its Allow/Deny keyboard. Existing replies omit
  // it and Telegram sends a plain message.
  replyToTelegram?: { text: string; parseMode?: 'HTML'; inlineKeyboard?: InlineKeyboardLike }
}

// ─────────────────────────────────────────────────────────────────────
// /help text. Lists ONLY Scope A commands. Do not add /compact, /halt
// here — they belong to Scope B and grep checks enforce their absence.
// ─────────────────────────────────────────────────────────────────────

function helpText(): string {
  return (
    '<b>команды</b>\n\n'
    + '<code>/help</code> — эта справка\n'
    + '<code>/status</code> — снимок плагина и сессии\n'
    + '<code>/stop</code> — попросить Claude остановить текущую задачу\n'
    + '<code>/reset force</code> — сбросить состояние сессии (подтверди флагом <code>force</code>)\n'
    + '<code>/new force</code> — начать новую сессию (подтверди флагом <code>force</code>)\n'
    + '<code>/mirror on|off|status</code> — управлять зеркалом терминала (tmux, обновляется в реальном времени)\n'
    + '<code>/keys</code> — панель кнопок: тап = нажатие в сессии (ответить на нативный диалог Claude Code; есть ⌫ backspace и 🧹 clear)\n'
    + '<code>/cc</code> — панель команд Claude Code (тап = выполнить); либо <code>/cc &lt;команда&gt;</code>: <code>/cc compact</code>, <code>/cc model opus</code>\n\n'
    + '<i>примечание: /stop — best-effort: плагин передаёт сигнал остановки через '
    + 'канал, но не может гарантировать прерывание посреди вызова инструмента.</i>'
  )
}

// Public so server.ts can feed the SAME list to bot.api.setMyCommands and
// Telegram autocomplete stays in sync with what the parser actually accepts.
export interface BotCommandSpec {
  command: string
  description: string
}
// ponytail: only the commands worth a tap-menu slot live here. /new (dup of
// /reset), /mirror, /keys (no perm gates under --skip-permissions) still parse
// if typed — they're just off the autocomplete list.
export const BOT_COMMANDS: ReadonlyArray<BotCommandSpec> = [
  { command: 'help', description: 'справка по командам' },
  { command: 'status', description: 'память и размер контекста' },
  { command: 'stop', description: 'попросить Claude остановиться' },
  { command: 'reset', description: 'сбросить сессию (нужен force)' },
  { command: 'cc', description: 'панель команд Claude Code (тап) или /cc <команда>' },
]

// ponytail: Jarvis-specific paths hardcoded — this is Jarvis's own fork, not
// the generic upstream plugin. If reused elsewhere, lift to config/env.
const JARVIS_CORE = '/home/edgelab/.claude-lab/jarvis/.claude/core'
const CTX_WINDOW = 400_000 // CLAUDE_CODE_AUTO_COMPACT_WINDOW

function kb(bytes: number): string {
  return bytes < 1024 ? `${bytes} Б` : `${(bytes / 1024).toFixed(1)} КБ`
}

// Last usage.jsonl row ≈ what was sent to the model that turn:
// input + cache_read + cache_creation ≈ current context fill.
function contextFill(): number | undefined {
  try {
    const raw = readFileSync(`${JARVIS_CORE}/usage.jsonl`, 'utf8').trimEnd()
    const last = raw.slice(raw.lastIndexOf('\n') + 1)
    const r = JSON.parse(last) as { input?: number; cache_read?: number; cache_creation?: number }
    return (r.input ?? 0) + (r.cache_read ?? 0) + (r.cache_creation ?? 0)
  } catch {
    return undefined
  }
}

function fileStat(path: string): { bytes: number; entries: number } | undefined {
  try {
    const txt = readFileSync(path, 'utf8')
    return { bytes: Buffer.byteLength(txt, 'utf8'), entries: (txt.match(/^### /gm) ?? []).length }
  } catch {
    return undefined
  }
}

function statusText(ctx: OobContext): string {
  const lines: string[] = ['<b>память + контекст</b>']

  const fill = contextFill()
  if (fill !== undefined) {
    const pct = Math.round((fill / CTX_WINDOW) * 100)
    const flag = pct >= 80 ? ' ⚠️' : ''
    lines.push(`контекст: ~${Math.round(fill / 1000)}k / ${CTX_WINDOW / 1000}k (${pct}%)${flag}`)
  }

  const recent = fileStat(`${JARVIS_CORE}/hot/recent.md`)
  if (recent) lines.push(`recent.md: ${recent.entries} записей, ${kb(recent.bytes)}`)
  const handoff = fileStat(`${JARVIS_CORE}/hot/handoff.md`)
  if (handoff) lines.push(`handoff.md: ${kb(handoff.bytes)} (последние 5)`)
  const mem = fileStat(`${JARVIS_CORE}/MEMORY.md`)
  if (mem) lines.push(`MEMORY.md: ${kb(mem.bytes)}`)

  lines.push('')
  lines.push('<code>/reset force</code> — сбросить окно (handoff сохранится сам)')

  // compact diag tail — webhook/poller health in one glance
  const diag: string[] = []
  if (ctx.webhookStatus) {
    const ws = ctx.webhookStatus()
    diag.push(`webhook ${ws.enabled ? `on:${ws.port}` : 'off'}`)
  }
  if (ctx.pollerStatus) {
    const ps = ctx.pollerStatus()
    if (ps.lastError) diag.push(`poller_err: ${escapeHtml(ps.lastError)}`)
  }
  if (ctx.statusManager) {
    diag.push(`status ${ctx.statusManager.isActive(ctx.chatId) ? 'active' : 'idle'}`)
  }
  if (diag.length) lines.push(`<i>${diag.join(' · ')}</i>`)

  return lines.join('\n')
}

function escapeHtml(s: string): string {
  return s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
}

// ─────────────────────────────────────────────────────────────────────
// Main dispatcher. Pure data — caller actually issues sendMessage and
// channel notification calls based on the OobResult. This keeps the
// function trivially testable.
// ─────────────────────────────────────────────────────────────────────

export async function handleOobCommand(
  parsed: ParsedOobCommand,
  ctx: OobContext,
): Promise<OobResult> {
  const baseMeta: Record<string, string> = {
    source: 'telegram',
    chat_id: ctx.chatId,
    user_id: ctx.senderId,
    ts: new Date().toISOString(),
    command: parsed.name,
  }

  switch (parsed.name) {
    case 'help': {
      ctx.log.info('oob /help', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'help',
        replyToTelegram: { text: helpText(), parseMode: 'HTML' },
      }
    }

    case 'status': {
      ctx.log.info('oob /status', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'status',
        replyToTelegram: { text: statusText(ctx), parseMode: 'HTML' },
      }
    }

    case 'stop': {
      ctx.log.info('oob /stop', { chat_id: ctx.chatId })
      // Cancel any active status — the user explicitly asked to halt, so
      // leaving "Печатает..." pulsing while we wait for Claude to notice
      // the channel event would be confusing. Best-effort: errors in cancel
      // are swallowed inside the manager.
      if (ctx.statusManager && ctx.statusManager.isActive(ctx.chatId)) {
        try {
          await ctx.statusManager.cancel(ctx.chatId, 'user stop')
        } catch (err) {
          ctx.log.warn('oob /stop status cancel failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
      }
      // Real interrupt: Escape stops Claude's current generation/tool. Falls
      // back to the channel-notification signal when no pane is resolvable.
      if (ctx.tmuxKeys) {
        const sent = await sendNamedKey(ctx.tmuxKeys.target, 'Escape', ctx.tmuxKeys.exec)
        return {
          handled: true,
          command: 'stop',
          replyToTelegram: {
            text: sent.ok
              ? '<b>stop</b> — Escape отправлен в сессию (прерывание).'
              : `<b>stop</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
            parseMode: 'HTML',
          },
        }
      }
      return {
        handled: true,
        command: 'stop',
        replyToTelegram: {
          text: '<b>stop</b> — запрос принят. Claude увидит сигнал остановки при следующем чтении канала.',
          parseMode: 'HTML',
        },
        notifyChannel: {
          content: '/stop',
          meta: baseMeta,
        },
      }
    }

    case 'reset': {
      if (!parsed.hasForceFlag) {
        return {
          handled: true,
          command: 'reset',
          replyToTelegram: {
            text: 'Для подтверждения добавь <code>force</code>: <code>/reset force</code>',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /reset force', { chat_id: ctx.chatId })
      // Real reset: type Claude Code's own /clear into the pane. Fallback to
      // the (best-effort) channel signal when no pane is resolvable.
      if (ctx.tmuxKeys) {
        const sent = await sendSlashCommand(ctx.tmuxKeys.target, { name: 'clear', rest: '' }, ctx.tmuxKeys.exec)
        return {
          handled: true,
          command: 'reset',
          replyToTelegram: {
            text: sent.ok
              ? '<b>сессия сброшена</b> — отправил <code>/clear</code> в сессию.'
              : `<b>reset</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
            parseMode: 'HTML',
          },
        }
      }
      return {
        handled: true,
        command: 'reset',
        replyToTelegram: {
          text: '<b>сессия сброшена (force)</b>\n\nследующее сообщение начнёт новую сессию',
          parseMode: 'HTML',
        },
        notifyChannel: { content: '/reset force', meta: baseMeta },
      }
    }

    case 'new': {
      if (!parsed.hasForceFlag) {
        return {
          handled: true,
          command: 'new',
          replyToTelegram: {
            text: 'Для подтверждения добавь <code>force</code>: <code>/new force</code>',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /new force', { chat_id: ctx.chatId })
      // Claude Code has no separate «new session» — /clear IS the reset.
      if (ctx.tmuxKeys) {
        const sent = await sendSlashCommand(ctx.tmuxKeys.target, { name: 'clear', rest: '' }, ctx.tmuxKeys.exec)
        return {
          handled: true,
          command: 'new',
          replyToTelegram: {
            text: sent.ok
              ? '<b>новая сессия</b> — отправил <code>/clear</code> в сессию.'
              : `<b>new</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
            parseMode: 'HTML',
          },
        }
      }
      return {
        handled: true,
        command: 'new',
        replyToTelegram: {
          text: '<b>новая сессия</b>\n\nследующее сообщение начнёт новую сессию',
          parseMode: 'HTML',
        },
        notifyChannel: { content: '/new force', meta: baseMeta },
      }
    }

    case 'mirror': {
      // Sub-action lives in `args`. Empty args → behave like `status`.
      const action = parsed.args.trim().toLowerCase()
      const mirror = ctx.tmuxMirror
      if (!mirror) {
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text:
              '<b>зеркало терминала</b> — отключено в конфиге\n\n'
              + 'Установи <code>tmux_mirror.enabled = true</code> и перезапусти плагин.',
            parseMode: 'HTML',
          },
        }
      }
      if (action === 'on') {
        ctx.log.info('oob /mirror on', { chat_id: ctx.chatId })
        try {
          // MED-A #2: a permanent error (403 / parse) flips the
          // mirror's `disabled` flag and the polling loop becomes a
          // no-op forever — `/mirror off; /mirror on` alone never
          // cleared the flag because start() short-circuits on a
          // disabled mirror. Call reset() first so /mirror on
          // unconditionally re-arms the mirror after a permanent
          // error. Idempotent when the mirror is healthy. Optional
          // on the control interface for source-compat with test
          // stubs that don't implement it.
          if (mirror.reset) mirror.reset()
          await mirror.start()
        } catch (err) {
          ctx.log.warn('oob /mirror on start failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text: '<b>зеркало терминала</b> — <code>on</code>',
            parseMode: 'HTML',
          },
        }
      }
      if (action === 'off') {
        ctx.log.info('oob /mirror off', { chat_id: ctx.chatId })
        try {
          await mirror.stop()
        } catch (err) {
          ctx.log.warn('oob /mirror off stop failed', {
            chat_id: ctx.chatId,
            error: err instanceof Error ? err.message : String(err),
          })
        }
        return {
          handled: true,
          command: 'mirror',
          replyToTelegram: {
            text: '<b>зеркало терминала</b> — <code>off</code>',
            parseMode: 'HTML',
          },
        }
      }
      // Default / explicit `status` — read-only snapshot.
      const s = mirror.status()
      const lines = [
        '<b>зеркало терминала — статус</b>',
        `enabled: <code>${s.enabled ? 'on' : 'off'}</code>`,
      ]
      if (s.messageId !== undefined) lines.push(`message_id: <code>${s.messageId}</code>`)
      if (s.lastPollAt !== undefined) {
        const age = Math.max(0, Math.floor((Date.now() - s.lastPollAt) / 1000))
        lines.push(`last poll: <code>${age}s ago</code>`)
      }
      if (s.lastError) lines.push(`last error: <code>${s.lastError.slice(0, 200)}</code>`)
      if (action !== '' && action !== 'status') {
        lines.push('', '<i>usage: /mirror on | off | status</i>')
      }
      return {
        handled: true,
        command: 'mirror',
        replyToTelegram: {
          text: lines.join('\n'),
          parseMode: 'HTML',
        },
      }
    }

    case 'keys': {
      // Render the one-tap keypad. Each button injects one whitelisted
      // keystroke — their `kkey:` callbacks are dispatched in server.ts with
      // the same fail-closed allowlist auth. We only need a resolvable pane to
      // make the panel useful; if none, explain that the pane is unavailable.
      if (!ctx.tmuxKeys) {
        return {
          handled: true,
          command: 'keys',
          replyToTelegram: {
            text: '<b>/keys</b> — недоступно: плагин не знает tmux-pane сессии (нет tmux-конфига).',
            parseMode: 'HTML',
          },
        }
      }
      ctx.log.info('oob /keys', { chat_id: ctx.chatId })
      return {
        handled: true,
        command: 'keys',
        replyToTelegram: {
          text: KEYS_PANEL_HEADER,
          parseMode: 'HTML',
          inlineKeyboard: buildKeysKeyboard(),
        },
      }
    }

    case 'cc': {
      // Passthrough to Claude Code's OWN slash commands (/compact, /model,
      // /context, custom skills…) by typing them into the agent pane.
      if (!ctx.tmuxKeys) {
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: '<b>/cc</b> — недоступно: плагин не знает tmux-pane сессии.',
            parseMode: 'HTML',
          },
        }
      }
      // Bare `/cc` (no args) → render the one-tap command panel. The buttons
      // run the SAME passthrough `/cc <command>` does — their `ccmd:` callbacks
      // are dispatched in server.ts with the same fail-closed allowlist auth.
      if (parsed.args.trim() === '') {
        ctx.log.info('oob /cc panel', { chat_id: ctx.chatId })
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: {
            text: CC_PANEL_HEADER,
            parseMode: 'HTML',
            inlineKeyboard: buildCcKeyboard(),
          },
        }
      }
      const cc = parseCcCommand(parsed.args)
      if ('error' in cc) {
        return {
          handled: true,
          command: 'cc',
          replyToTelegram: { text: escapeHtml(cc.error), parseMode: 'HTML' },
        }
      }
      ctx.log.info('oob /cc', { chat_id: ctx.chatId, name: cc.name })
      const sent = await sendSlashCommand(ctx.tmuxKeys.target, cc, ctx.tmuxKeys.exec)
      const shown = cc.rest ? `/${cc.name} ${cc.rest}` : `/${cc.name}`
      return {
        handled: true,
        command: 'cc',
        replyToTelegram: {
          text: sent.ok
            ? `<b>отправлено в сессию:</b> <code>${escapeHtml(shown)}</code>`
            : `<b>/cc</b> — tmux ошибка: <code>${escapeHtml(sent.error)}</code>`,
          parseMode: 'HTML',
        },
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Convenience side-effect runner used by handlers.ts. Keeps the wiring
// in one place: send the Telegram reply (if any) and emit the channel
// notification (if any). Errors during the Telegram send are logged but
// never thrown — a /help send-failure must not crash the update loop.
// ─────────────────────────────────────────────────────────────────────

export async function executeOobResult(
  result: OobResult,
  ctx: OobContext,
  server: Server,
): Promise<void> {
  if (result.replyToTelegram) {
    try {
      await ctx.telegramApi.sendMessage(ctx.chatId, result.replyToTelegram.text, {
        ...(result.replyToTelegram.parseMode !== undefined
          ? { parse_mode: result.replyToTelegram.parseMode }
          : {}),
        ...(result.replyToTelegram.inlineKeyboard !== undefined
          ? { reply_markup: result.replyToTelegram.inlineKeyboard }
          : {}),
      })
    } catch (err) {
      ctx.log.warn('oob reply send failed', {
        command: result.command,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }
  if (result.notifyChannel) {
    const event: ChannelEvent = {
      content: result.notifyChannel.content,
      meta: result.notifyChannel.meta,
    }
    await sendChannelNotification(server, event, ctx.log)
  }
}
