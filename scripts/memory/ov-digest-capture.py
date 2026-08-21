#!/usr/bin/env python3
"""Stop hook: store a digest of the finished turn (clean ask + the answer the
user actually saw) into OpenViking. Replaces the plugin's auto-capture.mjs,
which stored every raw user message with its Telegram wrapper.

The hook itself returns instantly; the network work (session -> extract, ~5 s)
runs in a detached worker so the Stop event is never slowed down or timed out.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ov_memory import STATE_FILE, OVClient, last_turn, log, make_digest  # noqa: E402


def _state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state))


def capture(transcript_path: str, session_id: str, client: OVClient | None = None) -> list[str]:
    """Store the last turn once; returns URIs OpenViking created/edited."""
    turn = last_turn(transcript_path)
    if not turn:
        log("capture_skip", reason="no_turn")
        return []
    uuid, ask_raw, answer_raw = turn
    state = _state()
    if state.get(session_id) == uuid:
        log("capture_skip", reason="already_captured", uuid=uuid[:8])
        return []
    digest = make_digest(ask_raw, answer_raw)
    state[session_id] = uuid
    _save_state(state)  # mark first: a failed extract must not retry forever on every Stop
    if not digest:
        log("capture_skip", reason="noise_or_no_answer", uuid=uuid[:8], ask=ask_raw[:60])
        return []
    client = client or OVClient(timeout=60)
    uris = client.store_digest(digest)
    log("capture", uuid=uuid[:8], lesson=digest.lesson, ask=digest.ask[:80],
        uris=[u.split("/memories/", 1)[-1] for u in uris])
    return uris


def main() -> None:
    if len(sys.argv) >= 4 and sys.argv[1] == "--worker":
        try:
            capture(sys.argv[2], sys.argv[3])
        except Exception as exc:  # noqa: BLE001
            log("capture_error", error=str(exc)[:200])
        return
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    path, sid = data.get("transcript_path"), data.get("session_id", "")
    if not path or not os.path.exists(path):
        return
    subprocess.Popen([sys.executable, __file__, "--worker", path, sid],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


if __name__ == "__main__":
    main()
