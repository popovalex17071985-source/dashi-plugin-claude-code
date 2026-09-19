import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import { journalSentOutbound, permIsoTimestamp } from '../../src/channel/outbound-journal.js'

function tempJournal(): string {
  return join(mkdtempSync(join(tmpdir(), 'dashi-outbound-journal-')), 'logs', 'sent-outbound.jsonl')
}

function readLines(path: string): Record<string, unknown>[] {
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l) as Record<string, unknown>)
}

describe('permIsoTimestamp', () => {
  test('renders Perm time (UTC+5) at second precision, matching tg-notify.py', () => {
    // 2026-09-19T19:00:00Z is 2026-09-20T00:00:00 in Perm.
    expect(permIsoTimestamp(new Date('2026-09-19T19:00:00.000Z'))).toBe('2026-09-20T00:00:00+05:00')
  })

  test('does not shift with the host timezone', () => {
    const fixed = new Date('2026-01-01T00:00:00.000Z')
    expect(permIsoTimestamp(fixed)).toBe('2026-01-01T05:00:00+05:00')
  })
})

describe('journalSentOutbound', () => {
  test('writes one tg-notify-shaped line per call and creates the directory', () => {
    const path = tempJournal()
    journalSentOutbound(path, { chatId: '140141496', ok: true, text: 'привет', messageIds: [50172], via: 'reply' })

    const [rec] = readLines(path)
    expect(rec).toBeDefined()
    expect(rec!.chat_id).toBe('140141496')
    expect(rec!.ok).toBe(true)
    expect(rec!.message_id).toBe(50172)
    expect(rec!.len).toBe(6)
    expect(rec!.text).toBe('привет')
    expect(rec!.via).toBe('reply')
    // Single-part reply stays as lean as a tg-notify.py line.
    expect(rec!.message_ids).toBeUndefined()
    expect(rec!.parts).toBeUndefined()
    expect(rec!.error).toBeUndefined()
    expect(typeof rec!.ts).toBe('string')
    expect(rec!.ts as string).toMatch(/\+05:00$/)
  })

  test('a chunked reply is ONE record that still names every delivered id', () => {
    const path = tempJournal()
    journalSentOutbound(path, { chatId: '1', ok: true, text: 'long', messageIds: [10, 11, 12], via: 'reply' })

    const [rec] = readLines(path)
    // grep for any single id must find the record — that is the whole point.
    expect(rec!.message_id).toBe(10)
    expect(rec!.message_ids).toEqual([10, 11, 12])
    expect(rec!.parts).toBe(3)
  })

  test('a failed send is recorded as ok:false with the error and the ids that DID land', () => {
    const path = tempJournal()
    journalSentOutbound(path, {
      chatId: '1',
      ok: false,
      text: 'half',
      messageIds: [7],
      error: 'Bad Request: message is too long',
      via: 'reply',
    })

    const [rec] = readLines(path)
    expect(rec!.ok).toBe(false)
    expect(rec!.message_id).toBe(7)
    expect(rec!.error).toBe('Bad Request: message is too long')
  })

  test('no ids at all (guest answer) records a null message_id rather than dropping the line', () => {
    const path = tempJournal()
    journalSentOutbound(path, { chatId: '-100500', ok: true, text: 'guest', via: 'guest' })

    const [rec] = readLines(path)
    expect(rec!.message_id).toBeNull()
    expect(rec!.via).toBe('guest')
  })

  test('caps text at 400 and error at 200 chars, like tg-notify.py', () => {
    const path = tempJournal()
    journalSentOutbound(path, {
      chatId: '1',
      ok: false,
      text: 'x'.repeat(900),
      error: 'e'.repeat(500),
      via: 'reply',
    })

    const [rec] = readLines(path)
    expect((rec!.text as string).length).toBe(400)
    expect((rec!.error as string).length).toBe(200)
    // len reports the TRUE body length, not the truncated one.
    expect(rec!.len).toBe(900)
  })

  test('appends rather than truncating', () => {
    const path = tempJournal()
    journalSentOutbound(path, { chatId: '1', ok: true, text: 'a', messageIds: [1], via: 'reply' })
    journalSentOutbound(path, { chatId: '1', ok: true, text: 'b', messageIds: [2], via: 'reply' })
    expect(readLines(path).length).toBe(2)
  })

  test('writes non-ASCII unescaped so a Russian grep matches (ensure_ascii=False parity)', () => {
    const path = tempJournal()
    journalSentOutbound(path, { chatId: '1', ok: true, text: 'закуп', messageIds: [1], via: 'reply' })
    expect(readFileSync(path, 'utf8')).toContain('закуп')
  })

  test('an unwritable path never throws — a journal fault must not fail a delivery', () => {
    const dir = mkdtempSync(join(tmpdir(), 'dashi-outbound-journal-gone-'))
    const path = join(dir, 'logs', 'sent-outbound.jsonl')
    // A FILE where the log directory should be: mkdir + append both fail.
    journalSentOutbound(join(dir, 'logs'), { chatId: '1', ok: true, text: 'seed', via: 'reply' })
    expect(() =>
      journalSentOutbound(path, { chatId: '1', ok: true, text: 'x', messageIds: [1], via: 'reply' }),
    ).not.toThrow()
    rmSync(dir, { recursive: true, force: true })
  })
})
