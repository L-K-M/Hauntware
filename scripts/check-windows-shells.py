#!/usr/bin/env python3
"""Flag multi-line run scripts that a Windows leg would run under PowerShell.

A step without ``shell:`` runs under PowerShell on a Windows runner. A
one-line command such as ``dart pub get`` behaves the same there, but a
multi-line bash script (``set -euo pipefail``, ``case``, ``$(...)``)
does not even parse. In a job that can run on Windows (its header,
``runs-on`` or matrix, names ``windows``), every ``run: |`` or
``run: >`` step must therefore name its shell, or inherit bash from the
job's or workflow's ``defaults``, unless an ``if:`` limits it to another
platform (``== 'linux'``, ``startsWith(matrix.target, 'linux')``; a
``!=`` test does not count).

The workflows keep a fixed two-space layout (jobs at 2 spaces, job keys
at 4, steps at 6, step keys at 8); this reads that layout rather than
pulling in a YAML parser.

  scripts/check-windows-shells.py .github/workflows/*.yml

exits non-zero and names each offending step. ``--self-test`` runs the
check against synthetic workflows.
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

_BLOCK_SCALAR = re.compile(r"^[|>][-+]?\s*(#.*)?$")
_OTHER_PLATFORM = re.compile(
    r"(==\s*|startsWith\([^,]+,\s*)['\"](linux|macos|android|ios|ubuntu)", re.I
)


def _key(line: str, indent: int):
    """The ``key: value`` at exactly [indent] spaces, or None."""
    match = re.match(r"^ {%d}([A-Za-z0-9_-]+):(.*)$" % indent, line)
    return (match.group(1), match.group(2).strip()) if match else None


def _step_keys(step: list) -> dict:
    keys = {}
    first = re.match(r"^      - ([A-Za-z0-9_-]+):(.*)$", step[0])
    if first:
        keys[first.group(1)] = first.group(2).strip()
    for line in step[1:]:
        key = _key(line, 8)
        if key:
            keys.setdefault(key[0], key[1])
    return keys


def _has_bash_default(lines: list, indent: int) -> bool:
    """Whether a ``defaults:`` at [indent] makes ``run`` steps use bash."""
    inside = False
    for line in lines:
        if _key(line, indent) and _key(line, indent)[0] == "defaults":
            inside = True
            continue
        if inside:
            if line.strip() and not line.startswith(" " * (indent + 1)):
                inside = False
            elif _key(line, indent + 4) and _key(line, indent + 4)[0] == "shell":
                return _key(line, indent + 4)[1].split()[:1] in (["bash"], ["sh"])
    return False


def _gated_off_windows(condition: str) -> bool:
    if "!=" in condition or "windows" in condition.lower():
        return False
    return _OTHER_PLATFORM.search(condition) is not None


def violations(path: Path) -> list:
    lines = path.read_text(encoding="utf-8").split("\n")
    if _has_bash_default(lines, 0):
        return []
    starts = []
    in_jobs = False
    for index, line in enumerate(lines):
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        # A column-zero comment between jobs does not end the mapping.
        if in_jobs and re.match(r"^[^\s#]", line):
            in_jobs = False
        if in_jobs and _key(line, 2):
            starts.append(index)
    starts.append(len(lines))

    found = []
    for start, end in zip(starts, starts[1:]):
        block = lines[start:end]
        job = _key(block[0], 2)[0]
        steps_at = next(
            (i for i, line in enumerate(block) if _key(line, 4) == ("steps", "")),
            None,
        )
        if steps_at is None:
            continue
        header = [line for line in block[:steps_at] if not line.strip().startswith("#")]
        if "windows" not in "\n".join(header).lower():
            continue
        if _has_bash_default(header, 4):
            continue
        steps = []
        for offset, line in enumerate(block[steps_at + 1:], start + steps_at + 2):
            if line.startswith("      - "):
                steps.append((offset, [line]))
            elif steps:
                steps[-1][1].append(line)
        for line_no, step in steps:
            keys = _step_keys(step)
            run = keys.get("run")
            if run is None or not _BLOCK_SCALAR.match(run) or "shell" in keys:
                continue
            if _gated_off_windows(keys.get("if", "")):
                continue
            name = keys.get("name", "(unnamed step)")
            found.append(f"{path}:{line_no}: job {job}: step '{name}' runs a "
                         "multi-line script without shell: (PowerShell on Windows)")
    return found


def self_test() -> int:
    header = (
        "jobs:\n"
        "  leg:\n"
        "    runs-on: ${{ matrix.os }}\n"
        "    strategy:\n"
        "      matrix:\n"
        "        os: [ubuntu-latest, windows-latest]\n"
    )
    script = "        run: |\n          set -euo pipefail\n          echo hi\n"
    cases = {
        "unshelled script on a windows leg": (header + "    steps:\n      - name: S\n" + script, 1),
        "explicit shell": (header + "    steps:\n      - name: S\n        shell: bash\n" + script, 0),
        "one-line command": (header + "    steps:\n      - name: S\n        run: dart pub get\n", 0),
        "linux-only job": ("jobs:\n  leg:\n    runs-on: ubuntu-latest\n    steps:\n      - name: S\n" + script, 0),
        "gated to linux": (header + "    steps:\n      - name: S\n        if: matrix.target == 'linux'\n" + script, 0),
        "gated with startsWith": (header + "    steps:\n      - name: S\n        if: startsWith(matrix.target, 'linux')\n" + script, 0),
        "gated with !=": (header + "    steps:\n      - name: S\n        if: matrix.target != 'linux'\n" + script, 1),
        "gated to windows": (header + "    steps:\n      - name: S\n        if: runner.os == 'Windows'\n" + script, 1),
        "job default shell": (header + "    defaults:\n      run:\n        shell: bash\n    steps:\n      - name: S\n" + script, 0),
        "workflow default shell": ("defaults:\n  run:\n    shell: bash\n" + header + "    steps:\n      - name: S\n" + script, 0),
        "windows named only in a comment": ("jobs:\n  leg:\n    # not windows\n    runs-on: ubuntu-latest\n    steps:\n      - name: S\n" + script, 0),
        "comment between jobs": ("jobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n# windows legs\n  b:\n    runs-on: windows-latest\n    steps:\n      - name: S\n" + script, 1),
        "double-quoted linux gate": (header + "    steps:\n      - name: S\n        if: runner.os == \"Linux\"\n" + script, 0),
        "double-quoted windows gate": (header + "    steps:\n      - name: S\n        if: runner.os == \"Windows\"\n" + script, 1),
        "workflow default pwsh": ("defaults:\n  run:\n    shell: pwsh\n" + header + "    steps:\n      - name: S\n" + script, 1),
        "non-ASCII step name": (header + "    steps:\n      - name: Séance 👻\n" + script, 1),
        "folded script": (header + "    steps:\n      - name: S\n        run: >-\n          echo a\n          && echo b\n", 1),
    }
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for label, (text, want) in cases.items():
            path = Path(tmp) / "workflow.yml"
            path.write_text(text, encoding="utf-8")
            got = len(violations(path))
            if got != want:
                failures += 1
                print(f"self-test FAIL: {label}: {got} violation(s), want {want}",
                      file=sys.stderr)
    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: all fixture cases passed")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("workflows", nargs="*", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.workflows:
        parser.error("no workflow files given")
    found = [v for workflow in args.workflows for v in violations(workflow)]
    for violation in found:
        print(f"!! {violation}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
