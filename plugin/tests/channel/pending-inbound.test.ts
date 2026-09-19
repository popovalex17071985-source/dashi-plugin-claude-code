// Правка 6 (19.09.2026): a notify failure must not cost the inbound message.
// Before this, a single failed MCP notification made the poller dead-letter the
// update and advance its offset — the user's message was gone.

import { describe, expect, test, beforeEach, afterEach } from 'bun:test'
import { mkdtempSync, readdirSync, rmSync, writeFileSync, readFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import {
  parkPendingInbound,
  replayPendingInbound,
  sendChannelNotification,
  type ChannelEvent,
} from '../../src/channel/notify.js'

const log = {
  info: () => undefined,
  warn: () => undefined,
  error: () => undefined,
  debug: () => undefined,
} as unknown as Parameters<typeof parkPendingInbound>[2]

const event: ChannelEvent = { content: 'сообщение оператора', meta: { chat_id: '140141496' } }

function serverThat(behaviour: () => Promise<void>): Parameters<typeof replayPendingInbound>[1] {
  return { notification: behaviour } as unknown as Parameters<typeof replayPendingInbound>[1]
}

let dir: string
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'pending-inbound-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('sendChannelNotification: повтор при моргнувшем канале', () => {
  test('вторая попытка спасает сообщение', async () => {
    let calls = 0
    const server = serverThat(async () => {
      calls += 1
      if (calls === 1) throw new Error('transport closed')
    })
    const ok = await sendChannelNotification(server, event, log, async () => undefined)
    expect(ok).toBe(true)
    expect(calls).toBe(2)
  })

  test('три провала -- честный false, без вечного цикла', async () => {
    let calls = 0
    const server = serverThat(async () => {
      calls += 1
      throw new Error('transport closed')
    })
    const ok = await sendChannelNotification(server, event, log, async () => undefined)
    expect(ok).toBe(false)
    expect(calls).toBe(3)
  })
})

describe('карантин входящих', () => {
  test('запаркованное сообщение переигрывается и исчезает из очереди', async () => {
    await parkPendingInbound(dir, event, log)
    const seen: string[] = []
    const server = serverThat(async () => {
      seen.push('ok')
    })
    const n = await replayPendingInbound(dir, server, log)
    expect(n).toBe(1)
    expect(seen.length).toBe(1)
    expect(readdirSync(join(dir, 'pending-inbound')).filter((f) => f.endsWith('.json')).length).toBe(0)
  })

  test('канал снова лежит -- попытка растёт, запись остаётся', async () => {
    await parkPendingInbound(dir, event, log)
    const server = serverThat(async () => {
      throw new Error('transport closed')
    })
    const n = await replayPendingInbound(dir, server, log)
    expect(n).toBe(0)
    const files = readdirSync(join(dir, 'pending-inbound')).filter((f) => f.endsWith('.json'))
    expect(files.length).toBe(1)
    const rec = JSON.parse(readFileSync(join(dir, 'pending-inbound', files[0] as string), 'utf8'))
    expect(rec.attempts).toBe(2)
    expect(rec.event.content).toBe('сообщение оператора')
  })

  test('исчерпанные попытки уходят в .failed и канал не трогают', async () => {
    const pending = join(dir, 'pending-inbound')
    await parkPendingInbound(dir, event, log)
    const name = readdirSync(pending)[0] as string
    writeFileSync(join(pending, name), JSON.stringify({ event, attempts: 8 }), 'utf8')
    let calls = 0
    const server = serverThat(async () => {
      calls += 1
    })
    const n = await replayPendingInbound(dir, server, log)
    expect(n).toBe(0)
    expect(calls).toBe(0)
    expect(readdirSync(pending).filter((f) => f.endsWith('.failed')).length).toBe(1)
  })
})
