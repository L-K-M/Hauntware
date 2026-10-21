#!/usr/bin/env python3
"""Select the product CI jobs a pull request needs.

Each product (Planchette, Séance, Poltergeist, Klabautermann) has its own
build and test jobs. A pull request needs them only when it changes a
package the product reaches through pubspec path dependencies:

  klabautermann/app/...             -> klabautermann
  seance/app/...                    -> seance
  seance/packages/seance_core/...   -> every product (all depend on it)
  docs/design/...                   -> none (shared gates only)
  .github/workflows/ci.yml          -> every product (fail open)

A product workspace root (e.g. ``seance/pubspec.yaml``) owns every file
outside its member packages, so ``seance/CHANGELOG.md`` selects Séance
alone. Files outside all packages select every product, except the docs
and root tooling that only the shared, ungated jobs read.

  scripts/ci-affected-products.py BASE HEAD

prints ``<product>=true|false`` lines for ``$GITHUB_OUTPUT`` and, on
stderr, why each product was selected. ``--all`` selects every product
(main pushes and manual runs). ``--check-references`` fails when a
product file names another product's path, relative or quoted from
the repo root, that neither the dependency graph nor ``_FILE_READERS``
covers.
``--self-test`` checks the rules against a synthetic graph.
"""

import argparse
import posixpath
import re
import subprocess
import sys

PRODUCTS = ("planchette", "seance", "poltergeist", "klabautermann")

# Paths only the ungated jobs read: the history gate (`contracts`), the
# version markers (`suite_tool`) and the root guards (`dart_tools`).
# Packages under tool/ (tool/l10n_contract) still select their dependents.
_UNGATED_PREFIXES = ("docs/", "tool/")

# Files one product reads from another outside pub. Prefix -> readers.
_FILE_READERS = {
    # klabautermann/test/integration mounts Poltergeist's sshd fixture
    # config and runs its check_config.dart.
    "poltergeist/test/integration/": ("klabautermann",),
}

# `../../seance/packages/seance_core` or `'poltergeist/test/x'` in a
# product file.
_PRODUCT_REFERENCE = re.compile(
    r"(?:(?:\.\./)+|['\"])((?:%s)/[^\s'\"`:,;)\]}]*)" % "|".join(PRODUCTS)
)

# A pubspec `path:` key, block or flow style (`b: {path: ../b}`). A
# dependency *named* path (`path: ^1.9.1`) matches too; its value is a
# version, never a relative path.
_PATH_KEY = re.compile(
    r"(?:^[ \t]+|[{,][ \t]*)path[ \t]*:[ \t]*['\"]?([^'\"\s#,}]+)", re.M
)


def _normalize(path: str) -> str:
    path = posixpath.normpath(path)
    return "" if path == "." else path


def _product(path: str):
    head = path.split("/", 1)[0]
    return head if head in PRODUCTS else None


def path_dependencies(pubspecs: dict) -> tuple:
    """Map each package directory to the package directories it depends on.

    ``pubspecs`` maps pubspec paths to their text. Returns the graph and
    the dependencies that name no known package.
    """
    packages = {_normalize(posixpath.dirname(p)) for p in pubspecs}
    graph = {package: set() for package in packages}
    unresolved = []
    for pubspec, text in pubspecs.items():
        package = _normalize(posixpath.dirname(pubspec))
        for value in _PATH_KEY.findall(text):
            if "/" not in value and not value.startswith("."):
                continue
            target = _normalize(posixpath.join(package, value))
            if target in packages:
                graph[package].add(target)
            else:
                unresolved.append(f"{pubspec}: {value}")
    return graph, unresolved


def _owner(path: str, graph: dict):
    """The deepest package containing ``path``; the repo root never owns."""
    while path:
        if path in graph:
            return path
        path = posixpath.dirname(path)
    return None


def affected_products(changed, graph: dict) -> dict:
    """Map each product the changed paths reach to the first reason."""
    dependents = {package: set() for package in graph}
    for package, targets in graph.items():
        for target in targets:
            dependents[target].add(package)

    selected = {}

    def select(product, reason):
        selected.setdefault(product, reason)

    for path in changed:
        for prefix, readers in _FILE_READERS.items():
            if path.startswith(prefix):
                for reader in readers:
                    select(reader, f"{path} (read outside pub)")

        owner = _owner(path, graph)
        if owner is None:
            if path.startswith(_UNGATED_PREFIXES):
                continue
            if "/" not in path and path.endswith(".md"):
                continue
            for product in PRODUCTS:
                select(product, f"{path} (outside every package)")
            continue

        # Reverse closure: the owner and every package reaching it.
        reached, pending = {owner}, [owner]
        while pending:
            for dependent in dependents[pending.pop()]:
                if dependent not in reached:
                    reached.add(dependent)
                    pending.append(dependent)
        for package in reached:
            product = _product(package)
            if product:
                select(product, f"{path} (via {package})")
    return selected


def _git(*args) -> str:
    return subprocess.run(
        ("git", *args), check=True, capture_output=True, text=True
    ).stdout


def _pubspecs(*revisions) -> dict:
    """Pubspec texts across revisions, so removed packages still count."""
    texts = {}
    for revision in revisions:
        for path in _git("ls-tree", "-r", "--name-only", revision).splitlines():
            if path != "pubspec.yaml" and not path.endswith("/pubspec.yaml"):
                continue
            text = _git("show", f"{revision}:{path}")
            texts[path] = texts.get(path, "") + "\n" + text
    return texts


