# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Syntax highlighting now stops above 32 KiB instead of 200,000 characters.
  The editor surface lays out one span per token on every keystroke, and that
  cost was roughly an order of magnitude over the plain-text path; the status
  bar reads `Large file` when highlighting is off. Widening the limit needs an
  editor surface that lays out only the visible lines.
- Word wrap is off by default, with `View > Toggle Word Wrap` (`Alt+Z`) to
  turn it back on. Code is read by structure, and folding a long line hides
  the rest of the statement.

### Added
- Standalone desktop editor for macOS, Linux and Windows, with document tabs,
  New/Open/Save/Save As, native menus, file-open events and guarded close/quit.
- Shared pure-Dart `planchette_core` and Flutter `planchette_editor` packages
  used by Poltergeist and Séance, including dotenv syntax, find/replace,
  line numbers and document status.
- Exclusive file creation, digest-guarded replacement and regression coverage
  for publication, rollback, save revisions and host lifecycle behavior.
- Tab and Shift+Tab indent the selection, matching the file's own tabs or
  spaces, and padding to the next tab stop when the caret follows code.
- Repo scaffolding: Dart pub workspace, `packages/planchette_core` package
  skeleton, CI/release/review workflows, build/release/package scripts, and
  the agent operating manual.
