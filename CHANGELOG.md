# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- The menu bar and the tab strip were drawn in the middle of the window. A
  `Column` centres its children across the cross axis, and both of those
  shrink-wrap their content, so both landed in the centre.
- The find and replace fields had no outline, no fill and no surface of their
  own. In the dark theme they were bare text with a caret, on whatever happened
  to be behind them.
- The editor had no scrollbar. A field's own scrollable never gets one, so a
  document long enough to lose the caret in it gave nothing to drag.
- The status bar's position readout started under the line numbers instead of
  under the text.
- Two tooltips appeared at once when hovering a tab's close button: one on the
  tab and one on the button.
- A tab's ink splash painted a square over its rounded top corners.
- Launching created a blank buffer, so the empty state — the only screen
  offering New and Open — could not be seen without first closing the tab.

### Changed
- The window's top toolbar is gone. New, Open and Save are in the File menu
  with their shortcuts, the path is in the tab and the window title, and the
  status bar reports a running save. It spent 52 rows of the window repeating
  all of it.
- The window now has a real theme: flat dialogs, fast square tooltips, a thin
  always-visible scrollbar, and a menu bar with a baseline rule instead of
  floating on the surface.
- The tab strip keeps a fixed row height, clips its ink to the rounded tab
  shape, caps long names with an ellipsis, shows the dirty marker as an icon
  rather than a bullet character, and no longer grows a scrollbar that would
  clip the last tab's close button.
- The launch state is the empty state, which carries the two things worth
  doing and their shortcuts.
- Syntax highlighting now stops above 32,768 characters instead of
  200,000. The count is characters, not bytes, unlike the 4 MiB file limit.
  The editor surface lays out one span per token on every keystroke, and that
  cost was roughly an order of magnitude over the plain-text path; the status
  bar reads `Large file` when highlighting is off. Widening the limit needs an
  editor surface that lays out only the visible lines.
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
