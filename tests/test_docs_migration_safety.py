"""Docs safety tests for migration + troubleshooting docs (MED-F).

MED-F closes two docs-B findings from the medium codex review:

  docs-B1 #8 — docs/04-migration-from-gateway.md must not recommend
  `sudo rm -rf` against operator-owned paths as the canonical cleanup
  workflow. Public docs that teach `rm -rf ~/jarvis-...` set up
  future operators for the same self-destruction class of bug we
  already saw in docs/05 problem 8. Replace with archive (tar) +
  move (rename to .old) workflow. Optional cleanup against the
  `.old` rollback artefact stays, but only after explicit
  operator verification.

  docs-B2 #3 — docs/05-troubleshooting.md mixed current Bun-plugin
  problems with pre-cutover (Python gateway.py) migration problems
  without telling fresh installers which to skip. Split into
  «Section A — Current (Bun plugin)» and «Section B — Pre-cutover
  migration only (Python gateway.py) — applicable until 2026-06-15».

These tests fail if a future PR regresses either fix.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

MIGRATION_DOC = REPO_ROOT / "docs" / "04-migration-from-gateway.md"
TROUBLESHOOTING_DOC = REPO_ROOT / "docs" / "05-troubleshooting.md"


class MigrationDocRmRfSafetyTest(unittest.TestCase):
    """docs/04-migration-from-gateway.md must not teach `rm -rf ~/jarvis...`.

    Concretely: any `rm -rf` that targets the operator-owned source
    directory (`~/jarvis-telegram-gateway`, no `.old` suffix) is
    forbidden — it deletes the rollback artefact before the operator
    can verify the new plugin is stable. Allowed: `rm -rf` against
    `~/jarvis-telegram-gateway.old` inside an explicitly-marked
    optional-cleanup section.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = MIGRATION_DOC.read_text(encoding="utf-8")

    def test_no_destructive_rm_rf_against_source_directory(self) -> None:
        """`rm -rf ~/jarvis-telegram-gateway` (no .old) must not appear.

        We scan line-by-line so the assertion message points at the
        offending wording exactly.
        """
        forbidden_forms = (
            "rm -rf ~/jarvis-telegram-gateway\n",
            "rm -rf ~/jarvis-telegram-gateway ",
            "sudo rm -rf ~/jarvis-telegram-gateway\n",
            "sudo rm -rf ~/jarvis-telegram-gateway ",
        )
        hits: list[str] = []
        for token in forbidden_forms:
            if token in self.text:
                hits.append(token.rstrip("\n"))
        # Extra guard: any line that contains `rm -rf` followed by
        # `~/jarvis` but NOT `.old` is forbidden.
        for line in self.text.splitlines():
            stripped = line.strip()
            if "rm -rf" not in stripped:
                continue
            if "~/jarvis" not in stripped:
                continue
            if ".old" in stripped:
                continue
            hits.append(stripped)
        self.assertEqual(
            hits,
            [],
            f"{MIGRATION_DOC.name} still teaches destructive cleanup against "
            "the source `~/jarvis-telegram-gateway` directory. Replace with "
            "the archive (tar czf) + move (mv to .old) workflow; only the "
            "optional cleanup step may `rm -rf` the `.old` artefact. "
            "Offending lines:\n" + "\n".join(hits),
        )

    def test_archive_command_present(self) -> None:
        """The migration doc must teach `tar czf` archive as Step 7.1."""
        self.assertIn(
            "tar czf ~/jarvis-telegram-gateway-backup-",
            self.text,
            f"{MIGRATION_DOC.name} must contain the archive command "
            "`tar czf ~/jarvis-telegram-gateway-backup-$(date +%Y%m%d).tgz "
            "~/jarvis-telegram-gateway` so operators have a snapshot before "
            "moving the directory aside.",
        )

    def test_move_to_dot_old_workflow_present(self) -> None:
        """The doc must teach `mv ... .old` rather than `rm -rf`."""
        self.assertIn(
            "mv ~/jarvis-telegram-gateway ~/jarvis-telegram-gateway.old",
            self.text,
            f"{MIGRATION_DOC.name} must contain the `mv ~/jarvis-... .old` "
            "rename step. The `.old` directory is the rollback artefact — "
            "deleting in place removes the operator's safety net.",
        )

    def test_optional_cleanup_explicitly_marked(self) -> None:
        """If `rm -rf ~/jarvis-telegram-gateway.old` appears, it must
        be inside an explicitly-marked optional cleanup section."""
        if "rm -rf ~/jarvis-telegram-gateway.old" in self.text:
            # The opt-cleanup paragraph must mark this as optional and
            # gated on verification — explicit wording prevents the
            # next reader from copying the line in isolation.
            for marker in ("опционально", "Optional cleanup"):
                self.assertIn(
                    marker,
                    self.text,
                    f"{MIGRATION_DOC.name} contains `rm -rf "
                    "~/jarvis-telegram-gateway.old` but the surrounding "
                    f"section must mark it as optional (looked for `{marker}`). "
                    "Operators must know the `.old` directory is a rollback "
                    "artefact they may keep.",
                )


