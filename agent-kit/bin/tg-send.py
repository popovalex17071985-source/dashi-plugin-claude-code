#!/usr/bin/env python3
"""Send one Telegram message as the agent's own bot.

Reads the channel config the installer wrote (/etc/dashi-plugin/<agent>/channel.env),
so it works without the plugin runtime — cron jobs and hooks can talk to the owner
directly.

Usage: tg-send.py "text" [--html] [--chat <id>]
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ENV_FILE = pathlib.Path(
    os.environ.get("DASHI_CHANNEL_ENV", "/etc/dashi-plugin/__AGENT__/channel.env")
)


def config() -> tuple[str, str]:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("DASHI_CHAT_ID", "")
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            key, _, val = line.partition("=")
            if key == "TELEGRAM_BOT_TOKEN" and not token:
                token = val.strip()
            elif key == "TELEGRAM_ALLOWED_USER_IDS" and not chat:
                chat = val.strip().split(",")[0]
    return token, chat


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: tg-send.py <text> [--html] [--chat <id>]", file=sys.stderr)
        return 2
    text, argv = sys.argv[1], sys.argv[2:]
    token, chat = config()
    if "--chat" in argv:
        chat = argv[argv.index("--chat") + 1]
    if not token or not chat:
        print("tg-send: нет токена или chat_id", file=sys.stderr)
        return 1

    params = {"chat_id": chat, "text": text}
    if "--html" in argv:
        params["parse_mode"] = "HTML"
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = json.dumps(params).encode()
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=20).read()
    except urllib.error.HTTPError as e:
        # A malformed tag must not swallow the message — resend as plain text.
        if e.code == 400 and "parse_mode" in params:
            params.pop("parse_mode")
            urllib.request.urlopen(
                urllib.request.Request(url, data=json.dumps(params).encode(),
                                       headers={"Content-Type": "application/json"}),
                timeout=20).read()
        else:
            print(f"tg-send failed: {e}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
