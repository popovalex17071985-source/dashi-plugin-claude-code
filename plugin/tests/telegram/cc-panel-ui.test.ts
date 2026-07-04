import { describe, expect, test } from 'bun:test'

import {
  CC_PANEL_COMMANDS,
  CCMD_PREFIX,
  buildCcKeyboard,
  buildForwardHtml,
  handleCcmdCallback,
  parseCcmdCallback,
  type CcmdCallbackContext,
  type CcmdCallbackDeps,
} from '../../src/telegram/cc-panel-ui.js'
import { captureCleanPane, type TmuxExecResult } from '../../src/status/tmux-mirror.js'
import type { Logger } from '../../src/log.js'

const log = { info() {}, warn() {}, error() {}, debug() {} } as unknown as Logger
const ALLOWED = [164795011]
const PANE = { paneTarget: '%1', socketPath: '/tmp/s' }

// A minimal idle composer — IT2-1 now probes the pane before the sendSlashCommand
// fall-through, so the send-path fakes must serve an idle snapshot to proceed.
const IDLE_PROBE = [
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
  '  ? for shortcuts',
].join('\n')

function makeCtx(data: string, fromId: number | undefined): {
  ctx: CcmdCallbackContext
  answers: string[]
} {
  const answers: string[] = []
  const ctx: CcmdCallbackContext = {
    callbackQuery: { data },
    from: { id: fromId },
    answerCallbackQuery: async (arg) => {
      answers.push(arg.text)
    },
  }
  return { ctx, answers }
}

function capturingExec(): { calls: string[][]; deps: CcmdCallbackDeps } {
  const calls: string[][] = []
  const deps: CcmdCallbackDeps = {
    allowedUserIds: ALLOWED,
    tmuxKeysTarget: PANE,
    log,
    exec: async (args) => {
      calls.push([...args])
      return { exitCode: 0, stderr: '' }
    },
    // IT2-1: the non-control send path now probes the pane first; serve idle.
    captureExec: async () => ({ exitCode: 0, stdout: IDLE_PROBE, stderr: '' }),
  }
  return { calls, deps }
}

