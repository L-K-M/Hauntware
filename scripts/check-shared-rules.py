#!/usr/bin/env python3
"""Verify each product AGENTS.md carries the root shared-rules block.

The root AGENTS.md holds the suite's working rules between
`<!-- shared-rules:start -->` and `<!-- shared-rules:end -->`; every
product AGENTS.md repeats them between the same markers, so an agent
started in a subtree reads the same rules as one started at the root.
A subtree edit that drifts from root is exactly what this gate catches.

Run from anywhere; the repository root is the script's parent directory.
Exits non-zero on a missing or differing block.
"""

from pathlib import Path
import difflib
import sys

ROOT = Path(__file__).resolve().parent.parent
START = "<!-- shared-rules:start -->"
END = "<!-- shared-rules:end -->"
PRODUCTS = ("klabautermann", "seance", "poltergeist", "planchette")


def shared_block(path):
    lines = path.read_text().splitlines()
    starts = [index for index, line in enumerate(lines) if line == START]
    ends = [index for index, line in enumerate(lines) if line == END]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ValueError(f"{path}: expected one {START} before one {END}")
    return lines[starts[0] + 1 : ends[0]]


canonical = shared_block(ROOT / "AGENTS.md")
failed = False
for name in PRODUCTS:
    path = ROOT / name / "AGENTS.md"
    try:
        actual = shared_block(path)
    except (OSError, ValueError) as error:
        print(f"!! {error}", file=sys.stderr)
        failed = True
        continue
    if actual == canonical:
        continue
    failed = True
    print(
        f"!! {name}/AGENTS.md shared rules differ from root AGENTS.md",
        file=sys.stderr,
    )
    diff = difflib.unified_diff(
        canonical,
        actual,
        fromfile="AGENTS.md (root)",
        tofile=f"{name}/AGENTS.md",
        lineterm="",
    )
    print("\n".join(diff), file=sys.stderr)

if failed:
    print("shared agent rules FAILED", file=sys.stderr)
    raise SystemExit(1)
print(f"Shared agent rules match in {len(PRODUCTS)} subtrees")
