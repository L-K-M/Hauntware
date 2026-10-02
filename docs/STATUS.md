# Status

The initial desktop app and shared editor extraction are implemented. The
ownership boundaries and compatibility policies are documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Implemented

- One tabbed document window with New, Open, Save, Save As, Save All, Revert
  to Saved, Reopen Closed Tab, native desktop menus and guarded
  document/application close. One quit prompt covers several unsaved
  documents, and saving over a read-only file asks first. Outside changes
  are checked when the window regains focus: unedited documents reload in
  place, and edited, deleted or moved ones show a notice.
- A single tab strip in the sibling apps' shape: dirty dots, middle-click
  close, Close Others and Close All, Copy Full Path, labels that tell
  same-named files apart by folder, and the active tab kept in view.
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
- Text menu groups, palette keywords/paths, an inline options bar, Repeat and
  Recent, and a result notice with Undo. The catalog contains 48 menu tools
  plus Extract Matches. The find bar supports Keep/Delete Lines Matching,
  Extract and a stored Find in Selection scope. A shared catalog browser
  (Repeat and Recent first, the seven groups with descriptions, keyword
  filter) opens from `controller.openTextTools()` and from the app's Text
  menu; hosts add one header icon each on adoption.
- Clickable app status segments for indentation, LF/CRLF and UTF-8 BOM, with
  metadata-aware dirty state. Opt-in trim/final-newline save settings and
  Normalize Line Endings. Remaining host/deferred work is recorded in
  [TEXT_TOOLS.md](TEXT_TOOLS.md#remaining-work-slices-5c-7-and-8).

## Verification

### Text-column tool integration, 2026-10-02

On the integrated tree with the browser, Unicode/JSON, Edit/File and search
slices: core 565 tests, editor 393 tests, app 406 tests pass locally. App has
the two existing case-sensitive-volume skips. All analysis and format checks
are clean. Hard Wrap and full tab expansion cover text-cell widths, CRLF,
backward selections, comment/quote prefixes, protected lists and early output
limits. A conditional saved-EOL policy matches raw-buffer host preflight
without changing the host's save bytes. CI/review results are on the PR.

### Text tools slice 8 (Unicode/ASCII/JSON), 2026-10-01

Local Linux checks with Flutter 3.47.2 / Dart 3.13.2:

- Core: analysis clean, 490 tests passed (44 new). Compose Accents
  (NFC), Decompose Accents (NFD) and Strip Diacritics run through
  `unorm_dart`, new in core; Convert to ASCII uses a small Latin
  table and keeps unmapped non-ASCII literal with a count.
  Format/Minify JSON reformat whitespace only, keep number and
  string literals verbatim, and refuse invalid input with line and
  column. Output size stays capped by the existing runner preflight.
- Shared editor: analysis clean, 324 tests passed (3 new: JSON
  size cap, JSON line/column refusal, Unicode run scope).
- App: analysis clean, 402 tests passed; two case-insensitive-volume
  tests skipped on this case-sensitive host.
- `dart format` and `git diff --check` clean.
- Replacement backslash escapes are untouched. Hard Wrap and
  Convert Tabs to Spaces stay deferred on B8.

### Text tools through slice 6, 2026-10-01

Local Linux checks with Flutter 3.47.2 / Dart 3.13.2:

- Core: analysis clean, 446 tests passed.
- Shared editor: analysis clean, 321 tests passed.
- App: analysis clean, 402 tests passed; two case-insensitive-volume tests
  skipped on this case-sensitive host.
- `dart format` and `git diff --check` clean.
- New checks cover exact EOL/BOM bytes, untitled Save As, reload, conflict
  rejection, undo/redo cleanup, concurrent typing, composition refusal and
  narrow status controls at doubled text scale. Independent save-path review
  found no important defects. Cross-platform CI is recorded on the PR.

### Text tools browser (slice 7), 2026-10-02

Local Linux checks with Flutter 3.47.2 / Dart 3.13.2:

- Core: analysis clean, 446 tests passed (unchanged).
- Shared editor: analysis clean, 345 tests passed (24 new: browser state,
  dispatch, filter, 320 px width, doubled text scale, keyboard, headings,
  focus and lock).
- App: analysis clean, 403 tests passed (1 new menu-entry test); two
  case-insensitive-volume tests skipped on this case-sensitive host.
- `dart format` and `git diff --check` clean. Cross-platform CI is recorded
  on the PR.

### Integration baseline, 2026-09-28

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
