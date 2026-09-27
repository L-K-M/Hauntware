# Planchette analysis and backlog

A working backlog for Planchette: review findings, follow-ups, and ideas.
Each open item is written so that an agent can pick it up without
rediscovering the context: why it matters, where the code is, what to
change, and how to know it is done. Read [AGENTS.md](AGENTS.md) first.

- Baselines reviewed: `main` at `d53f416`, again at `a580387`, and again
  at `e974cde` (2026-09-27). Toolchain: Flutter 3.47.2 / Dart 3.13.4. At
  `d53f416` and at `e974cde`: core 84 tests, the editor 19 and the app 38
  (2 skipped), all green.
- **All timing numbers in this document are milliseconds per keystroke in
  the `flutter test` harness**, which runs Dart in the VM without AOT. A
  release build is several times faster; the *scaling* is what carries over.
  Anything quoted as a measurement was taken on the same machine back to
  back against `main`, not compared across sessions.
- Evidence labels: **confirmed** means reproduced with a test or probe.
  **Read** means found by reading code or Flutter/Skia sources but not
  observed on a real desktop. **Idea** means a suggestion.
- Effort: S (under an hour), M (half a day), L (days). Risk is the chance
  of regressions in hosts (Poltergeist, Séance) or native behavior.
- When you finish an item, delete it here in the same PR, and add a
  CHANGELOG line. An item that is *mostly* done by a PR keeps its
  heading and its "still open" list, so the next agent does not
  re-derive what is left.

**How to get a toolchain in a fresh container.** Neither Dart nor Flutter is
installed. The dev container has no `unzip` and no `xz`, so extract with
Python rather than `unzip`/`tar`:

```sh
mkdir -p ~/sdk && cd ~/sdk
curl -sSL -o dart.zip https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip
python3 -c "import zipfile; zipfile.ZipFile('dart.zip').extractall('.')"
export PATH=~/sdk/dart-sdk/bin:$PATH

curl -sSL -o flutter.tar.xz https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.2-stable.tar.xz
python3 -c "import tarfile; tarfile.open('flutter.tar.xz').extractall('.')"
export PATH=~/sdk/flutter/bin:$PATH   # after ~3 min
```

Pin 3.47.2 or newer: the editor's pubspec requires `>=3.47.2`, so a 3.47.1
SDK fails to resolve and the error names the version rather than the cause.
Then:

```sh
(cd packages/planchette_core && dart pub get && dart analyze && dart test)
(cd packages/planchette_editor && flutter pub get && flutter analyze && flutter test)
(cd app/planchette_app && flutter pub get && flutter analyze && flutter test)
```

## Contents

