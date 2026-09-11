// Новая рабочая группа должна работать СРАЗУ: владелец создаёт чат, кидает туда
// людей и бота, зовёт его через @ -- и получает ответ. Без правки policy.yaml
// руками (Саня 11.09.2026).
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { autojoinGroupChat, loadPolicy } from '../../src/chats/policy-loader'

const BASE_YAML = `version: 1
allowlist:
  chats: ["140141496"]
  users: ["140141496"]
mention_allowlist: []
chats:
  "140141496":
    mode: private
    streaming: progress
    tmux_mirror: false
    edit_message_progress: true
    delivery: streamed
    persona_file: CLAUDE.md
    handoff_file: handoff.md
    system_reminder: ""
`

function fixture(): string {
  const dir = mkdtempSync(join(tmpdir(), 'policy-autojoin-'))
  writeFileSync(join(dir, 'policy.yaml'), BASE_YAML)
  return dir
}

describe('autojoinGroupChat', () => {
  test('добавляет новую группу и переживает перезагрузку политики', () => {
    const dir = fixture()
    const added = autojoinGroupChat(dir, '-5482872411', '140141496')
    expect(added?.mode).toBe('public')

    const policy = loadPolicy(dir)
    expect(policy.allowlist.chats).toContain('-5482872411')
    expect(policy.chats['-5482872411']?.mode).toBe('public')
    // Групповой чат не должен сыпать в чужой чат черновиками работы.
    expect(policy.chats['-5482872411']?.streaming).toBe('off')
    expect(policy.chats['-5482872411']?.delivery).toBe('final_only')
  })

  test('второй вызов ничего не меняет', () => {
    const dir = fixture()
    autojoinGroupChat(dir, '-5482872411', '140141496')
    const first = readFileSync(join(dir, 'policy.yaml'), 'utf8')
    expect(autojoinGroupChat(dir, '-5482872411', '140141496')).toBeNull()
    expect(readFileSync(join(dir, 'policy.yaml'), 'utf8')).toBe(first)
  })

  test('чужой человек группу не протащит', () => {
    const dir = fixture()
    expect(autojoinGroupChat(dir, '-5482872411', '999999')).toBeNull()
    expect(loadPolicy(dir).chats['-5482872411']).toBeUndefined()
  })

  test('личку не трогает -- только группы с отрицательным id', () => {
    const dir = fixture()
    expect(autojoinGroupChat(dir, '777000', '140141496')).toBeNull()
    expect(loadPolicy(dir).chats['777000']).toBeUndefined()
  })
})
