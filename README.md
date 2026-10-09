# Hauntware

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Current version:** v<!-- version -->1.9.0<!-- /version --> · [Releases](https://github.com/L-K-M/Hauntware/releases)

Free to use. Haunting included.

One repository, one version and one release cadence:

| Product | Purpose | Clients |
| --- | --- | --- |
| [Planchette](planchette/README.md) | Text editor and shared editor/UI packages | Linux, macOS, Windows |
| [Séance](seance/README.md) | SSH client and optional local terminal | Android, iOS, Linux, macOS, Windows |
| [Poltergeist](poltergeist/README.md) | File transfer and folder synchronization | Android, iOS, Linux, macOS, Windows |

Séance also supplies the shared encrypted sync server. Product names,
application IDs, storage locations and keystore namespaces stay distinct.

## Develop

Use Flutter **3.47.2** and its bundled Dart, Python 3 for history checks,
and the native toolchains documented in each product's `AGENTS.md`.
The sync-server tests also need the SQLite shared library.

```bash
scripts/test.sh dart       # Pure-Dart packages, guards and tooling
scripts/test.sh flutter    # Shared Flutter packages and applications
scripts/build.sh --check   # Inspect available products/toolchains
scripts/build.sh seance    # Build the selected product
scripts/build.sh --install # Build all three apps and install them (macOS: /Applications)
python3 scripts/check-history.py
```

Each project retains its pure-Dart workspace. Flutter packages resolve
separately; internal dependencies use local paths. Run commands in their
actual working directories and resolve dependencies sequentially.

## Release

`scripts/release.sh` uses the shared [release-tool](https://github.com/L-K-M/release-tool)
engine. It synchronizes all owned package/app versions, Android build codes,
Apple metadata, lockfiles and README markers. Child release scripts forward
to the whole suite.

Update `release-tool` before releasing: the required pre-tag hook refreshes
and commits the Séance provenance proof after the version-bump commit.

```bash
scripts/release.sh --check
scripts/release.sh 1.2.0 --push  # Explicit future release, not part of migration
```

One `vX.Y.Z` tag drives all 13 client targets, sync-server binaries and its
container image. One publish point follows every required test/build and
artifact/checksum check. Android keeps the existing committed sideload
signing keys; desktop bundles remain unsigned/ad-hoc and iOS bundles unsigned.
Vendored package versions and historical benchmark measurements stay intact.

## Migration and history

[Source history](docs/history/README.md) records the reviewed source heads,
407 captured refs and exact historical tag metadata. Full-history imports
retain original commit IDs; rejected/experimental trees remain historical.

The standalone repositories are archived. Their final releases point here,
so standalone installs see the suite release through their update check.
Séance 0.9.2, Poltergeist 1.0.1 and earlier used `com.lkm.*` application
IDs; suite builds use `ch.lkmc.*`, install as new apps and start without
the old apps' data. Séance's macOS sandbox migration covers only sandboxed
builds with the current bundle ID; see its [status](seance/docs/STATUS.md).
