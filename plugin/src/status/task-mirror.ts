// TaskMirror — third rolling Telegram message per chat. Where StatusManager
// owns the transient «Печатает.../🔧 tool» bubble and ProgressReporter owns
// the per-tool activity thread, TaskMirror owns a separate persistent message
// that mirrors Claude's TodoWrite milestone list: in-progress / pending /
// completed items.
//
// The three surfaces NEVER share state — each Map entry is keyed on chatId
// inside its own class. This isolation is intentional: an operator can flip
// any of (status.enabled / progress.enabled / task_mirror.enabled) without
// disturbing the others.
//
// Architectural mirror of ProgressReporter (see plan §2.1):
//   * Single-slot queue per chat — `flushPromise !== null` guards in-flight
//     ops. Multiple TodoWrite events while a flush runs overwrite
//     `desiredText`; only the freshest snapshot ever publishes.
//   * Throttle via `edit_throttle_ms`. First send bypasses throttle, subsequent
//     edits within the window defer onto a single timer slot.
//   * Idempotency: same rendered text → no Telegram round-trip.
//   * TTL eviction on `session_ttl_ms` of idleness — protects against lost
//     `session_stop` hooks the way ProgressReporter does.
//   * `recordEvent` is fire-and-forget; top-level try/catch swallows every
//     throw so the webhook 200 path is never blocked.

import type { AppConfig } from '../config.js'
import type { Logger } from '../log.js'
import type { TaskMirrorEvent } from '../hooks/claude-events.js'
import type { TodoItem } from '../schemas.js'
import type { TelegramApiForProgress } from './telegram-api.js'
import { escapeHtml } from '../format/html.js'
import {
  PerChatMessageQueue,
  type BaseChatEntry,
  type QueueConfigSlice,
} from './per-chat-message-queue.js'

// Telegram editMessageText cap (4096 chars). Default render budget below it
// — the spec asks for ~3500-char headroom (see plan §3 file 4).
const DEFAULT_MAX_CHARS = 3500
const TRUNCATE_MARGIN = 100 // safety cushion below MAX_CHARS for tail strings

// Status icons. Unicode glyphs match the plan §2.3 spec.
const ICONS = {
  in_progress: '◐',
  pending: '◻',
  completed: '☑',
} as const

export interface TaskMirrorDeps {
  telegramApi: TelegramApiForProgress
  config: AppConfig
  log: Logger
  now?: () => number
  setTimer?: (cb: () => void, ms: number) => NodeJS.Timeout
  clearTimer?: (handle: NodeJS.Timeout) => void
}

// Per-chat lifecycle entry. Extends the shared queue entry with the two
// TaskMirror-specific render sources.
interface ChatTaskEntry extends BaseChatEntry {
  // Latest TodoWrite snapshot from Claude. Replaced wholesale on each event
  // — TodoWrite is itself the full list, so we never merge incrementally.
  todos: ReadonlyArray<TodoItem>
  // Incremental task map for the TaskCreate/TaskUpdate path (newer Claude Code
  // harness). Key is the harness taskId once reconciled from `toolResult`, or
  // the provisional `toolUseId` until then. `todos` is rebuilt from this map
  // after every mutation so `scheduleFlush` keeps using the existing renderer.
  // Insertion-order Map keeps the visual ordering stable across renders.
  taskMap: Map<string, TodoItem>
}

