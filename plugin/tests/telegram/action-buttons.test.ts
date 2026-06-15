import { afterAll, describe, expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  isActionCallback,
  handleActionCallback,
  type ActionCallbackContext,
  type InlineButton,
} from '../../src/telegram/action-buttons.js'

const log = { info() {}, warn() {} }

// A throwaway "python" — really a shell script — so the test exercises the TS
// orchestration without touching the real handle-action-callback.py / its log.
const dir = mkdtempSync(join(tmpdir(), 'action-buttons-'))
function makeStub(body: string): string {
  const p = join(dir, `stub-${Math.random().toString(36).slice(2)}.sh`)
  writeFileSync(p, `#!/bin/sh\n${body}\n`)
  chmodSync(p, 0o755)
  return p
}
const OK_STUB = makeStub(
  `echo '{"label":"✅ Обработано · Тим · 4 мин","locked_data":"mqz:locked","cls":"success","mins":4,"ok":true}'`,
)
const FAIL_STUB = makeStub('exit 3')

afterAll(() => rmSync(dir, { recursive: true, force: true }))

function makeCtx(data: string): {
  ctx: ActionCallbackContext
  answers: Array<{ text?: string; alert?: boolean }>
  edits: InlineButton[][][]
} {
  const answers: Array<{ text?: string; alert?: boolean }> = []
  const edits: InlineButton[][][] = []
  const ctx: ActionCallbackContext = {
    data,
    chatId: -5247042177,
    messageId: 123,
    from: { id: 908736857, first_name: 'Тим' },
    editReplyMarkup: async kb => {
      edits.push(kb)
    },
    answerCallbackQuery: async (text, alert) => {
      answers.push({ text, alert })
    },
  }
  return { ctx, answers, edits }
}

const opts = (script: string) => ({ pythonBin: '/bin/sh', scriptPath: script, log })

describe('isActionCallback', () => {
  test('matches our prefixes only', () => {
    expect(isActionCallback('mqz:done:success:abc')).toBe(true)
    expect(isActionCallback('ord:done:mail:refuse:9')).toBe(true)
    expect(isActionCallback('mqz:locked')).toBe(true)
    expect(isActionCallback('ask:0')).toBe(false)
    expect(isActionCallback('pgate:allow')).toBe(false)
  })
})

describe('handleActionCallback', () => {
  test('locked button just acks, no edit, no CLI', async () => {
    const { ctx, answers, edits } = makeCtx('mqz:locked')
    await handleActionCallback(ctx, opts('/nonexistent'))
    expect(edits).toHaveLength(0)
    expect(answers).toEqual([{ text: undefined, alert: undefined }])
  })

  test('done press collapses keyboard + acks «Готово»', async () => {
    const { ctx, answers, edits } = makeCtx('mqz:done:success:abc')
    await handleActionCallback(ctx, opts(OK_STUB))
    expect(edits).toHaveLength(1)
    expect(edits[0]).toEqual([[{ text: '✅ Обработано · Тим · 4 мин', callback_data: 'mqz:locked' }]])
    expect(answers).toEqual([{ text: 'Готово', alert: undefined }])
  })

  test('CLI failure clears spinner with an error alert', async () => {
    const { ctx, answers, edits } = makeCtx('ord:done:refuse:10042')
    await handleActionCallback(ctx, opts(FAIL_STUB))
    expect(edits).toHaveLength(0)
    expect(answers).toEqual([{ text: 'Ошибка обновления', alert: true }])
  })

  test('missing chat/message id → error alert, no CLI call', async () => {
    const { ctx, answers, edits } = makeCtx('ord:done:success:1')
    ctx.chatId = undefined
    await handleActionCallback(ctx, opts('/nonexistent'))
    expect(edits).toHaveLength(0)
    expect(answers).toEqual([{ text: 'Ошибка обновления', alert: true }])
  })
})
