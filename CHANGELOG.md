# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Standalone desktop editor for macOS, Linux and Windows, with document tabs,
  New/Open/Save/Save As, native menus, file-open events and guarded close/quit.
- Shared pure-Dart `planchette_core` and Flutter `planchette_editor` packages
  used by Poltergeist and Séance, including dotenv syntax, find/replace,
  line numbers and document status.
- Exclusive file creation, digest-guarded replacement and regression coverage
  for publication, rollback, save revisions and host lifecycle behavior.
- Workspace errors are scoped to the document or operation that produced
  them: the matching success retires only its own failure, so a retried save
  or open clears a stale banner while unrelated failures stay visible, and
  the banner announces itself to screen readers.
- File Save All (`Ctrl+Alt+S` on Windows and Linux, `Cmd+Opt+S` on macOS)
  writes every dirty document in one action and reports partial failures as a
  single message naming what was written and what was not.
- Repo scaffolding: Dart pub workspace, `packages/planchette_core` package
  skeleton, CI/release/review workflows, build/release/package scripts, and
  the agent operating manual.
- Saving over a read-only file asks first: Save As… (the default), Save
  Anyway or Cancel. Save Anyway covers that file for the tab once the write
  succeeds, and on Windows the read-only attribute survives the save.
- Quitting with several unsaved documents asks one question that lists them
  (Don't Save, Cancel or Save All) instead of one dialog per document. Its
  Save All reports a partial failure the way File › Save All does.
- Diff and patch highlighting, plus Rust attributes and lifetimes, Go raw
  strings, JSON and YAML keys, C preprocessor lines and Python decorators.

### Changed
- Loading and saving a large file takes about half the time and a third of
  the peak memory.
- Save errors name their cause: an unwritable or deleted folder, or the
  operating system's error code when the original cannot be moved aside.
- A refused quit says what it is waiting for (a save, an open, a close or a
  dialog), and the notice clears itself once nothing blocks the quit.
- Opening several files reports every failure in one message; a single
  failure clears once that file opens.
- File › Close Tab follows the tab's close button: a loading or failed tab
  can close, a saving one cannot.
- The status bar says "1 line" and "1 byte".
- On Linux and Windows the window opens at its final size and position.

### Fixed
- A file whose name nearly fills the 255-byte limit can be saved.
- Saving text that contains a NUL character is refused instead of writing a
  file the editor would then refuse to open.
- A Save As requested while a save is running writes to the chosen file,
  and saves for one document run in the order they were requested.
- Startup arguments naming files that begin with `-` open, while options
  such as `--help` and those macOS injects are no longer opened as files.
- CSS and Rust highlighting no longer stall on a long line with no closing
  token.
- A case-insensitive find whose fold erases the whole query finds nothing
  instead of matching at every position.
- The Linux package's metadata describes Planchette, and a failed
  `objdump` stops the build instead of passing silently.
