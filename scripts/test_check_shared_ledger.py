#!/usr/bin/env python3
"""Tests for scripts/check-shared-ledger.py."""

import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).resolve().parent / "check-shared-ledger.py"
SPEC = importlib.util.spec_from_file_location("check_shared_ledger", SCRIPT_PATH)
check_shared_ledger = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(check_shared_ledger)


class SharedLedgerTest(unittest.TestCase):
    def make_tree(self, source_text=None, copy_text=None, digest="same"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        ledger = root / "klabautermann/docs/SHARED.md"
        ledger.parent.mkdir(parents=True)
        ledger.write_text(
            "# Copied native code ledger\n"
            "\n"
            "Ledger prose stays outside the checked block.\n"
            "\n"
            "## Checked copies\n"
            "\n"
            "The check compares folded sources with their copies.\n"
            "\n"
            "```text\n"
            f"klabautermann/copy.txt seance/source.txt {digest}\n"
            "```\n",
            encoding="utf-8",
        )
        if source_text is not None:
            source = root / "seance/source.txt"
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(source_text, encoding="utf-8")
        if copy_text is not None:
            copy = root / "klabautermann/copy.txt"
            copy.parent.mkdir(parents=True, exist_ok=True)
            copy.write_text(copy_text, encoding="utf-8")
        return root, ledger

    def test_folding_renames_the_source_product(self):
        self.assertEqual(
            check_shared_ledger.fold_source_text(
                "Seance SEANCE seance Séance Poltergeist",
                "seance/app/file",
            ),
            "Klabautermann KLABAUTERMANN klabautermann Klabautermann Poltergeist",
        )
        self.assertEqual(
            check_shared_ledger.fold_source_text(
                "Poltergeist POLTERGEIST poltergeist Seance",
                "poltergeist/app/file",
            ),
            "Klabautermann KLABAUTERMANN klabautermann Seance",
        )

    def test_identical_folded_pair_checks_as_same(self):
        root, _ = self.make_tree(
            source_text="Seance settings\n",
            copy_text="Klabautermann settings\n",
        )
        output = io.StringIO()

        result = check_shared_ledger.check(root, output)

        self.assertEqual(result, 0)
        self.assertIn("checked 1 copy: all digests match", output.getvalue())

    def test_final_newline_difference_is_not_same(self):
        diff_text = check_shared_ledger.unified_diff_text("same text", "same text\n")

        self.assertNotEqual(check_shared_ledger.digest_for_diff(diff_text), "same")

    def test_mismatch_fails_and_prints_the_folded_diff(self):
        root, _ = self.make_tree(
            source_text="Seance old behavior\n",
            copy_text="Klabautermann new behavior\n",
        )
        output = io.StringIO()

        result = check_shared_ledger.check(root, output)

        self.assertEqual(result, 1)
        text = output.getvalue()
        self.assertIn("-Klabautermann old behavior", text)
        self.assertIn("+Klabautermann new behavior", text)
        self.assertIn("review the divergence", text)
        self.assertIn("scripts/check-shared-ledger.py --update", text)

    def test_missing_file_fails(self):
        root, _ = self.make_tree(copy_text="Klabautermann settings\n")
        output = io.StringIO()

        result = check_shared_ledger.check(root, output)

        self.assertEqual(result, 1)
        self.assertIn("missing source file", output.getvalue())
        self.assertIn("seance/source.txt", output.getvalue())

    def test_update_rewrites_only_the_digest(self):
        root, ledger = self.make_tree(
            source_text="Seance one behavior\n",
            copy_text="Klabautermann two behavior\n",
        )
        before = ledger.read_text(encoding="utf-8")
        output = io.StringIO()

        result = check_shared_ledger.update(root, output)

        self.assertEqual(result, 0)
        after = ledger.read_text(encoding="utf-8")
        before_lines = before.splitlines()
        after_lines = after.splitlines()
        self.assertEqual(len(before_lines), len(after_lines))
        changed = [
            (old, new)
            for old, new in zip(before_lines, after_lines)
            if old != new
        ]
        self.assertEqual(len(changed), 1)
        old_line, new_line = changed[0]
        self.assertEqual(
            old_line,
            "klabautermann/copy.txt seance/source.txt same",
        )
        self.assertRegex(
            new_line,
            r"^klabautermann/copy\.txt seance/source\.txt [0-9a-f]{16}$",
        )
        self.assertNotEqual(new_line, old_line)
        self.assertIn("updated 1 digest", output.getvalue())


if __name__ == "__main__":
    unittest.main()
