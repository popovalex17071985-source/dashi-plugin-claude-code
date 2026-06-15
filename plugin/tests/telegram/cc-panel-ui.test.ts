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
    const { calls, deps } = capturingExec()
    const { ctx, answers } = makeCtx(`${CCMD_PREFIX}compact`, ALLOWED[0]!)
    await handleCcmdCallback(ctx, deps)
    // sendSlashCommand: C-u clear, then literal text, then Enter
    expect(calls.some((c) => c.includes('/compact'))).toBe(true)
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
  const deps: CcmdCallbackDeps = {
    allowedUserIds: ALLOWED,
    tmuxKeysTarget: PANE,
    log,
    chatId: '164795011',
    exec: async () => ({ exitCode: 0, stderr: '' }),
    captureExec: async (): Promise<TmuxExecResult> => {
      captureCalls += 1
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

  test('forwardOutput=false commands (compact/clear/model) do NOT forward', async () => {
    for (const name of ['compact', 'clear', 'model']) {
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
