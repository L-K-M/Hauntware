# Working on Planchette

Planchette is the shared text editor for Planchette, Poltergeist, and Séance.
Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing package
boundaries and [docs/STATUS.md](docs/STATUS.md) for verified capabilities.

## Layout

- `packages/planchette_core`: pure Dart syntax, search, document metadata,
  and guarded local-file reads and writes. No Flutter or SSH dependency.
- `packages/planchette_editor`: Flutter editor controller and surface, with
  host-supplied strings, styling, and file actions.
- `app/planchette_app`: the standalone desktop application.
- `scripts`: local builds and native regression checks.

The two host apps consume Git-pinned packages from this repository. Shared
editor behavior belongs here; application windows, tabs, remote connections,
managed checkouts, uploads, and conflict dialogs belong to the host.

## Development

Use Dart 3.12 or newer and Flutter 3.47.2 (the CI pin). Resolve and test each
package from its own directory. The core must remain testable without Flutter.

```sh
cd packages/planchette_core
dart pub get
dart analyze
dart test

cd ../planchette_editor
flutter pub get
flutter analyze
flutter test

cd ../../app/planchette_app
flutter pub get
flutter analyze
flutter test
```

Fetch first and branch from current `origin/main`. Preserve unrelated local
work. Keep changes focused, inspect the diff, and commit only intended files.
Commit subjects are imperative; include a co-author trailer and session link,
without model identifiers. Changes finish through reviewed, green PRs merged
to main, unless the user explicitly chooses another end state.

Reproduce bugs with a regression before fixing them. In particular, preserve
new edits made during an asynchronous save, refuse unexpected disk changes,
retain unsaved documents when close is cancelled, and run post-save host
bookkeeping even if the view has closed. Never silently follow a symlink in
a managed checkout. Keep temporary plaintext owner-only on supported systems.

Run relevant tests and analysis after the final edit. Cross-cutting editor
changes also require the consumers' integration tests. State which platforms
and native behavior were verified; a widget capture is not a native screenshot.
