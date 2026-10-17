# Planchette

A focused text editor, and the shared editor foundation for
[Poltergeist](https://github.com/L-K-M/Poltergeist) and
[Séance](https://github.com/L-K-M/Seance).

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The pointer that spells it out.*

**Current version:** v<!-- version -->1.9.1<!-- /version --> · [Releases](https://github.com/L-K-M/Hauntware/releases) (`planchette-*` assets)

Planchette edits UTF-8 text, configuration files, and scripts. Its
standalone desktop app provides document tabs, Open/New/Save/Save As,
find and replace, syntax highlighting, line numbers, and protection against
accidental loss of unsaved changes. The same editing surface is embedded in
the two host apps, which retain their own remote-file workflows.

**File > Open Folder** adds a resizable file browser beside the editor tabs.
**Open Containing Folder** adds it to an existing file window. Opening a file
directly starts with the editor alone.

**File > Open Server** connects to servers from your encrypted suite catalog.
Sign in with your existing sync account; credential import is optional.
Files load on demand over SSH/SFTP. Save writes a durable local copy, then
uploads with remote-change checks. Failed uploads stay marked as pending;
**Recover Remote Edits** reopens them after restart, including while offline.
**Save a Local Copy** exports the buffer without changing its remote target.

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

The standalone app targets macOS, Linux, and Windows. Server workspaces use
an optional existing sync account. It has no telemetry or updater.

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
