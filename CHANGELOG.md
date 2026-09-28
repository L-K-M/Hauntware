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
