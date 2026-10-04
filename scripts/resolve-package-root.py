#!/usr/bin/env python3
"""Resolve a pub package's source root from .dart_tool/package_config.json.

pub writes each package's ``rootUri`` *relative to the package_config
file itself* for path dependencies, and as an absolute ``file://`` URI
for hosted and git pins. Treating the value as always-absolute (or
guessing a pub-cache layout) resolves one layout and breaks the other.

This resolves ``rootUri`` against the config file's own directory —
percent-decoding ``file://`` URIs — then walks upward until an ancestor
contains ``--require`` (the anchor that proves the source root, e.g.
``packages/seance_sync_server/Dockerfile``), failing loudly otherwise.

  scripts/resolve-package-root.py --package seance_core \
      --require packages/seance_sync_server/Dockerfile

prints the resolved source root. ``--self-test`` runs the resolver
against synthetic fixtures (relative, absolute, and percent-encoded
URIs; missing package; missing anchor) and exits non-zero on failure —
it needs no checkout and no Docker daemon.
"""

import argparse
import json
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse


def _fail(message):
    raise SystemExit(f"resolve-package-root: {message}")


def resolve_package_dir(config: Path, package: str) -> Path:
    try:
        data = json.loads(config.read_text())
    except OSError as error:
        _fail(f"cannot read {config}: {error}")
    match = next(
        (p for p in data.get("packages", []) if p.get("name") == package), None
    )
    if match is None:
        _fail(f"{package} not found in {config}; did dart pub get resolve it?")
    raw = match["rootUri"]
    parsed = urlparse(raw)
    if parsed.scheme == "":
        # Relative to the package_config file's own directory (path deps).
        resolved = (config.parent / unquote(parsed.path)).resolve()
    elif parsed.scheme == "file":
        resolved = Path(unquote(parsed.path)).resolve()
    else:
        _fail(f"{package} rootUri {raw!r} is not a file path")
    if not resolved.is_dir():
        _fail(f"{package} rootUri resolves to {resolved}, not a directory")
    return resolved


def resolve_source_root(package_dir: Path, require: str) -> Path:
    for ancestor in (package_dir, *package_dir.parents):
        if (ancestor / require).is_file():
            return ancestor
    _fail(f"no ancestor of {package_dir} contains {require}")


def self_test() -> int:
    failures = 0

    def check(label, got, want):
        nonlocal failures
        if got == want:
            print(f"ok   {label}")
        else:
            print(f"FAIL {label}: got {got}, want {want}", file=sys.stderr)
            failures += 1

    def check_fails(label, fn):
        nonlocal failures
        try:
            fn()
        except SystemExit:
            print(f"ok   {label}")
        else:
            print(f"FAIL {label}: expected a loud failure", file=sys.stderr)
            failures += 1

    anchor = "packages/seance_sync_server/Dockerfile"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        config_dir = tmp / "repo" / "poltergeist" / ".dart_tool"
        config_dir.mkdir(parents=True)
        config = config_dir / "package_config.json"

        def write_config(root_uri):
            config.write_text(
                json.dumps(
                    {"packages": [{"name": "seance_core", "rootUri": root_uri}]}
                )
            )

        # 1. Path dependency: rootUri relative to the config file.
        source = tmp / "repo" / "seance"
        (source / "packages" / "seance_core").mkdir(parents=True)
        (source / "packages" / "seance_sync_server").mkdir(parents=True)
        (source / anchor).write_text("FROM scratch\n")
        write_config("../../seance/packages/seance_core")
        check(
            "relative rootUri resolves against the config file",
            resolve_source_root(
                resolve_package_dir(config, "seance_core"), anchor
            ),
            source.resolve(),
        )

        # 2. Git pin in a cache: absolute file:// URI.
        cache_source = tmp / "cache" / "Seance-a1b2c3d4"
        (cache_source / "packages" / "seance_core").mkdir(parents=True)
        (cache_source / "packages" / "seance_sync_server").mkdir(parents=True)
        (cache_source / anchor).write_text("FROM scratch\n")
        write_config(
            "file://" + str(cache_source) + "/packages/seance_core"
        )
        check(
            "absolute file:// rootUri resolves",
            resolve_source_root(
                resolve_package_dir(config, "seance_core"), anchor
            ),
            cache_source.resolve(),
        )

        # 3. Percent-encoded characters (a space in the path).
        space_source = tmp / "with space" / "seance"
        (space_source / "packages" / "seance_core").mkdir(parents=True)
        (space_source / "packages" / "seance_sync_server").mkdir(parents=True)
        (space_source / anchor).write_text("FROM scratch\n")
        write_config(
            "file://" + str(space_source).replace(" ", "%20")
            + "/packages/seance_core"
        )
        check(
            "percent-encoded rootUri decodes before resolving",
            resolve_source_root(
                resolve_package_dir(config, "seance_core"), anchor
            ),
            space_source.resolve(),
        )

        # 4. Missing package entry fails closed.
        write_config("../../seance/packages/seance_core")
        check_fails(
            "unknown package fails",
            lambda: resolve_package_dir(config, "seance_nope"),
        )

        # 5. Resolved package whose tree lacks the anchor fails closed
        # (e.g. a hosted layout, which has no sibling packages/).
        hosted = tmp / "hosted" / "seance_core-1.0.0"
        hosted.mkdir(parents=True)
        write_config("file://" + str(hosted))
        check_fails(
            "missing anchor fails before any docker build",
            lambda: resolve_source_root(
                resolve_package_dir(config, "seance_core"), anchor
            ),
        )

    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("self-test: all fixture cases passed")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
    )
    parser.add_argument("--package")
    parser.add_argument(
        "--config",
        default=".dart_tool/package_config.json",
        type=Path,
        help="resolved package_config.json (default: %(default)s, relative to the working directory)",
    )
    parser.add_argument(
        "--require",
        help="anchor file that must exist under the printed source root",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.package or not args.require:
        parser.error("--package and --require are required")

    package_dir = resolve_package_dir(args.config, args.package)
    print(resolve_source_root(package_dir, args.require))
    return 0


if __name__ == "__main__":
    sys.exit(main())
