// feature/dm-fallback-reply-hook (2026-06-03) — unit tests for the DM
// fallback-reply Stop hook. Pure functions only: no real network, no real
// session. Exercises the turn-walk (reply-tool detection, final-text capture,
// turn-boundary respect, telegram chat_id extraction), config resolution from
// env-file + explicit URL, and per-session dedup state.

import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

import {
  analyzeCurrentTurn,
  parseTelegramChatId,
  isUserPrompt,
  resolveFallbackConfig,
  resolveStatePath,
  dedupeToken,
  loadDedupState,
  alreadyForwarded,
  loadChannelEnvFile,
  type DedupState,
} from '../../scripts/fallback-reply-hook.js'

// Helper: build a JSON transcript line for an assistant/user message.
function line(role: 'assistant' | 'user', content: unknown, uuid?: string): string {
  const obj: Record<string, unknown> = { type: role, message: { role, content } }
  if (uuid) obj.uuid = uuid
  return JSON.stringify(obj)
}

const TG_PROMPT = (chatId: string, msgId: number): string =>
  `<channel source="dashi-channel" source="telegram" chat_id="${chatId}" message_id="${msgId}">hi</channel>`

describe('parseTelegramChatId', () => {
  test('extracts chat_id from raw form', () => {
    expect(parseTelegramChatId(TG_PROMPT('164795011', 5))).toBe('164795011')
  })
  test('extracts from JSON-escaped transcript form', () => {
    const l = '{"message":{"content":"<channel source=\\"telegram\\" chat_id=\\"164795011\\" message_id=\\"7\\">x</channel>"}}'
    expect(parseTelegramChatId(l)).toBe('164795011')
  })
  test('supports negative group chat_id', () => {
    expect(parseTelegramChatId('<channel source="telegram" chat_id="-1003784643974" message_id="1">g</channel>')).toBe(
      '-1003784643974',
    )
  })
  test('ignores non-telegram channel blocks', () => {
    expect(parseTelegramChatId('<channel source="orgrimmar-inbox" from="sa-silvana">x</channel>')).toBeUndefined()
  })
  test('undefined when no channel block', () => {
    expect(parseTelegramChatId('plain user text')).toBeUndefined()
  })
})

describe('isUserPrompt', () => {
  test('non-blank string is a prompt', () => {
    expect(isUserPrompt('hello')).toBe(true)
  })
  test('blank string is not', () => {
    expect(isUserPrompt('   ')).toBe(false)
  })
  test('tool_result-only list is not a prompt (turn-internal echo)', () => {
    expect(isUserPrompt([{ type: 'tool_result', content: 'out' }])).toBe(false)
  })
  test('list with a text block is a prompt', () => {
    expect(isUserPrompt([{ type: 'text', text: 'hi' }, { type: 'tool_result' }])).toBe(true)
  })
  test('empty list is not a prompt', () => {
    expect(isUserPrompt([])).toBe(false)
  })
})