// Extract the harness-assigned task id from a TaskCreate PostToolUse
// `tool_result`. The harness emits `Task #<n> created successfully...`; we
// pull out the first `#<digits>` token. Returns null if the shape doesn't
// match — caller falls back to the provisional `toolUseId`.
function parseCreatedTaskId(toolResult: unknown): string | null {
  if (typeof toolResult !== 'string') return null
  const match = toolResult.match(/#(\d+)/)
  return match ? (match[1] ?? null) : null
}

export class TaskMirror extends PerChatMessageQueue<ChatTaskEntry> {
  private readonly config: AppConfig
  protected readonly logPrefix = 'task mirror'

  constructor(deps: TaskMirrorDeps) {
    super({
      telegramApi: deps.telegramApi,
      log: deps.log,
      now: deps.now ?? (() => Date.now()),
      setTimer: deps.setTimer ?? ((cb, ms) => setTimeout(cb, ms)),
      clearTimer: deps.clearTimer ?? ((h) => clearTimeout(h)),
    })
    this.config = deps.config
  }

  /**
   * Main entry point. Called by the webhook handler for every Claude hook
   * that mapped to a TaskMirrorEvent. Never throws — top-level try/catch
   * swallows any failure so the webhook 200 path stays open.
   *
   * Three input shapes:
   *   - `todo_write`: full list snapshot (legacy TodoWrite tool). Replaces
   *     `todos` wholesale AND clears `taskMap` so a mid-session switch from
   *     TodoWrite to TaskCreate/Update starts cleanly.
   *   - `task_create` / `task_update`: incremental events from the newer
   *     TaskCreate/TaskUpdate tools. Mutate `taskMap`, then synthesise the
   *     `todos` array from it.
   *   - `todo_session_stop`: terminal signal, handled separately.
   */
  async recordEvent(chatId: string, event: TaskMirrorEvent): Promise<void> {
    if (!this.config.task_mirror.enabled) return
    try {
      if (event.kind === 'todo_session_stop') {
        await this.handleStop(chatId)
        return
      }
      const entry = this.getOrCreate(chatId)
      if (entry.stopped) return
      entry.lastActivityMs = this.now()

      switch (event.kind) {
        case 'todo_write':
          // Replace the snapshot wholesale. TodoWrite payloads ARE the full list.
          entry.taskMap.clear()
          entry.todos = event.todos
          break
        case 'task_create':
          this.applyTaskCreate(entry, event)
          entry.todos = Array.from(entry.taskMap.values())
          break
        case 'task_update':
          this.applyTaskUpdate(entry, event)
          entry.todos = Array.from(entry.taskMap.values())
          break
      }
      this.scheduleFlush(entry)
    } catch (err) {
      this.log.warn('task mirror recordEvent failed (ignored)', {
        chat_id: chatId,
        error: err instanceof Error ? err.message : String(err),
      })
    }
  }

  /**
   * TaskCreate handler. PreToolUse adds the task to `taskMap` keyed on
   * `toolUseId` (provisional id, always present). The follow-up PostToolUse
   * carries `toolResult`; if we can parse a real `#<n>` id we re-key the
   * entry so subsequent `TaskUpdate` events (which use the real id) can find
   * it. Two arrivals are idempotent — a TaskCreate that has already been
   * recorded under its provisional id and a matching PostToolUse with the
   * same toolUseId find the entry and reconcile without duplicating.
   *
   * Note: the harness convention is `Task #N created successfully` — see
   * TaskCreate tool description. `parseCreatedTaskId` extracts the first
   * `#<digits>` substring and returns null on shape mismatch.
   */
  private applyTaskCreate(
    entry: ChatTaskEntry,
    event: Extract<TaskMirrorEvent, { kind: 'task_create' }>,
  ): void {
    const realId =
      event.toolResult !== undefined ? parseCreatedTaskId(event.toolResult) : null
    const provisionalId = event.toolUseId
    const provisional = entry.taskMap.get(provisionalId)
    const item: TodoItem = {
      id: realId ?? provisional?.id ?? provisionalId,
      content: event.input.subject,
      status: provisional?.status ?? 'pending',
      ...(event.input.activeForm !== undefined
        ? { activeForm: event.input.activeForm }
        : provisional?.activeForm !== undefined
          ? { activeForm: provisional.activeForm }
          : {}),
    }
    // Drop the provisional entry, insert under the canonical id. This re-keys
    // the Map without dropping anything else; insertion-order semantics mean
    // the task moves to the tail on reconciliation, which is the right place
    // visually (most recently activated).
    entry.taskMap.delete(provisionalId)
    if (realId !== null && realId !== provisionalId) {
      entry.taskMap.delete(realId)
    }
    entry.taskMap.set(item.id ?? provisionalId, item)
  }

  /**
   * TaskUpdate handler. `taskId` from the harness is always a string after
   * the schema coerce. If the entry exists, mutate in place; if not (e.g.
   * TaskMirror missed the TaskCreate due to a webhook drop), synthesise a
   * minimal placeholder so the list stays consistent.
   */
  private applyTaskUpdate(
    entry: ChatTaskEntry,
    event: Extract<TaskMirrorEvent, { kind: 'task_update' }>,
  ): void {
    const id = event.input.taskId
    // Drop 'deleted' before constructing the TodoItem -- the rendered TodoItem
    // type accepts only pending/in_progress/completed, and the schema-coerced
    // 'deleted' value would not narrow correctly otherwise.
    if (event.input.status === 'deleted') {
      entry.taskMap.delete(id)
      return
    }
    const existing = entry.taskMap.get(id)
    const status = event.input.status ?? existing?.status ?? 'pending'
    const next: TodoItem = {
      id,
      content: event.input.subject ?? existing?.content ?? `task ${id}`,
      status,
      ...(event.input.activeForm !== undefined
        ? { activeForm: event.input.activeForm }
        : existing?.activeForm !== undefined
          ? { activeForm: existing.activeForm }
          : {}),
    }
    entry.taskMap.set(id, next)
  }

  // ─────────────────────────────────────────────────────────────────────
  // Subclass hooks
  // ─────────────────────────────────────────────────────────────────────

  protected getConfigSlice(): QueueConfigSlice {
    return this.config.task_mirror
  }

  protected createEntryState(
    _chatId: string,
  ): { todos: ReadonlyArray<TodoItem>; taskMap: Map<string, TodoItem> } {
    return { todos: [], taskMap: new Map() }
  }

  protected renderEntry(entry: ChatTaskEntry): string {
    return this.safeRender(entry.todos)
  }

  /**
   * Final-edit body: current snapshot + «сессия завершена» marker. The
   * marker ALWAYS differs from any intermediate render so idempotency
   * never skips this edit (otherwise the warchief might never see a
   * session-end signal). Same DEFAULT_MAX_CHARS budget applies — if the
   * snapshot already pushes against the cap, the marker still fits inside
   * the safety margin renderTodoList reserves.
   */
  protected renderFinalEntry(entry: ChatTaskEntry): string {
    const block = this.safeRender(entry.todos)
    if (!block) return ''
    return `${block}\n<i>сессия завершена</i>`
  }

  private safeRender(todos: ReadonlyArray<TodoItem>): string {
    try {
      return renderTodoList(todos, this.config.task_mirror.collapse_completed_after)
    } catch (err) {
      this.log.warn('task mirror render failed (ignored)', {
        error: err instanceof Error ? err.message : String(err),
      })
      return ''
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Renderer (exported for tests)
// ─────────────────────────────────────────────────────────────────────

/**
 * Render a TodoWrite snapshot as Telegram-friendly HTML. Section order:
 *   1. Header — bold «Задачи» + counts.
 *   2. In-progress items — icon ◐.
 *   3. Pending items — icon ◻.
 *   4. Last `collapseCompletedAfter` completed items — icon ☑.
 *   5. Tail line if more completed exist: `<i>+M завершено ранее</i>`.
 *
 * Edge cases:
 *   - Empty list: `<i>задач нет</i>` (don't delete the message).
 *   - Total length cap at ~DEFAULT_MAX_CHARS: pending list truncates first,
 *     then completed, with `<i>+N ещё…</i>` tail.
 *
 * Every dynamic string passes through `escapeHtml` so user-supplied todo
 * content can't break out of the message.
 */
export function renderTodoList(
  todos: ReadonlyArray<TodoItem>,
  collapseCompletedAfter: number,
  maxChars: number = DEFAULT_MAX_CHARS,
): string {
  if (todos.length === 0) {
    return '<b>Задачи</b>\n<i>задач нет</i>'
  }

  let doneCount = 0
  let inProgressCount = 0
  let pendingCount = 0
  const inProgress: TodoItem[] = []
  const pending: TodoItem[] = []
  const completed: TodoItem[] = []
  for (const t of todos) {
    switch (t.status) {
      case 'in_progress':
        inProgressCount++
        inProgress.push(t)
        break
      case 'pending':
        pendingCount++
        pending.push(t)
        break
      case 'completed':
        doneCount++
        completed.push(t)
        break
    }
  }

  const header = '<b>Задачи</b>'
  const counts = `${doneCount} done / ${inProgressCount} in progress / ${pendingCount} pending`

  // Show only the last N completed items; older ones collapse into a tail
  // notice. `collapseCompletedAfter=0` means «hide all completed» — render
  // none, then the tail says how many were hidden.
  const visibleCompleted = collapseCompletedAfter > 0
    ? completed.slice(-collapseCompletedAfter)
    : []
  const hiddenCompletedCount = completed.length - visibleCompleted.length

  const lines: string[] = [header, counts, '']
  for (const t of inProgress) lines.push(`${ICONS.in_progress} ${escapeTodoLine(t)}`)
  for (const t of pending) lines.push(`${ICONS.pending} ${escapeTodoLine(t)}`)
  if (hiddenCompletedCount > 0) {
    lines.push(`<i>+${hiddenCompletedCount} завершено ранее</i>`)
  }
  for (const t of visibleCompleted) lines.push(`${ICONS.completed} ${escapeTodoLine(t)}`)

  let body = lines.join('\n')
  if (body.length <= maxChars) return body

  // Over budget. Truncation pass: drop trailing pending lines first, then
  // completed. Always keep header + counts + at least the in-progress block.
  const safeBudget = maxChars - TRUNCATE_MARGIN
  // Header block (header + counts + blank line) is mandatory.
  const headerBlock = [header, counts, ''].join('\n')
  const inProgressBlock = inProgress
    .map((t) => `${ICONS.in_progress} ${escapeTodoLine(t)}`)
    .join('\n')
  let used = headerBlock.length + (inProgressBlock.length > 0 ? 1 + inProgressBlock.length : 0)
  const out: string[] = [headerBlock]
  if (inProgressBlock.length > 0) out.push(inProgressBlock)

  // Add pending lines one by one until budget runs out.
  let droppedPending = 0
  const pendingLines = pending.map((t) => `${ICONS.pending} ${escapeTodoLine(t)}`)
  const pendingKept: string[] = []
  for (const line of pendingLines) {
    // +1 for the joining newline.
    if (used + 1 + line.length > safeBudget) {
      droppedPending = pendingLines.length - pendingKept.length
      break
    }
    pendingKept.push(line)
    used += 1 + line.length
  }
  if (pendingKept.length > 0) out.push(pendingKept.join('\n'))
  if (droppedPending > 0) {
    const tail = `<i>+${droppedPending} ещё…</i>`
    out.push(tail)
    used += 1 + tail.length
  }

  // Completed: respect collapse rule first, then truncate visible block.
  let droppedCompleted = hiddenCompletedCount
  if (hiddenCompletedCount > 0) {
    const tail = `<i>+${hiddenCompletedCount} завершено ранее</i>`
    if (used + 1 + tail.length <= safeBudget) {
      out.push(tail)
      used += 1 + tail.length
    }
  }
  const completedLines = visibleCompleted.map(
    (t) => `${ICONS.completed} ${escapeTodoLine(t)}`,
  )
  const completedKept: string[] = []
  for (const line of completedLines) {
    if (used + 1 + line.length > safeBudget) {
      droppedCompleted += completedLines.length - completedKept.length
      break
    }
    completedKept.push(line)
    used += 1 + line.length
  }
  if (completedKept.length > 0) out.push(completedKept.join('\n'))
  if (droppedCompleted > hiddenCompletedCount) {
    const extraDropped = droppedCompleted - hiddenCompletedCount
    const tail = `<i>+${extraDropped} ещё…</i>`
    out.push(tail)
  }

  return out.join('\n')
}

function escapeTodoLine(todo: TodoItem): string {
  // Prefer `activeForm` for in-progress items (Claude convention is
  // gerund — «Reading file» vs «Read file»), otherwise show `content`.
  const raw = todo.status === 'in_progress' && todo.activeForm
    ? todo.activeForm
    : todo.content
  return escapeHtml(raw)
}