class TroubleshootingSplitStructureTest(unittest.TestCase):
    """docs/05-troubleshooting.md must split current / pre-cutover problems."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = TROUBLESHOOTING_DOC.read_text(encoding="utf-8")

    def test_section_a_header_present(self) -> None:
        self.assertIn(
            "Section A — Current (Bun plugin)",
            self.text,
            f"{TROUBLESHOOTING_DOC.name} must have a `Section A — Current "
            "(Bun plugin)` header that groups problems applicable to the "
            "current Bun + TypeScript plugin.",
        )

    def test_section_b_header_present(self) -> None:
        # The Pre-cutover header must include the date cutoff so readers
        # know when the section becomes obsolete.
        self.assertIn(
            "Pre-cutover",
            self.text,
            f"{TROUBLESHOOTING_DOC.name} must have a section header "
            "containing `Pre-cutover` that groups Python gateway.py "
            "migration-only problems.",
        )
        self.assertIn(
            "2026-06-15",
            self.text,
            f"{TROUBLESHOOTING_DOC.name} pre-cutover section must mention "
            "the 2026-06-15 cutoff date so fresh installers know when to "
            "ignore the section.",
        )

    def test_pre_cutover_when_to_read_note_present(self) -> None:
        """A skip-this-if-fresh-install note must appear with the section."""
        # The doctrine markers we expect either in the top intro or the
        # Section B header block: explicit "skip if installing fresh"
        # wording so readers do not waste time on irrelevant problems.
        markers = ("Skip if installing fresh", "skip if installing fresh")
        found = any(m in self.text for m in markers)
        self.assertTrue(
            found,
            f"{TROUBLESHOOTING_DOC.name} must contain a `Skip if installing "
            "fresh after 2026-06-15` note so fresh installers know the "
            "pre-cutover section does not apply to them.",
        )

    def test_toc_tags_current_and_pre_cutover(self) -> None:
        """The TOC must tag each problem with [current] or [pre-cutover]."""
        self.assertIn(
            "[current]",
            self.text,
            "TOC entries for Section A must be tagged `[current]` so the "
            "split is visible at a glance.",
        )
        self.assertIn(
            "[pre-cutover]",
            self.text,
            "TOC entries for Section B must be tagged `[pre-cutover]` so "
            "fresh installers see at a glance which entries to skip.",
        )

    def test_problem_3_lives_in_section_b(self) -> None:
        """Problem 3 (getUpdates conflict) must be after the Section B header."""
        section_b_idx = self.text.find("\n# Section B — Pre-cutover")
        self.assertGreater(
            section_b_idx,
            0,
            "Section B header missing — cannot locate Problem 3 placement.",
        )
        # The full Problem 3 block (with its body) must live after Section B.
        problem3_full_after_b = self.text.find(
            "## Проблема 3. `getUpdates conflict`",
            section_b_idx,
        )
        self.assertGreater(
            problem3_full_after_b,
            section_b_idx,
            "Problem 3 (`getUpdates conflict`) must be located inside "
            "Section B (Pre-cutover migration only) — it only happens "
            "during the legacy gateway.py cutover window.",
        )
        # And the same header must NOT appear BEFORE Section B (i.e. the
        # old in-place copy was removed, only the Section B copy remains).
        problem3_full_before_b = self.text.rfind(
            "## Проблема 3. `getUpdates conflict`",
            0,
            section_b_idx,
        )
        self.assertEqual(
            problem3_full_before_b,
            -1,
            "Problem 3 body must NOT be duplicated in Section A — move "
            "it entirely to Section B; a redirect note in Section A is OK.",
        )

    def test_problem_6_lives_in_section_b(self) -> None:
        """Problem 6 (state loss on migration) must be after the Section B header."""
        section_b_idx = self.text.find("\n# Section B — Pre-cutover")
        self.assertGreater(
            section_b_idx,
            0,
            "Section B header missing — cannot locate Problem 6 placement.",
        )
        problem6_full_after_b = self.text.find(
            "## Проблема 6. Потеря состояния при миграции",
            section_b_idx,
        )
        self.assertGreater(
            problem6_full_after_b,
            section_b_idx,
            "Problem 6 (state loss on migration) must be located inside "
            "Section B — it is specific to the migration window.",
        )
        problem6_full_before_b = self.text.rfind(
            "## Проблема 6. Потеря состояния при миграции",
            0,
            section_b_idx,
        )
        self.assertEqual(
            problem6_full_before_b,
            -1,
            "Problem 6 body must NOT be duplicated in Section A — move "
            "it entirely to Section B; a redirect note in Section A is OK.",
        )

    def test_current_bun_problems_stay_in_section_a(self) -> None:
        """Sanity: at least one current-Bun problem (e.g. Problem 1) lives
        BEFORE Section B so the split is meaningful."""
        section_b_idx = self.text.find("\n# Section B — Pre-cutover")
        problem1_idx = self.text.find(
            "## Проблема 1. Сервис «active», но Telegram не отвечает"
        )
        self.assertGreater(
            problem1_idx,
            0,
            "Problem 1 missing from troubleshooting doc.",
        )
        self.assertLess(
            problem1_idx,
            section_b_idx,
            "Problem 1 (current Bun-plugin issue) must stay in Section A, "
            "before the Section B (Pre-cutover) header.",
        )


if __name__ == "__main__":
    unittest.main()
