// Review-reply buttons + edit-by-reply (variant C). The approval card carries
//   rev:ok:<src>:<id>     ✅ Запостить  — publish the stored draft
//   rev:edit:<src>:<id>   ✏️ Править    — regenerate a fresh draft option
//   rev:locked            already-posted button — just ack
// Editing the answer is done by REPLYING to the card with your own text
// (tryHandleReviewReply): that text is published verbatim.
//
// All business logic (publish via Avito API, regenerate, jsonl state) lives in
// the Python CLI bin/reviews-action.py; this module owns only the Telegram I/O.
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

export interface InlineButton {
  text: string
  callback_data: string
}

export interface ReviewCliResult {
  ok: boolean
  label: string
  card_text: string | null
  toast: string
  error: string | null
}

export interface ReviewActionOpts {
  pythonBin: string
  scriptPath: string
  log: { info: (m: string, c?: Record<string, unknown>) => void; warn: (m: string, c?: Record<string, unknown>) => void }
}

export function isReviewCallback(data: string): boolean {
  return data.startsWith('rev:')
}

async function runCli(opts: ReviewActionOpts, args: string[]): Promise<ReviewCliResult> {
  const { stdout } = await execFileAsync(opts.pythonBin, [opts.scriptPath, ...args], {
    // Publishing drives a headless browser (Yandex/2GIS cabinet) — 30s wasn't enough
    // on this 2-core VPS, the CLI got SIGKILLed mid-post and the card hung "Загрузка".
    timeout: 90_000,
    maxBuffer: 1 << 20,
  })
  return JSON.parse(stdout.trim()) as ReviewCliResult
}

const LIVE_KEYBOARD = (src: string, id: string): InlineButton[][] => [[
  { text: '✅ Запостить', callback_data: `rev:ok:${src}:${id}` },
  { text: '✏️ Править', callback_data: `rev:edit:${src}:${id}` },
]]

export interface ReviewCallbackContext {
  data: string
  editReplyMarkup: (kb: InlineButton[][]) => Promise<void>
  editMessageText: (text: string, kb: InlineButton[][]) => Promise<void>
  answerCallbackQuery: (text?: string, showAlert?: boolean) => Promise<void>
}

/** Handle a rev:* button press. Never throws. */
export async function handleReviewCallback(ctx: ReviewCallbackContext, opts: ReviewActionOpts): Promise<void> {
  const parts = ctx.data.split(':') // rev:<action>:<src>:<id>
  const [, action, src, id] = parts
  if (action === 'locked' || !src || !id) {
    await ctx.answerCallbackQuery()
    return
  }
  const cliAction = action === 'ok' ? 'ok' : action === 'edit' ? 'regen' : null
  if (!cliAction) {
    await ctx.answerCallbackQuery()
    return
  }
  // Ack the tap immediately. Telegram invalidates an unanswered callback within
  // seconds, so if we wait for the (slow, browser-driven) publish before answering,
  // the button stays stuck on "Загрузка". Clear the spinner now, then edit the card
  // to reflect the real outcome once the CLI returns.
  await ctx.answerCallbackQuery(cliAction === 'ok' ? '⏳ Публикую…' : undefined)
  try {
    const res = await runCli(opts, ['--action', cliAction, '--source', src, '--id', id])
    if (cliAction === 'regen' && res.ok && res.card_text) {
      await ctx.editMessageText(res.card_text, LIVE_KEYBOARD(src, id))
    } else if (res.ok) {
      await ctx.editReplyMarkup([[{ text: res.label, callback_data: 'rev:locked' }]])
    } else {
      // Publish failed — keep the buttons so она can retry, don't leave it ambiguous.
      await ctx.editReplyMarkup(LIVE_KEYBOARD(src, id))
    }
    opts.log.info('review callback handled', { action, src, ok: res.ok, error: res.error })
  } catch (err) {
    opts.log.warn('review callback failed', { data: ctx.data, error: err instanceof Error ? err.message : String(err) })
    try { await ctx.editReplyMarkup(LIVE_KEYBOARD(src, id)) } catch { /* ignore */ }
  }
}

export interface ReviewReplyContext {
  text: string
  replyToMessageId: number | undefined
  sendReply: (text: string) => Promise<void>
}

/**
 * Edit-by-reply: if this text message is a reply to an approval card, publish
 * the text verbatim and return true (consumed). Returns false for any message
 * that isn't a reply to a tracked review card, so it falls through to the
 * normal inbound-text path.
 */
export async function tryHandleReviewReply(ctx: ReviewReplyContext, opts: ReviewActionOpts): Promise<boolean> {
  if (ctx.replyToMessageId === undefined || !ctx.text.trim()) return false
  let res: ReviewCliResult
  try {
    res = await runCli(opts, [
      '--action', 'posttext',
      '--approve-msg-id', String(ctx.replyToMessageId),
      '--text', ctx.text,
    ])
  } catch (err) {
    opts.log.warn('review reply CLI failed', { error: err instanceof Error ? err.message : String(err) })
    return false
  }
  if (res.error === 'not_found') return false // not a reply to a review card
  await ctx.sendReply(res.ok ? '✅ Опубликовано' : `⚠️ ${res.toast}`)
  opts.log.info('review reply handled', { ok: res.ok, error: res.error })
  return true
}
