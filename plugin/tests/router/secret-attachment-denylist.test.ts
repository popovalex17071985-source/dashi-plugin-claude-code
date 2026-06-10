// The ONLY hard limit on multichat attachments: secret material must never be
// sendable to a (public) chat, while ordinary files are allowed (warchief
// 2026-06-10). Guards the file-exfil surface of the multichat file-send.
import { describe, expect, test } from 'bun:test'
import { isSecretAttachmentPath } from '../../src/router/multichat-router.js'

describe('isSecretAttachmentPath', () => {
  test('BLOCKS secret material', () => {
    for (const p of [
      '/home/openclaw/.claude-lab/thrall/secrets/socialdata.env',
      '/home/openclaw/app/.env',
      '/home/openclaw/app/.env.production',
      '/etc/ssl/private/server.key',
      '/home/x/cert.pem',
      '/home/x/keystore.p12',
      '/home/x/.ssh/id_rsa',
      '/home/x/id_ed25519',
      '/home/x/.npmrc',
      '/home/x/.netrc',
      '/home/openclaw/.secrets/firebase/sa-thrall.json',
      '/var/run/sa-gbrain.json',
      '/tmp/api.secret',
    ]) {
      expect(isSecretAttachmentPath(p)).toBe(true)
    }
  })

  test('ALLOWS ordinary files (any path, any common type)', () => {
    for (const p of [
      '/home/openclaw/.claude-lab/thrall/.claude/skills/present/present-gbrain.html',
      '/tmp/report.pdf',
      '/home/x/cover.png',
      '/home/x/cowork-1.txt',
      '/home/x/diagram.svg',
      '/home/x/data.json',
      '/home/x/token-economy-lesson.html',
      '/home/x/credentials-explained.md',
    ]) {
      expect(isSecretAttachmentPath(p)).toBe(false)
    }
  })
})
