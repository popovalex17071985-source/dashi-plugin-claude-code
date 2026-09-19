"""Tests for agent-kit/bin/dead-letter-digest.py -- the quarantine reader.

The script shipped with no tests: it was only ever syntax-checked. What matters
here is that it FINDS parked records, names them correctly, archives only the
old ones, and pings the owner exactly when something fresh showed up.
"""

import gzip
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
DIGEST_PATH = REPO_ROOT / "agent-kit" / "bin" / "dead-letter-digest.py"


def load_digest():
    module_name = "dead_letter_digest"
    loader = SourceFileLoader(module_name, str(DIGEST_PATH))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)
    return module


digest = load_digest()


def iso(delta: timedelta) -> str:
    return (datetime.now(timezone.utc) + delta).isoformat()


def write_record(directory: Path, name: str, payload, age: timedelta = timedelta(0)) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    if isinstance(payload, dict) and "ts" not in payload:
        payload = {"ts": iso(-age), **payload}
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


class QuarantineDiscoveryTest(unittest.TestCase):
    def test_finds_every_known_quarantine(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = Path(tmp)
            state = ws / "state" / "telegram"
            for bucket in ("updates", "webhook", "outbound", "albums"):
                (state / "dead-letter" / bucket).mkdir(parents=True)
            (state / "fallback-reply" / "undelivered").mkdir(parents=True)
            (state / "chats" / "-100500" / "outbox" / "dead-letter").mkdir(parents=True)

            names = [name for name, _ in digest.quarantine_dirs(ws)]

            self.assertEqual(
                names,
                [
                    "входящие/updates",
                    "входящие/webhook",
                    "входящие/outbound",
                    "входящие/albums",
                    "ответы/недоставленные",
                    "группа -100500",
                ],
            )

    def test_missing_directories_are_skipped_not_invented(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = Path(tmp)
            (ws / "state" / "telegram" / "dead-letter" / "updates").mkdir(parents=True)

            self.assertEqual(
                [name for name, _ in digest.quarantine_dirs(ws)], ["входящие/updates"]
            )

    def test_chat_without_outbox_dead_letter_is_not_listed(self):
        with tempfile.TemporaryDirectory() as tmp:
            ws = Path(tmp)
            (ws / "state" / "telegram" / "chats" / "-100777" / "outbox").mkdir(parents=True)

            self.assertEqual(digest.quarantine_dirs(ws), [])


class RecordAgeTest(unittest.TestCase):
    def test_prefers_own_timestamp_over_mtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_record(Path(tmp), "a.json", {"ts": "2026-06-21T10:00:00+00:00"})

            self.assertEqual(
                digest.record_age(path), datetime(2026, 6, 21, 10, 0, tzinfo=timezone.utc)
            )

    def test_accepts_zulu_suffix_and_first_failed_at(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "b.json"
            path.write_text(
                json.dumps({"first_failed_at": "2026-09-01T07:30:00Z"}), encoding="utf-8"
            )

            self.assertEqual(
                digest.record_age(path), datetime(2026, 9, 1, 7, 30, tzinfo=timezone.utc)
            )

    def test_naive_timestamp_is_read_as_utc_not_crashed_on(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_record(Path(tmp), "c.json", {"ts": "2026-09-01T07:30:00"})

            self.assertEqual(digest.record_age(path).tzinfo, timezone.utc)

    def test_falls_back_to_mtime_when_payload_has_no_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "d.json"
            path.write_text("{}", encoding="utf-8")

            age = digest.record_age(path)

            self.assertLess(abs((datetime.now(timezone.utc) - age).total_seconds()), 60)

    def test_unreadable_record_still_yields_a_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "e.json"
            path.write_text("{ not json", encoding="utf-8")

            self.assertIsInstance(digest.record_age(path), datetime)


class RecordKindTest(unittest.TestCase):
    def kind(self, payload) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            return digest.record_kind(path)

    def test_reason_wins(self):
        self.assertEqual(self.kind({"reason": "tmux session died"}), "tmux session died")

    def test_error_is_used_when_there_is_no_reason(self):
        self.assertEqual(self.kind({"error": "Telegram 429"}), "Telegram 429")

    def test_long_reason_is_trimmed_to_80(self):
        self.assertEqual(len(self.kind({"reason": "x" * 200})), 80)

    def test_callback_query_is_named(self):
        self.assertEqual(
            self.kind({"value": {"update": {"callback_query": {"id": "1"}}}}),
            "необработанный callback_query",
        )

    def test_unknown_update_shape_is_still_an_update(self):
        self.assertEqual(
            self.kind({"value": {"update": {"poll_answer": {}}}}), "необработанный апдейт"
        )

    def test_text_payload_is_an_unsent_reply(self):
        self.assertEqual(self.kind({"value": {"text": "привет"}}), "неотправленный ответ")

    def test_broken_json_is_reported_as_unreadable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.json"
            path.write_text("{{{", encoding="utf-8")

            self.assertEqual(digest.record_kind(path), "нечитаемая запись")

    def test_non_dict_json_is_unknown_format(self):
        self.assertEqual(self.kind([1, 2, 3]), "неизвестный формат")


class ArchiveTest(unittest.TestCase):
    def test_records_move_into_gzip_and_originals_disappear(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            paths = [write_record(src, f"{i}.json", {"reason": f"r{i}"}) for i in range(3)]
            target = Path(tmp) / "archive"

            moved = digest.archive("входящие/updates", paths, target)

            self.assertEqual(moved, 3)
            self.assertEqual([p for p in paths if p.exists()], [])
            out = list(target.glob("входящие-updates-*.jsonl.gz"))
            self.assertEqual(len(out), 1)
            with gzip.open(out[0], "rt", encoding="utf-8") as fh:
                rows = [json.loads(line) for line in fh if line.strip()]
            self.assertEqual([row["file"] for row in rows], ["0.json", "1.json", "2.json"])
            self.assertIn("r1", rows[1]["body"])

    def test_appending_twice_keeps_both_batches_in_one_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            target = Path(tmp) / "archive"
            digest.archive("группа -1", [write_record(src, "a.json", {"reason": "a"})], target)
            digest.archive("группа -1", [write_record(src, "b.json", {"reason": "b"})], target)

            out = list(target.glob("группа--1-*.jsonl.gz"))
            self.assertEqual(len(out), 1)
            with gzip.open(out[0], "rt", encoding="utf-8") as fh:
                self.assertEqual(len([line for line in fh if line.strip()]), 2)

    def test_empty_batch_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "archive"

            self.assertEqual(digest.archive("x", [], target), 0)
            self.assertFalse(target.exists())


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self.tmp.name)
        self.updates = self.ws / "state" / "telegram" / "dead-letter" / "updates"
        self.notified = self.ws / "notified.txt"
        sender = self.ws / "bin" / "tg-send.py"
        sender.parent.mkdir(parents=True, exist_ok=True)
        sender.write_text(
            "import sys, pathlib\n"
            f"pathlib.Path({str(self.notified)!r}).write_text(sys.argv[1], encoding='utf-8')\n",
            encoding="utf-8",
        )
        self.addCleanup(self.tmp.cleanup)

    def run_main(self, *argv):
        out = io.StringIO()
        with patch.object(sys, "argv", ["dead-letter-digest.py", "--workspace", str(self.ws), *argv]):
            with patch.object(sys, "stdout", out):
                code = digest.main()
        return code, out.getvalue()

    def test_empty_quarantines_report_nothing_and_do_not_ping(self):
        self.updates.mkdir(parents=True)

        code, out = self.run_main()

        self.assertEqual(code, 0)
        self.assertIn("карантины пустые", out)
        self.assertFalse(self.notified.exists())

    def test_fresh_record_pings_the_owner_with_counts(self):
        write_record(self.updates, "fresh.json", {"reason": "нет прав"}, age=timedelta(hours=2))

        _, out = self.run_main()

        self.assertIn("входящие/updates: всего 1, свежих 1", out)
        self.assertTrue(self.notified.exists())
        text = self.notified.read_text(encoding="utf-8")
        self.assertIn("1 свежих записей", text)
        self.assertIn("входящие/updates: 1 из 1", text)

    def test_stale_record_is_not_fresh_and_raises_no_alarm(self):
        write_record(self.updates, "old.json", {"reason": "старьё"}, age=timedelta(days=40))

        _, out = self.run_main("--archive-days", "90")

        self.assertIn("свежих 0", out)
        self.assertFalse(self.notified.exists())

    def test_quiet_suppresses_the_ping_but_keeps_the_report(self):
        write_record(self.updates, "fresh.json", {"reason": "свежак"}, age=timedelta(hours=1))

        _, out = self.run_main("--quiet")

        self.assertIn("свежих 1", out)
        self.assertFalse(self.notified.exists())

    def test_old_records_are_archived_and_removed(self):
        write_record(self.updates, "old.json", {"reason": "трёхмесячное"}, age=timedelta(days=95))
        write_record(self.updates, "new.json", {"reason": "вчерашнее"}, age=timedelta(hours=5))

        _, out = self.run_main("--archive-days", "30")

        self.assertIn("в архив 1", out)
        self.assertFalse((self.updates / "old.json").exists())
        self.assertTrue((self.updates / "new.json").exists())
        archive_dir = self.ws / "state" / "telegram" / "dead-letter" / "archive"
        self.assertEqual(len(list(archive_dir.glob("*.jsonl.gz"))), 1)

    def test_samples_are_read_before_archiving_not_after(self):
        # Regression: archive() unlinks the originals, so reading samples
        # afterwards reported every archived record as «нечитаемая запись».
        for i in range(2):
            write_record(
                self.updates, f"old{i}.json", {"reason": f"причина {i}"}, age=timedelta(days=95)
            )

        _, out = self.run_main("--archive-days", "30")

        self.assertIn("причина 1", out)
        self.assertNotIn("нечитаемая запись", out)

    def test_json_mode_emits_machine_readable_rows(self):
        write_record(self.updates, "a.json", {"reason": "сбой"}, age=timedelta(hours=3))

        _, out = self.run_main("--json", "--quiet")

        rows = json.loads(out)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["bucket"], "входящие/updates")
        self.assertEqual(rows[0]["total"], 1)
        self.assertEqual(rows[0]["fresh"], 1)
        self.assertEqual(rows[0]["samples"], ["сбой"])

    def test_only_json_and_failed_suffixes_are_counted(self):
        write_record(self.updates, "a.json", {"reason": "считается"}, age=timedelta(hours=1))
        write_record(self.updates, "b.failed", {"reason": "тоже"}, age=timedelta(hours=1))
        (self.updates / "README.md").write_text("не запись", encoding="utf-8")

        _, out = self.run_main("--json", "--quiet")

        self.assertEqual(json.loads(out)[0]["total"], 2)

    def test_run_is_appended_to_the_log(self):
        write_record(self.updates, "a.json", {"reason": "в лог"}, age=timedelta(hours=1))

        self.run_main("--quiet")
        self.run_main("--quiet")

        lines = (self.ws / "logs" / "dead-letter.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("входящие/updates", lines[0])

    def test_undelivered_answers_are_covered_too(self):
        undelivered = self.ws / "state" / "telegram" / "fallback-reply" / "undelivered"
        write_record(undelivered, "x.json", {"value": {"text": "ответ"}}, age=timedelta(hours=2))

        _, out = self.run_main("--json", "--quiet")

        rows = json.loads(out)
        self.assertEqual(rows[0]["bucket"], "ответы/недоставленные")
        self.assertEqual(rows[0]["samples"], ["неотправленный ответ"])


if __name__ == "__main__":
    unittest.main()