describe('analyzeCurrentTurn', () => {
  test('(a) reply tool_use in turn → replied=true (suppress)', () => {
    const transcript = [
      line('user', TG_PROMPT('1', 10)),
      line('assistant', [{ type: 'text', text: 'answer' }], 'u1'),
      line('assistant', [{ type: 'tool_use', name: 'mcp__dashi-channel__reply', input: {} }], 'u2'),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.replied).toBe(true)
  })

  test('edit_message tool_use also counts as replied', () => {
    const transcript = [
      line('user', TG_PROMPT('1', 10)),
      line('assistant', [{ type: 'tool_use', name: 'mcp__dashi-channel__edit_message', input: {} }], 'u1'),
    ].join('\n')
    expect(analyzeCurrentTurn(transcript).replied).toBe(true)
  })

  test('(b) no reply tool + final text + telegram chat_id → would forward', () => {
    const transcript = [
      line('user', TG_PROMPT('164795011', 10)),
      line('assistant', [{ type: 'text', text: 'final answer' }], 'u9'),
      // turn ended on a non-reply tool call (Bash) — must NOT drop the text
      line('assistant', [{ type: 'tool_use', name: 'Bash', input: {} }], 'u10'),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.replied).toBe(false)
    expect(r.text).toBe('final answer')
    expect(r.uuid).toBe('u9')
    expect(r.chatId).toBe('164795011')
  })

  test('(c) turn boundary respected — does not cross into a previous turn', () => {
    const transcript = [
      line('user', 'old prompt without channel tag'),
      line('assistant', [{ type: 'text', text: 'OLD reply' }], 'uOld'),
      line('user', TG_PROMPT('1', 20)),
      line('assistant', [{ type: 'text', text: 'NEW reply' }], 'uNew'),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.text).toBe('NEW reply')
    expect(r.uuid).toBe('uNew')
    expect(r.chatId).toBe('1')
  })

  test('tool_result user echo does NOT end the turn (kept walking)', () => {
    const transcript = [
      line('user', TG_PROMPT('1', 30)),
      line('assistant', [{ type: 'text', text: 'answer before tool' }], 'uA'),
      line('assistant', [{ type: 'tool_use', name: 'Bash', input: {} }], 'uB'),
      line('user', [{ type: 'tool_result', content: 'cmd output' }]),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.replied).toBe(false)
    expect(r.text).toBe('answer before tool')
    expect(r.chatId).toBe('1')
  })

  test('(d) tool-only / thinking-only turn → no text', () => {
    const transcript = [
      line('user', TG_PROMPT('1', 40)),
      line('assistant', [{ type: 'tool_use', name: 'Bash', input: {} }], 'uX'),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.text).toBeUndefined()
    expect(r.replied).toBe(false)
  })

  test('(e) no telegram chat_id in turn → chatId undefined', () => {
    const transcript = [
      line('user', 'plain prompt, no channel tag'),
      line('assistant', [{ type: 'text', text: 'reply' }], 'uY'),
    ].join('\n')
    const r = analyzeCurrentTurn(transcript)
    expect(r.text).toBe('reply')
    expect(r.chatId).toBeUndefined()
  })

  test('captures the MOST RECENT text when the turn has several text blocks', () => {
    const transcript = [
      line('user', TG_PROMPT('1', 50)),
      line('assistant', [{ type: 'text', text: 'first' }], 'u1'),
      line('assistant', [{ type: 'text', text: 'second (final)' }], 'u2'),
    ].join('\n')
    expect(analyzeCurrentTurn(transcript).text).toBe('second (final)')
  })

  test('empty transcript → no text, not replied, no chatId', () => {
    const r = analyzeCurrentTurn('')
    expect(r.text).toBeUndefined()
    expect(r.replied).toBe(false)
    expect(r.chatId).toBeUndefined()
  })
})

describe('(f) resolveFallbackConfig', () => {
  test('explicit url + token wins', () => {
    const cfg = resolveFallbackConfig({
      TELEGRAM_FALLBACK_REPLY_URL: 'http://127.0.0.1:8089/hooks/fallback-reply',
      TELEGRAM_WEBHOOK_TOKEN: 'tok',
    })
    expect(cfg).toEqual({ url: 'http://127.0.0.1:8089/hooks/fallback-reply', token: 'tok' })
  })
  test('builds url from host+port', () => {
    const cfg = resolveFallbackConfig({
      TELEGRAM_WEBHOOK_HOST: '127.0.0.1',
      TELEGRAM_WEBHOOK_PORT: '8093',
      TELEGRAM_WEBHOOK_TOKEN: 'filetok',
    })
    expect(cfg).toEqual({ url: 'http://127.0.0.1:8093/hooks/fallback-reply', token: 'filetok' })
  })
  test('defaults host when only port present', () => {
    expect(resolveFallbackConfig({ TELEGRAM_WEBHOOK_PORT: '9001', TELEGRAM_WEBHOOK_TOKEN: 'e' })).toEqual({
      url: 'http://127.0.0.1:9001/hooks/fallback-reply',
      token: 'e',
    })
  })
  test('errors when token missing', () => {
    const cfg = resolveFallbackConfig({})
    expect('kind' in cfg && cfg.kind === 'error').toBe(true)
  })
  test('errors when port missing and no explicit url', () => {
    const cfg = resolveFallbackConfig({ TELEGRAM_WEBHOOK_TOKEN: 'tok' })
    expect('kind' in cfg && cfg.kind === 'error').toBe(true)
  })
  test('resolves via env-file in a sanitised process env (multichat-style)', () => {
    const fileVars = loadChannelEnvFile(
      { TELEGRAM_CHANNEL_ENV_FILE: '/fake' },
      () => 'TELEGRAM_WEBHOOK_PORT=8093\nTELEGRAM_WEBHOOK_TOKEN=filetok\n',
    )
    expect(resolveFallbackConfig({ ...fileVars })).toEqual({
      url: 'http://127.0.0.1:8093/hooks/fallback-reply',
      token: 'filetok',
    })
  })
})

