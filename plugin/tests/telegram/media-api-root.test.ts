import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { fetchTelegramFile, isCloudApi, telegramApiRoot } from '../../src/telegram/media.js'

const ORIGINAL = process.env.TELEGRAM_API_ROOT

afterEach(() => {
  if (ORIGINAL === undefined) delete process.env.TELEGRAM_API_ROOT
  else process.env.TELEGRAM_API_ROOT = ORIGINAL
})

describe('TELEGRAM_API_ROOT', () => {
  test('defaults to the cloud API', () => {
    delete process.env.TELEGRAM_API_ROOT
    expect(telegramApiRoot()).toBe('https://api.telegram.org')
    expect(isCloudApi()).toBe(true)
  })

  test('self-hosted root is used for downloads, trailing slash stripped', async () => {
    process.env.TELEGRAM_API_ROOT = 'http://127.0.0.1:8081/'
    expect(isCloudApi()).toBe(false)
    const seen: string[] = []
    const fakeFetch = (async (url: string) => {
      seen.push(url)
      return new Response(new Uint8Array([1, 2, 3]))
    }) as unknown as typeof fetch
    const buf = await fetchTelegramFile('documents/file_1.m4a', 'TOKEN', fakeFetch)
    expect(Array.from(buf ?? [])).toEqual([1, 2, 3])
    expect(seen).toEqual(['http://127.0.0.1:8081/file/botTOKEN/documents/file_1.m4a'])
  })

  test('absolute file_path (local mode) is read from disk without any fetch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tg-local-'))
    const p = join(dir, 'big.m4a')
    writeFileSync(p, new Uint8Array([7, 8, 9]))
    const fakeFetch = (async () => {
      throw new Error('must not fetch')
    }) as unknown as typeof fetch
    const buf = await fetchTelegramFile(p, 'TOKEN', fakeFetch)
    expect(Array.from(buf ?? [])).toEqual([7, 8, 9])
    expect(await fetchTelegramFile(join(dir, 'missing.m4a'), 'TOKEN', fakeFetch)).toBeUndefined()
    rmSync(dir, { recursive: true, force: true })
  })
})
