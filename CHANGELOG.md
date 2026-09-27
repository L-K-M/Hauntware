# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Programmer's key commands in the shared editing surface: Tab inserts
  indentation (indenting every selected line), Shift+Tab outdents, Enter
  preserves the line's leading whitespace, Alt+ArrowUp/ArrowDown move the
  touched lines, and Shift+Alt+Arrow duplicates them.
- Standalone desktop editor for macOS, Linux and Windows, with document tabs,
  New/Open/Save/Save As, native menus, file-open events and guarded close/quit.
- Shared pure-Dart `planchette_core` and Flutter `planchette_editor` packages
  used by Poltergeist and Séance, including dotenv syntax, find/replace,
  line numbers and document status.
- Exclusive file creation, digest-guarded replacement and regression coverage
  for publication, rollback, save revisions and host lifecycle behavior.
- Repo scaffolding: Dart pub workspace, `packages/planchette_core` package
  skeleton, CI/release/review workflows, build/release/package scripts, and
  the agent operating manual.
