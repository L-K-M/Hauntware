# Planchette

A focused text editor, and the shared editor foundation for
[Poltergeist](https://github.com/L-K-M/Poltergeist) and
[Séance](https://github.com/L-K-M/Seance).

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The pointer that spells it out.*

**Current version:** v<!-- version -->1.1.0<!-- /version --> · [Releases](https://github.com/L-K-M/Planchette/releases)

Planchette edits local UTF-8 text, configuration files, and scripts. Its
standalone desktop app provides document tabs, Open/New/Save/Save As,
find and replace, syntax highlighting, line numbers, and protection against
accidental loss of unsaved changes. The same editing surface is embedded in
the two host apps, which retain their own remote-file workflows.

## Development

Use Flutter 3.47.2 or newer; CI is pinned to 3.47.2. The pure core package
needs only Dart 3.12 or newer. See [AGENTS.md](AGENTS.md) for package tests.

```sh
cd app/planchette_app
flutter pub get
flutter run -d macos   # or linux / windows
```

From the repository root, `scripts/build.sh` builds and stages the current
desktop platform under `dist/`. Add `--install` to install on macOS or Linux;
the Windows build is portable.

The standalone app targets macOS, Linux, and Windows. It has no account,
network service, telemetry, or updater.

## Shared packages

| Package | Purpose |
|---|---|
| `planchette_core` | Syntax, search, UTF-8 document metadata, and guarded file writes, without Flutter |
| `planchette_editor` | The reusable Flutter editing controller and surface |

Changes to these packages reach Poltergeist and Séance through reviewed
dependency updates. [Architecture](docs/ARCHITECTURE.md) describes ownership,
host adapters, and file-safety contracts. [Status](docs/STATUS.md) records the
checks actually completed and current limitations.

The editor accepts UTF-8 files up to 4 MiB. Syntax highlighting is disabled
above 200,000 characters to keep editing responsive. It preserves UTF-8 BOM
and dominant line-ending metadata; it does not preserve each mixed line
ending independently. External-change guards are best-effort filesystem
checks, not a lock on other programs.

## License

[Unlicense](LICENSE), matching both sibling applications. Initial editor
code was extracted from Poltergeist and Séance; provenance is recorded in
the architecture document.