def check_references() -> int:
    """Fail on cross-product relative paths the selection would miss."""
    graph, _ = path_dependencies(_pubspecs("HEAD"))

    # git grep pre-filters lines; exit status 1 only means no match.
    grep = subprocess.run(
        (
            "git", "grep", "-I", "-z", "-E",
            r"(\.\./|['\"])(%s)/" % "|".join(PRODUCTS),
            "--", *PRODUCTS, ":!*.md",
        ),
        capture_output=True,
        text=True,
    )
    if grep.returncode > 1:
        raise SystemExit(f"ci-affected-products: git grep failed: {grep.stderr}")

    missed = 0
    for line in grep.stdout.splitlines():
        source, text = line.split("\0", 1)
        reader = _product(source)
        for match in _PRODUCT_REFERENCE.finditer(text):
            target = match.group(1).rstrip("/")
            if _product(target) == reader:
                continue
            if reader in affected_products([target], graph):
                continue
            print(
                f"!! {source} reads {target}, but changes there do not "
                f"select {reader}; add it to _FILE_READERS",
                file=sys.stderr,
            )
            missed += 1
    return 1 if missed else 0


def self_test() -> int:
    pubspecs = {
        "pubspec.yaml": "dependencies:\n  path: ^1.9.1\n",
        "seance/pubspec.yaml": "workspace:\n  - packages/proto\n",
        "seance/packages/proto/pubspec.yaml": "",
        "seance/app/s/pubspec.yaml": (
            "dependencies:\n  core:\n    path: ../../../planchette/packages/core\n"
        ),
        "planchette/packages/core/pubspec.yaml": (
            "dependencies:\n  proto:\n    path: '../../../seance/packages/proto'\n"
        ),
        "planchette/app/p/pubspec.yaml": (
            "dependencies:\n"
            "  core:\n    path: ../../packages/core # shared\n"
            "  pcore:\n    path: ../../../poltergeist/packages/pcore\n"
        ),
        "poltergeist/pubspec.yaml": "",
        "poltergeist/packages/pcore/pubspec.yaml": (
            "dependencies:\n  proto:\n    path: ../../../seance/packages/proto\n"
        ),
        "klabautermann/app/k/pubspec.yaml": (
            "dependencies:\n"
            "  core:\n    path: ../../../planchette/packages/core\n"
            "  l10n:\n    path: ../../../tool/l10n\n"
        ),
        "tool/l10n/pubspec.yaml": "",
    }
    graph, unresolved = path_dependencies(pubspecs)
    everything = set(PRODUCTS)
    cases = {
        "klabautermann/app/k/lib/main.dart": {"klabautermann"},
        "seance/app/s/lib/main.dart": {"seance"},
        "seance/packages/proto/lib/proto.dart": everything,
        "seance/packages/proto": everything,
        "seance/CHANGELOG.md": {"seance"},
        "poltergeist/packages/pcore/lib/core.dart": {"planchette", "poltergeist"},
        "poltergeist/test/integration/sshd-common/config/x": {
            "poltergeist",
            "klabautermann",
        },
        "tool/l10n/lib/scan.dart": {"klabautermann"},
        "tool/guards.yaml": set(),
        "docs/design/plan.md": set(),
        "README.md": set(),
        ".github/workflows/ci.yml": everything,
        "scripts/build.sh": everything,
        "pubspec.yaml": everything,
    }
    failures = 0
    if unresolved:
        print(f"FAIL unexpected unresolved {unresolved}", file=sys.stderr)
        failures += 1
    for path, want in cases.items():
        got = set(affected_products([path], graph))
        if got == want:
            print(f"ok   {path}")
            continue
        print(f"FAIL {path}: got {sorted(got)}, want {sorted(want)}", file=sys.stderr)
        failures += 1

    _, unresolved = path_dependencies(
        {"a/pubspec.yaml": "dependencies:\n  b:\n    path: ../b\n"}
    )
    if unresolved != ["a/pubspec.yaml: ../b"]:
        print(f"FAIL unknown target not reported: {unresolved}", file=sys.stderr)
        failures += 1

    flow, _ = path_dependencies(
        {
            "a/pubspec.yaml": "dependencies:\n  b: {path: ../b}\n  c:\n    path : ../c\n",
            "b/pubspec.yaml": "",
            "c/pubspec.yaml": "",
        }
    )
    if flow["a"] != {"b", "c"}:
        print(f"FAIL flow-style path keys: {sorted(flow['a'])}", file=sys.stderr)
        failures += 1

    references = {
        "import '../../../seance/packages/x/lib/a.dart';": "seance/packages/x/lib/a.dart",
        "read('poltergeist/test/integration/c.dart')": "poltergeist/test/integration/c.dart",
    }
    for line, want in references.items():
        got = [m.group(1) for m in _PRODUCT_REFERENCE.finditer(line)]
        if got != [want]:
            print(f"FAIL reference in {line!r}: got {got}", file=sys.stderr)
            failures += 1

    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: all cases passed")
    return 0


def _print_selection(selected: dict) -> None:
    for product in PRODUCTS:
        reason = selected.get(product)
        print(f"{product}={'true' if reason else 'false'}")
        print(f"{product}: {reason or 'unaffected'}", file=sys.stderr)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("base", nargs="?")
    parser.add_argument("head", nargs="?")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--check-references", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if args.check_references:
        return check_references()
    if args.all:
        _print_selection({product: "full run" for product in PRODUCTS})
        return 0
    if not args.base or not args.head:
        parser.error("BASE and HEAD are required")

    graph, unresolved = path_dependencies(_pubspecs(args.base, args.head))
    if unresolved:
        reason = f"unresolved path dependency {unresolved[0]}"
        _print_selection({product: reason for product in PRODUCTS})
        return 0

    changed = _git(
        "diff", "--name-only", "--no-renames", "-z", args.base, args.head
    ).split("\0")
    _print_selection(affected_products([p for p in changed if p], graph))
    return 0


if __name__ == "__main__":
    sys.exit(main())
