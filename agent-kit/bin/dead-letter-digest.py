#!/usr/bin/env python3
"""Consumer for the channel quarantines: nobody was reading them.

19.09.2026: the bridge parks whatever it could not deliver or could not parse --
inbound updates, webhook payloads, answers killed with their tmux session,
answers whose send never confirmed. Four separate quarantines, and not one of
them had a reader: 82 records sat in `dead-letter/updates` from 21.06 unseen for
three months. A quarantine no one reads is the same as /dev/null with extra
steps.

This is the reader. It walks every known quarantine, reports what is in there
(kind, age, why), archives records older than ARCHIVE_DAYS into a gzipped
JSONL so the directories stay small, and pings the owner when something FRESH
appears -- fresh meaning «happened since yesterday», which is the only case a
human needs to act on.

Deliberately does NOT replay records. A three-month-old callback_query cannot be
re-answered (Telegram expires them) and a replayed inbound would wake the agent
about a conversation nobody remembers. Replay belongs to the specific hooks that
own each payload; this tool's job is visibility plus housekeeping.

Usage:
  dead-letter-digest.py [--workspace DIR] [--archive-days N] [--quiet] [--json]
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

FRESH_HOURS = 36
DEFAULT_ARCHIVE_DAYS = 30
MAX_SAMPLES = 3


def workspace_default() -> Path:
    env = os.environ.get("AGENT_WORKSPACE")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def quarantine_dirs(workspace: Path) -> list[tuple[str, Path]]:
    """Every place the bridge parks something it could not deliver."""
    found: list[tuple[str, Path]] = []
    state = workspace / "state" / "telegram"
    for bucket in ("updates", "webhook", "outbound", "albums"):
        path = state / "dead-letter" / bucket
        if path.is_dir():
            found.append((f"входящие/{bucket}", path))
    undelivered = state / "fallback-reply" / "undelivered"
    if undelivered.is_dir():
        found.append(("ответы/недоставленные", undelivered))
    chats = state / "chats"
    if chats.is_dir():
        for chat_dir in sorted(chats.iterdir()):
            path = chat_dir / "outbox" / "dead-letter"
            if path.is_dir():
                found.append((f"группа {chat_dir.name}", path))
    return found


def record_age(path: Path) -> datetime:
    """Timestamp of a record: its own `ts` when present, else mtime."""
    try:
        with path.open("r", encoding="utf-8") as fh:
            obj = json.load(fh)
        for key in ("ts", "first_failed_at", "timestamp"):
            raw = obj.get(key) if isinstance(obj, dict) else None
            if isinstance(raw, str):
                parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                return parsed
    except (OSError, ValueError, TypeError):
        pass
    try:
        return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    except OSError:
        return datetime.now(timezone.utc)


def record_kind(path: Path) -> str:
    """One short phrase saying what this record is, for the digest."""
    try:
        obj = json.load(path.open("r", encoding="utf-8"))
    except (OSError, ValueError):
        return "нечитаемая запись"
    if not isinstance(obj, dict):
        return "неизвестный формат"
    value = obj.get("value") if isinstance(obj.get("value"), dict) else obj
    reason = value.get("reason") or value.get("error")
    if isinstance(reason, str) and reason:
        return reason[:80]
    update = value.get("update") if isinstance(value.get("update"), dict) else None
    if update:
        for key in ("callback_query", "message", "edited_message", "my_chat_member"):
            if key in update:
                return f"необработанный {key}"
        return "необработанный апдейт"
    if "text" in value:
        return "неотправленный ответ"
    return "запись без опознавательных знаков"


def archive(bucket: str, paths: list[Path], target_dir: Path) -> int:
    """Fold old records into one gzipped JSONL per bucket+month, then remove."""
    if not paths:
        return 0
    moved = 0
    target_dir.mkdir(parents=True, exist_ok=True)
    slug = bucket.replace("/", "-").replace(" ", "-")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m")
    out = target_dir / f"{slug}-{stamp}.jsonl.gz"
    try:
        with gzip.open(out, "at", encoding="utf-8") as fh:
            for path in paths:
                try:
                    body = path.read_text(encoding="utf-8")
                except OSError:
                    continue
                fh.write(json.dumps({"file": path.name, "body": body}, ensure_ascii=False) + "\n")
                try:
                    path.unlink()
                    moved += 1
                except OSError:
                    pass
    except OSError:
        return moved
    return moved


def notify(workspace: Path, text: str) -> None:
    sender = workspace / "bin" / "tg-send.py"
    if not sender.exists():
        sender = workspace / "bin" / "tg-notify.py"
    if not sender.exists():
        return
    try:
        subprocess.run([sys.executable, str(sender), text], check=False, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default=None)
    ap.add_argument("--archive-days", type=int, default=DEFAULT_ARCHIVE_DAYS)
    ap.add_argument("--quiet", action="store_true", help="не звать владельца")
    ap.add_argument("--json", action="store_true", help="машинный вывод")
    args = ap.parse_args()

    workspace = Path(args.workspace) if args.workspace else workspace_default()
    now = datetime.now(timezone.utc)
    fresh_cut = now - timedelta(hours=FRESH_HOURS)
    old_cut = now - timedelta(days=args.archive_days)
    archive_dir = workspace / "state" / "telegram" / "dead-letter" / "archive"

    report: list[dict[str, object]] = []
    fresh_total = 0
    for bucket, path in quarantine_dirs(workspace):
        try:
            files = [p for p in path.iterdir() if p.is_file() and p.suffix in (".json", ".failed")]
        except OSError:
            continue
        if not files:
            continue
        dated = sorted(((record_age(p), p) for p in files), key=lambda pair: pair[0])
        fresh = [p for ts, p in dated if ts >= fresh_cut]
        old = [p for ts, p in dated if ts < old_cut]
        # Read the samples BEFORE archiving: archive() unlinks the originals, and
        # reading them afterwards reported every archived record as unreadable.
        samples = [record_kind(p) for _, p in dated[-MAX_SAMPLES:]]
        archived = archive(bucket, old, archive_dir) if old else 0
        fresh_total += len(fresh)
        report.append(
            {
                "bucket": bucket,
                "total": len(files),
                "fresh": len(fresh),
                "archived": archived,
                "oldest": dated[0][0].isoformat(),
                "samples": samples,
            }
        )

    log_path = workspace / "logs" / "dead-letter.log"
    stamp = now.astimezone().strftime("%d.%m %H:%M")
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    elif not report:
        print("карантины пустые")
    else:
        for row in report:
            print(
                f"{row['bucket']}: всего {row['total']}, свежих {row['fresh']}, "
                f"в архив {row['archived']}, самая старая {str(row['oldest'])[:10]}"
            )
            for sample in row["samples"]:  # type: ignore[union-attr]
                print(f"    - {sample}")
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {json.dumps(report, ensure_ascii=False)}\n")
    except OSError:
        pass

    if fresh_total and not args.quiet:
        lines = [f"Карантин канала: {fresh_total} свежих записей за последние сутки-полтора."]
        for row in report:
            if row["fresh"]:
                lines.append(f"{row['bucket']}: {row['fresh']} из {row['total']}")
        lines.append("Разбор: bin/dead-letter-digest.py --json")
        notify(workspace, "\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
