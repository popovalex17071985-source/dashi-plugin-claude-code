// Probity (successor of TDD Guard): PreToolUse gate enforcing test-first on plugin code.
// Scoped to src/ and tests/ only — memory/notes/docs written by agents pass through.
// ponytail: AI validator per edit in scope; add forbidCommandPattern rules here later
// if we want zero-cost deterministic gates (force push, rm -rf).
import { defineConfig, enforceTdd } from '@nizos/probity'

export default defineConfig({
  rules: [
    {
      files: ['src/**', 'tests/**'],
      rules: [enforceTdd()],
    },
  ],
})
