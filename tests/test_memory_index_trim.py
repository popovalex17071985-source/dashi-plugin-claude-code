"""Тесты сторожа индекса памяти (agent-kit/bin/memory-index-trim.py).

Индекс подгружается в каждую сессию целиком, поэтому ошибка дорогая в обе
стороны: не ужал -- агент молча теряет хвост памяти; ужал лишнего -- потерял
ссылку и дорогу к факту. Проверяем оба края.

  python3 tests/test_memory_index_trim.py
"""
from __future__ import annotations

import importlib.util
import pathlib
import re
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "memory_index_trim", str(ROOT / "agent-kit" / "bin" / "memory-index-trim.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

LINK = re.compile(r"\(([A-Za-z0-9_\-]+\.md)\)")


def big(n: int = 260) -> str:
    """Индекс заведомо больше лимита."""
    head = "# Memory index\n\nТолько АКТИВНОЕ.\n\n## Раздел\n"
    rows = [f"- [Тема номер {i} с довольно длинным названием](file-{i}.md) — "
            f"пояснение {i}, которое тянется и тянется и занимает много места в строке "
            f"индекса, хотя подробности лежат в самом файле памяти\n" for i in range(n)]
    return head + "".join(rows)


def links(p: pathlib.Path) -> set[str]:
    return set(LINK.findall(p.read_text(encoding="utf-8"))) if p.exists() else set()


class TrimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, text: str) -> pathlib.Path:
        d = self.tmp / "projects" / "agent" / "memory"
        d.mkdir(parents=True, exist_ok=True)
        p = d / "MEMORY.md"
        p.write_text(text, encoding="utf-8")
        return p

    def test_small_index_untouched(self):
        p = self.write("# Memory index\n\n- [Тема](a.md) — короткий хвост\n")
        before = p.read_text(encoding="utf-8")
        self.assertIn("в норме", M.trim(p, apply=True))
        self.assertEqual(p.read_text(encoding="utf-8"), before)

    def test_oversized_gets_under_limit(self):
        p = self.write(big())
        self.assertGreater(M.size(p.read_text(encoding="utf-8")), M.LIMIT)
        M.trim(p, apply=True)
        self.assertLessEqual(M.size(p.read_text(encoding="utf-8")), M.LIMIT)

    def test_no_link_is_lost(self):
        p = self.write(big())
        had = links(p)
        M.trim(p, apply=True)
        self.assertEqual(had - (links(p) | links(p.with_name("MEMORY-archive.md"))), set())

    def test_dry_run_changes_nothing(self):
        p = self.write(big())
        before = p.read_text(encoding="utf-8")
        self.assertIn("нужен --apply", M.trim(p, apply=False))
        self.assertEqual(p.read_text(encoding="utf-8"), before)
        self.assertFalse(p.with_name("MEMORY-archive.md").exists())

    def test_archive_is_appended_not_overwritten(self):
        p = self.write(big())
        arch = p.with_name("MEMORY-archive.md")
        arch.write_text("# Memory archive\n\n- [Старое](old-topic.md) — прошлый вынос\n",
                        encoding="utf-8")
        M.trim(p, apply=True)
        body = arch.read_text(encoding="utf-8")
        self.assertIn("old-topic.md", body, "прошлый архив затёрли")
        self.assertIn("Снято с активного индекса", body)

    def test_squeeze_keeps_name_and_link(self):
        long = ("- [Очень длинное имя темы, которое само тянет на половину строки]"
                "(some-memory-file.md) — и ещё хвост на сотню символов, который можно "
                "резать без потери навигации, подробности всё равно в файле")
        out = M.squeeze(long)
        self.assertLessEqual(M.size(out), M.LINE_MAX)
        self.assertIn("(some-memory-file.md)", out)
        self.assertTrue(out.startswith("- [Очень длинное имя"))

    def test_line_without_tail_survives(self):
        row = "- [A](a.md) · [B](b.md) · [C](c.md)"
        self.assertEqual(M.squeeze(row), row)

    def test_headings_are_not_touched(self):
        p = self.write(big())
        M.trim(p, apply=True)
        self.assertIn("## Раздел", p.read_text(encoding="utf-8"))

    def test_second_run_is_idempotent(self):
        p = self.write(big())
        M.trim(p, apply=True)
        once = p.read_text(encoding="utf-8")
        self.assertIn("в норме", M.trim(p, apply=True))
        self.assertEqual(p.read_text(encoding="utf-8"), once)

    def test_no_indexes_does_not_crash(self):
        home = pathlib.Path.home
        pathlib.Path.home = staticmethod(lambda: self.tmp / "empty")
        try:
            self.assertEqual(M.indexes(), [])
            self.assertEqual(M.main(), 0)
        finally:
            pathlib.Path.home = home


if __name__ == "__main__":
    unittest.main(verbosity=2)