describe('resolveStatePath (per-session)', () => {
  test('explicit state path wins over state dir', () => {
    expect(
      resolveStatePath({ TELEGRAM_FALLBACK_REPLY_STATE: '/x/y.json', TELEGRAM_STATE_DIR: '/d' }, 's1'),
    ).toBe('/x/y.json')
  })
  test('derives a per-session file from state dir', () => {
    expect(resolveStatePath({ TELEGRAM_STATE_DIR: '/d' }, 'sess-1')).toBe('/d/fallback-reply/sess-1.json')
  })
  test('falls back to MULTICHAT_STATE_DIR', () => {
    expect(resolveStatePath({ MULTICHAT_STATE_DIR: '/mc' }, 'abc')).toBe('/mc/fallback-reply/abc.json')
  })
  test('sanitises a hostile session id', () => {
    expect(resolveStatePath({ TELEGRAM_STATE_DIR: '/d' }, '../../etc/passwd')).toBe(
      '/d/fallback-reply/.._.._etc_passwd.json',
    )
  })
  test('undefined when no base dir', () => {
    expect(resolveStatePath({}, 's1')).toBeUndefined()
  })
})

describe('(g) dedup', () => {
  let dir: string
  afterEach(() => {
    if (dir) rmSync(dir, { recursive: true, force: true })
  })

  test('dedupeToken prefers uuid, falls back to text hash', () => {
    expect(dedupeToken('u1', 'whatever')).toBe('u1')
    const a = dedupeToken(undefined, 'same text')
    const b = dedupeToken(undefined, 'same text')
    const c = dedupeToken(undefined, 'different')
    expect(a).toBe(b)
    expect(a).not.toBe(c)
    expect(a).toMatch(/^[0-9a-f]{64}$/)
  })

  test('alreadyForwarded matches the exact same turn triple', () => {
    const base: DedupState = { session_id: 's', transcript_path: '/t', dedupe_token: 'u1' }
    expect(alreadyForwarded(base, base)).toBe(true)
    expect(alreadyForwarded(undefined, base)).toBe(false)
    expect(alreadyForwarded({ ...base, dedupe_token: 'u2' }, base)).toBe(false)
    // Same text in a DIFFERENT turn (different uuid token) is NOT suppressed.
    expect(alreadyForwarded({ ...base, dedupe_token: 'uOld' }, base)).toBe(false)
  })

  test('loadDedupState round-trips a written state file', () => {
    dir = mkdtempSync(join(tmpdir(), 'fr-'))
    const p = join(dir, 'state.json')
    const state: DedupState = { session_id: 's1', transcript_path: '/abs/t.jsonl', dedupe_token: 'tok' }
    writeFileSync(p, JSON.stringify(state))
    expect(loadDedupState(p)).toEqual(state)
  })

  test('loadDedupState → undefined on missing / malformed file', () => {
    expect(loadDedupState('/nope/missing.json')).toBeUndefined()
    expect(loadDedupState('/whatever', () => 'not json')).toBeUndefined()
    expect(loadDedupState('/whatever', () => '{"session_id":1}')).toBeUndefined()
  })
})
