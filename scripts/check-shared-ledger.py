#!/usr/bin/env python3
"""Check Klabautermann's copied-native-file ledger against its sources."""

import argparse
import difflib
import hashlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
LEDGER_PATH = Path("klabautermann/docs/SHARED.md")
HEADING = "## Checked copies"
FENCE = "```text"
CLOSING_FENCE = "```"
DIGEST_PATTERN = re.compile(r"(?:same|[0-9a-f]{16})")
DIGEST_LINE_PATTERN = re.compile(r"(\s*\S+\s+\S+\s+)(\S+)(\s*)")

SEANCE_RENAMES = (
    ("SEANCE", "KLABAUTERMANN"),
    ("Seance", "Klabautermann"),
    ("seance", "klabautermann"),
    ("Séance", "Klabautermann"),
)
POLTERGEIST_RENAMES = (
    ("POLTERGEIST", "KLABAUTERMANN"),
    ("Poltergeist", "Klabautermann"),
    ("poltergeist", "klabautermann"),
)


class LedgerFormatError(ValueError):
    """The machine-readable ledger block is missing or malformed."""


@dataclass(frozen=True)
class LedgerEntry:
    copy_path: str
    source_path: str
    digest: str
    line_index: int


def fold_source_text(text, source_path):
    if source_path.startswith("poltergeist/"):
        renames = POLTERGEIST_RENAMES
    else:
        renames = SEANCE_RENAMES
    for old, new in renames:
        text = text.replace(old, new)
    return text


def unified_diff_text(source_text, copy_text):
    diff_lines = list(
        difflib.unified_diff(
            source_text.splitlines(keepends=True),
            copy_text.splitlines(keepends=True),
            fromfile="folded-source",
            tofile="copy",
            n=0,
        )
    )
    return "".join(diff_lines)


def digest_for_diff(diff_text):
    if not diff_text:
        return "same"
    return hashlib.sha256(diff_text.encode("utf-8")).hexdigest()[:16]


def _validate_relative_path(path, line_number):
    parsed = PurePosixPath(path)
    if parsed.is_absolute() or ".." in parsed.parts or not path:
        raise LedgerFormatError(
            f"line {line_number}: path is not repository-relative: {path}"
        )


def parse_ledger(text):
    lines = text.splitlines(keepends=True)
    heading_index = next(
        (index for index, line in enumerate(lines) if line.strip() == HEADING),
        None,
    )
    if heading_index is None:
        raise LedgerFormatError(f"{LEDGER_PATH}: missing `{HEADING}` section")

    fence_index = next(
        (
            index
            for index in range(heading_index + 1, len(lines))
            if lines[index].strip() == FENCE
        ),
        None,
    )
    if fence_index is None:
        raise LedgerFormatError(f"{LEDGER_PATH}: missing `{FENCE}` block")

    entries = []
    closing_index = None
    for index in range(fence_index + 1, len(lines)):
        stripped = lines[index].strip()
        if stripped == CLOSING_FENCE:
            closing_index = index
            break
        if not stripped:
            continue
        fields = stripped.split()
        line_number = index + 1
        if len(fields) != 3:
            raise LedgerFormatError(
                f"{LEDGER_PATH}:{line_number}: expected "
                "`<copy path> <source path> <digest>`"
            )
        copy_path, source_path, digest = fields
        _validate_relative_path(copy_path, line_number)
        _validate_relative_path(source_path, line_number)
        if not DIGEST_PATTERN.fullmatch(digest):
            raise LedgerFormatError(
                f"{LEDGER_PATH}:{line_number}: malformed digest `{digest}`"
            )
        entries.append(
            LedgerEntry(
                copy_path=copy_path,
                source_path=source_path,
                digest=digest,
                line_index=index,
            )
        )

    if closing_index is None:
        raise LedgerFormatError(f"{LEDGER_PATH}: unterminated `{FENCE}` block")
    return entries


def load_entries(root):
    ledger = root / LEDGER_PATH
    if not ledger.is_file():
        raise LedgerFormatError(f"missing ledger file: {LEDGER_PATH}")
    return parse_ledger(ledger.read_text(encoding="utf-8"))


