# Status

The initial desktop app and shared editor extraction are implemented. The
ownership boundaries and compatibility policies are documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Implemented

- One tabbed document window with New, Open, Save, Save As, native desktop
  menus and guarded document/application close. The launch state is the empty
  state, which offers New and Open with their shortcuts.
- Syntax highlighting including `.env`, literal find/replace, line numbers,
  selection, undo/redo and document status shared with Poltergeist and Séance.
- Bounded UTF-8 loading, BOM/EOL metadata, digest conflict checks, protected
  replacement/rollback and exclusive new-file publication.
- macOS Finder file-open events and Linux/Windows command-line file intake.
  Linux desktop entries pass selected files; Windows builds are portable.
- Desktop CI builds and a release pipeline for macOS, Linux and Windows.

## Verification

Local checks use Flutter 3.47.3 / Dart 3.13.3 on macOS. CI uses Flutter 3.47.2.

- Core: analysis clean, 84 tests passed, including real macOS file publication
  and deterministic failure/race regressions.
- Shared editor: analysis clean, 19 controller/view tests passed, including
  save revisions, callback changes, disposal, find/replace, undo, input
  composition, editing locks and gutter reparenting.
- Standalone app: analysis clean and 40 document/menu/native-intake tests passed;
  macOS release build and native keyboard/accessibility fixtures passed.
  Save As casing checks also run on case-insensitive temporary volumes.
- Poltergeist adapter: analysis clean, 58 core document/checkout and 90
  Flutter editor/window/localization/syntax/checkout tests passed. Real-font
  light/dark before-and-after captures are recorded in its adoption PR.
- Séance adapter: analysis clean, full Flutter suite passed 1,133 tests with
  two existing skips against the Git packages, using real capture fonts.

Cross-platform CI and final review results are recorded on the implementation
and adoption PRs. The local checks above do not claim Windows/Linux runtime
verification or a published release. No release tag has been created.

## Current limits

The standalone app is desktop-only, uses one tabbed window per process, and
does not restore documents after application exit. It accepts UTF-8 files up
to 4 MiB in bytes; highlighting stops above 32,768 UTF-16 code units, above
which the status bar reads
`Large file`. The editing surface is a single-paragraph `TextField`, so cost
per keystroke still grows with file size: a plain 800 KB document takes a few
hundred milliseconds per keystroke in the Flutter test harness and would need
a viewport-limited surface to improve. File conflict guards
are best-effort checks, not cross-process locks. Mixed line endings follow
the selected host normalization policy. Android hard-link publication limits
are documented in the core package; mobile runtime file I/O has not been
verified locally.
