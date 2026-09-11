#!/usr/bin/env python3
"""Stop hook: reconstruct the just-finished turn's usage from the plugin
transcript and append it to core/usage.jsonl.

Background: under the old gateway, the daemon parsed each `claude -p` result and
wrote usage.jsonl. The plugin has no such writer, so the file froze at cutover
and the `echo-last-turn-cost.sh` fat-turn guardrail + weekly usage-report.py
both went blind. Claude Code's own transcript carries per-message `usage`, so we
sum the turn here and write a gateway-compatible record.

Schema (must stay compatible with echo-last-turn-cost.sh and usage-report.py):
  ts, agent, chat_id, session, model, effort,
  input, output, cache_creation, cache_read, cost_usd, num_turns, dur_ms

Pricing (Opus 4.8, USD per MTok): input 5, output 25, cache-write(1h) 10,
cache-read 0.5 — exactly reproduces the historical gateway cost_usd values.
Non-blocking: any failure exits 0 silently so the turn is never disrupted.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Пути берём от самого хука: он лежит в <claude_dir>/hooks/.
CLAUDE_DIR = Path(__file__).resolve().parent.parent
USAGE_LOG = CLAUDE_DIR / "core" / "usage.jsonl"
AGENT = CLAUDE_DIR.parent.name
# Чат хозяина хук получает переменной окружения (её ставит install-hooks).
CHAT_ID = os.environ.get("TELEGRAM_HOOK_CHAT_ID") or os.environ.get("CHAT_ID") or ""
DEFAULT_EFFORT = "medium"  # config.json default; transcript doesn't carry it


# USD per million tokens. Cache-write billed at the 1h rate to match the
# historical gateway records (Claude Code uses 1h ephemeral cache).
PRICE_INPUT = 5.0
PRICE_OUTPUT = 25.0
PRICE_CACHE_WRITE = 10.0
PRICE_CACHE_READ = 0.5


def _is_real_user_turn(entry: dict) -> bool:
    """True if this transcript entry is a genuine user/agent prompt, not a
    tool_result echo. Tool results are role=user but carry tool_result blocks,
    never a text block."""
    if entry.get("type") != "user":
        return False
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return any(b.get("type") == "text" for b in content if isinstance(b, dict))
    return False


def main() -> None:
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    transcript_path = payload.get("transcript_path")
    session_id = payload.get("session_id", "unknown")
    if not transcript_path:
        return
    path = Path(transcript_path)
    if not path.is_file():
        return

    lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    entries = []
    for ln in lines:
        try:
            entries.append(json.loads(ln))
        except json.JSONDecodeError:
            continue

    # Turn boundary: everything after the last genuine user prompt.
    boundary = -1
    for i, e in enumerate(entries):
        if _is_real_user_turn(e):
            boundary = i
    turn = entries[boundary + 1 :]

    inp = out = cc = cr = 0
    window = 0  # exact context fill = the LAST sub-request's tokens, not the sum
    model = "claude-opus-4-8"
    num_turns = 0
    timestamps: list[str] = []
    for e in turn:
        if e.get("type") != "assistant":
            continue
        msg = e.get("message", {})
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        inp += usage.get("input_tokens", 0) or 0
        out += usage.get("output_tokens", 0) or 0
        cc += usage.get("cache_creation_input_tokens", 0) or 0
        cr += usage.get("cache_read_input_tokens", 0) or 0
        # Overwritten each iteration -> ends holding the last request's window.
        window = (
            (usage.get("input_tokens", 0) or 0)
            + (usage.get("cache_creation_input_tokens", 0) or 0)
            + (usage.get("cache_read_input_tokens", 0) or 0)
        )
        model = msg.get("model", model)
        num_turns += 1
        if e.get("timestamp"):
            timestamps.append(e["timestamp"])

    if num_turns == 0:
        return  # nothing model-side happened this turn (e.g. pure command)

    cost = (
        inp / 1e6 * PRICE_INPUT
        + out / 1e6 * PRICE_OUTPUT
        + cc / 1e6 * PRICE_CACHE_WRITE
        + cr / 1e6 * PRICE_CACHE_READ
    )

    dur_ms = 0
    if len(timestamps) >= 2:
        try:
            t0 = datetime.fromisoformat(timestamps[0].replace("Z", "+00:00"))
            t1 = datetime.fromisoformat(timestamps[-1].replace("Z", "+00:00"))
            dur_ms = int((t1 - t0).total_seconds() * 1000)
        except ValueError:
            dur_ms = 0

    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "agent": AGENT,
        "chat_id": CHAT_ID,
        "session": session_id,
        "model": model,
        "effort": DEFAULT_EFFORT,
        "input": inp,
        "output": out,
        "cache_creation": cc,
        "cache_read": cr,
        "window": window,
        "cost_usd": cost,
        "num_turns": num_turns,
        "dur_ms": dur_ms,
        # Stop fires 2-3x on long turns; same turn_start = same turn, replace not append
        "turn_start": timestamps[0] if timestamps else None,
    }
    USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
    if record["turn_start"] and USAGE_LOG.is_file():
        with USAGE_LOG.open("rb+") as fh:
            try:
                fh.seek(-8192, 2)
            except OSError:
                fh.seek(0)
            tail = fh.read().decode("utf-8", errors="ignore").splitlines()
            try:
                last = json.loads(tail[-1]) if tail else {}
            except json.JSONDecodeError:
                last = {}
            if (last.get("session") == session_id
                    and last.get("turn_start") == record["turn_start"]):
                fh.seek(0, 2)
                fh.truncate(fh.tell() - len(tail[-1].encode("utf-8")) - 1)
    with USAGE_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never disrupt the turn on a logging failure.
        pass