def folded_diff(root, entry):
    source_text = (root / entry.source_path).read_text(encoding="utf-8")
    copy_text = (root / entry.copy_path).read_text(encoding="utf-8")
    folded_source = fold_source_text(source_text, entry.source_path)
    return unified_diff_text(folded_source, copy_text)


def missing_paths(root, entry):
    missing = []
    for kind, path in (("copy", entry.copy_path), ("source", entry.source_path)):
        if not (root / path).is_file():
            missing.append((kind, path))
    return missing


def _plural(count, singular, plural):
    return singular if count == 1 else plural


def _load_or_report(root, out):
    try:
        return load_entries(root)
    except (LedgerFormatError, OSError, UnicodeError) as error:
        print(f"error: {error}", file=out)
        return None


def check(root, out):
    entries = _load_or_report(root, out)
    if entries is None:
        return 1

    failures = 0
    for entry in entries:
        missing = missing_paths(root, entry)
        if missing:
            for kind, path in missing:
                print(
                    f"error: missing {kind} file for {entry.copy_path}: {path}",
                    file=out,
                )
                failures += 1
            continue

        try:
            diff_text = folded_diff(root, entry)
        except (OSError, UnicodeError) as error:
            print(f"error: {entry.copy_path}: {error}", file=out)
            failures += 1
            continue

        actual = digest_for_diff(diff_text)
        if actual == entry.digest:
            continue
        failures += 1
        print(
            f"error: {entry.copy_path}: ledger digest {entry.digest}, actual {actual}",
            file=out,
        )
        if diff_text:
            out.write(diff_text)
        else:
            print("folded diff is empty", file=out)
        print(
            "Next step: review the divergence, update the ledger table row "
            "(source commit, divergences), then run "
            "`scripts/check-shared-ledger.py --update`.",
            file=out,
        )

    noun = _plural(len(entries), "copy", "copies")
    if failures:
        failure_noun = _plural(failures, "failure", "failures")
        print(f"checked {len(entries)} {noun}: {failures} {failure_noun}", file=out)
        return 1
    print(f"checked {len(entries)} {noun}: all digests match", file=out)
    return 0


def _replace_digest(line, digest):
    ending = ""
    body = line
    if body.endswith("\r\n"):
        body, ending = body[:-2], "\r\n"
    elif body.endswith(("\n", "\r")):
        body, ending = body[:-1], body[-1]
    match = DIGEST_LINE_PATTERN.fullmatch(body)
    if match is None:
        raise LedgerFormatError("internal error: parsed ledger line no longer matches")
    return f"{match.group(1)}{digest}{match.group(3)}{ending}"


def update(root, out):
    ledger = root / LEDGER_PATH
    entries = _load_or_report(root, out)
    if entries is None:
        return 1

    failures = 0
    replacements = []
    for entry in entries:
        missing = missing_paths(root, entry)
        for kind, path in missing:
            print(f"error: missing {kind} file for {entry.copy_path}: {path}", file=out)
            failures += 1
        if missing:
            continue
        try:
            actual = digest_for_diff(folded_diff(root, entry))
        except (OSError, UnicodeError) as error:
            print(f"error: {entry.copy_path}: {error}", file=out)
            failures += 1
            continue
        if actual != entry.digest:
            replacements.append((entry, actual))

    if failures:
        failure_noun = _plural(failures, "failure", "failures")
        print(f"update aborted: {failures} {failure_noun}", file=out)
        return 1

    if replacements:
        text = ledger.read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        for entry, digest in replacements:
            lines[entry.line_index] = _replace_digest(lines[entry.line_index], digest)
        ledger.write_text("".join(lines), encoding="utf-8")

    digest_noun = _plural(len(replacements), "digest", "digests")
    print(f"updated {len(replacements)} {digest_noun} in {LEDGER_PATH}", file=out)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite stale digests in the checked-copies block",
    )
    args = parser.parse_args(argv)
    if args.update:
        return update(ROOT, sys.stdout)
    return check(ROOT, sys.stdout)


if __name__ == "__main__":
    raise SystemExit(main())
