// Shared test fixtures for AppConfig / Logger.
//
// Before this helper, ~14 test files each inlined a full AppConfig literal
// (bot_id/status/commands/memory/progress/task_mirror/watcher/tmux_mirror/
// multichat/ask_user_question/permission_gate …). They drifted: some enabled
// status, some used different allowed-id sets, some omitted optional blocks
// behind `as unknown as AppConfig`. This module is the single canonical
// fixture; per-file deviations are passed as `overrides` at the call site (or
// via a thin local wrapper for files that override a nested block).
//
// Canonical defaults mirror tests/commands/oob.test.ts — the most complete
// historical literal (a strict AppConfig, no `as unknown` cast needed).

import type { AppConfig } from '../../src/config.js'
import type { Logger } from '../../src/log.js'

export function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    bot_id: 8507713167,
    dm_only: true,
    allowed_user_ids: [164795011],
    allowed_chat_ids: [164795011],
    status: {
      enabled: true,
      interval_ms: 700,
      ttl_ms: 300_000,
      delete_on_complete: true,
      suppress_typing_bubble: false,
    },
    album: { flush_ms: 2000 },
    voice: { provider: 'groq', language: 'ru', model: 'whisper-large-v3-turbo' },
    webhook: { enabled: false, host: '127.0.0.1', port: 0 },
    permission_relay: {
      enabled: true,
      allowed_user_ids: [164795011],
      bash_only_proof: true,
    },
    commands: { help: true, status: true, stop: true, reset: true, new: true },
    memory: {
      enabled: false,
      source_tag: 'tg',
      max_hot_bytes: 20480,
      trim_keep_lines: 600,
      buffer_ttl_ms: 5 * 60 * 1000,
      buffer_max_entries: 100,
    },
    progress: {
      enabled: true,
      edit_throttle_ms: 3000,
      recent_buffer: 10,
      session_ttl_ms: 600000,
    },
    task_mirror: {
      enabled: true,
      edit_throttle_ms: 3000,
      session_ttl_ms: 600000,
      collapse_completed_after: 5,
    },
    watcher: {
      enabled: true,
      debounce_ms: 10_000,
      busy_threshold_ms: 30_000,
    },
    tmux_mirror: {
      enabled: false,
      pane_target: '',
      socket_name: '',
      poll_interval_ms: 5000,
      line_count: 50,
      hide_segments: ['boot_banner', 'inbound_warning', 'footer_hints', 'input_box'],
      mode: 'latest_inbound_only',
      max_lines: 14,
    },
    multichat: { enabled: false },
    ask_user_question: { enabled: false, timeout_ms: 300_000, max_preview_chars: 1000 },
    permission_gate: { enabled: false, timeout_ms: 120_000 },
    ...overrides,
  }
}

export function makeLogger(): Logger {
  return {
    debug: () => {},
    info: () => {},
    warn: () => {},
    error: () => {},
  }
}
