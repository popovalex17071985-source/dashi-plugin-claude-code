// `route: master` merges a group chat into the warchief's main session
// instead of spawning its own — so one Claude holds both threads and two
// sessions stop duplicating the same task (Саня 02.09.2026).
import { describe, expect, it } from 'bun:test'
import { ChatPolicySchema } from '../../src/chats/policy-loader.js'

const base = {
  mode: 'public' as const,
  streaming: 'off' as const,
  tmux_mirror: false,
  edit_message_progress: false,
  delivery: 'final_only' as const,
  persona_file: 'chats/personas/jarvis.md',
  handoff_file: 'core/hot/handoff.md',
  system_reminder: 'x',
}

describe('chat policy route', () => {
  it('defaults to its own session when the key is absent', () => {
    expect(ChatPolicySchema.parse(base).route).toBeUndefined()
  })

  it('accepts master', () => {
    expect(ChatPolicySchema.parse({ ...base, route: 'master' }).route).toBe('master')
  })

  it('rejects a typo rather than silently routing somewhere else', () => {
    expect(() => ChatPolicySchema.parse({ ...base, route: 'main' })).toThrow()
  })
})
