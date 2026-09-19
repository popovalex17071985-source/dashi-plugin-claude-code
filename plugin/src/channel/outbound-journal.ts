// ─────────────────────────────────────────────────────────────────────
// outbound-journal — «писал или нет» for the agent's OWN replies.
//
// `bin/tg-notify.py` has journalled every cron/script send to
// state/telegram/logs/sent-outbound.jsonl since 16.09.2026. Replies shipped
// through the `reply` MCP tool were never journalled, so on 19.09.2026 the
// file's last line was ~25 minutes old while two live answers had just been
// delivered: absence of a line proved nothing. This module closes that half
// of the trail.
//
// The record shape deliberately MIRRORS tg-notify.py (ts in Perm time,
// chat_id, ok, message_id, len, text, error) so a single grep answers for
// both writers; `via` is the only addition and tells them apart.
//
// Best-effort by construction: a journal fault must NEVER fail or duplicate
// a delivery, so every call is wrapped and errors are swallowed.
// ─────────────────────────────────────────────────────────────────────
import { appendFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

// Text cap matches tg-notify.py: a forensic trail, not a chat archive.
const TEXT_CAP = 400
const ERROR_CAP = 200

// Asia/Yekaterinburg is a fixed UTC+5 — no DST since 2011, so a constant
// offset is correct here and keeps the timestamp readable by the operator
// without a conversion step (the same choice tg-notify.py makes).
const PERM_OFFSET_MINUTES = 5 * 60

/**
 * ISO-8601 second-precision timestamp in Perm time, e.g.
 * `2026-09-20T00:31:07+05:00` — byte-comparable with tg-notify.py's
 * `datetime.now(timezone(timedelta(hours=5))).isoformat(timespec='seconds')`.
 */
export function permIsoTimestamp(now: Date = new Date()): string {
  const shifted = new Date(now.getTime() + PERM_OFFSET_MINUTES * 60_000)
  return `${shifted.toISOString().slice(0, 19)}+05:00`
}

export interface OutboundJournalEntry {
  chatId: string
  ok: boolean
  text: string
  /** Every Telegram message id this one reply produced (chunks + attachments). */
  messageIds?: readonly number[]
  error?: string
  /** Which egress path shipped it — `reply` (owner/group) or `guest`. */
  via: 'reply' | 'guest'
}

/**
 * Append one line per `reply` CALL (not per chunk): a long answer split into
 * parts is one logical reply, and folding it into one record keeps the file
 * readable. Every id still appears — `message_id` is the first, `message_ids`
 * lists all — so a grep for ANY delivered id finds the record.
 */
export function journalSentOutbound(path: string, entry: OutboundJournalEntry): void {
  try {
    const ids = entry.messageIds ?? []
    const record: Record<string, unknown> = {
      ts: permIsoTimestamp(),
      chat_id: entry.chatId,
      ok: entry.ok,
      message_id: ids[0] ?? null,
      len: entry.text.length,
      text: entry.text.slice(0, TEXT_CAP),
      via: entry.via,
    }
    if (ids.length > 1) {
      record.message_ids = ids
      record.parts = ids.length
    }
    if (entry.error !== undefined && entry.error !== '') {
      record.error = entry.error.slice(0, ERROR_CAP)
    }
    mkdirSync(dirname(path), { recursive: true })
    appendFileSync(path, JSON.stringify(record) + '\n')
  } catch {
    /* journal is best-effort — a delivery must never fail over its own trail */
  }
}
