// MCP `notifications/claude/channel` event helpers.
//
// Claude Code drops meta keys with hyphens silently (per RESEARCH.md). We
// enforce identifier-style snake_case keys and stringify all values so the
// receiver never has to guess how to render a number/boolean.
//
// Multichat contract: callers MUST populate `meta.chat_id` with the
// originating Telegram chat id (already done in handlers.ts:buildMeta).
// The master Claude session inspects `meta.chat_id` to know which chat
// the inbound message came from — there is NO implicit fallback to the
// warchief's DM. This module never injects a default chat_id; an event
// arriving without one is a wiring bug at the caller, not something we
// paper over here.

import { mkdir, readdir, readFile, rename, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import type { Server } from '@modelcontextprotocol/sdk/server/index.js'
import type { Logger } from '../log.js'

export type ChannelEvent = {
  content: string
  // Caller-supplied metadata. In multichat mode this MUST include
  // `chat_id` so the master session can route the event; in the legacy
  // DM-only mode `chat_id` is still set (handlers.ts always populates it).
  meta: Record<string, string>
}

const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/

export function normalizeMeta(raw: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (value === null || value === undefined) continue
    if (key.includes('-')) continue
    if (!IDENT_RE.test(key)) continue
    if (typeof value === 'string') {
      out[key] = value
    } else if (typeof value === 'number' && Number.isFinite(value)) {
      out[key] = String(value)
    } else if (typeof value === 'boolean') {
      out[key] = value ? 'true' : 'false'
    } else if (typeof value === 'bigint') {
      out[key] = value.toString()
    } else {
      // Object/array/symbol/function — drop with a serialized fallback only if JSON works.
      try {
        out[key] = JSON.stringify(value)
      } catch {
        // skip
      }
    }
  }
  return out
}

// Правка 6 (19.09.2026): a notify failure used to cost the message.
//
// The transport is an MCP notification to a live Claude session. It breaks for
// SECONDS at a time — a session restart, a reconnect — and a single failed write
// meant the poller dead-lettered the update and advanced its offset: the user's
// message was gone, with nothing but a quarantine file no one read. Two layers
// now stand between a blip and a lost message: a bounded retry here, and (in
// handlers.ts) a pending-inbound park that later notifications replay.
const NOTIFY_ATTEMPTS = 3
const NOTIFY_RETRY_DELAY_MS = 250
const PENDING_DIR = 'pending-inbound'
/** Replay cap per drain: never hold a live inbound behind a long backlog. */
const PENDING_REPLAY_PER_RUN = 5
const PENDING_MAX_ATTEMPTS = 8

const defaultSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

// Returns true when server.notification accepted the write; false when the
// transport threw on every attempt (error already logged). Callers MUST honour
// false: poller parks + dead-letters the update, webhook returns 503.
export async function sendChannelNotification(
  server: Server,
  event: ChannelEvent,
  log: Logger,
  sleep: (ms: number) => Promise<void> = defaultSleep,
): Promise<boolean> {
  let lastError = 'unknown'
  for (let attempt = 1; attempt <= NOTIFY_ATTEMPTS; attempt++) {
    try {
      await server.notification({
        method: 'notifications/claude/channel',
        params: {
          content: event.content,
          meta: event.meta,
        },
      })
      if (attempt > 1) log.info('channel notification delivered on retry', { attempt })
      return true
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err)
      if (attempt < NOTIFY_ATTEMPTS) await sleep(NOTIFY_RETRY_DELAY_MS * attempt)
    }
  }
  log.error('channel notification failed', { error: lastError, attempts: NOTIFY_ATTEMPTS })
  return false
}

/**
 * Park an inbound event whose notification never landed, so it can be replayed.
 *
 * Best-effort: the poller still dead-letters and advances its offset (infinite
 * redelivery is worse), but the event itself survives here and the next
 * successful notification drains it.
 */
export async function parkPendingInbound(
  stateRoot: string,
  event: ChannelEvent,
  log: Logger,
): Promise<string | undefined> {
  const dir = join(stateRoot, PENDING_DIR)
  try {
    await mkdir(dir, { recursive: true })
    const name = `${Date.now()}-${Math.random().toString(16).slice(2, 6)}.json`
    const path = join(dir, name)
    await writeFile(path, JSON.stringify({ event, attempts: 1, parked_at: new Date().toISOString() }), 'utf8')
    log.warn('inbound notify failed — event parked for replay', { path })
    return path
  } catch (err) {
    log.error('inbound park failed — event lost', {
      error: err instanceof Error ? err.message : String(err),
    })
    return undefined
  }
}

/**
 * Replay parked inbound events, oldest first. Returns how many were delivered.
 *
 * Called after a SUCCESSFUL notification: the transport is demonstrably up, so a
 * replay has a real chance and cannot delay a live message (it runs after it).
 * A record that keeps failing burns its attempts and is retired to `*.failed`.
 */
export async function replayPendingInbound(
  stateRoot: string,
  server: Server,
  log: Logger,
): Promise<number> {
  const dir = join(stateRoot, PENDING_DIR)
  let names: string[]
  try {
    names = (await readdir(dir)).filter((n) => n.endsWith('.json')).sort()
  } catch {
    return 0
  }
  let delivered = 0
  for (const name of names.slice(0, PENDING_REPLAY_PER_RUN)) {
    const path = join(dir, name)
    let parsed: { event?: ChannelEvent; attempts?: number }
    try {
      parsed = JSON.parse(await readFile(path, 'utf8')) as { event?: ChannelEvent; attempts?: number }
    } catch {
      await rename(path, `${path}.failed`).catch(() => undefined)
      continue
    }
    const event = parsed.event
    const attempts = typeof parsed.attempts === 'number' ? parsed.attempts : 0
    if (
      event === undefined ||
      typeof event.content !== 'string' ||
      attempts >= PENDING_MAX_ATTEMPTS
    ) {
      log.warn('parked inbound retired', { path, attempts })
      await rename(path, `${path}.failed`).catch(() => undefined)
      continue
    }
    const ok = await sendChannelNotification(server, event, log)
    if (ok) {
      delivered += 1
      await unlink(path).catch(() => undefined)
      log.info('parked inbound replayed', { path })
      continue
    }
    await writeFile(path, JSON.stringify({ ...parsed, attempts: attempts + 1 }), 'utf8').catch(
      () => undefined,
    )
    break // Transport is down again — stop draining, keep the order.
  }
  return delivered
}
