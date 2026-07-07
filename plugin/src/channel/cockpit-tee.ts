// Cockpit web mirror: tee the cockpit DM's messages into a transcript the web
// panel polls, so the desktop cockpit and Telegram stay in sync. Best-effort —
// a write failure must never break the Telegram send/notify path.
//
// ponytail: single-chat filter + append-only JSONL, no rotation (one DM's
// transcript is tiny). Add a size cap only if it ever grows unbounded.

import { appendFileSync, mkdirSync } from 'fs'
import { join } from 'path'

const COCKPIT_CHAT_ID = process.env.COCKPIT_CHAT_ID ?? '140141496'
const COCKPIT_STATE_DIR =
  (process.env.MULTICHAT_STATE_DIR ?? '/home/edgelab/.claude-lab/jarvis/state/telegram') +
  '/cockpit'

export function teeCockpit(chatId: number | string, dir: 'in' | 'out', text: string): void {
  if (String(chatId) !== COCKPIT_CHAT_ID) return
  if (!text) return
  try {
    mkdirSync(COCKPIT_STATE_DIR, { recursive: true })
    const line = JSON.stringify({ ts: new Date().toISOString(), dir, text }) + '\n'
    appendFileSync(join(COCKPIT_STATE_DIR, `${COCKPIT_CHAT_ID}.jsonl`), line)
  } catch {
    // convenience mirror only — swallow
  }
}
