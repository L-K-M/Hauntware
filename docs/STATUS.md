# Status

The initial desktop app and shared editor extraction are implemented. The
ownership boundaries and compatibility policies are documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Implemented

- One tabbed document window with New, Open, Save, Save As, Save All, Revert
  to Saved, Reopen Closed Tab, native desktop menus and guarded
  document/application close. One quit prompt covers several unsaved
  documents, and saving over a read-only file asks first.
- A single tab strip: dirty dots, middle-click close, Close Others and Close
  All, Copy Full Path, labels that tell same-named files apart by folder, and
  the active tab kept in view.
- Settings for theme (Parchment and Séance), text size and indentation, a
  command palette, and Export as HTML.
- Shared with Poltergeist and Séance: syntax highlighting including `.env`
  and diff, find/replace with whole-word search and paging past the highlight
  cap, Go to Line, Go to Matching Bracket, line commands, Toggle Comment, Tab
  indent and auto-indent, line numbers from the editor's own layout, real
  monospace fonts with zoom, undo/redo that stops at a reload, and document
  status. Known gaps from the integration, such as undo pressed in the same
  frame as a reload, are listed in ANALYSIS.md section 13.
- Bounded UTF-8 loading, BOM/EOL metadata, digest conflict checks, protected
  replacement/rollback and exclusive new-file publication.
- macOS Finder file-open events and Linux/Windows command-line file intake.
  Linux desktop entries pass selected files; Windows builds are portable.
- Desktop CI builds and a release pipeline for macOS, Linux and Windows.

## Verification

After the 2026-09-28 integration (ANALYSIS.md section 13), on Linux with
Flutter 3.47.2 / Dart 3.13.2, the versions CI uses:

- Core: analysis clean, 233 tests passed and 1 skipped.
- Shared editor: analysis clean, 194 tests passed.
- Standalone app: analysis clean, 327 tests passed and 2 skipped.
- `dart format` clean. CI runs the core suite on macOS, Linux and Windows,
  the shared editor and app suites on Linux, the app suite again on macOS and
  Windows, release builds on all three, and the macOS native keyboard and
  accessibility fixtures. All of it passed on #101, whose tree is the
  merged revision.

Earlier local checks on macOS (Flutter 3.47.3) also covered real macOS file
publication and Save As casing on case-insensitive temporary volumes.

The two host results below predate the integration; both hosts still need
to move to the current shared-editor revision.

- Poltergeist adapter: analysis clean, 58 core document/checkout and 90
  Flutter editor/window/localization/syntax/checkout tests passed. Real-font
  light/dark before-and-after captures are recorded in its adoption PR.
- Séance adapter: analysis clean, full Flutter suite passed 1,133 tests with
  two existing skips against the Git packages, using real capture fonts.

Cross-platform CI and final review results are recorded on the implementation
and adoption PRs. The local checks above do not claim Windows/Linux runtime
verification or a published release. The Windows window backdrop has not had
a native smoke test. No release tag has been created.

## Current limits

The standalone app is desktop-only, uses one tabbed window per process, and
does not restore documents after application exit. It accepts UTF-8 files up
to 4 MiB; highlighting stops above 200,000 characters. File conflict guards
are best-effort checks, not cross-process locks. Mixed line endings follow
the selected host normalization policy. Android hard-link publication limits
are documented in the core package; mobile runtime file I/O has not been
verified locally.