describe('parseCcmdCallback', () => {
  test('accepts a whitelisted command', () => {
    expect(parseCcmdCallback(`${CCMD_PREFIX}compact`)).toBe('compact')
    expect(parseCcmdCallback(`${CCMD_PREFIX}model`)).toBe('model')
  })

  test('rejects unknown command, wrong prefix, empty, non-string', () => {
    expect(parseCcmdCallback(`${CCMD_PREFIX}rm`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}compact extra`)).toBeNull()
    expect(parseCcmdCallback('kkey:1')).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}__proto__`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}constructor`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}toString`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}Compact`)).toBeNull()
    expect(parseCcmdCallback(`${CCMD_PREFIX}compact `)).toBeNull()
    // @ts-expect-error runtime guard for non-string
    expect(parseCcmdCallback(undefined)).toBeNull()
  })
})

describe('buildCcKeyboard', () => {
  test('exposes exactly the whitelisted commands as ccmd: callbacks', () => {
    const kb = buildCcKeyboard()
    const datas = kb.inline_keyboard.flat().map((b) => b.callback_data)
    expect(datas.sort()).toEqual(
      CC_PANEL_COMMANDS.map((c) => `${CCMD_PREFIX}${c.name}`).sort(),
    )
  })
})

describe('handleCcmdCallback', () => {
  test('unauthorized user id: toast, NO command typed', async () => {
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, 999)
    await handleCcmdCallback(ctx, deps)
    expect(calls.length).toBe(0)
    expect(answers[0]).toContain('не авторизовано')
  })

  test('missing id is unauthorized (fail-closed)', async () => {
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, undefined)
    await handleCcmdCallback(ctx, deps)
    expect(calls.length).toBe(0)
    expect(answers[0]).toContain('не авторизовано')
  })

  test('authorized + valid command types /<name> into pane', async () => {
    // Use a non-control command (`context`) — the simple sendSlashCommand path.
    // (compact/clear have their own state-aware routing, covered separately.)
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}context`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    // sendSlashCommand: C-u clear, then literal text, then Enter
    expect(calls.some((c) => c.includes('/context'))).toBe(true)
    expect(calls.some((c) => c.includes('C-u'))).toBe(true)
    expect(answers[0]).toContain('выполнено')
  })

  test('authorized + unknown command: toast, NO command typed', async () => {
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}reboot`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(calls.length).toBe(0)
    expect(answers[0]).toContain('неизвестная команда')
  })

  test('no pane resolvable: toast, NO command typed', async () => {
    const calls: string[][] = []
    const deps: CcmdCallbackDeps = {
      allowedUserIds: ALLOWED,
      log,
      exec: async (args) => {
        calls.push([...args])
        return { exitCode: 0, stderr: '' }
      },
    }
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(calls.length).toBe(0)
    expect(answers[0]).toContain('pane недоступен')
  })
})

// ── Output forwarding ─────────────────────────────────────────────────

// A forwarding-enabled deps bundle: stubs the keystroke exec, the capture
// exec (returns a canned pane), and a sendMessage that records its calls.
// `sleep` is a no-op so the stability poll runs instantly.
function forwardingDeps(paneText: string): {
  sent: Array<{ chatId: string; html: string }>
  captureCalls: number
  deps: CcmdCallbackDeps
} {
  const sent: Array<{ chatId: string; html: string }> = []
  let captureCalls = 0
  // IT2-1 (origin/main): non-control commands now probe the pane for idle
  // BEFORE sendSlashCommand fires. Serve that first probe an idle snapshot,
  // then paneText for every capture after — the forward-poll (which wants 2
  // identical reads to call the frame "stable") sees the same constant text
  // on its first two polls, so it stabilizes immediately.
  let probed = false
  const deps: CcmdCallbackDeps = {
    allowedUserIds: ALLOWED,
    tmuxKeysTarget: PANE,
    log,
    chatId: '164795011',
    exec: async () => ({ exitCode: 0, stderr: '' }),
    captureExec: async (): Promise<TmuxExecResult> => {
      captureCalls += 1
      if (!probed) {
        probed = true
        return { stdout: IDLE_PROBE, stderr: '', exitCode: 0 }
      }
      return { stdout: paneText, stderr: '', exitCode: 0 }
    },
    sendMessage: async (chatId, html) => {
      sent.push({ chatId, html })
    },
    sleep: async () => {},
  }
  return {
    sent,
    get captureCalls() {
      return captureCalls
    },
    deps,
  }
}

describe('handleCcmdCallback output forwarding', () => {
  test('forwardOutput=true commands (context/cost/status) DO forward', async () => {
    for (const name of ['context', 'cost', 'status']) {
      const f = forwardingDeps(`/${name} output\nline two`)
      const { ctx, answers } = makeCtx(`${CCMD_PREFIX}${name}`, ALLOWED[0]!)
      await handleCcmdCallback(ctx, f.deps)
      expect(answers[0]).toContain('выполнено')
      expect(f.sent.length).toBe(1)
      expect(f.sent[0]!.chatId).toBe('164795011')
      expect(f.sent[0]!.html).toContain('<pre>')
      expect(f.sent[0]!.html).toContain('line two')
    }
  })

  // compact/clear are excluded here: origin/main's control-routing merge
  // (below) special-cases both BEFORE this generic idle-probe path — compact
  // goes through the reliable sendControlCommand state machine, clear posts
  // the /new confirm card — so this generic idle fixture can't drive their
  // real state transitions. Each has its own precise coverage in
  // `describe('handleCcmdCallback control routing')`.
  test('forwardOutput=false commands (model) do NOT forward', async () => {
    for (const name of ['model']) {
      const f = forwardingDeps('some pane state')
      const { ctx, answers } = makeCtx(`${CCMD_PREFIX}${name}`, ALLOWED[0]!)
      await handleCcmdCallback(ctx, f.deps)
      // The command is still typed + toasted, but NOTHING is forwarded.
      expect(answers[0]).toContain('выполнено')
      expect(f.sent.length).toBe(0)
    }
  })

  test('unauthorized tap forwards NOTHING (and types nothing)', async () => {
    const f = forwardingDeps('/context output')
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}context`, 999)
    await handleCcmdCallback(ctx, f.deps)
    expect(answers[0]).toContain('не авторизовано')
    expect(f.sent.length).toBe(0)
    expect(f.captureCalls).toBe(0)
  })

  test('forward deps missing (no captureExec/sendMessage): toast only, no throw', async () => {
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}context`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    // Command typed + toasted; no forward deps wired → no send, no throw.
    expect(calls.some((c) => c.includes('/context'))).toBe(true)
    expect(answers[0]).toContain('выполнено')
  })

  test('blank/chrome-only pane: nothing forwarded', async () => {
    const f = forwardingDeps('\n\n>  \n? for shortcuts\n')
    const { ctx } = makeCtx(`${CCMD_PREFIX}context`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, f.deps)
    expect(f.sent.length).toBe(0)
  })
})

describe('buildForwardHtml', () => {
  test('wraps output in <pre>, strips trailing chrome + blank lines', () => {
    const raw = 'Context: 42% used\n47k/200k tokens\n\n>\n? for shortcuts'
    const html = buildForwardHtml(raw, 'context')
    expect(html).not.toBeNull()
    expect(html).toContain('<pre>')
    expect(html).toContain('Context: 42% used')
    expect(html).toContain('47k/200k tokens')
    // Footer/input chrome stripped.
    expect(html).not.toContain('for shortcuts')
  })

  test('escapes HTML-special characters in pane text', () => {
    const html = buildForwardHtml('a < b && c > d', 'status')
    expect(html).toContain('a &lt; b &amp;&amp; c &gt; d')
  })

  test('returns null for empty / whitespace-only pane', () => {
    expect(buildForwardHtml('', 'context')).toBeNull()
    expect(buildForwardHtml('   \n\n  ', 'context')).toBeNull()
  })

  test('truncates oversized output to a Telegram-safe size', () => {
    const big = 'x'.repeat(10_000)
    const html = buildForwardHtml(big, 'export')!
    expect(html).toContain('[truncated]')
    expect(html.length).toBeLessThan(4096)
  })
})

describe('captureCleanPane cleaning', () => {
  test('strips ANSI, control chars, box-drawing; keeps text', async () => {
    // CSI color + box-drawing frame + a tool bullet glyph.
    const rawPane =
      '\x1b[1;32mContext\x1b[0m: 42%\n' +
      '╭──────────╮\n' +
      '│ 47k used │\n' +
      '╰──────────╯\n' +
      '⏺ done'
    const exec = async (): Promise<TmuxExecResult> => ({
      stdout: rawPane,
      stderr: '',
      exitCode: 0,
    })
    const res = await captureCleanPane(PANE, exec, { lineCount: 50 })
    expect(res.ok).toBe(true)
    expect(res.text).toContain('Context: 42%')
    expect(res.text).toContain('47k used')
    // ANSI escape gone.
    expect(res.text).not.toContain('\x1b')
    // Box-drawing frame stripped.
    expect(res.text).not.toContain('╭')
    expect(res.text).not.toContain('│')
    // ⏺ swapped to text-presentation ● (no emoji glyph).
    expect(res.text).not.toContain('⏺')
    expect(res.text).toContain('●')
  })

  test('non-zero exit → ok:false with error, never throws', async () => {
    const exec = async (): Promise<TmuxExecResult> => ({
      stdout: '',
      stderr: "can't find pane",
      exitCode: 1,
    })
    const res = await captureCleanPane(PANE, exec)
    expect(res.ok).toBe(false)
    expect(res.text).toBe('')
    expect(res.error).toContain("can't find pane")
  })

  test('addresses the same socket as the pane target', async () => {
    let seenArgs: readonly string[] = []
    const exec = async (args: readonly string[]): Promise<TmuxExecResult> => {
      seenArgs = args
      return { stdout: 'ok', stderr: '', exitCode: 0 }
    }
    await captureCleanPane(PANE, exec)
    // PANE uses socketPath '/tmp/s' → must be addressed with -S /tmp/s.
    expect(seenArgs).toContain('-S')
    expect(seenArgs).toContain('/tmp/s')
    expect(seenArgs).toContain('capture-pane')
    expect(seenArgs).toContain('%1')
  })
})

// ─────────────────────────────────────────────────────────────────────
// Control-command routing (task 6): `clear` and `compact` go through the
// state-aware sendControlCommand (probe → interrupt → confirm), while every
// other panel command stays on sendSlashCommand. We prove the split by
// scripting capture-pane snapshots for the control path and asserting the
// send-keys / capture-pane calls.
// ─────────────────────────────────────────────────────────────────────

const IDLE = [
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
  '  ? for shortcuts',
].join('\n')

const COMPACTING = [
  '❯ /compact',
  'Compacting conversation…',
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
].join('\n')

const BUSY = [
  '✳ Working… (esc to interrupt)',
  '╭────────────────────────────────╮',
  '│ >                              │',
  '╰────────────────────────────────╯',
].join('\n')

// Idle pane with a typed '/cmd' draft — the pre-Enter TOCTOU snapshot (FIX-3).
function typed(cmd: string): string {
  return [
    '╭────────────────────────────────╮',
    `│ > /${cmd}                        │`,
    '╰────────────────────────────────╯',
    '  ? for shortcuts',
  ].join('\n')
}

const noSleep = async (_ms: number): Promise<void> => {}

// Builds deps whose capture-pane fake replays the scripted panes and whose
// send-keys fake records every call. sleep is a no-op so confirm polls are instant.
function controlDeps(panes: string[]): {
  sends: string[][]
  captures: string[][]
  deps: CcmdCallbackDeps
} {
  const sends: string[][] = []
  const captures: string[][] = []
  let i = 0
  const deps: CcmdCallbackDeps = {
    allowedUserIds: ALLOWED,
    tmuxKeysTarget: PANE,
    log,
    exec: async (args) => {
      sends.push([...args])
      return { exitCode: 0, stderr: '' }
    },
    captureExec: async (args) => {
      captures.push([...args])
      const out = i < panes.length ? panes[i]! : (panes[panes.length - 1] ?? '')
      i++
      return { exitCode: 0, stdout: out, stderr: '' }
    },
    sleep: noSleep,
  }
  return { sends, captures, deps }
}

describe('handleCcmdCallback control routing', () => {
  test('compact → reliable path: probes pane (capture-pane) then confirms fire', async () => {
    // probe → pre-Enter re-check (FIX-3) → confirm.
    const { sends, captures, deps } = controlDeps([IDLE, typed('compact'), COMPACTING])
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    // capture-pane was used (state-aware), and /compact typed + Enter submitted.
    expect(captures.some((c) => c.includes('capture-pane'))).toBe(true)
    expect(sends.some((c) => c.includes('/compact'))).toBe(true)
    expect(sends.some((c) => c.includes('Enter'))).toBe(true)
    expect(answers[0]).toContain('выполнено: /compact')
  })

  // FIX-7: the destructive `clear` button posts the /new confirm card — it is
  // NEVER a one-tap clear. Nothing is typed into the pane at tap time.
  test('clear → posts the /new confirm card, types NOTHING into the pane', async () => {
    const cards: { chatId: string; text: string; keyboard: unknown }[] = []
    const sends: string[][] = []
    const deps: CcmdCallbackDeps = {
      allowedUserIds: ALLOWED,
      tmuxKeysTarget: PANE,
      log,
      exec: async (args) => {
        sends.push([...args])
        return { exitCode: 0, stderr: '' }
      },
      sendConfirmCard: async (chatId, text, keyboard) => {
        cards.push({ chatId, text, keyboard })
      },
    }
    const ctx: CcmdCallbackContext = {
      callbackQuery: { data: `${CCMD_PREFIX}clear` },
      from: { id: ALLOWED[0]! },
      chatId: '164795011',
      answerCallbackQuery: async () => {},
    }
    await handleCcmdCallback(ctx, deps)
    expect(cards.length).toBe(1)
    expect(cards[0]!.chatId).toBe('164795011')
    expect(cards[0]!.text).toContain('Новый диалог')
    // Not a single keystroke typed into the pane.
    expect(sends.length).toBe(0)
  })

  // FIX-7 fail-closed: without a way to post the card, `clear` refuses rather
  // than fall back to a one-tap destructive clear.
  test('clear without sendConfirmCard → refuses, types NOTHING', async () => {
    const sends: string[][] = []
    const deps: CcmdCallbackDeps = {
      allowedUserIds: ALLOWED,
      tmuxKeysTarget: PANE,
      log,
      exec: async (args) => {
        sends.push([...args])
        return { exitCode: 0, stderr: '' }
      },
    }
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}clear`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(sends.length).toBe(0)
    expect(answers[0]).toContain('недоступно')
  })

  test('compact busy → reports «не выполнено: busy» (state-aware refusal)', async () => {
    // busy then still busy after Escape → busy verdict.
    const { deps } = controlDeps([BUSY, BUSY])
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(answers[0]).toContain('не выполнено: busy')
  })

  // IT2-1: the non-control `context` button now PROBES the pane (an idle gate)
  // before the sendSlashCommand path — one capture-pane, then the send at idle.
  test('non-control command (context) probes idle, then sends via sendSlashCommand', async () => {
    const { sends, captures, deps } = controlDeps([IDLE])
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}context`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    // Exactly one probe (the idle gate), then the /context send.
    expect(captures.length).toBe(1)
    expect(sends.some((c) => c.includes('/context'))).toBe(true)
    expect(answers[0]).toContain('выполнено: /context')
  })

  // IT2-1: a non-control button tapped while a permission dialog is OPEN must NOT
  // blind-fire — the trailing Enter would approve the dialog. Refuse, send nothing.
  test('non-control command (status) on a DIALOG pane refuses, types NOTHING', async () => {
    const dialog = [
      '│ Do you want to proceed?        │',
      '│ ❯ 1. Yes                       │',
      '│   2. No                        │',
    ].join('\n')
    const { sends, deps } = controlDeps([dialog])
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}status`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(sends.length).toBe(0) // never typed into an open dialog
    expect(answers[0]).toContain('сессия не готова')
    expect(answers[0]).toContain('dialog')
  })

  // IT2-1: likewise a BUSY pane refuses (the command would be queued behind a
  // running tool), rather than blind-firing.
  test('non-control command (context) on a BUSY pane refuses, types NOTHING', async () => {
    const { sends, deps } = controlDeps([BUSY])
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}context`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    expect(sends.length).toBe(0)
    expect(answers[0]).toContain('сессия не готова')
    expect(answers[0]).toContain('busy')
  })
})