0. [Do not regress this](#0-do-not-regress-this)
1. [In review](#1-in-review): findings already addressed by open PRs
2. [Follow-ups to the open PRs](#2-follow-ups-to-the-open-prs)
3. [Bugs](#3-bugs)
4. [Performance](#4-performance), including a **measured dead end** worth
   reading before starting on the metrics
5. [Editing features](#5-editing-features)
6. [App features](#6-app-features)
7. [Platform integration](#7-platform-integration)
8. [Visual design and theming](#8-visual-design-and-theming)
9. [Delightful and quirky ideas](#9-delightful-and-quirky-ideas)
10. [Process and documentation](#10-process-and-documentation)

---

## 0. Do not regress this

Almost everything below is additive. This part is not. It was measured
rather than assumed, so read it before "simplifying" any of it.

**The file-safety core is the strongest part of this repository and it
holds up.** Tested directly against `LocalDocumentStore` and the temp
directory:

- A load / edit / save / reload round trip preserves the bytes and the digest.
- A stale digest is refused with a plain-language message, the on-disk file
  is left exactly as the other writer left it, and no `.planchette-*`
  sibling leaks.
- A `Save As` onto the current path still goes through the conflict guard
  rather than bypassing it.
- BOM and CRLF survive a save byte for byte: `[EF BB BF] a CRLF b CRLF c CRLF`.
- A file with a NUL byte is rejected as binary; a missing file, a directory
  and an unresolvable path each produce their own message.

**The dirty-close machinery is careful**: a discard decision is
revision-checked, a save begun from a native menu while a dialog was pending
is re-checked, and a failed native window destruction does not leave the
workspace locked. Do not "simplify" `_confirmTab` or `EditorSaveResult`.

**The performance architecture is right; the constants were wrong.**
`CodeEditingController` memoizes tokenization, the gutter repaints through a
`Listenable` rather than a rebuild, and `EditorController` owns a
`revealRequest` counter so the view can act on a reveal without the
controller knowing anything about scrolling. #28's problem was that the
memoization keyed on `identical(text)`, which is always false after an edit
because every edit produces a fresh `String` — not that the design was
wrong.

**The tests are the asset.** 84 / 22 / 45 at the second baseline, all green,
and the file-safety regressions include real publication, rollback and
race cases. Any change to `planchette_core`'s write path needs a new test
before it needs a refactor.

---

## 1. In review

These findings have PRs open against `main`, left for the owner's review.
If a PR is closed without merging, move its findings back into the
sections below. The problem statements live in the PR descriptions, and
are summarized in the table.

The table was accurate when this document was last updated. **More PRs
have been opened since, by other agents working in parallel, and are not
listed.** Run `gh pr list` before assuming an item below is unstarted;
several backlog entries here are also covered by an unlisted PR.

| PR | Addresses |
|---|---|
| [L-K-M/Planchette#14](https://github.com/L-K-M/Planchette/pull/14) | Tab moved focus out of the editor, so you couldn't indent at all (**confirmed**). Adds Tab/Shift+Tab indent and outdent, Enter keeps indentation, Backspace removes a level, indentation detection in core, `EditorTabKeyBehavior`, and tabs rendered at indentation width instead of one space |
| [L-K-M/Planchette#17](https://github.com/L-K-M/Planchette/pull/17) | Every keystroke and caret move rebuilt the whole shell, re-sent the window title, and re-serialized the native macOS menu (**confirmed**). Also `isDirty` O(n) per call |
| [L-K-M/Planchette#22](https://github.com/L-K-M/Planchette/pull/22) | The gutter laid out the whole document a second time per edit, and numbers drifted from soft-wrapped lines above 200k chars (**confirmed**). Adds a current-line band |
| [L-K-M/Planchette#26](https://github.com/L-K-M/Planchette/pull/26) | A save conflict said "Reopen it" but reopening was impossible and there was no Revert. Adds on-focus change detection, a Reload / Keep Mine notice, recreate-on-save for deleted files, and File › Revert to Saved |
| [L-K-M/Planchette#30](https://github.com/L-K-M/Planchette/pull/30) | `fontFamily: 'monospace'` is Courier on Apple and likely proportional on Windows (**read**). Adds a per-platform monospace stack and View › Zoom In/Out/Actual Size |
| [L-K-M/Planchette#31](https://github.com/L-K-M/Planchette/pull/31) | Rust lifetimes swallowed lines as strings (**confirmed**), Go raw strings, backslashes in shell/SQL/YAML single quotes, JSON/YAML keys, C preprocessor, Rust attributes, Python decorators, and a diff/patch language |
| [L-K-M/Planchette#33](https://github.com/L-K-M/Planchette/pull/33) | Go to Line (Cmd+L / Ctrl+G, and a clickable status position). Find shortcuts per platform: Ctrl chords no longer shadow macOS text bindings. Status shows the on-disk byte count (CRLF + BOM), language display names and a selection summary |
| [L-K-M/Planchette#39](https://github.com/L-K-M/Planchette/pull/39) | Loading a 3.9 MB file cost about 450 ms on the UI isolate (**confirmed**, measured). Byte buffers instead of `List<int>`, and a loop instead of two regexes for the line-ending census: load 453 → 178 ms, peak memory 124 → 37 MB |
| [L-K-M/Planchette#41](https://github.com/L-K-M/Planchette/pull/41) | Curated Parchment (light) and Séance (dark) themes with AA-checked syntax colors and a warm selection color. `EditorSyntaxTheme` becomes a `ThemeExtension` hosts can set once |
| [L-K-M/Planchette#35](https://github.com/L-K-M/Planchette/pull/35) | The Linux/Windows menu bar and tab strip were centered mid-window (**confirmed**). Merges the toolbar into one tab strip with a dirty dot and close on hover, middle-click close, Cmd/Ctrl+1…9, the active tab kept in view, wheel scrolling, and "Untitled"/"Untitled 2" naming |

From the second review pass, on three further branches:

| PR | Addresses |
|---|---|
| [#21](https://github.com/L-K-M/Planchette/pull/21) `fix/review-correctness` | **Tab could not be typed at all** (**confirmed**): the document is a bare `TextField`, so Flutter routed Tab to focus traversal, and pressing it moved focus out of the editor and inserted nothing. Adds `insertIndent` / `removeIndent` / `measureIndentation` to `planchette_core`, Tab and Shift+Tab in the editor matching the file's own tabs or spaces, and padding to the next tab stop when the caret follows code. Also: **Find Next was a dead key whenever the find bar was closed** (**confirmed** — `F3` after Escape did nothing), now reopens the bar with the remembered query; **a missing or unresolvable file surfaced as a raw `PathNotFoundException` naming the syscall and errno**; the toolbar printed the empty state's marketing line next to any untitled document; and opening three files made the next new document "Untitled 4". Core 113 tests, editor 31, app 39 + 2 skipped |
| [#28](https://github.com/L-K-M/Planchette/pull/28) `perf/keystroke-cost` | **The gutter re-laid out the whole document on every keystroke and then asked for one caret offset per line** (**confirmed**: 59.0 ms layout + 124.3 ms of `getOffsetForCaret` for 5,001 lines, against 9.1 ms for a single `computeLineMetrics`). One metrics call replaces the caret loop; revealing a match reads the cached tops instead of measuring. **Highlighting cost roughly an order of magnitude over the plain floor** (79 KB JSON: 12,001 spans, 11 ms to build the tree, 70 ms to lay it out, against 35 ms plain), so the cap moves from 200,000 characters to 32 KiB and the status bar says `Large file` instead of silently dropping colours. See P1 and P3 for what is left |
| [#36](https://github.com/L-K-M/Planchette/pull/36) `ui/window-chrome` | **The menu bar and tab strip were drawn in the middle of the window** (**confirmed**: a `Column` centres its children across the cross axis and both shrink-wrap — the `MenuBar` measured x 537–863 in a 1400 px window, the first tab label started at x 426). **The 52-row toolbar repeated the File menu, the tab and the window title** — 132 rows of chrome before the first character, 23% of a 900 px window. The empty state is now the launch state, so the only screen offering New and Open is reachable. The find and replace fields had no outline, no fill and no surface (bare text with a caret in dark mode); **the editor had no scrollbar at all**; the status bar's readout started under the line numbers instead of under the text; two tooltips appeared at once on a tab; a tab's ink splash painted a square over its rounded corners; the dirty marker was a bullet character depending on the UI font; a horizontal scrollbar in a 40 px strip would have clipped the last close button. Plus a real `ThemeData` (flat dialogs, fast square tooltips, thin always-visible scrollbar, menu bar with a baseline rule). Core 84, editor 22, app 45 + 2 skipped |

From a third review pass, on these branches:

| PR | Addresses |
|---|---|
| [#7](https://github.com/L-K-M/Planchette/pull/7) `fix/linux-packaging-metadata` | The `.deb` metadata was Poltergeist residue (**confirmed**): the copyright read "a two-pane file transfer client", the section was `net`, `objdump` ran unchecked, and `libglib2.0-bin` was a dead dep — the Linux file picker uses the XDG portal over D-Bus, so nothing spawns `gio`. Also fixes `floor_of`: a `die` inside it previously aborted only a pipeline subshell and let the script continue without a floor |
| [#13](https://github.com/L-K-M/Planchette/pull/13) `feat/tab-indent` | Same Tab-focus bug as #14/#21 (**confirmed**). Tab/Shift+Tab indent and outdent on the document field only (the search field keeps traversal), caret clamped inside removed whitespace, forward and backward selection direction preserved |
| [#16](https://github.com/L-K-M/Planchette/pull/16) `feat/go-to-line` | The dialog half of #33's Go to Line (Ctrl+G/Ctrl+L), plus clearing a stale validation error when the input changes |
| [#19](https://github.com/L-K-M/Planchette/pull/19) `fix/undo-load-boundary` | **Undo history crossed the document-load boundary** (**confirmed**): `UndoHistory` binds its stack to the controller instance, so focused edits stayed undoable after `_installText` replaced the buffer — undo could resurrect pre-load text into a blank file. A fresh `CodeEditingController` per install severs the stack; replaced controllers retire (listeners removed, disposed with the parent) so no widget touches a disposed controller mid-frame |
| [#20](https://github.com/L-K-M/Planchette/pull/20) `ci/dependabot-coverage` | `dependabot.yml` covered only the workspace root (`planchette_core`); `packages/planchette_editor` and `app/planchette_app` sit outside the pub workspace, so their deps never got update PRs |
| [#23](https://github.com/L-K-M/Planchette/pull/23) `feat/comment-toggle` | E1: Ctrl+/ toggles `lineComments` per language, keeps indentation, skips blank and whitespace-only lines, preserves caret and both selection directions |
| [#25](https://github.com/L-K-M/Planchette/pull/25) `feat/font-zoom` | The zoom half of #30: Ctrl+=/-/0 and a View menu, folded into the text style so the gutter and reveal painter scale consistently |
| [#32](https://github.com/L-K-M/Planchette/pull/32) `fix/gutter-wrap-drift` | Same gutter finding as #22/#28 (**confirmed**). Exact per-line measured heights at every document size, with unchanged prefix/suffix heights spliced back after edits and a full-measurement fallback |
| [#38](https://github.com/L-K-M/Planchette/pull/38) `feat/revert-file` | The Revert command from #26 alone: File › Revert File on file-backed tabs, prompting only when dirty |
| [#40](https://github.com/L-K-M/Planchette/pull/40) `fix/temp-leftover-sweep` | The delete half of B10: sweeps `.planchette-<uuid>.edit`/`.backup` siblings older than 7 days when a document opens, keyed on `changed` — a `.backup` inherits the old file's mtime, so `modified` could call a fresh recovery file ancient. B10 keeps the restore half |
| [#42](https://github.com/L-K-M/Planchette/pull/42) `feat/tab-close-others` | Middle-click closes a tab; right-click offers Close / Close Others / Close All Tabs, each still running the per-tab consent decision with Cancel stopping the sweep. Covers part of A7 and the context-menu part of FU5 |

From a fourth review pass, on a stacked chain. **These five are one chain, not
five independent PRs:** #34 is based on `main`, #37 on #34, #43 on #37, and
#44 on #27. #27 is independent of the other four. Merge in this order —
**#27, #34, #37, #43** — and #44 either side of #27. They were developed in
parallel by one agent, so the later ones are written against the earlier ones'
APIs and their tests are green against them, not against `main`.

| PR | Addresses |
|---|---|
| [#27](https://github.com/L-K-M/Planchette/pull/27) `perf/gutter-window` | **A keystroke in a file of any size cost 173 ms** (**confirmed**, 122,161-character document, JIT warmed, same machine, back to back: 173 ms → 36 ms; a bare `TextField` over the same text is 34 ms, so the editor's own overhead went 145 ms → 2 ms). `_ensureGutterLayout` laid out the *whole* document plus one `getOffsetForCaret` per line on every text change — 139 ms and 104 ms of the 173. A viewport can only show a few dozen rows, so it now measures a prefix (viewport + 64 rows) and extrapolates past it, and passes the previous prefix back as a floor so scrolling lays out progressively larger prefixes a logarithmic number of times. Revealing a search match was laying the document out a *second* time for the same answer. See P1's dead-end box for what this pass learned about the other terms. Also fixes a one-row drift in the extrapolated tail, reported by the reviewer |
| [#34](https://github.com/L-K-M/Planchette/pull/34) `feat/code-style-input` | **Tab did nothing in the document** (**confirmed** by probe: the text was unchanged *and* focus was unchanged, so it was swallowed rather than traversing). Enter did not carry indentation. Brackets did not pair. Adds Tab/Shift+Tab, Enter-keeps-indentation with a block-opener rule, and bracket/quote pairing with type-over. Covers E3, E10a and the Tab half of the focus bug. Core 98, editor 45, app 40 |
| [#37](https://github.com/L-K-M/Planchette/pull/37) `feat/settings` | **Every adjustable thing was a compile-time constant** — theme pinned to `ThemeMode.system` in `main.dart`, font size to 14, font family to `'monospace'`, and no indent at all. A settings file, a controller over it, a live-preview preferences dialog, and the shell's hardcoded English extracted to `ShellStrings` (see D0e). Covers A1 and part of FU4. App 72 |
| [#43](https://github.com/L-K-M/Planchette/pull/43) `feat/shell-chrome` | **~130 px of chrome before the first character, in rows that repeated each other** (**confirmed**). The dirty marker was a `'● '` prefixed onto the tab's *label string*, so every tab changed width the moment it was edited and again when saved; the error banner was a row spliced into the column, so a failed save moved the document; tabs were basename-only, so ten `index.js` files looked identical; the strip never scrolled the active tab into view; nothing handled a dropped file. One strip, a fixed-width dirty slot, the directory beside the tabs, the error as an overlay, active-tab reveal on every selection change, and a drop target. Covers A4, the stable-dirty-dot part of the chrome, and V6's placement |
| [#44](https://github.com/L-K-M/Planchette/pull/44) `feat/find-query` | **The find bar matched plain text and nothing else**, and a mistyped pattern was indistinguishable from no match. Adds a `.*` toggle, `planchette_core.FindQuery` with compile-once, a visible pattern error, zero-width-match handling, field chrome, and a selection word/character count in the status bar. Covers the regex half of E5, the field part of V4, and the selection-summary half of E10b. Core 94, editor 41, app 40 |

**Overlaps between PRs.** These findings were found independently — by the
review passes working in parallel — and are addressed by more than one open
PR. Whoever merges second should keep the union rather than resolve in
favour of one side:

| finding | PRs | what each does |
|---|---|---|
| Tab moves focus out of the editor | #14, #21, #13 | #14 adds an `EditorTabKeyBehavior` and line-editing keys. #21 puts the indentation rules in `planchette_core` as pure functions, matches the file's own tab or space convention, pads to the next tab stop, and leaves Tab to focus traversal while the editor is read-only. #13 keeps the fix in the editor package and preserves backward selection direction |
| The gutter re-measures the document per edit | #22, #28, #32 | #22 moves the numbers into a decorations render object and adds a current-line band. #28 keeps the existing painter and replaces its per-line caret loop with one `computeLineMetrics` call. #32 keeps per-line measured heights in a cache and splices unchanged regions on edit. All change `_ensureGutterLayout`; the union is one measurement path plus a band |
| Go to Line | #33, #16 | #33 adds a clickable status position and per-platform find chords. #16 is the dialog and reveal plumbing alone |
| Font zoom | #30, #25 | #30 adds the platform monospace stack and Actual Size. #25 folds the scale into the text style so gutter metrics and the reveal painter stay consistent |
| Revert to disk | #26, #38 | #26 adds on-focus change detection, recreate-on-save and the Reload/Keep Mine notice. #38 is the File-menu command alone |
| Centered menu bar and tab strip | #35, #36 | #35 folds the toolbar into the tab strip and adds tab commands. #36 removes the toolbar outright, fixes the `Column` alignment, and reworks the tab and status rows. #35's tab-strip features and #36's row geometry should both survive |
| Untitled document naming | #35, #21 | #35 reuses "Untitled 1" for a fresh buffer. #21 gives untitled documents a counter separate from the tab identity counter |
| Search and status rows | #33, #36 | #33 makes the status position clickable and adds language display names. #36 aligns the status bar's leading edge to the text column and stops claiming a language for a file too large to highlight |
| Error text | #26, #21 | #26 maps disk-change failures. #21 maps a missing or unresolvable path in the core so hosts get it too |
| Tab moved focus out of the editor | + #34, #21 | #34 is the fourth independent arrival at this bug. It differs from the others in that it accepts the change the platform already made rather than intercepting a key, and it takes a language predicate rather than a heuristic. Whichever merges second: keep #34's "single character at a caret" guard, because it is the only one of the four that states what it will *not* touch |
| The gutter re-measures the document per edit | + #27, #22, #28, #32 | **Four independent arrivals, and they are not the same fix.** #27 measures a *viewport-sized prefix* and extrapolates the rest from the paragraph's preferred line height; #22 moves the numbers into a decorations render object; #28 replaces the per-line caret loop with one `computeLineMetrics`; #32 caches per-line measured heights and splices unchanged regions. #27 and #32 are the closest — both keep the existing painter. #27's extrapolation is O(lines) per edit where #32's splice is O(changed region), so **#32 is the better answer if only one survives**; #27's contribution to keep either way is the single measurement path shared with the find-reveal, which was laying the document out a second time for an answer the gutter already had |
| Centered menu bar and tab strip | + #43, #35, #36 | #43 removes the header row entirely and folds the commands, the tabs and the document's directory into one strip. #35 folds the toolbar into the tab strip and adds tab commands; #36 removes the toolbar and fixes the `Column` alignment. **#36's geometry fixes are orthogonal to #43's layout** and should survive whichever merges; #35's tab commands and #43's dirty slot are the parts to keep from each |
| Error banner | + #43, #36, #21, #26 | #43 makes the banner an overlay so a failed save cannot move the document — a placement change only. #36's error-copy work and #21's and #26's error mapping are independent and should all survive. #43 does not touch the copy |
| Search bar and status rows | + #44, #33, #36 | #44 adds the pattern toggle, the field chrome and the selection count; #33 makes the status position clickable and adds language display names; #36 aligns the status bar's leading edge. The three touch adjacent lines in the same two widgets — resolve by keeping all three features |
| Indentation and its settings | + #37, #34, #14, #21, #13 | Five independent arrivals. #34 owns the buffer behaviour and the `EditorIndent` value; #37 owns persistence and the preferences UI. **#37 changed `PlanchetteApp`'s constructor** (a required `SettingsController` replaces a test-only `themeMode`), so it conflicts with any PR that constructs the app; it also added `==` to `EditorIndent`, which #34 needed for a settings round-trip to compare equal at all |

**Merge-order notes.** Every branch listed above starts from `d53f416`.
These pairs touch nearby lines and will need a small conflict resolution for
whichever merges second:

- #14 and #33 both edit the status list in `editor_view.dart`. Keep both
  the indentation segment and the language display name.
- #30 and #33 both add to the app's Find/View menus in
  `planchette_app.dart`.
- #41 changes the app's `_theme` and the editor's syntax-theme lookup.
  It overlaps nothing else, but re-check #22's current-line band on the
  new surfaces after both merge.
- #22, #30 and #33 touch other parts of `editor_view.dart`, as do #26,
  #30, #33 and #35 in `planchette_app.dart`. Their hunks are separated, so
  expect clean merges, but re-run all three test suites after each merge.
- #21 and #28 both rewrite `_ensureGutterLayout`'s neighbourhood and the
  document `TextField` in `editor_view.dart`; #21 adds a `Shortcuts` wrapper
  around the field and #28 adds a `Scrollbar` outside it. Keep both.
- #28's cap constant and #21's indentation helpers do not overlap.
- #39 rewrites the load path in `text_document.dart`; #21 changes the error
  type thrown from `resolveTextDocumentTarget` in the same file. Keep both.
- #36 rewrites most of `planchette_app.dart`, including `_menus()`, so it
  will conflict with #26, #30, #33 and #35. #36 removes the toolbar and the
  File-menu duplicates; those PRs' new menu items must be re-added to
  `_menus()` rather than dropped with the toolbar.
- **#43 rewrites the same region #36 does**, so those two will conflict
  hardest. #43 keeps `_menus()` and adds a Settings entry to it, so #43 is
  the smaller diff of the two against `main`; #36's geometry fixes and real
  `ThemeData` are the parts worth carrying across.
- #37 changes the `PlanchetteApp` constructor and `main.dart`, so it
  conflicts with every PR that mounts the app in a test. The resolution is
  mechanical: construct a `SettingsController` over a `MemorySettings`
  double and pass it, instead of the old `themeMode` argument.
- #27 and #44 both edit `editor_view.dart`'s gutter and status
  neighbourhood and are already in that order on the same branch, so they
  merge cleanly as a pair. #22, #28 and #32 also change
  `_ensureGutterLayout`; see the overlaps table for which of those to keep.
- #27's `line_tops.dart` is deliberately **not** exported from
  `planchette_editor.dart`, so it adds no public API. If a host ends up
  wanting it for its own gutter, that is a one-line export change — but do
  not export it speculatively.

## 2. Follow-ups to the open PRs

Do these after the named PRs merge.

### FU1. Re-detect indentation on revert (after #14 and #26) — S
`EditorController.revertTo` (#26) installs disk text without calling
`_detectIndentation(reset: true)` (#14), so a file reformatted on disk
keeps the old indent unit until reopened. **Plan:** call
`_detectIndentation(reset: true)` in `revertTo`, and add a test that
reverting from 2-space to 4-space text updates `indentation`.

### FU2. One reveal path (after #22 and #33) — S
#22 reveals find matches through `_RenderDocumentDecorations.textTopOf`.
#33 reveals Go to Line targets through `EditableTextState.renderEditable`.
**Plan:** keep one helper `_revealOffset(int offset)` in `editor_view.dart`
backed by the decorations geometry, and call it from both
`_revealMatch` and `_revealCaret`. **Done when** both keep their tests
green and neither lays out text itself.

### FU3. Cache the highlighted span (after #14) — M
Caret moves still rebuild every span. `EditableText` rebuilds on each
selection change, and `CodeEditingController.buildTextSpan` rebuilds the
whole span list, O(tokens). **Plan:** memoize the returned `TextSpan` on
`identical(text)`, `identical(tokens)`, `identical(matches)`,
`activeMatchIndex`, `theme`, `style`, the tab style and the composing
range. `RenderEditable.text =` then short-circuits on `identical`.
**Done when** a test shows two consecutive selection-only builds return
the identical span, and a text or theme change returns a new one.

### FU4. Persist zoom and other view settings (after #30) — M
Zoom resets on every launch. See A1 (settings store). Store the zoom
index, and restore and clamp it on startup.

### FU5. Tab strip context menu and more tab keys (after #30 and #35) — M
Planned in #35 but not built there; #42 added the right-click menu with
Close / Close Others / Close All Tabs, so what remains is:
- Extend the menu: Close to the Right, Copy Path, Reveal in
  Finder/Explorer/Files.
- Drag to reorder.
- Aliases through `_Command.aliases` from #30: Ctrl+PageDown/PageUp for
  next/previous tab on Windows/Linux, and Cmd+Shift+] / [ on macOS.

Reveal needs `open -R` on macOS, `explorer /select,` on Windows, and
`xdg-open` on the parent directory on Linux. Keep that behind an app
service, not in the widget.

### FU6. Languages left out of #31 — S each
- **PHP**: has its own `#` line comments. Under `c-family` (#31), a
  leading `#` reads as a preprocessor line. Give PHP an entry with `//`,
  `#` and `/* */` comments, `$variable` meta and PHP keywords.
- **Rust raw strings**: `r"…"` and `r#"…"#`. Add a scanner case: `r`,
  N×`#`, then `"`, closed by `"` + N×`#`.
- **TOML**: own entry. `[table]` and `[[array]]` headers as meta,
  `key =` as meta, `"""`/`'''` multiline strings, dates as numbers.
- **More languages**: TypeScript-only keywords (`interface`,
  `implements`, `declare`, `keyof`, `readonly`, `satisfies`), Kotlin
  and Swift keyword sets, PowerShell, Batch, HCL/Terraform, CMake, Nix.
- **Tests**: follow the `language fixes` group in `editor_syntax_test.dart`.

### FU7. Soft-keyboard auto-indent for hosts (after #14) — M, risk: high
#14 indents only on hardware Enter. On mobile, a newline arrives as a
text edit. **Plan:** in `EditorController._textChanged`, detect a
single `\n` inserted at a collapsed caret with no composing range, and
rewrite it with `core.insertNewline`. Do not do this while composing.
Validate in Poltergeist and Séance before merging; IMEs are the risk.

### FU8. Keyboard escape from indent mode (after #14) — S
With `EditorTabKeyBehavior.indent`, keyboard-only users can't Tab out of
the document. **Plan:** add Ctrl+M (VS Code's "Toggle Tab Key Moves
Focus"), or Escape followed by Tab, to move focus once. Add a test that
focus leaves the document.

## 3. Bugs

### B2. Backslash-newline continues "single-line" strings — S (read)
`_scanString` skips two code units after `\`, so `"abc\` followed by a
newline keeps the string open onto the next line. That's correct for
C-family and shell continuations but not for JSON, INI or YAML.
**Plan:** add a per-language `lineContinuation` flag, and never let an
escape consume `\n` when it is false.

### B3. Saving a read-only file overwrites it silently — S (read)
Replacement renames a sibling into place and restores the old mode bits,
so a `0444` file in a writable directory saves without warning.
**Plan:** check `stat.mode & 0o222` (POSIX) or the read-only attribute
(Windows) at load time. Show a read-only marker in the tab and status bar,
and ask before saving ("Save anyway" / "Save As…").

### B4. Startup window jump on Linux and Windows — S (read)
The Windows runner creates a 1280×720 window at (10,10) and shows it on
the first frame (`windows/runner/main.cpp`, `flutter_window.cpp`). GTK
shows 1280×720 (`linux/runner/my_application.cc`). Then
`DesktopWindow.initialize` resizes to 1080×760 and centers it. **Plan:**
make the native sizes match 1080×760, or keep the window hidden until
`waitUntilReadyToShow` shows it, as window_manager's README describes.

### B5. Close button vs Close Tab during load — S (read)
Close Tab in the menu requires `!isLoading` (`ready`), while the tab's ×
only checks `busy`. Pick one rule (probably allow closing a loading
tab, which cancels the load) and test it.

### B7. Multiple carets — L (structural, the largest single gap)
There is exactly one caret. Every serious code editor's defining feature is
absent, and `EditorController` already owns the selection plumbing
(`revealRequest`, `lineStarts`, a `CodeEditingController`) so most of the
groundwork is there. **Plan:** carry a `List<TextSelection>` instead of one
selection, add `Cmd/Ctrl+D` (add next occurrence), `Cmd/Ctrl+Alt+↑/↓` (add
above/below) and `Escape` (collapse to one). Editing operations — indent,
dedent, comment toggle, replace — must apply to every caret in one pass, so
do this *after* E1 and E2 have pure core transforms that can take a list.
**Done when** three carets can be typed into at once and one undo removes
the lot.

### B8. The status bar's column number lies about tabs and wide characters — M (confirmed)
`EditorController.caretLineColumn` counts UTF-16 code units, so a tab counts
as 1 and a surrogate pair as 2. Confirmed: with the text `"\tindented"`, the
caret at offset 4 reports **Col 5** while sitting at visual column 9 under an
8-wide tab stop. A CJK character is off the same way. A programmer reads the
column off the ruler and compares it to what the editor shows. **Plan:**
count display columns — a tab advances to the next multiple of the tab
width, East Asian wide and emoji count 2 — in a pure core function beside
`lineStartOffsets`, and unit-test it against the same strings.

### B9. `Ctrl+Tab` is taken from the desktop — S (read)
`Window › Next Tab` is bound to `Ctrl+Tab` / `Ctrl+Shift+Tab`
(`planchette_app.dart`). On Windows and most Linux desktops that chord
switches *applications*, so the editor swallows a system shortcut to change
tabs. **Plan:** use `Ctrl+PageDown` / `Ctrl+PageUp` (VS Code) and
`Cmd+Shift+]` / `[` on macOS. #30 already adds platform-correct aliases
through `_Command.aliases`; reuse that.

### B10. Offer recovery for a lone save sibling — S
The delete half landed in #40: `.planchette-<uuid>.edit`/`.backup`
siblings older than 7 days are swept when a document opens, keyed on
`changed` — keep that cutoff, a `.backup` inherits the old file's mtime
so `modified` cannot date the leftover. What is left: a lone `.backup`
still holds the previous file content after a mid-save crash. When an
opened document has one, offer to restore it rather than letting the
sweep discard it — restore beats delete for the recovery case the
format exists for.

### B11. Quit during a save is refused with no explanation — S (read)
`_confirmQuit` returns false when any tab is busy or saving
(`document_workspace.dart`), and `DesktopWindow.requestQuit` treats a false
as "do nothing". The user presses Cmd+Q during a large save and the window
simply does not move. **Plan:** queue the quit and run it when the save
settles, or show "A document is still saving" with a Cancel. It must stay
correct against `onWindowClose` and `AppExitListener`, which both route
through the same decision.

### B12. `Save As` is silently dropped while a plain `Save` is in flight — S (read)
`DocumentWorkspace._save` dedupes per tab, so a second call returns the
in-flight future. A `Save As` issued while a plain `Save` is running is
discarded without a word, and the user has to press it again. **Plan:** key
the in-flight map on `(tab, saveAs)`, or queue the Save As behind the save
and run it when the first settles.

### B13. Disposing a controller with an attached FocusNode schedules work on a dead FocusManager — S (confirmed)
`EditorController.dispose` disposes `editorFocus`, `searchFocus` and
`replacementFocus` while they may still be attached to the focus tree
(`closeTab` does exactly this while the tab is still in the `IndexedStack`).
Disposing an attached `FocusNode` calls `unfocus`, which schedules a
microtask on `FocusManager.instance` — so the focus change lands after
whatever tore the tree down. Hit as a real test failure:
`A FocusManager was used after being disposed`. **Plan:** have
`PlanchetteEditorState.dispose` unfocus its nodes first, and/or have
`DocumentWorkspace._remove` remove the tab from the list before disposing the
controller so the view is already unmounted. **Done when** closing the
active tab while it holds focus does not warn.

### B14. Magic numbers where the repo's rules want constants — S (read)
`setFilePermissions(temporary.path, 0x180)` for 0600 and
`stat.mode & 0x1ff` for 0777 in `text_document.dart`, with the meaning in a
trailing comment. `AGENTS.md` asks for descriptive constants. **Plan:** a
`_ownerOnlyMode` and a `_permissionBits` const, or `package:ffi`'s
constants if they cover it.

### B15. `DesktopWindow` is never disposed — S (read)
`main()` builds a `DesktopWindow`, hands it to `PlanchetteApp`, and drops the
reference. `windowManager.removeListener` and `AppLifecycleListener.dispose`
never run. Harmless for a single-window app that quits, but the hosts mirror
this file, and the leak grows with every window. **Plan:** own the
`DesktopWindow` in a `State`ful root so `dispose` runs, or have `PlanchetteApp`
take it as a disposable collaborator.

### B16. `Cmd/Ctrl+N` stacks empty untitled buffers — S (read)
`newDocument` always creates a tab, so pressing it four times gives four
`Untitled 1…4` buffers with nothing in them. #35 reuses the name; the reuse
of the *tab* is separate. **Plan:** if the active document is untitled, empty
and not dirty, focus it instead of creating another.

### B17. Only the last error survives a multi-file open — S (read)
`DocumentWorkspace.openDialog` overwrites `error` for each failing file.
Collect the failures and show "2 files could not be opened: a.bin (binary),
b.txt (not UTF-8)".

### B18. Opening a file that is already open should flash its tab — S (idea)
Today the existing tab is simply activated. Add a short highlight
animation on that tab so it's clear why nothing new appeared.

### B19. Save As can slip the open-tab check while a sibling is loading — S (read)
`DocumentWorkspace._findPath` canonicalizes the target and compares it
against `tab.path`, but a tab's `path` is only set after its load
finishes. A Save As aimed at a still-loading tab's unresolved alias can
miss the check. The digest guard still refuses a true collision at
write time, so the worst case is a confusing error rather than lost
data — recheck `_documents` once the pending load lands.

### B20. The load path hashes the file three times, and one of them is provably redundant — S (confirmed)
`loadTextDocument` computes a `before` digest by streaming the whole file,
then streams it again into `bytes`, then computes an `after` digest by
streaming it a third time. Measured SHA-256 cost is 66 ms per 3 MB, so a
4 MiB file pays about 200 ms of hashing plus two extra full reads.

The `before` digest buys nothing. The check that already exists —
`crypto.sha256.convert(bytes) != after` — detects any change during the
read, and detects it *more* strictly, because it compares the bytes
actually returned rather than a separate pass over the path. `before` is
only used in `before != after`, which the byte comparison already implies.

**Plan:** drop `before` and the first read. The safety tests in
`document_safety_test.dart` must pass unchanged; the `sha256Of` hook the
tests inject is what makes the mid-read-change case observable, so keep it.

### B21. The save path re-reads the temporary it just wrote — S (confirmed)
`_writeTextDocument` writes `bytes`, then calls `textDocumentSha256(temporary)`,
which streams the file back in to hash it. The bytes are already in memory.
Hash the list instead: `crypto.sha256.convert(bytes).toString()`. Same digest,
one fewer read, on every save and on every create.

### B22. Line-ending normalization is three full string allocations — S (confirmed)
`_normalizeLineEndings` runs `_foldToLf` — two `replaceAll` passes over the
whole buffer — and then possibly a third `replaceAll('\n', '\r\n')`. Measured
28 ms per save on 3 M characters. The common case, a buffer that is already LF
and a target of LF, still copies the document twice for no reason. A single
pass appending into a `StringBuffer`, with an early return when the buffer
already matches, fixes it.

### B23. A dropped path starting with `-` is silently discarded — S (read)
`OpenDocuments.start` passes `arguments.where((a) => !a.startsWith('-'))` to
the opener. A file literally named `-draft.txt`, opened from a command line or
a desktop entry, is dropped without a word. Filter the flags out by name
against the known set instead of by prefix. macOS Finder events come through a
different path and are unaffected.

## 4. Performance

### P1. O(document) work per keystroke — L (structural)
Every edit re-tokenizes the whole text on the UI thread (including the
regex meta pass), rebuilds all spans, relays out the whole paragraph,
recomputes `lineStartOffsets`, and recounts UTF-8 bytes. With find open,
it also lowercases and re-searches the whole document. The highlighting cap
exists because of this; #28 lowered it from 200,000 characters to 32 KiB,
which trades colours for responsiveness above that size. The cap is a
band-aid, not a fix.

Measured, per keystroke, in the harness:

| document | cost | where |
|---|---|---|
| 380 KB text | **12.1 ms** | `lineStartOffsets` + `utf8EncodedLength` in `_updateMetrics`, recomputed on every text change and read by the status bar every frame |
| 380 KB text, find open | **175 ms** | `findSearchMatches` lowercases the entire haystack per query keystroke, then `setSearchMatches` forces a full span relayout with up to 1,000 match spans |
| 79 KB JSON | ~95 ms | 12,001 spans: 11 ms to build, 70 ms to lay out, against a 35 ms plain floor |
| 787 KB text | ~330 ms | Flutter's own single-paragraph `TextField` layout. **This is the floor for this architecture** and #28 changed nothing here |

Short-term steps, each S–M:
1. Incremental tokenization. Store the scanner state at each line start
   (inside a block comment or multiline string, or not). On an edit,
   re-tokenize from the edited line until the state converges with the
   previous run, and splice the token list. A common-prefix/suffix scan is
   cheap enough to find the edit first.
2. Cache the lowercased haystack per text instance in `EditorController`,
   and debounce the query by one frame. This is the single biggest cheap win
   in the table above.
3. **Do not make the line-start and byte metrics incremental.** This was
   built and measured, and it is a dead end — see the box below. Take the
   "lazily, at most once per frame" half instead, which is most of the win
   for none of the risk.
4. Compare a monotonic revision counter against the revision recorded at the
   last save instead of comparing the whole buffer in `isDirty`. It is read
   by the tab label, the status bar, the window title and twice by
   `_menus()`, so on a large file that is several full-buffer scans a frame.

Long-term: see P3.

> **Measured dead end: incremental document metrics.** An earlier pass of this
> review implemented a `TextMetrics` in `planchette_core` that took the edit
> range from a pair of `TextEditingValue`s, found the shared prefix and suffix,
> and spliced the line-start list. The merge arithmetic is the hard part and it
> is worth writing down, because the shape looks obviously right and is not:
>
> ```text
>     new  [0, shared)   [shared, newTailStart)   [newTailStart, length)
>     old  [0, shared)   [shared, oldTailStart)   [oldTailStart, oldLength)
> ```
>
> Three boundaries are the fiddly part, and each has a reason. The rescan's
> upper bound must be **exclusive**, or it also claims the old tail's first
> line start — which cannot be carried, because its predecessor was removed.
> The old tail's *second* start **is** safe to carry, because the character
> before it is the tail's first and the shared suffix guarantees that one too.
> And a start at or before `shared` is kept unshifted and never carried, since
> carrying it would claim a line start at an offset the edit never wrote.
> A surrogate pair straddling a fragment edge also has to be charged to
> exactly one side, or a 4-byte character is counted as two 3-byte
> replacement characters. Random property tests against a from-scratch scan
> found three real defects in that arithmetic, each of which had to be fixed
> before it was correct.
>
> **And then it turned out not to be worth having.** The line-start list is
> 60,000 entries for a 3 MB file, and shifting the tail means rebuilding it:
>
> | operation, 3,060,000 characters / 60,000 lines | cost |
> |---|---|
> | `lineStartOffsets` (what the editor does today) | 6.4 ms |
> | copy 60,000 boxed starts, no shift | 3.9 ms |
> | copy 60,000 boxed starts, shifting by 1 | 2.2 ms |
> | the same shift on a `Uint32List`, unboxed | **0.6 ms** |
> | `String ==` over 3 M characters, which is all the affix verification costs | 3.5 ms |
>
> So the tail shift is inherently O(lines) and a boxed rebuild of it costs
> *more per element* than the character scan it was meant to replace — the
> first working version measured **10.3 ms per keystroke for appends and
> 24.2 ms for mid-buffer inserts, against 12.3 ms for the full scan it was
> replacing.** Even a perfect implementation cannot avoid the 3.5 ms
> `memcmp` that verifying the shared tail requires. A `Uint32List` would
> make the shift 0.6 ms, and then you are maintaining a bespoke piece table
> with a 4 GiB offset ceiling and a fallback path, to save 9 ms on a 3 MB
> file — in a package three applications depend on.
>
> **The actual measurement that settles it: on a 122,161-character document the
> whole per-keystroke cost is 173 ms, of which the metrics are 2 ms.** They are
> 1% of the problem. The gutter was 145 ms. Spending effort on the metrics
> would have been spending 99% of the effort on 1% of the cost. Take the
> scheduling fix — recompute at most once per frame, off the keystroke — and
> leave the arithmetic alone. The branch was abandoned, not merged.
>
> The transferable lesson: **measure which term dominates before optimizing
> one.** The gutter looked like "the highlighting cap", the metrics looked like
> "the dirty check", and both were invisible next to a whole-document
> `TextPainter` layout.

### P2. `IndexedStack` lays out every tab — M (read, Flutter source)
`RenderIndexedStack` lays out all children and paints one. Resizing the
window relays out every open document's full text. **Plan:** keep
inactive editors out of layout, for example
`Visibility(visible: false, maintainState: true)` or `Offstage`, and
verify that undo history survives tab switches. The existing test "tab
switches retain undo, selection and search state" must stay green.

### P3. A virtualized editor surface — L (idea)
The `TextField` approach bounds document size and responsiveness. A
line-based editor (render only visible lines, keep a piece table or rope,
own the caret, selection and IME client) would remove the 32 KiB highlight
cap and the 4 MiB ceiling, and would enable minimap, folding, true tab
stops, multi-caret and a word-wrap toggle. It is also the prerequisite for
E6 and Q7, and #28 documents that raising the cap is blocked on it. It's a
big project: prototype behind a flag in `planchette_editor`, keeping
`EditorController`'s API.

**Flutter 3.47 has no way to turn soft wrap off** on `TextField` or
`EditableText` — there is no `softWrap` parameter on either, confirmed
against the SDK sources. That is why E6 exists as it does, and why #28's
first push (which assumed wrapping could be disabled, and shipped a gutter
that assumed uniform rows while the text was in fact folding) had to be
corrected. A surface that owns its rows is the only way out.

### P4. Load and save off the UI isolate — M
After #39, opening a 3.9 MB file still costs about 180 ms of CPU on the UI
isolate: three SHA-256 passes (about 50 ms each in AOT), the UTF-8 decode,
and line-ending folding. **Plan:** run the pure steps (hash, decode, census,
fold, and encode on save) in `Isolate.run` inside `planchette_core`. Keep
the file I/O and the digest ordering exactly as they are, since the safety
tests inject `sha256Of`. **Done when** opening a 4 MiB file leaves the UI
isolate responsive (no frame over 16 ms in a profile build), and all
document-safety tests pass unchanged.

### P5. `replaceAll` materialises one match object per occurrence — S (read)
`EditorController.replaceAll` calls `findSearchMatches(..., limit:
source.length + 1)`, so a one-character query over a large document builds
tens of thousands of `TextMatch` objects plus a `StringBuffer` for the whole
result. Measured at 14 ms for a 769 KB document, which is survivable, but
the limit exists for a reason and this path bypasses it. **Plan:** stream
matches and splice, or cap and ask. `core.findSearchMatches` should grow a
callback form so the caller never materializes the list.

### P6. The gutter allocates per painted line — S (read)
`_LineNumberGutterPainter.paint` creates one `TextPainter` and then calls
`layout()` for every visible line — roughly 50 paragraph layouts a frame
while scrolling — plus a fresh `Paint()` for the divider. **Plan:** cache
`ui.Paragraph`s for the line numbers, or one `TextPainter` over a
pre-measured digit atlas, and hoist the divider's `Paint`.

## 5. Editing features

### E2. Line operations — S each
Duplicate line or selection (Cmd/Ctrl+Shift+D), move line up/down
(Alt+↑/↓), delete line (Cmd/Ctrl+Shift+K), join lines (Cmd/Ctrl+J).
Write pure core transforms returning text and selection. #21 landed the
shape: a `TextEdit` with `text`, `start` and `end` in `planchette_core`, the
same class `insertIndent` and `removeIndent` return, so line operations
should return that too rather than inventing a second shape.

### E3. Auto-close brackets and quotes — mostly done in #34
**Landed in #34:** `( [ { " ' \`` insert their closer with the caret between;
typing the closer again takes back the character the platform inserted and
steps over the pair; a closer with something *else* after it is a real bracket
and is inserted as one; Markdown is excluded, because its brackets are content;
a locked editor does not pair.

**Two decisions that matter more than the feature:**

- **Enter and the bracket keys are not intercepted as shortcuts.** They reach
  the buffer through the platform's text input, so #34 runs on the change the
  platform already made, and accepts it only when it is *a single character
  inserted at a collapsed caret*. A paste, an IME composition, an undo and a
  replaced selection all arrive as more than that and are left exactly as they
  came. That constraint is what keeps this from rewriting text the user did not
  type, and it is the part to preserve if this is extended.
- **A language gate, not a heuristic.** Pairing is decided by
  `pairsBrackets(language)`, which is "not null and not Markdown". Extending it
  to more prose formats is a one-line change to that predicate.

**Still open from this item:** Backspace between an empty pair deleting both;
respecting string and comment context with the tokenizer rather than only the
character after the caret; a setting to turn it off. All three are worth doing
together — the third is a `bool` on `EditorController` beside `indent`.

### E4. Bracket-match highlight — M
When the caret touches a bracket, find its partner (skipping strings and
comments via tokens) and paint both backgrounds. The decorations render
object from #22 can paint them.

### E5. Search options — regular expression done in #44
**Landed in #44:** a `.*` toggle beside the existing `Aa` button, a
`planchette_core.FindQuery` that compiles the pattern once, and — the part
worth keeping — **a pattern that does not compile says so in the match counter
in the error colour**, rather than reporting "No matches", which is
indistinguishable from a file with no occurrences and sends people looking in
the wrong place. Fixing the pattern clears it.

Patterns compile with `multiLine`, so `^` and `$` anchor to a line. A match of
**nothing** (`x*`, `^`, `\b`) is skipped rather than reported, because the bar
cannot highlight or replace an empty range — but the search *continues* rather
than stopping, or a leading empty match would lose the real ones after it.

`replaceAll` honours the pattern mode too, and does nothing at all when the
pattern will not compile.

**Still open from this item:** whole word; "in selection"; highlight all
occurrences of the selected word; capture groups in the replacement (the
current `replaceAll` substitutes a literal string, so `$1` is written out
rather than expanded — a real trap now that patterns exist).

### E6. Word wrap toggle — M
The `TextField` always soft-wraps. No-wrap needs a horizontally
scrollable field of intrinsic width (a `SingleChildScrollView` plus
`IntrinsicWidth`, or a very wide constraint), and the gutter must follow
vertical scroll only. Consider doing this with P3 instead.

### E7. Visible whitespace and indent guides — M
Paint dots for spaces and arrows for tabs in the selection or all text,
and thin vertical guides per indent level. The decorations painter from
#22 can do both.

### E8. True tab stops — M
#14 renders each tab at a fixed width. Tabs after text should align to
the next multiple of the tab width. That needs per-tab measurement of
the preceding column (monospace makes this arithmetic) and a
letter-spacing value per tab.

### E9. Trim trailing whitespace and final newline — S
Settings: "Trim trailing whitespace on save" and "Ensure final newline".
Honor `.editorconfig` if present (see A1).

### E10a. Enter does not keep indentation — done in #34
**Landed in #34,** alongside Tab/Shift+Tab. The pure transform is in
`planchette_core` as `indentForNewLine`, next to `leadingWhitespace` and
`indentRange`, so FU7 can reuse it for the soft-keyboard case.

One judgement call inside it: a trailing **colon** indents the next line for the
line-oriented families (YAML, INI, dotenv, XML, Markdown, CSS) and not for
languages where a colon is punctuation — so `services:` in a compose file opens
a block and `var x:` in Dart does not. That list is a single `const Set<String>`
in `code_input.dart` and is the most likely thing an owner would want to
change.

**Still open from this item:** Backspace removing a level, which #14 covers.
Take whichever of #14 and #34 merges second and keep both.

### E10b. Search debounce and a selection summary — S
`findSearchMatches` runs synchronously on every query keystroke (P1 step 2).
Debounce it by a frame and show "N selected" in the status bar, replacing
the byte count, which no programmer reads.

### E10. Change line endings, indentation and language from the status bar — M
Make the status segments into menus:
- LF / CRLF converts the document on the next save.
- Spaces / Tabs sets `indentation`, with "Convert indentation".
- The language picker sets the language explicitly.

The status row lives in the shared editor, so do this through
`statusBuilder` or new callbacks, not app-only code.

## 6. App features

### A1. Settings store — mostly done in #37 (enables FU4, E9, A3, A4)
**Landed in #37:** an `AppSettings` value, a `SettingsStore` interface with
`LocalSettingsStore` and a test double following `DocumentStore`, a
`SettingsController`, and a preferences dialog for theme mode, font size and
indentation.

Two decisions in #37 worth keeping whatever else is added, because the next
settings will otherwise be added the naive way and break them:

- **Read defensively, field by field.** `AppSettings.fromJson` falls back per
  field, so a hand-edited value costs that value and not the file. Font size is
  bounded *on read* (9–40) so a bad file cannot make the editor unreadable, and
  `LocalSettingsStore` maps an unparseable file to "no settings" rather than to
  an error — that is the store's documented contract, and the test double
  honours it too.
- **A failed write reports, it does not throw.** `SettingsController.error`,
  because it is called from a dialog's button press and a setting the user just
  chose is worth keeping even when the disk said no. The first version rethrew
  and produced an unhandled async error in a caller that awaits nothing.

**Still open:** the settings #37 does not carry. Font family, trim and
final-newline rules, current-line band, line numbers, status-bar contents and
restore-session. The store, the controller and the dialog all take new fields
without structural change.

**Deviation from this item's advice:** #37 computes the per-user configuration
path from the environment rather than adding `path_provider`. Worth keeping —
it is a new dependency in an app whose AGENTS.md warns about
`file_picker` ≥11 and AGP 9, and the path is three branches.

### A2. Session restore and hot exit — L
Reopen the last session's files, and restore unsaved untitled buffers and
unsaved edits after a quit or crash. Journal dirty buffers to the app
support directory on idle, with owner-only permissions, and clear the
journal on save or close. It must survive a failed save and must not
resurrect discarded edits.

### A3. Open Recent and a recent list in the empty state — M
Keep the last 20 paths in settings. Show them in File › Open Recent (on
macOS, prefer `NSDocumentController`'s recents) and in the empty state.
Remove entries whose files are gone. While the list is there, also
remember the last directory used per file type and pass it as
`FilePicker.saveFile`'s `initialDirectory` — today every Save As starts in
the document's own directory or nowhere at all.

### A4. Drag and drop files onto the window — done in #43, without the plugin
**Landed in #43:** a `DragTarget<String>` around the shell, opening each
dropped path through `DocumentWorkspace.open`, refusing the drop while
`interactionLocked`, and turning the chrome strip the primary colour while a
drag is over it. It uses Flutter's own `DragTarget` rather than the
`desktop_drop` plugin this item originally suggested — so **no runner
registrants change and Linux packaging is unaffected**, which is the whole
risk this item carried.

The payload is newline-separated, because that is what a desktop drop delivers
for several files and for one; `droppedPaths` is public and tested directly.

**Read D0e before adding coverage here:** Flutter's `DragTarget` cannot be
driven from a widget test. #43 asserts the wiring and the payload parsing and
says plainly that the drop itself needs a real desktop run.

### A5. Quick Open (Cmd/Ctrl+P) — M
A fuzzy list over recent files and the active file's directory. Enter
opens, and Esc returns to the editor.

### A6. Command palette (Cmd/Ctrl+Shift+P) — S–M
The shell already models menus as `_ShellMenu` / `_Command`. List every
enabled command with its shortcut, filter by fuzzy match, and run it on
Enter.

### A7. Save All and Reopen Closed Tab — S each
Close Others and Close All landed with #42, with the consent decision
still per tab. Reopen Closed Tab (Cmd/Ctrl+Shift+T) keeps a stack of
recently closed paths. The quit prompt should list the dirty files,
with "Save All" and "Discard All" buttons instead of one dialog per tab.

### A8. Remember window size, position and maximized state — S
Store them in settings (A1). Restore them before `waitUntilReadyToShow`,
clamped to a visible display.

### A9. Encodings — M
Only strict UTF-8 is accepted. Detect UTF-16 LE/BE by BOM, and offer
"Reopen with Encoding…" for Latin-1/CP1252. Save in the document's
encoding. Keep the 4 MiB limit in bytes, and update ARCHITECTURE.md.

### A10. Markdown preview — M
A split view for `.md` using `flutter_markdown` or a small renderer, with
scroll sync by heading.

### A11. Print or export to HTML/PDF with highlighting — M
Build HTML from the tokens (colors from the syntax theme), then print or
save through the platform.

## 7. Platform integration

### I1. Single instance on Linux and Windows — M
Linux uses `G_APPLICATION_NON_UNIQUE` (`linux/runner/my_application.cc`),
and Windows doesn't forward argv. Opening a file from the file manager
while Planchette runs starts a second window.
- **Linux**: drop NON_UNIQUE, handle `open`/`command-line` in the primary
  instance, and forward paths to Dart over the existing
  `planchette/documents` channel.
- **Windows**: use a named mutex, and `WM_COPYDATA` to the existing
  window.

### I2. macOS document affordances — S–M
Set `NSWindow.isDocumentEdited` (the dot in the close button) instead of
a "●" title prefix, and `representedURL` for the proxy icon. Add
`public.data`/`public.item` document types so extensionless files
(`Makefile`, `.env`) offer Planchette in Open With
(`macos/Runner/Info.plist`).

### I3. Save-time metadata — M, risk: medium
Saving swaps inodes, so hard links, xattrs, ACLs, Finder tags and
creation dates are lost. Only mode bits are restored
(`text_document.dart`). Option: copy xattrs on macOS and Linux (via
`listxattr`/`getxattr`/`setxattr` FFI) before the rename. Document which
metadata survives in ARCHITECTURE.md.

### I4. Directory write permission — S
A writable file in a read-only directory can't be saved, because the
temp sibling can't be created. Explain this in the error, and offer
"Save As…".

### I5. Host-neutral wording in core errors — S
Core messages say "the local copy", which is Poltergeist/Séance
vocabulary. Make the messages injectable (like `EditorStrings`), or use
neutral wording, and check both hosts' error adapters first.

## 8. Visual design and theming

### V2. More token classes — M, risk: medium
A follow-up to #41.
Five classes (comment, string, number, keyword, meta) limit themes. Add
`type` (capitalized identifiers in C-family, Dart, Swift, Kotlin and
Rust), `function` (an identifier before `(`), and `constant`.
`SyntaxTokenType` is used by hosts, so coordinate the enum change or add
optional theme fields with defaults.

### V4. Search bar polish — partly done in #44
**Landed in #44:** the find field had **no border, no icon and no clear
button** — `isDense: true, border: InputBorder.none` and nothing else — so the
query floated in the toolbar with nothing saying it was something to type into,
in a dialog that renders boxed `TextField`s everywhere else in the same file.
It has a box, a magnifier and a clear button now.

**Still open from this item** (#36's surface and fill are in the other branch,
so the two will need reconciling): the match count as a chip rather than loose
text — #44 gives it the error colour but it is still loose text; the two fields
sharing one bordered group instead of two separate boxes; the bar spanning only
as much width as it needs.

### V5. Status bar segments — S
#36 aligned the leading edge with the text column and stopped claiming a
language for a file too large to highlight. After #33, turn the "·"-joined
text into distinct, clickable segments (see E10) and show "Unsaved" as a
dot. The language id is still a raw value — `shell`, `c-family`, `dotenv` —
and `c-family` is an internal grouping that means nothing to a reader;
#33 adds display names.

### V6. Error banner with actions — S
#21 stopped `FileSystemException` and errno text reaching the user for a
missing or unresolvable path, in the core so both hosts get it. What is
left: map the remaining failures (permission denied, read-only directory,
a save conflict) to friendly text with actions (Retry, Save As, Reveal,
Dismiss), in the style of the disk notice in #26. A UTF-16 file still ends
at "This file is not valid UTF-8 text." with no way forward — see A9.

### V6a. The active search match fails AA contrast in the light theme — S (confirmed)
`EditorSyntaxTheme.light.activeMatchBackground` is `#3D8A78` with
`#FFFFFF` text: **4.11:1**, below the 4.5:1 WCAG AA requirement for normal
text. Every other token passes comfortably — light 5.29–7.06:1, dark
7.09–10.91:1 — so this is an isolated fix. The same hue is also a
desaturated teal that reads as muddy grey-green beside the Material
primary. **Plan:** darken the light active-match background to about
`#2F6E5E` and add a contrast test in the editor package that checks every
token against both the surface and the current-line band.

**With #41:** that PR's Parchment and Séance themes are AA-checked, so the
fix is probably theirs to make. What is still needed either way is the
*test* — #41 adds the colours, but nothing stops the next one from shipping
a 4.1:1 pair. Add the contrast test to the editor package once the theme
extension exists, and check the current-line band as well as the surface.

### V7. Scroll past the end — S
The last line sits at the bottom edge. Add bottom padding of about half
the viewport to the document field. The gutter geometry from #22 already
follows the text.

### V8. Unified macOS title bar — M
Use `TitleBarStyle.hidden` with the traffic lights over the tab strip,
so tabs sit in the title bar as in Safari and Xcode. Needs drag-to-move
regions in the strip and double-click to zoom.

### V9. Bundled monospace font — S
For identical metrics everywhere, bundle an OFL font such as JetBrains
Mono or Iosevka as the first family in `editorMonospaceFor` (#30).
Weigh the bundle size (about 300 KB per weight).

### V10. Gutter styling — S
The gutter has a hard 1 px `dividerColor` line. Try a tinted gutter
background with no divider, line numbers one size smaller with tabular
figures, and the current number in the accent color. It lives in the
decorations painter from #22.

### V11. A richer empty state — S
#36 made the empty state the launch state (before, `main()` opened a blank
buffer, so the screen could not be seen without first closing the tab) and
gave it a subtitle and the three main shortcuts. What is left: recent files
(A3), a drop hint once A4 exists, and the planchette easter egg in Q2. Keep
focus handling: New and Open shortcuts must keep working with no tab open,
as covered by the existing test.

**On claiming features in the UI:** #36's first draft of this screen said
"or drop a file here to open it". Drag and drop is not implemented. A claim
the app cannot honour is worse than its absence — do not ship copy for a
feature that is not in the build.

### V12. The editor is nearly invisible to a screen reader — M (read)
`packages/planchette_editor/lib/src/editor_view.dart` renders a bare
`TextField` with no label, so a screen reader announces an unlabelled
multiline field. The status bar is not wrapped in `ExcludeSemantics`, so
`Ln 4, Col 12 · 88 lines · 2,913 bytes · CRLF · UTF-8` is read unprompted
on every caret move, and the workspace error banner is not a live region,
so a failure to open a file is silent. macOS has an accessibility fixture
(`scripts/test-macos-accessibility.sh`) but it tests lifecycle, not content,
so none of this is caught. **Plan:** give the document field a semantics
label, `ExcludeSemantics` the status bar, wrap the error banner in
`Semantics(liveRegion: true)`, and add a semantics test asserting the
editor's node exposes a label.

### V13. The editor and its chrome use two unrelated typefaces — S (read)
The document uses `fontFamily: 'monospace'` while the status bar, find bar
and gutter numbers use the platform UI font. The find fields were moved to
the editor's face in #36, which makes the mismatch sharper rather than
solving it: a search pattern is now shaped the way it will match while the
match counter beside it is not. Either commit to the mono face for
everything that describes the buffer (gutter, status, find) or keep the UI
font throughout and accept the difference. #36 also applies
`visualDensity: VisualDensity.compact` globally, which leaves the find
fields under-padded next to their own buttons.

### V14. The window flashes white before the first frame on Windows and Linux — S (read)
`DesktopWindow.initialize` sets the size, position and title but never
`windowManager.setBackgroundColor`, so the native window shows the default
white until Flutter's first frame. Painful in dark mode.
**Plan:** call `setBackgroundColor` with the surface colour for the current
brightness before `waitUntilReadyToShow`, and consider keeping the window
hidden until it is shown (which also fixes B4's startup jump).

### V15. The tab strip needs a defined container — S (idea)
#36 gave the strip a full-width surface and a fixed row, which is most of
what it needed, but the inactive tabs still have no background and the
active one is a white rounded rectangle with no rule tying it to the editor
below. A subtle inset border around the strip, or a hairline under it, would
make it read as a bar rather than a row of pills. Paint it in the same place
as the rest of the chrome so it is one decision, not three.

## 9. Delightful and quirky ideas

- **Q1. The planchette caret.** An optional caret shaped like a tiny
  planchette (a heart-shaped pointer with a lens) that glides between
  positions with a short ease instead of jumping. Put it under View ›
  Caret Style, off by default, and respect reduced motion.
- **Q2. Spirit-board empty state.** Draw an arc of A–Z and YES/NO in the
  theme's ink. Hovering New or Open makes a faint planchette drift toward
  YES. Keep it quiet: an easter egg, not an animation to sit through.
- **Q3. Séance mode (focus mode).** Hide all chrome, dim every line
  except the current paragraph, and center the text column. Toggle with
  Cmd/Ctrl+Shift+Enter.
- **Q4. Automatic writing.** After a short idle pause, faintly underline
  every occurrence of the word under the caret.
- **Q5. Ghost text for untitled documents.** A faint rotating placeholder
  ("The spirits are listening…", "Type to summon…") that disappears on
  the first keystroke.
- **Q6. Board words in the status bar.** A one-shot "YES" drifting across
  the status bar after a successful save, and "GOODBYE" when the last tab
  closes. Subtle, and skipped under reduced motion.
- **Q7. Minimap as a board.** A narrow overview strip showing the
  document's silhouette, search hits and the viewport. Realistic with P3.
- **Q8. Rainbow CSV columns and log-level coloring.** Color each CSV/TSV
  column in turn. In `.log` files, color ERROR, WARN and INFO and dim
  timestamps. Both are small tokenizer additions.
- **Q9. Inline color swatches.** A small swatch before `#RRGGBB`,
  `rgb(…)` and `Color(0xFF…)` literals in CSS, JSON and Dart, painted by
  the decorations render object.
- **Q10. Clickable paths and URLs.** Cmd/Ctrl-click a path or URL in the
  text to open it.
- **Q11. Quote and bracket teleport.** `Cmd/Ctrl+B` jumps the caret to the
  matching bracket, and a modifier variant toggles between the two quotes of
  a string literal. This is the most satisfying micro-feature in a text
  editor and it is cheap: a small pure matcher in `planchette_core` that
  uses the tokenizer to skip strings and comments, plus one paint in the
  decorations render object from #22 to show the partner while the caret is
  touching it. Does the same work give E4 for free.
- **Q12. Peek the caret's line.** One extra dimmed row in the status bar
  showing the caret's whole logical line, truncated in the middle. In a
  10,000 line file it gives structural context for one row of layout, and it
  doubles as the place to surface a selection's column span (E10b). Keep it
  to one line and let it be hidden in a narrow window.
- **Q13. Quiet "this changed on disk" inline notice.** #26 adds the notice;
  give it a quieter form for the common case — a dim line above the status
  bar rather than a modal-feeling banner — and make the Revert action
  reachable from the status bar too.
- **Q14. Trim trailing whitespace and a final newline on paste.** Not a
  setting, just correct behaviour: strip trailing spaces from a pasted line
  and add the final newline if the file already had one. Cheaper to live
  with than to look for afterwards.
- **Q15. "Ask the board" scratch buffer.** A persistent SCRATCH tab that
  survives sessions — paste-and-forget notes that never need a filename.
  Small once session restore (A2) exists.
- **Q16. The board answers when idle.** Leave the empty state untouched
  for a while and the planchette drifts across the letter arc to spell
  something. Subtle, disablable, skipped under reduced motion — a
  companion to Q2, not a screen saver.
- **Q17. Ritual incantations.** `:wq` or `ZZ` in the Go to Line field —
  or the command palette once A6 exists — saves and closes the tab. The
  editor answers to muscle memory.
- **Q18. Typewriter mode.** The caret line stays vertically centered
  while typing, so neck and context stay still. One scroll-offset rule;
  toggle under View, and make it compose with V7's scroll-past-end
  padding.

## 10. Process and documentation

- **D0a. Dead code in the shared public API.** `EditorController` is a
  host-facing surface for three applications, so an unused member is not
  dead code in the usual sense — but it is untested-in-anger and
  unmentioned in `docs/STATUS.md`. Confirmed by grep:

  | member | status |
  |---|---|
  | `EditorController.reload()` | **called from nowhere** — not the app, not a host, not a test. It exists to retry a failed load, and the view's error branch shows the message with no button. Wire it to a Retry, or drop it. |
  | `EditorSaveMode.local` | never passed by any caller |
  | `EditorController.canPublish` | read only by its own test |
  | `defaultTextDocumentMaximumBytes` | a redundant alias of `textDocumentMaximumBytes`, used nowhere |

- **D0b. The dirty-close decision is implemented twice.**
  `EditorController.confirmClose` is the shared, tested contract for "may
  this discard happen", including the revision re-check. The app's
  `DocumentWorkspace._confirmTab` reimplements it with its own revision
  check and never calls the shared one, so the shared one is exercised
  only by its own tests. Two implementations of one safety rule is exactly
  the shape that produces a future divergence bug. Either have `_confirmTab`
  call the shared contract, or delete the shared one and say so in the
  architecture note.

- **D0c. Stale vector source for the app icon.** #4 wired the new PNGs
  into the macOS asset catalog, the Windows `.ico` and `scripts/build.sh`,
  which is what shipped. But `media-sources/icon.svg` is still the *old*
  icon, and it is the only editable source in the tree — so the next person
  to change the icon will regenerate the old one. Replace it with a vector
  of the new design, or note in `media-sources/` that the PNGs are now
  authoritative.

- **D0d. Two authorities for the first window's size.** The GTK runner sets
  `gtk_window_set_default_size(window, 1280, 720)` in
  `linux/runner/my_application.cc`, and `DesktopWindow.initialize` asks
  `window_manager` for `Size(1080, 760)`. Whichever runs last wins, and they
  disagree on both axes. Pick one; the runner is earlier scaffolding, so
  `window_manager` probably should.

- **D0e. Flutter's `DragTarget` cannot be driven from a widget test.**
  Confirmed on Flutter 3.47.2 with a tree containing nothing but a
  `Draggable<String>` and a `DragTarget<String>`: `tester.dragFrom`,
  `tester.timedDragFrom`, a manual gesture with pumps between moves, and
  `PointerDeviceKind.mouse` all leave `onWillAcceptWithDetails` uncalled.
  So a drop target's *wiring* can be asserted (`find.byType(DragTarget<T>)`)
  and its *payload handling* can be extracted into a tested function, but the
  drop itself needs a real desktop run. Do not write a test that appears to
  cover it. #43 does exactly this, and says so in its description.

- **D0f. Checked and dropped.** The initial review suspected that one `İ`
  in a document would make case-insensitive search case-sensitive,
  because `findSearchMatches` falls back when lowercasing changes the
  length. That can't happen on Planchette's targets: on the Dart VM,
  `toLowerCase` uses simple case mapping and changes the length of no
  code point (all 1.1M were checked; `İ` → `i`). It would only matter
  for a web build, where JavaScript applies full mappings.

- **D1. CHANGELOG.** None of the first eight PRs edits `CHANGELOG.md`, to
  avoid eight-way conflicts. #21, #28 and #36 each add their own
  "Unreleased" entries, so those three will conflict with each other on
  `CHANGELOG.md` — resolve by keeping all the entries. Any PR still missing
  one: add it after merging.
- **D2. STATUS.md.** Update "Implemented" and "Current limits" after the
  merges: indentation, disk change detection, zoom, Go to Line, fonts, and
  the diff language. #28 already moved the highlighting limit to 32 KiB in
  all three documents and recorded that a plain 800 KB document still costs
  a few hundred milliseconds a keystroke; keep that. Also note the file's
  verification claims are all macOS-local runs (it cites Flutter 3.47.3
  while CI pins 3.47.2) — fine, but not cross-platform proof.
- **D3. Visual regression shots — do this next.** Real-font screenshots
  caught the centered menu bar that no test noticed, and then the bare find
  fields, the missing scrollbar and the misaligned status bar. A second
  independent pass caught the same centered menu bar again, which is a
  strong argument for making it permanent. **Plan:** a small golden suite
  in the app package, pinned to the fonts in the Dart and Flutter caches
  (`$DART_SDK/bin/resources/devtools/assets/fonts`,
  `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`) so CI is
  deterministic, covering light and dark, three tabs, the find bar open, an
  empty workspace, and a long document so the scrollbar appears. Assert on
  geometry as well as pixels where geometry is the point — the menu bar
  being flush left is one `getRect` comparison and does not need a golden.
  The structural geometry tests in #36 are a partial substitute and should
  stay either way.

- **D4. Focus regressions.** Chrome changes easily break where focus lands
  after dialogs, tab switches and closing search. Keep the app tests that
  assert `editorFocus.hasFocus` after each of those flows, and add one
  whenever a new overlay (palette, Go to Line, notices) appears. Two
  concrete rules from this pass: a shortcut map that consumes a key it cannot
  act on is a focus trap, so #21 now leaves Tab unclaimed while the editor is
  read-only; and a test that disposes a workspace while its focus nodes are
  still attached fails in teardown for reasons unrelated to what it asserts
  (see B13).

- **D5. Desktop verification gap.** Everything above was verified with widget
  tests only — no display was available, so nothing was run on a real
  desktop. Before a release, run a manual pass on real macOS, Windows and
  Linux covering fonts (#30), native menus, IME Enter and Tab (#14, #21),
  focus-driven disk checks (#26), and the scrollbar and find-bar chrome
  from #36.

- **D6. Check a Flutter API exists before wiring to it.** #28's first push
  added a `softWrap` flag, routed the gutter through an "unfolded rows" fast
  path, and asserted in the PR body that word wrap was off by default.
  `TextField` and `EditableText` in Flutter 3.47 have **no** `softWrap`
  parameter. The flag was inert, the gutter mis-numbered any document with a
  long line, and the claim was wrong. One grep of the SDK source would have
  caught it. The same pass found that a reviewer's suggested fix
  (`TextEditingController.userUpdate`) does not exist either, and that the
  real `UndoHistory` behaviour had to be *measured*: an indent turned out to
  be undoable, contrary to the claim. Verify the API, then measure the
  behaviour, then write it down.

- **D7. Timing claims need a same-session baseline.** The first pass of #28
  compared numbers taken minutes apart on a machine other agents were also
  using and briefly reported a win that was noise. Every table in this
  document was re-measured back to back against `main` on an idle machine,
  repeated after each change. A "before" from an earlier run is not evidence.
  Watch for the cliff: the first pass also set the measurement ceiling at
  1 MiB, which regressed a 787 KB document by 1.9x, and only a measurement
  caught that.

- **D8. A golden capture earns its keep.** Rendering the app through
  `matchesGoldenFile` with real fonts loaded by `FontLoader` (Roboto and
  Roboto Mono from the Dart SDK, MaterialIcons from the Flutter cache) is
  what made the centered menu bar, the bare find fields and the missing
  scrollbar obvious. Nothing in the code or the test output hinted at them.
  See D3 for making it permanent.

- **D9. Pin the baseline, not just the finding.** A finding that is
  reproduced but not pinned by a test comes back. Every confirmed item acted
  on in this pass also got a regression test, including the ones that turned
  out to be *non*-issues (D0, and the undo question in the #21 review) — a
  test that says "this is fine" is worth as much as one that says "this was
  broken", and it is cheaper than re-deriving it.

- **D10. Gate `dart format` in CI.** `dart analyze` and `flutter analyze`
  run on every PR, but nothing enforces formatter output, so style drift
  enters one hunk at a time. A `dart format --set-exit-if-changed` leg
  over the workspace packages and the app is one workflow step.

- **D11. AGENTS.md delegates SDK installs to a doc that is not here.**
  "See Poltergeist's AGENTS.md §1" does not exist in this repository, and
  fresh containers ship no Dart or Flutter at all. Copy the incantations
  in-repo: dart-archive stable zip for the Dart SDK, the Flutter release
  tarball for 3.47.2, and note `xz` may be absent — Python's `lzma`
  module extracts `.tar.xz` fine.

- **D12. Port archaeology cleanup — S.** `editor_syntax.dart` is dotted
  with `// 06 §7.3`-style references to decision docs that live in the
  sibling repositories. Either map the numbering in `docs/` or drop the
  references. Also `defaultTextDocumentMaximumBytes` is an unused alias
  of `textDocumentMaximumBytes` kept for host compatibility — remove it
  once no host references it.

- **D13. Index in UTF-16 code units and keep it there.** Dart `String`
  offsets are UTF-16 code units; match ranges, syntax tokens and
  selections all share that convention. Keep new features on it — a
  feature that quietly mixes in byte offsets corrupts positions for
  astral characters. (LSP positions are UTF-16 too, so the convention
  survives even a future language-server client.)

- **D14. `textDocumentSha256` reads the file three times per open** —
  before, during and after. The third pass is what makes the
  changed-during-load guard meaningful; a stream-hash plus one compare
  would only be equivalent if the after-read were free. Leave it.
