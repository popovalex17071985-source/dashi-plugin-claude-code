// Marquiz / InSales-orders outcome buttons (✅ Успех / ⏳ Думает / ❌ Отказ /
// 🔁 Повтор). Re-homed into the plugin after the 2026-06-14 gateway cutover,
// which killed the gateway process that used to dispatch these callbacks
// (gateway_ext_marquiz.py / gateway_ext_orders.py). The bot is now polled by
// this plugin, so the button presses (callback_query) land here.
//
// Callback grammar (unchanged from the gateway era):
//   mqz:done:<cls>:<dedupe>            marquiz lead (розыгрыш / выкуп б/у)
//   ord:done:<cls>:<order_number>      InSales order (site)
//   ord:done:mail:<cls>:<uid>          InSales order (mail)
//   *:locked                           already-handled button — just ack
//
// Division of labour: this module owns the Telegram I/O (collapse the keyboard
// to one locked button + answer the callback); the Python CLI
// `bin/handle-action-callback.py` owns the business logic (append the handled
// record to orders-handled.jsonl + action log + compute the button label).
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/** True for any callback this module is responsible for. */
export function isActionCallback(data: string): boolean {
  return data.startsWith('mqz:') || data.startsWith('ord:')
}

export interface InlineButton {
  text: string
  callback_data: string
}

/** Structural subset of the grammY callback context this handler reads. */
export interface ActionCallbackContext {
  data: string
  chatId: number | undefined
  messageId: number | undefined
  from: {
    id?: number
    first_name?: string
    last_name?: string
    username?: string
  }
  /** Replace the message's inline keyboard with a single locked button. */
  editReplyMarkup: (keyboard: InlineButton[][]) => Promise<void>
  /** Clear the Telegram spinner (optionally with a toast / alert). */
  answerCallbackQuery: (text?: string, showAlert?: boolean) => Promise<void>
}

export interface ActionCallbackOpts {
  pythonBin: string
  scriptPath: string
  log: {
    info: (m: string, ctx?: Record<string, unknown>) => void
    warn: (m: string, ctx?: Record<string, unknown>) => void
  }
}

interface CliResult {
  label: string
  locked_data: string
  cls: string
  mins: number | null
  ok: boolean
}

/**
 * Handle one `mqz:*` / `ord:*` button press. Never throws — on any failure it
 * still clears the spinner (with an error toast) so the manager isn't left
 * staring at a hung button.
 */
export async function handleActionCallback(
  ctx: ActionCallbackContext,
  opts: ActionCallbackOpts,
): Promise<void> {
  const { data } = ctx

  // Already-handled card: the locked button is non-functional, just ack.
  if (data === 'mqz:locked' || data === 'ord:locked') {
    await ctx.answerCallbackQuery()
    return
  }

  const root = data.startsWith('mqz:') ? 'mqz' : 'ord'
  if (!data.startsWith(`${root}:done:`)) {
    // Unknown variant under our prefix — clear the spinner, do nothing.
    await ctx.answerCallbackQuery()
    return
  }

  if (ctx.chatId === undefined || ctx.messageId === undefined) {
    opts.log.warn('action-buttons: missing chat/message id', { data })
    await ctx.answerCallbackQuery('Ошибка обновления', true)
    return
  }

  try {
    const { stdout } = await execFileAsync(
      opts.pythonBin,
      [
        opts.scriptPath,
        '--prefix', root,
        '--data', data,
        '--chat-id', String(ctx.chatId),
        '--message-id', String(ctx.messageId),
        '--user-json', JSON.stringify(ctx.from ?? {}),
      ],
      { timeout: 10_000, maxBuffer: 1 << 20 },
    )
    const res = JSON.parse(stdout.trim()) as CliResult
    if (!res.ok || !res.label) throw new Error('CLI returned not-ok')

    await ctx.editReplyMarkup([[{ text: res.label, callback_data: res.locked_data }]])
    await ctx.answerCallbackQuery('Готово')
    opts.log.info('action-buttons handled', { root, cls: res.cls, mins: res.mins })
  } catch (err) {
    opts.log.warn('action-buttons handler failed', {
      data,
      error: err instanceof Error ? err.message : String(err),
    })
    // Best-effort spinner clear; swallow a failure of the ack itself.
    try {
      await ctx.answerCallbackQuery('Ошибка обновления', true)
    } catch {
      /* ignore */
    }
  }
}
