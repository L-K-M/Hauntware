# Planchette analysis and backlog

A working backlog for Planchette: review findings, follow-ups, and ideas.
Each open item is written so that an agent can pick it up without
rediscovering the context: why it matters, where the code is, what to
change, and how to know it is done. Read [AGENTS.md](AGENTS.md) first.

- Consolidated 2026-09-27 from the existing backlogs at `e6bd9ba`, `f4c1f46` and `87caa35` and this
  session's review of `e7ec67f`. The inherited reviews cite `d53f416`, `a580387` and `e974cde`; `d53f416`
  also integrated the new icon. Other workers' PRs were not inspected.
- A parallel session implemented and monitored #8/#9/#12/#18 (Go to Line,
  zoom, whole-word search, Reopen Closed Tab) from its own review of
  `e7ec67f`. Its findings are folded into §1/§2/E5/A7/FU2/FU4/FU13/V4/§9/§11
  below; its leftover ideas are consolidated with duplicates removed, and its
  working notes were discarded after the merge. Its PRs overlap #16/#33,
  #25/#30, #44 and A7 — see the overlap rows, do not duplicate them.
- This session: Flutter 3.47.2 / Dart 3.13.2 on Linux; baseline analyses
  passed with 84 core, 19 editor and 38 app tests. Two case-insensitive
  filesystem tests skipped on the local volume. Core performance probes
  used standalone Dart 3.13.4. Inherited baseline results report the same
  test counts at `d53f416`; those results were not independently rerun here.

  The latest inherited report also gives 84/19/38 (two app skips) at `e974cde`.
  Its combined Flutter 3.47.2 / Dart 3.13.4 label needs provenance checking:
  this session used bundled Dart 3.13.2 and standalone Dart 3.13.4 separately.
- Measurement provenance is local to each table/probe. The newer inherited
  keystroke table uses a non-AOT `flutter test` harness; #39 reports file-load
  time/memory, and #5 uses standalone Dart tokenization timings. Do not label
  all timings keystroke costs or infer a fixed release-build speedup.
- Evidence labels: **confirmed** means a reproduced test/probe;
  **read** means source-based evidence; **investigate** needs reproduction;
  **idea** is a proposal. **Inherited** marks another review's report,
  preserved without independently verifying its PR, implementation or timings.
  Source locations refer to the reviewed baselines and may move after merges.
- Effort: S (under an hour), M (half a day), L (days). Risk is the chance
  of regressions in hosts (Poltergeist, Séance) or native behavior.
- Preserve guarded writes, explicit conflicts, BOM/EOL metadata, dirty-close
  guards, saved-revision tracking, per-tab undo/search, injected host themes
  and strings, and the app → editor → core dependency boundary.
- Remove an item once merged, retaining unresolved limits and useful
  acceptance criteria. Open PRs stay listed to prevent duplicate work;
  record merged behavior in CHANGELOG and STATUS as described in D1/D2.

## Contents

0. [Preserve existing contracts](#0-preserve-existing-contracts)
1. [In review](#1-in-review): findings already addressed by open PRs
2. [Follow-ups to the open PRs](#2-follow-ups-to-the-open-prs)
3. [Bugs](#3-bugs)
4. [Performance](#4-performance)
5. [Editing features](#5-editing-features)
6. [App features](#6-app-features)
7. [Platform integration](#7-platform-integration)
8. [Visual design and theming](#8-visual-design-and-theming)
9. [Delightful and quirky ideas](#9-delightful-and-quirky-ideas)
10. [Process and documentation](#10-process-and-documentation)
11. [Review and verification ledger](#11-review-and-verification-ledger)

---

## 0. Preserve existing contracts

The newer inherited review reports direct `LocalDocumentStore`/temporary-file
probes. Preserve their tested contracts, with the limits below:

- Tested load/edit/save/reload fixtures retain expected bytes and digests.
  This does not promise byte-for-byte mixed-EOL preservation: documented
  normalization still applies.
- Its stale-digest fixture preserves the other writer's bytes without leaking
  siblings. Concurrent publication/rollback failures may intentionally retain
  recovery files and must continue reporting their exact paths.
- Save As onto the current path still uses the conflict guard.
- Its BOM/CRLF fixture round-trips `[EF BB BF] a CRLF b CRLF c CRLF`.
- Loading NUL rejects binary content; missing, directory and unresolvable
  paths have explicit failures. Save/load NUL asymmetry remains B20.
- Discard decisions are revision-checked; a native-menu save during a pending
  dialog is rechecked; failed native window destruction releases workspace
  locks. Preserve `_confirmTab` and `EditorSaveResult` contracts.

The inherited source also describes token memoization, a Listenable-driven
gutter and `revealRequest` as useful boundaries. Identity caching helps
unchanged text; it cannot eliminate the cost of changed buffers. Its #28
cost findings are preserved in P1 without concluding every performance issue
is merely a constant choice.

It reports 84 core / 22 editor / 45 app tests at a second `a580387` baseline.
That revision/worktree attribution is unresolved: this session observed
84/19/38 and main's intervening changes were icons/docs. Do not present the
84/22/45 report as independently verified main results. Preserve real
publication, rollback, race and dirty-close regressions before write-path work.

---

## 1. In review

These findings have open PR records against `main`, left for the owner's
review. Do not duplicate their implementation. If a PR closes unmerged,
restore its outstanding work to the backlog. Twenty-nine records below are
inherited from those main-branch documents; their statuses and claims were not independently
checked. Four additional PRs were implemented and monitored in an earlier session,
and seven more in the 2026-09-27 review pass.
The newer inherited source warns that more parallel PRs may exist. This is
not a complete ownership registry; refresh coordination from authorized
repository records before duplicating work. This session did not list or
inspect other workers' PRs.

### Verified in this session

| PR / branch | Change and proof | Latest recorded status |
|---|---|---|
| [#5](https://github.com/L-K-M/Planchette/pull/5), `codex/css-tokenizer-bound-20260927` | Bound CSS property candidate starts. A 20k colonless identifier fell from 7.456s to about 31ms; 200k took about 27ms after warmup, on Linux/Dart 3.13.4. Regression failed first; 86 core tests and analysis pass. Custom/vendor properties and comment/string precedence retained. | Open at `91ad93c`; all CI passed; two fresh GLM reviews on the same revision, no applicable important findings. |
| [#6](https://github.com/L-K-M/Planchette/pull/6), `codex/long-filenames-20260927` | A valid 234-byte filename could not save because recovery suffixes exceeded component limits. Bound recovery names to 255 UTF-8 bytes without splitting Unicode. Eight tests cover 255-byte ASCII/emoji names, three host prefixes, rollback, retained backups, relative paths and oversized prefixes. Four original regressions plus the relative-path regression failed first; 92 core tests and analysis pass. | Open at `2437ee7`; all CI passed; two GLM rounds without important findings. |
| [#10](https://github.com/L-K-M/Planchette/pull/10), `codex/search-accessibility-20260927` | Keyboard-accessible search controls and selected semantics; adaptive narrow/scaled layouts. Six original regressions failed first, followed by a regression for input-connection retention during resize. Nine new tests; editor 28/app 38 tests pass, two app filesystem skips. Real-font captures inspected. | Open at `718fa21`; all CI passed; three GLM reviews, last two without confirmed important findings. Final same-revision review was fresh, not cached. |
| [#11](https://github.com/L-K-M/Planchette/pull/11), `codex/visible-tabs-20260927` | Bounded labels retain close/dirty controls and full-path tooltips; active tabs reveal after selection, resize and scaling. Also fixes a reproduced focus race when switching to an earlier tab. App 42/editor 19 tests pass, two app filesystem skips. Real-font light/dark captures inspected. | Open at `d72013d`; all CI passed; two fresh GLM rounds without important findings. Overlaps inherited #35/#36/#43; coordinate before merging. |

Combined proof for these four PRs: their diffs apply together without conflicts;
all three analyses pass; 94 core, 28 editor and 42 app tests pass, with two
case-insensitive filesystem skips. This does not test combinations with the
twenty-nine inherited PRs. Local captures covered search at 320/360/800px and the app
at 640×400 in light/dark. No hands-on native macOS/Windows visual session.
Original CSS probes also measured 1k=31ms, 5k=744ms and 10k=2.80s before fixing.

### Implemented and monitored in a parallel session

Four more PRs (`planchette/*` branches, [#8](https://github.com/L-K-M/Planchette/pull/8),
[#9](https://github.com/L-K-M/Planchette/pull/9),
[#12](https://github.com/L-K-M/Planchette/pull/12),
[#18](https://github.com/L-K-M/Planchette/pull/18)) were implemented against
`e7ec67f`/`d53f416`, verified locally with Flutter 3.47.2 / Dart 3.13.2
(analyze clean; suites green as listed), reviewed by GLM rounds, and left
open for owner review/merging. They overlap #16/#33 (Go to Line), #25/#30
(zoom), #44 (search) and A7 (reopen); coordinate per the overlap rows below
and E5/A7/FU2/FU4/FU13/V4 notes, and do not duplicate them.

| PR / branch | Change and proof | Latest recorded status |
|---|---|---|
| [#8](https://github.com/L-K-M/Planchette/pull/8), `planchette/go-to-line` | Find-menu Go to Line dialog (Ctrl+L all platforms), `EditorController.gotoLine` with clamp, view scroll via the gutter line-top cache with a shared `_estimatedLineTop` fallback, digits-only input. Controller clamp/scroll tests plus an app widget test over shortcut and menu paths; editor 20 and app 40 suites pass. | Open at `9a6a272`; CI green. Round 1 minor-only addressed; round 2 raised only a disproved `int.clamp` compile claim (analyzer, tests and CI green on the sha). No valid important findings; steady. |
| [#9](https://github.com/L-K-M/Planchette/pull/9), `planchette/editor-zoom` | View menu Zoom In/Out/Reset (Ctrl/Cmd+=/-/0 plus numpad +/-, Shift-tolerant `=`), 8–32 clamp, session-only size state applied to every tab. Widget test pins clamps, background-tab tracking and the rendered monospace/1.35 style on all three variants. | Open at `4886cb7`; CI green. Round 1 fixed a real style-replacement regression the review caught; round 2 minor-only addressed; round 3 (comment-accuracy, editor-constants suggestion) accepted-in-principle but deferred without push per stopping rules, recorded in FU4. Steady, left open. |
| [#12](https://github.com/L-K-M/Planchette/pull/12), `planchette/whole-word-search` | Core `wholeWord` search option (ASCII alnum/`_` and BMP non-ASCII are word chars; astral surrogates are boundaries; CJK/full-width punctuation stays word content), controller toggle flowing into find and Replace All, underlined-`ab` button with `isSelected` on both search toggles. Core 85 and editor 20 suites pass. | Open at `a7af694`; CI green. Two minor-only rounds addressed; round 3 single minor (needle-edge `\b` parity) accepted-in-principle but deferred without push per stopping rules, recorded in E5. Steady, left open. |
| [#18](https://github.com/L-K-M/Planchette/pull/18), `planchette/reopen-tab` | Ten-deep closed-tab snapshot stack (text, save identity, full selection with affinity, dirty state) restored without a disk round-trip via a `restoreSnapshot` seam; Ctrl/Cmd+Shift+T and File menu; path reopened meanwhile is selected, not duplicated; save conflict guard still fires; cancelled closes enqueue nothing; restore writes outside undo history. App 45 and editor 20 suites pass. | Open at `6b2786b`; CI green. Round 1 (false `int.clamp` blocker declined; selection/cancel/conflict/undo accepted) and round 2 single minor (affinity) addressed. Awaiting confirmatory round 3. |

### Implemented and monitored in the 2026-09-27 review pass

Seven PRs (`fix/*` branches) were implemented against `797deb9`, each
verified locally with Flutter 3.47.2 (`analyze` clean; suites green as
listed; two app filesystem skips expected on a case-sensitive volume) and
left open for owner review/merging. They were kept deliberately small to
avoid colliding with the inherited PR territories above.

| PR / branch | Change and proof | Latest recorded status |
|---|---|---|
| [#57](https://github.com/L-K-M/Planchette/pull/57), `fix/save-rejects-nul` | B20 + B14: `_writeTextDocument` rejects NUL before publication, sharing `_firstNulIndex` with the loader's binary rule so the two cannot drift; the error names the first NUL's code-unit offset, and the 0x180/0x1ff literals became named constants. Regression asserts the original bytes and no leaked siblings; 85 core tests pass. | Open; round 1 GLM findings (matcher pinning, NUL offset, shared predicate) applied; awaiting round 2. |
| [#58](https://github.com/L-K-M/Planchette/pull/58), `fix/save-error-messages` | B-d/F-b/F-c core half + I4's explanation: temp-create failures wrap in `TextDocumentException` naming the unwritable folder and carrying the real `osError` detail and original stack; a vanished destination reports a mid-save conflict only on ENOENT, other rename failures keep an honest cause. Read-only-folder test skips under root and restores the recorded dir mode. 85 core tests pass. | Open; round 1 GLM findings (osError/stack, root guard, ENOENT-only conflict) applied; awaiting round 2. |
| [#59](https://github.com/L-K-M/Planchette/pull/59), `fix/multi-open-errors` | B15: `openDialog` collects a failure record per file and reports one message with the count, every failed name and each error, instead of keeping only the last; single failures keep the old shape. App 40 + 2 skipped. | Open; GLM review in progress. |
| [#60](https://github.com/L-K-M/Planchette/pull/60), `fix/close-tab-consistency` | B5 + B24 (partial): Close Tab follows the tab ×'s `!busy` rule — loading and load-error tabs close, in-flight saves still refuse; `_nextTab` selects the first tab instead of unwrapping a null active. Widget test closes a tab mid-load and confirms the in-flight open unwinds. App 42 + 2 skipped. | Open; GLM review pending. |
| [#61](https://github.com/L-K-M/Planchette/pull/61), `fix/open-dash-filenames` | `OpenDocuments.start` dropped every argv entry starting with `-`, so `planchette -draft.txt` silently lost a real file. Only macOS Finder's injected `-psn_*` is filtered now; other entries reach `open` as paths. App tests updated. | Open; GLM review pending. |
| [#62](https://github.com/L-K-M/Planchette/pull/62), `fix/startup-window-size` | B4: both desktop runners now create the window at 1080×760 centered on the work area (Windows computes a DPI-aware centered origin), matching `WindowOptions` so an early-shown frame already has final geometry. `window_manager` keeps owning runtime size. | Open; GLM review pending. |
| [#63](https://github.com/L-K-M/Planchette/pull/63), `fix/linux-title-sync` | B-b/I6 (upgraded to confirmed-by-reading): a `GtkHeaderBar` titlebar does not follow `GtkWindow:title`, so filename/dirty title updates were invisible on GNOME/Wayland. `notify::title` now syncs the header bar. | Open; GLM review pending. |

### Inherited PR records

The evidence labels and measurements in this table belong to the inherited
review. They are retained as reports, not claimed as this session's results.

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

The newer inherited review adds three branch records and the overlap table
below. Their implementation and test claims remain unverified here:

| PR | Addresses |
|---|---|
| [#21](https://github.com/L-K-M/Planchette/pull/21) `fix/review-correctness` | **Tab could not be typed at all** (**confirmed**): the document is a bare `TextField`, so Flutter routed Tab to focus traversal, and pressing it moved focus out of the editor and inserted nothing. Adds `insertIndent` / `removeIndent` / `measureIndentation` to `planchette_core`, Tab and Shift+Tab in the editor matching the file's own tabs or spaces, and padding to the next tab stop when the caret follows code. Also: **Find Next was a dead key whenever the find bar was closed** (**confirmed** — `F3` after Escape did nothing), now reopens the bar with the remembered query; **a missing or unresolvable file surfaced as a raw `PathNotFoundException` naming the syscall and errno**; the toolbar printed the empty state's marketing line next to any untitled document; and opening three files made the next new document "Untitled 4". Core 113 tests, editor 31, app 39 + 2 skipped |
| [#28](https://github.com/L-K-M/Planchette/pull/28) `perf/keystroke-cost` | **The gutter re-laid out the whole document on every keystroke and then asked for one caret offset per line** (**confirmed**: 59.0 ms layout + 124.3 ms of `getOffsetForCaret` for 5,001 lines, against 9.1 ms for a single `computeLineMetrics`). One metrics call replaces the caret loop; revealing a match reads the cached tops instead of measuring. **Highlighting added substantial cost over plain text** (79 KB JSON: 12,001 spans, 11 ms to build the tree, 70 ms to lay it out, against 35 ms plain), so the cap moves from 200,000 characters to 32 KiB and the status bar says `Large file` instead of silently dropping colours. See P1 and P3 for what is left |
| [#36](https://github.com/L-K-M/Planchette/pull/36) `ui/window-chrome` | **The menu bar and tab strip were drawn in the middle of the window** (**confirmed**: a `Column` centres its children across the cross axis and both shrink-wrap — the `MenuBar` measured x 537–863 in a 1400 px window, the first tab label started at x 426). **The toolbar repeated the File menu, the tab and the window title.** The source reports 52 logical pixels for the toolbar and 132 before the first character (14.7% of a 900 px window); its stated 23% needs a different denominator and is not supported by these measurements. The empty state is now the launch state, so the only screen offering New and Open is reachable. The find and replace fields had no outline, no fill and no surface (bare text with a caret in dark mode); **the editor had no scrollbar at all**; the status bar's readout started under the line numbers instead of under the text; two tooltips appeared at once on a tab; a tab's ink splash painted a square over its rounded corners; the dirty marker was a bullet character depending on the UI font; a horizontal scrollbar in a 40 px strip would have clipped the last close button. Plus a real `ThemeData` (flat dialogs, fast square tooltips, thin always-visible scrollbar, menu bar with a baseline rule). Core 84, editor 22, app 45 + 2 skipped |

Further inherited PR records, not inspected or independently verified here:

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
| [#40](https://github.com/L-K-M/Planchette/pull/40) `fix/temp-leftover-sweep` | Reports an age-based deletion approach to B10: sweeps `.planchette-<uuid>.edit`/`.backup` siblings older than 7 days when a document opens, keyed on `changed` — a `.backup` inherits the old file's mtime, so `modified` could call a fresh recovery file ancient. B10 retains ownership/recovery safeguards; age-only deletion is not accepted as safe |
| [#42](https://github.com/L-K-M/Planchette/pull/42) `feat/tab-close-others` | Middle-click closes a tab; right-click offers Close / Close Others / Close All Tabs, each still running the per-tab consent decision with Cancel stopping the sweep. Covers part of A7 and the context-menu part of FU5 |

From the fourth inherited pass. Its ancestry description is internally
inconsistent: it calls these five one chain, but reports #34 based on main,
#37 on #34, #43 on #37, #27 independent, and #44 based on #27. It also says
#44 can merge either side of #27. Do not adopt that order. Verify actual
ancestry/base dependencies before integration; tests reportedly include stacked
changes and are not proof each PR works alone against main.

| PR | Addresses |
|---|---|
| [#27](https://github.com/L-K-M/Planchette/pull/27) `perf/gutter-window` | Reports warmed JIT keystrokes on one 122,161-character fixture improving 173→36ms; bare TextField was 34ms. This does not establish an any-size bound. The stated 145→2ms editor overhead is inconsistent with 173−34=139; separate layout/caret probes report 139ms and 104ms and cannot be added as components of the 173ms total. Measures a viewport prefix plus 64 rows, extrapolates the rest and reuses the prior prefix as a floor during scrolling; reports logarithmically many prefix expansions, shared find-reveal geometry and a corrected one-row extrapolation drift. Compare alternatives in FU9 and retain P1’s abandoned-prototype measurements. |
| [#34](https://github.com/L-K-M/Planchette/pull/34) `feat/code-style-input` | **Tab did nothing in the document** (**confirmed** by probe: the text was unchanged *and* focus was unchanged, so it was swallowed rather than traversing). Enter did not carry indentation. Brackets did not pair. Adds Tab/Shift+Tab, Enter-keeps-indentation with a block-opener rule, and bracket/quote pairing with type-over. Covers E3, E10a and the Tab half of the focus bug. Core 98, editor 45, app 40 |
| [#37](https://github.com/L-K-M/Planchette/pull/37) `feat/settings` | **Every adjustable thing was a compile-time constant** — theme pinned to `ThemeMode.system` in `main.dart`, font size to 14, font family to `'monospace'`, and no indent at all. A settings file, a controller over it, a live-preview preferences dialog, and the shell's hardcoded English extracted to `ShellStrings`. Covers A1 and part of FU4. App 72 |
| [#43](https://github.com/L-K-M/Planchette/pull/43) `feat/shell-chrome` | **~130 px of chrome before the first character, in rows that repeated each other** (**confirmed**). The dirty marker was a `'● '` prefixed onto the tab's *label string*, so every tab changed width the moment it was edited and again when saved; the error banner was a row spliced into the column, so a failed save moved the document; tabs were basename-only, so ten `index.js` files looked identical; the strip never scrolled the active tab into view; nothing handled a dropped file. One strip, a fixed-width dirty slot, the directory beside the tabs, the error as an overlay, active-tab reveal on every selection change, and a drop target. Reports work toward A4 (native drop verification remains), the stable dirty slot, and V6's placement |
| [#44](https://github.com/L-K-M/Planchette/pull/44) `feat/find-query` | **The find bar matched plain text and nothing else**, and a mistyped pattern was indistinguishable from no match. Adds a `.*` toggle, `planchette_core.FindQuery` with compile-once, a visible pattern error, zero-width-match handling, field chrome, and a selection word/character count in the status bar. Covers the regex half of E5, the field part of V4, and the selection-summary half of E10b. Core 94, editor 41, app 40 |

Opened after the consolidation by the session that opened #14–#41. Each
passed local analysis and all three test suites before it was pushed; CI
and review status live on the PRs.

| PR | Addresses |
|---|---|
| [#47](https://github.com/L-K-M/Planchette/pull/47) `claude/kind-mendel-urd9v5-lines` | E2: Duplicate Line (Cmd/Ctrl+Shift+D), Move Line Up/Down (Option/Alt+↑/↓), Delete Line (Cmd/Ctrl+Shift+K) and Join Lines (Cmd/Ctrl+J), on the keyboard and in the Edit menu. Pure core transforms return a `LineEdit` (text, base, extent); a selection ending at a line start does not touch that line, and backward selections stay backward. Keys are bound around the document field only; a locked document or an IME composition leaves them to the field; a command at the edge consumes its key. **A programmatic edit does not scroll the field**, so a line moved past the bottom vanished (**confirmed**: the regression failed first); the controller bumps `caretRevealRequest` and the view calls `EditableTextState.bringIntoView`. Core 109, editor 34, app 40 + 2 skipped |
| [#49](https://github.com/L-K-M/Planchette/pull/49) `claude/kind-mendel-urd9v5-readonly` | B3 (**confirmed**: a core test shows a `chmod a-w` file replaced by a save). `isTextDocumentWriteProtected` reads the write bits, which Dart also reports for the Windows read-only attribute; Windows CI sets it with `attrib +r`. A plain save of such a file asks Save As… (default) / Save Anyway / Cancel; Save Anyway is remembered for that tab and path, an explicit Save As does not ask, and close-to-save asks too. On Windows the save also restores the read-only attribute and clears it on the backup so the backup can be deleted (**confirmed** by Windows CI; the attribute was lost and a `.backup` sibling left behind before). Core 86, app 46 + 2 skipped |
| [#50](https://github.com/L-K-M/Planchette/pull/50) `claude/kind-mendel-urd9v5-palette` | A6: Cmd/Ctrl+Shift+P and Window › Command Palette… list every enabled menu command with its menu and platform-styled shortcut. Best-alignment fuzzy match (word starts and runs score, gaps cost), shorter label then menu order on ties, matched letters in bold, Up/Down wrap, Enter or click runs after the palette closes, Escape closes. Reads the same `_ShellMenu`/`_Command` model as both menu bars. App 50 + 2 skipped |
| [#51](https://github.com/L-K-M/Planchette/pull/51) `claude/kind-mendel-urd9v5-reopen` | A7's Reopen half, **path-only**: a 20-entry stack of files the user closed through `closeTab`, File › Reopen Closed Tab (Cmd/Ctrl+Shift+T), skipping entries opened again. Duplicates #18, which restores text, selection and dirty state from snapshots and so supersedes it; merge one (see Overlaps). App 42 + 2 skipped |
| [#52](https://github.com/L-K-M/Planchette/pull/52) `claude/kind-mendel-urd9v5-ghost` | Q5: `PlanchetteEditor.placeholder` (faint italic, editor face, gone on the first keystroke) and one of five "Start typing. The board is waiting…" lines per untitled tab; opened files show none. Editor 21, app 39 + 2 skipped |
| [#53](https://github.com/L-K-M/Planchette/pull/53) `claude/kind-mendel-urd9v5-plurals` | Every new document's status bar read `1 lines · 0 bytes`; `documentPosition` now says `1 line`, `1 byte`. Editor 20 |
| [#54](https://github.com/L-K-M/Planchette/pull/54) `claude/kind-mendel-urd9v5-locks` | B17 (**confirmed**: three of its four lock tests fail on main). The controller keeps the host's lock and each mounted view's lock apart; `editingLocked` reports either and every guard reads it. Each view registers itself, so a same-frame remount under another parent keeps its lock (a review finding on the first version, fixed with a regression test). Editor 24, app 38 + 2 skipped |

**Overlaps between PRs.** Findings were repeated across parallel review passes — and are addressed by more than one open
PR. Merge coordination should retain the intended behaviors and acceptance
tests, not blindly combine competing implementations:

| Finding | Reported PRs | Integration requirement |
|---|---|---|
| Indentation/input | #13/#14/#21/#34/#37 | #13 preserves backward selections; #14 adds key modes and line edits; #21 supplies core transforms, detected convention, true input stops and read-only traversal. #34 reacts to platform text edits through `EditorIndent` and a language predicate; preserve its narrow-edit guard and explicitly test paste/IME/undo. #37 persists indent settings and reportedly adds equality for round trips. Reconcile one core edit model. |
| Gutter geometry | #22/#27/#28/#32 | #22 adds a decorations render object/current-line band; #28 uses one `computeLineMetrics`; #32 splices cached per-line heights; #27 measures a viewport prefix, extrapolates the tail and shares reveal geometry. The source prefers #32 over #27 based on reported O(changed-region) versus O(lines) work; that ignores possible affix/layout/cache costs, so benchmark correctness and complete workloads before choosing. Keep one geometry owner. A real Linux X11 release build of `e0acb11` draws each number about 6 px below its line (DejaVu Sans Mono via `monospace`); check the chosen owner on a native build, not only in widget tests. |
| Go to Line | #16/#33 | Preserve #16’s dialog/error clearing and #33’s clickable status/platform find chords. |
| Go to Line (parallel #8) | #16/#33 plus [#8](https://github.com/L-K-M/Planchette/pull/8) | #8 adds a Ctrl+L dialog on all platforms, clamp/scroll/focus semantics and a digits-only field. Reconcile shortcuts (Ctrl+G stays Find Next on macOS in #8) and keep one dialog. |
| Font zoom | #25/#30/#37 | #25 scales text style with gutter/reveal; #30 adds platform monospace and Actual Size; #37 persists preferences. Reconcile shortcuts, scale and storage. |
| Font zoom (parallel #9) | #25/#30/#37 plus [#9](https://github.com/L-K-M/Planchette/pull/9) | #9 ships Ctrl/Cmd+=/-/0, numpad +/-, a View menu, an 8–32 clamp and a rendered-style contract test; size is session-only. Persistence stays with #37/FU4; reconcile steps, Actual Size and storage on merge. |
| Revert | #26/#38/#19 | #38 adds the File command; #26 reports disk notices/recreate-on-save; #19 fixes load-boundary undo. Preserve all safety/lifetime behavior. |
| Reopen closed tab (parallel #18) | A7 plus [#18](https://github.com/L-K-M/Planchette/pull/18), #51 | #51 is a path-only duplicate opened before #18 was recorded here; prefer #18 and close #51 unless path-only is wanted. |
| Reopen closed tab (detail) | #18 | #18 restores text/identity/selection from a 10-deep snapshot stack, which supersedes A7's path-only stack and its "do not promise discarded-text recovery" constraint — recovery is real and guarded by the save conflict check. Keep its cancel/conflict coverage and FU5's remaining actions. |
| Tabs/chrome | #11/#35/#36/#43 | Retain #11’s focus/visibility tests, #35’s tab commands, #36’s row geometry/ThemeData and #43’s fixed dirty slot/directory display. #43 removes the header; geometry improvements still need validation in the chosen layout. |
| Untitled names | #21/#35 | Preserve separate counter semantics and decide name reuse. Empty-tab reuse remains B23. |
| Search/status | #10/#33/#36/#44 | Keep #10’s keyboard/IME/responsive guarantees, #33’s clickable position/display names, #36’s surfaces/alignment and #44’s regex errors/selection counts. |
| Error presentation | #21/#26/#36/#43 | Preserve core missing-path errors, disk-change mapping and user-facing copy; #43 reports an overlay preventing document movement. Placement must not obscure input or silence accessibility. |
| Line edits | #14/#21/#23/#47 | #47's `LineEdit`, #14's `IndentEdit` and #21's `TextEdit` are one shape (new text plus selection); keep a single type. #23 and #47 both add Edit-menu items and document key bindings; keep both sets. |
| Caret reveal | #33/#47 | Both add `caretRevealRequest`. #33 puts a Go to Line target a third of the way down; #47 scrolls a line command's caret minimally with `bringIntoView`. Keep one counter and both placements (FU2). |
| Store/dialog interfaces | #26/#49 | Both extend `DocumentStore` (#26 `stamp`, #49 `isWriteProtected`) and `DocumentDialogs` (#26 `confirmRevert`, #49 `chooseReadOnlySave`). Keep all members. |
| Menus and palette | #30/#36/#43/#50 | #50 lists whatever `_menus()` returns and adds one Window item. Move it to View once #30 lands, and keep it reading the same model after #36/#43 rewrite the shell. |
| Tab context actions | #35/#42 | #42 reports middle-click and Close/Close Others/Close All, with Cancel stopping consent traversal. Retain remaining FU5 actions. |

**Inherited merge-order notes.** Earlier sources report branches based on `d53f416`; the latest source
adds the inconsistent stack claims above. Predicted conflicts/clean merges are not verified here; check actual integration and preserve each behavior:

- #14 and #33 both edit the status list in `editor_view.dart`. Keep both
  the indentation segment and the language display name.
- #30 and #33 both add to the app's Find/View menus in
  `planchette_app.dart`.
- #41 changes the app's `_theme` and the editor's syntax-theme lookup.
  The source predicted no other conflict; verify against #36's theme
  work too, and re-check #22's current-line band on the new surfaces.
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

- #43 rewrites the same shell region as #36, preserves `_menus()` and adds
  Settings. Keep menu commands, geometry and theme behavior, not whichever
  hunk happens to merge last; reported relative diff sizes are not proof of fit.
- #37 reportedly replaces the app's test-only `themeMode` constructor argument
  with required `SettingsController`; app fixtures may need a `MemorySettings`
  double. Check the final API and preserve theme-test coverage.
- #27/#44 are reported stacked and textually compatible, but verify ancestry
  and run combined suites. #27's `line_tops.dart` intentionally remains private;
  exporting it is an API decision, not incidental merge cleanup.

**Additional coordination.** #11 and inherited #35/#36/#43 change tabs and chrome.
Reconcile their behavior; #11 and #35 both change active-tab
visibility. Select and reconcile their final behavior before merging both;
retain #11's earlier-tab focus regression, long-name/close-button visibility,
resize/scaling and undo/search tests. This session did not inspect #35.
#5 and inherited #31 both touch syntax code; #6 and inherited #21/#39 touch document
I/O; #10 and inherited #14/#21/#22/#28/#30/#33/#34/#36/#44 touch the shared surface. Re-run affected
tests after actual integration, not just textual conflict resolution.

**Next work.** Address independent lock ownership (B17) and measure editing
frames (P1). For geometry, reload, navigation, indentation, shell notifications,
fonts and status, validate the assigned PRs through FU9–FU15 instead of opening
duplicate feature implementations. Curated palettes are assigned to #41;
settings are assigned to #37; missing preferences remain V1/A1 follow-up work.

## 2. Follow-ups to the open PRs

Do these after the named PRs merge. FU1–FU8 originated in the inherited review;
API names there describe its reported PR implementations and need checking
against merged code. Later entries preserve this session's acceptance cases.

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
#47 adds the same `caretRevealRequest` for line commands but scrolls
minimally through `EditableTextState.bringIntoView`, which suits a caret
stepping past the edge; give the helper a placement (minimal, or a third
down for jumps). Open #8 already shares one `_estimatedLineTop` helper
between `_revealMatch` and its Go to Line reveal; keep that shape when
moving both onto the reconciled geometry owner.

### FU3. Cache the highlighted span (after #14) — M
Caret moves still rebuild every span. `EditableText` rebuilds on each
selection change, and `CodeEditingController.buildTextSpan` rebuilds the
whole span list, O(tokens). **Plan:** memoize the returned `TextSpan` on
`identical(text)`, `identical(tokens)`, `identical(matches)`,
`activeMatchIndex`, `theme`, `style`, the tab style and the composing
range. `RenderEditable.text =` then short-circuits on `identical`.
**Done when** a test shows two consecutive selection-only builds return
the identical span, and a text or theme change returns a new one.

### FU4. Validate persisted zoom/view settings (after #25/#30/#37) — M
Deferred from #30's second review: its zoom aliases (Cmd/Ctrl+Shift+=,
numpad +/−, numpad 0) have no key tests; the helper only sends the
unshifted primary chord. Cover them wherever zoom lands.
Baseline zoom resets on launch; #37 reports persisted font size. Reconcile
that representation with #25/#30 zoom steps, restore/clamp on startup, and
verify Actual Size and live preview. Remaining settings are A1. Verify
platform shortcuts/reset,
system text scaling, selection, undo, scroll anchor and gutter/reveal geometry.
Open #9 contributes zoom steps (Ctrl/Cmd+=/-/0, numpad +/-, View menu,
8–32 clamp, session-only) plus a rendered-style contract test pinning
monospace/1.35 on the live `EditableText`; validate its shortcuts and reset
against #25/#30/#37's persisted representation on merge.
Deferred from #9's round-3 review (no push): align the app/test `textStyle`
comments to the true contract — the app style replaces the widget default
at the boundary, then merges with the editor's family-less internal base —
and consider editor-owned constants for the face/height literals.

### FU5. Remaining tab actions and keys (after #30/#35/#42) — M
#42 reports a right-click menu with Close, Close Others and Close All Tabs,
plus middle-click close. Verify dirty consent and Cancel stopping the sweep.
Remaining menu actions: Close to the Right, Copy Path, Reveal in
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
- **JSONC**: the reviewed baseline maps `.jsonc` to strict JSON without
  comment rules (`editor_syntax.dart:823`). Check #31 after merge, then add
  a separate JSONC entry if still missing; test quoted comment delimiters.
- **Basename gaps** (2026-09-27 pass, distinct from language additions):
  `_basenameLanguages` misses `bashrc`/`zshrc`/`profile` without the dot,
  `.envrc` (direnv → shell — the only one arguably *wrong* today, since
  extension `envrc` doesn't match `env`), `PKGBUILD`, `Brewfile`,
  `Vagrantfile`, `CMakeLists.txt`, `SConstruct`/`wscript`, `.babelrc`/
  `.eslintrc`/`.prettierrc` (json), `.clang-format`/`.clang-tidy` (yaml),
  `Caddyfile`, `Jenkinsfile`, `meson.build`. Each is a one-line map entry;
  bulk-add with a test per name.
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

### FU8a. No extra indent after a comment ending in a colon (after #14) — S
Deferred from #14's second review: with `indentAfterColon` (Python, YAML),
Enter after `# TODO:` indents the next line. Skip the colon rule when the text
before the caret on that line is a line comment for the language, and test
`# note:|` in both languages.

### FU8. Keyboard escape from indent mode (after #14) — S
With `EditorTabKeyBehavior.indent`, keyboard-only users can't Tab out of
the document. **Plan:** add Ctrl+M (VS Code's "Toggle Tab Key Moves
Focus"), or Escape followed by Tab, to move focus once. Add a test that
focus leaves the document.

### FU9. Validate one editor geometry contract (after #22/#27/#28/#32, #25/#30 and #16/#33) — M
The baseline uses a parallel TextPainter below 200k characters and an
unwrapped approximation above it, although TextField still wraps
(`editor_view.dart:126-165,505-545`, **read**). Prefix-only search layout can
also wrap a partial word differently. Below the cutoff, the parallel painter
uses a different width from RenderEditable's caret reservation, introducing
another wrap mismatch. #22 reports addressing the owner.
#27/#28/#32 report competing prefix, metrics and cache changes; reconcile
their geometry first. Include tail extrapolation, distant search and edits
before/inside/after cached regions, not only the first viewport.
Verify actual RenderEditable geometry for 199,999/200,001 characters, long
wrapped lines, tabs, Unicode, custom fonts, scaling, resize and matches near
wrap boundaries. Include Go to Line and zoom; combine with FU2. Do not merely
raise the highlighting cap or add another independent layout calculation.
Also test the actual merged cap: the newer source calls #28's cap "32 KiB";
verify whether it counts bytes or UTF-16 units before changing documentation.

### FU10. Verify safe reload and conflict recovery (after #19/#26/#38) — M
Baseline reopening selects the stale existing tab, despite save conflicts
advising a reopen (`document_workspace.dart:147`). The inherited PR reports
Reload/Keep Mine, Revert and disk-change handling; do not implement them twice.
Test clean/dirty/deleted files, cancel, repeated changes, focus return and
Save As identity changes. Verify a diff or Save a Copy escape route remains
available when changes cannot safely be reconciled.

Baseline failed reload sets the fatal initial-load error, hides existing text
and disables save (`editor_controller.dart:153-168`, `editor_view.dart:396`,
**read**). Verify #26 retains the previous text, selection and undo until a
reload succeeds; preserve copy/recovery access, retry and disposal behavior.
If this case remains broken, reproduce it before a focused follow-up fix.

#19 reports replacing the editing controller on text installation to sever
Flutter UndoHistory across loads, retaining retired controllers until safe
parent disposal. Test load/reload/blank install after focused edits: Undo must
not resurrect the previous document. Preserve listener detachment and
mid-frame lifetime safety; profile accumulation after many reloads.

### FU11. Verify bounded shell notifications (after #17) — M
Deferred from #17's second review: the title cache's stale-failure guard
(`if (title == _title)` in `DesktopWindow.setTitle`'s error path) has no
test. Add one where an older title fails after a newer one is sent, and
check the newer one is not resent.
Baseline editor notifications fan out through `DocumentWorkspace._notify`,
loop all tabs, rebuild the shell/IndexedStack and resend the native title
(`document_workspace.dart:108,358`, `main.dart:31`, **read**). #17 reports a fix.
Profile holding arrow keys with 1/10/50 tabs. Measure build/title/menu-call
reduction and retain dirty markers, busy/lock state and per-tab undo/search.
Selection painting should remain local; avoid unmounting Flutter undo owners.

### FU12. Bound file work after buffer optimization (after #39) — M
#39 reports replacing generic integer buffers and optimizing the EOL census.
Keep those assigned changes separate from remaining safety/performance work:
digest passes can read beyond the initial byte bound when a file grows.
Reproduce concurrent growth and bound each pass while preserving snapshot
checks and the injectable digest order. No claim of an atomic snapshot.

Saving normalizes and encodes before rejecting oversized output
(`text_document.dart:213-217`). Preflight with `utf8EncodedLength`, accounting
for BOM and CRLF expansion, before large allocations. Test preserved original
bytes after rejection. Coordinate remaining CPU offload with P4 and replacement
preflight with P5; remeasure the inherited #39 results before further tuning.

### FU13. Validate navigation and status semantics (after #33) — M
#33 reports Go to Line, platform find shortcuts, encoded byte counts, language
names and selection status. Verify empty files, trailing newline, Unicode,
wrapped lines, Escape, out-of-range input, both platforms' shortcuts and focus
restoration without changing undo. Check whether line:column input is covered
before planning an extension; specify clamping/rejection explicitly.
Distinguish UTF-16 offsets from user-facing grapheme columns, and verify
on-disk counts for BOM/CRLF and selection counts for combining characters.
Keep format/status controls in E10 and native menu ownership in the app.
Open #8 covers part of this: its dialog total counts the trailing-newline
line (matching gutter and clamp), out-of-range input clamps, non-digits are
untypeable (digits-only formatter), and navigation requests editor focus.
Still open: line:column input, grapheme-column semantics, BOM/CRLF counts.

### FU14. Validate indentation across hosts (after #13/#14/#21/#34/#37 coordination) — M
Retain tests for forward/reverse multiline selections, tabs/spaces, blank
lines, one-step undo, editing locks and a documented indentation policy.
Hardware Enter, mobile newline edits, IME composition and accessibility
traversal are separate paths; combine this with FU1/FU7/FU8 rather than
reimplementing indentation. Verify rendered tabs and true-stop limits (E8).

### FU15. Reconcile tab and chrome behavior (after #11/#35/#36/#43 coordination) — M
The inherited #35/#36/#43 chrome changes overlap #11's visibility fix.
Retain the earlier-tab focus-race regression, keyboard navigation, long labels, visible dirty/close
controls, full-path tooltips, resize/scaling and per-tab undo/search.
Compare the final chrome at 640×400 and 1080×760, light/dark, 100%/200% scale;
keep Open/New/Save discoverable and use a quiet active-tab indicator.
Optional compact/focus styling belongs with Q3, not another toolbar rewrite.

### FU16. Validate language fixes without duplicating #31 — S
This session reproduced shell single-quote backslashes swallowing the comment
in `echo 'C:\' # note`; #31 reports fixing those escape rules. Retain that
regression after merge, including SQL/YAML variants reported by the inherited
review. JSONC and other remaining dialect work are in FU6; escaped-newline
policy remains B2 unless the merged implementation already resolves it.

### FU17. Adopt merged shared changes in both hosts — M
After reviewed shared changes merge here, pin core/editor to the same revision
in Poltergeist and Séance, update locks, and run editor/save/close tests plus
narrow/mobile layouts. Do not copy the shared implementation. For #6, inspect
host cleanup matching: recovery names preserve host prefixes/suffixes but may
truncate original basenames. Rollback errors identify exact retained backups;
filesystems with component limits below 255 bytes can still reject names.

## 3. Bugs

### B2. Backslash-newline continues "single-line" strings — S (read)
`_scanString` skips two code units after `\`, so `"abc\` followed by a
newline keeps the string open onto the next line. That's correct for
C-family and shell continuations but not for JSON, INI or YAML.
Check the merged #31 behavior before another change. **Plan:** use an explicit
per-language continuation policy, and never let an escape consume `\n` when
continuation is disallowed. Keep shell/C continuation behavior covered.
Adjacent confirmation from the 2026-09-27 pass: `_scanString` also treats
`\` as an escape in INI/YAML/config values that have no escape processing,
so `key = 'it\'s'` keeps the string open past its close quote — same root
cause; the fix wants a per-language `escapes` flag, not only the newline case.

### B3. Read-only files — save prompt assigned to #49
#49 asks before a save replaces a file marked read-only. **Still open:** a
read-only marker in the tab and status bar at load time, so the user learns
before editing rather than at save. Reuse `isTextDocumentWriteProtected`
from #49, store the answer on `DocumentTab` at load and on focus (#26's
`checkDisk` is the natural place), and test that the marker clears after
`chmod u+w` and a focus change.

### B4. Startup window jump on Windows — S (not reproduced on Linux)
The Windows runner creates a 1280×720 window at (10,10) and shows it on
the first frame (`windows/runner/main.cpp`, `flutter_window.cpp`). GTK
creates 1280×720 (`linux/runner/my_application.cc`). Then
`DesktopWindow.initialize` resizes to 1080×760 and centers it.
**Linux, measured:** release and debug builds of `e0acb11` under Xvfb (no
window manager), polling `xwininfo` every 20 ms, three runs: the window
exists unmapped at 1280×720 after ~180 ms and is first viewable at ~700 ms
already 1080×760 and centered, because `setSize`/`center` land before the
first frame shows it. No jump. Still unverified on Windows and under a
compositing window manager. **Plan if Windows shows it:** match the native
size to 1080×760 and center the origin, rather than hiding the window until
Dart shows it (a startup failure would then leave no window at all).
**In review at #62:** both runners now create 1080×760 centered on the work
area; manual Windows verification still needed after merge.

### B5. Close button vs Close Tab during load — S (read)
Close Tab in the menu requires `!isLoading` (`ready`), while the tab's ×
only checks `busy`. Pick one rule, probably allowing a loading tab to close,
and test it. Current disposal ignores late completion; it does not cancel
the underlying file I/O. Do not claim cancellation without implementing it.
**In review at #60:** the menu now follows the ×'s `!busy` rule — loading
and load-error tabs close, in-flight saves still refuse — with a widget
test closing a tab mid-load.

### B6. Multi-open error aggregation moved to B15
The earlier backlog used B6; B15 is the consolidated task. Do not implement twice.

### B7. Multiple carets — L (inherited structural proposal)
Support a list of selections, add-next-occurrence (proposed Cmd/Ctrl+D),
add-above/below (proposed Cmd/Ctrl+Alt+↑/↓), and Escape to collapse to one.
After E1/E2 expose reusable core edits, apply indent/dedent/comment/replace
to all carets in one pass with one undo. Acceptance: three carets type together
and one undo removes the edit. Existing selection/reveal plumbing helps, but
does not establish that IME, accessibility and rendering are solved; coordinate P3.

### B8. Specify display-column semantics — M (inherited finding)
`caretLineColumn` counts UTF-16 units, not tab-expanded/display columns;
surrogate pairs count two. The newer source reports `"\tindented"` at offset 4
as Col 5 versus visual column 9 under eight-wide tabs. That visual number
needs reproduction: ordinary eight-column expansion would yield column 12.
Define grapheme versus display-column policy and test tabs, CJK, emoji and
combining sequences against actual rendering/indent settings. A core helper
may count tab stops and wide characters; do not assume every font/glyph has
the proposed fixed width. Coordinate FU13/#33's already-assigned status work.

### B9. Additional tab-key aliases — S (inherited proposal, not a confirmed bug)
The incoming source claims Ctrl+Tab switches desktop applications; that is
not the Windows/Linux default, which uses Alt+Tab. Retain working Ctrl+Tab
navigation. Optional Ctrl+PageDown/PageUp and Cmd+Shift+]/[ aliases are already
FU5/#30 work; check actual platform/user binding conflicts rather than removing
a useful shortcut based on that claim.

### B10. Recover orphaned save siblings safely — M (inherited finding)
The standalone app lacks the host recovery sweeps described in ARCHITECTURE.
A crash can leave `.planchette-<uuid>.edit`/`.backup` plaintext siblings.
Integrate with A2's journal and known document directories; preserve #6's
truncated-name rules. The source proposed scanning siblings older than a day
or the current process, but age alone does not prove another process abandoned
them. Require ownership/conflict checks and explicit recovery/removal choice;
never automatically restore a lone backup over a destination or delete another
writer's active file. Test forced crashes, missing targets and two processes.

The latest source reports #40 deleting siblings older than seven days on open,
using `changed` because backups inherit the old mtime. Treat that as assigned
but unverified and insufficient for safe deletion: age/ctime do not establish
abandonment, and platform timestamp meaning differs. Offer recovery before
cleanup, retain lone backups, and require ownership/conflict evidence even
when preserving a documented retention cutoff.

### B11. Explain or defer quit during saving — S (inherited read)
`_confirmQuit` returns false while a tab is busy/saving, and the window treats
false as doing nothing. Reproduce Cmd+Q during a gated save. Queue quit until
settled or show a saving notice with Cancel; retain one decision path for
`onWindowClose` and `AppExitListener`, and rerun dirty-revision guards.

### B12. Serialize Save As requested during Save — M (inherited read)
`DocumentWorkspace._save` deduplicates per tab, so Save As during Save may
return the existing future without opening its dialog. Reproduce with a gated
store; queue the differing intent or explain why it is unavailable. The
source's alternative map key `(tab, saveAs)` is insufficient if it permits
concurrent writes: preserve per-tab serialization, identity and dirty baselines.

### B13. Focus disposal ordering — S (investigate inherited test failure)
The newer report observed `A FocusManager was used after being disposed`
with attached editor/search/replacement nodes. This session also saw that
trace during teardown after an earlier failed assertion skipped widget cleanup;
the passing app suite and desktop CI do not establish a runtime close-tab bug.
First isolate a focused close/disposal reproduction. `_remove` already removes
the list entry before disposing, which does not synchronously unmount widgets.
Validate detach/unmount/controller ownership before changing order or proposing
unfocus calls; active-tab close should produce no warning or lost focus state.

### B14. Name file-permission constants during related work — S (inherited read)
Replace meaningful POSIX `0x180` (0600) and `0x1ff` (0777 mask) with descriptive
constants such as `_ownerOnlyMode` and `_permissionBits`, or existing standard
definitions when available. Keep this optional cleanup scoped to file-operation
work and preserve mode/privacy tests; it is not a correctness blocker.
**Done in #57** as `_ownerReadWriteMode`/`_posixPermissionMask` (on that
branch only; re-apply if #57 closes unmerged).

### B15. Only the last error survives a multi-file open — S (read)
`DocumentWorkspace.openDialog` overwrites `error` for each failing file.
Collect the failures and show "2 files could not be opened: a.bin (binary),
b.txt (not UTF-8)". **In review at #59** with that exact aggregated shape.

### B16. Opening a file that is already open should flash its tab — S (idea)
Today the existing tab is simply activated. Add a short highlight
animation on that tab so it's clear why nothing new appeared.
Keep it optional and respect reduced motion; activation must work without it.

### B17. Preserve independently owned editing locks — assigned to #54
**Still open after merge:** guards added by #14 (`_canEditText`) and #47
(`canEditText`) read the private `_editingLocked` field; switch them to
`editingLocked` so they honor the view's lock too. Hosts that listen for lock
changes are not notified when only the view lock changes (as before #54).

### B18. Reserve Save As identities during async work — M (investigate, high priority)
`document_workspace.dart` checks ownership before async digest, confirmation
and write operations. Native Open during a pending save may create two tabs
for one target. Reproduce with a gated fake store, aliases and native-open
events. Reserve resolved identities until completion or reconcile without
discarding dirty buffers; do not change the identity after a failed save.

The latest inherited B19 reports a related loading-tab alias gap: `tab.path`
is assigned only when load completes, so `_findPath` may miss it. Test pending
load aliases as well as pending saves; the claimed digest protection against
all collisions needs proof rather than assuming only a confusing error.

### B19. Navigate beyond the 1,000-hit painting cap — M (read)
`editor_controller.dart:335,363,399` navigates stored hits only, while Replace
All changes all matches. Separate bounded highlights from next/previous
discovery and full counts. Test more than 1,000 hits, caret near EOF, wraparound,
exact-cap display and replacement counts with bounded memory. E5 and P5
must share these semantics instead of introducing another search model.
Whole-word mode (#12) flows into both navigation and Replace All; keep the
mode shared so the cap never silently bounds replacement.

### B20. Align input and output text policies — S (confirmed this session)
Core writing accepts NUL but loading rejects it as binary
(`text_document.dart:127,216`). A successful create was reproduced producing
a file that cannot reopen. Decide whether to reject NUL on save or support
it on load; give a precise error before publication. Test create/save and
round trips, preserving original bytes when rejecting an edit.
**In review at #57:** save/create reject NUL before publication with the
first offset named; load and write share `_firstNulIndex` so the binary
rule cannot drift. Wider "non-UTF-8 input" policy remains undecided — this
closes only the NUL hole.

### B21. Define find preview and caret behavior — S (read)
Typing a query highlights/reveals a hit without selecting it; Escape returns
to the old caret and the first Enter skips that highlighted result. Reproduce
with a unique distant marker. Define preview versus committed navigation,
preferably selecting the active result without stealing query focus, while
preserving ordinary Escape semantics and replacement/undo behavior.

### B22. Give DesktopWindow an explicit lifetime — S (inherited read)
The latest source reports `main()` creates DesktopWindow without disposing
its window-manager listener or AppLifecycleListener. Verify ownership on root
unmount and future multi-window flows, then dispose through the owning root
or app collaborator. Do not assume local usage proves a leak in sibling hosts.
Same class: `OpenDocuments` (`main.dart`) is also created and never
disposed — there it is arguably correct, since the macOS channel handler
must live for the app's lifetime to receive Finder open events. If a
lifetime decision lands here, either tie both to the root widget or
document why process scope is right for each.

### B23. Consider reusing an untouched untitled tab — S (inherited idea)
Repeated New creates empty buffers; name reuse in #35 is a separate behavior.
If the active tab is untitled, empty and clean, optionally focus it instead.
Keep this a product choice: tests must preserve deliberately separate buffers,
dirty/undo history and expected New semantics.

### B24. Harden workspace tab transitions — S (read)
`_nextTab` force-unwraps `workspace.active` after checking only that the tab
list is non-empty; prove non-empty implies active-non-null or handle null
explicitly. `open()` queues work behind the `_unlocked` completer while
locked; prove a dispose during that wait cannot run `_open` on a dead
workspace. Test closing/quit races that empty or move the active tab.
**Partially in review at #60:** `_nextTab` selects the first tab when
active is null instead of unwrapping. The `_unlocked`-wait dispose race
remains unproven.

### B25. Confirm-close decisions need visible outcomes — S (read)
A discard choice is silently dropped when the buffer changed under its
dialog (the `confirmClose` revision recheck), so "Don't Save" can appear to
do nothing; tell the user the close did not happen. Save/toolbar enable
states also disagree about error documents — unify the `ready` predicate
between native menus, the menu bar and the toolbar. A close requested while
`tab.editor.isSaving` is refused just as silently — same missing outcome.

### B26. One path for Cut/Copy/Paste — S (read)
Menu items route through remembered-focus intents while shell shortcuts
defer to `TextField` defaults (Edit is excluded from `CallbackShortcuts`).
Reconcile the two paths, especially around IME composition, or document why
both must exist. Do not change paste semantics here — see Q14.

### B27. Extend Save As casing checks to Windows CI — S (read)
Casing checks run on case-insensitive macOS temporary volumes; Windows
volumes are case-insensitive too and have no equivalent coverage. Port the
existing casing fixtures rather than inventing new ones.

### B28. `openSearch` scans the document twice when prefill is used — S (read, 2026-09-27)
`EditorController.openSearch` sets `_searchOpen = true`, then assigns
`search.text = prefill` (`editor_controller.dart`). The assignment
synchronously fires `_queryChanged`, which runs `_updateMatches`; `openSearch`
then calls `_updateMatches` again — two whole-document searches for every
"select text → Cmd+F". Fix: assign `search.text` before flipping
`_searchOpen` (the listener early-returns while closed). Ordering-only
change, no behavior delta.

### B29. Save As onto a symlink reports a misleading error — S (read, 2026-09-27)
`LocalDocumentStore.canonicalSavePath` checks `FileSystemEntity.type(...,
followLinks: false)`: a link whose target is a regular file throws
"Choose a regular file as the destination." The user did choose a regular
file — through a link. Decide the policy deliberately: resolve the link
(then `existingDigest`/guarded replace handle it like `load`'s
`resolveOnce`) or keep rejecting but say "destination is a symbolic link".
Current behavior is safe but confusing; needs a product decision.

### B30. `initialText` plus `loadDocument` is a silent API trap — S (read, 2026-09-27)
`EditorController`'s constructor only marks `_loading` when
`initialText == null`; a host passing both gets an editor that never calls
its loader. Assert the invariant in debug builds or document
"initialText wins" — the former catches host mistakes early, and the hosts
(Séance, Poltergeist) are exactly the audience that can hit it.

### B31. Case-insensitive find degrades on length-shifting Unicode — M (read, 2026-09-27)
`findSearchMatches` falls back to *case-sensitive* matching when
`toLowerCase()` changes the haystack length, while the UI still claims
case-insensitive mode. Query "STRASSE" in text with "straße" reports
"No matches" — wrong in a way the user cannot detect. Options: a
code-point-wise lowercase that preserves length per character where
possible (hard), or a visible "matching is limited for this text" state
(honest). ß/İ/ı cases are common in European text.

### B32. Pin `_mergeMetaTokens` group-offset assumption with a test — S (read, 2026-09-27)
`match[0]!.indexOf(groupText)` finds the first occurrence of the group's
text inside the match — wrong if the same text also appears earlier in the
prefix. Documented caveat in the code; all current patterns are safe (YAML
prefix is whitespace/dashes only). Leave a test pinning the property so a
future `([a-z]+)=` pattern where the key repeats in the prefix does not
silently mis-highlight.

### B33. Tab switch can steal find-field focus — S (read, 2026-09-27)
`_select` → `_focusAfterFrame` unconditionally requests `editorFocus` for the
newly active tab; the `didUpdateWidget` isActive logic that preserves
search/replacement focus runs *after* the focus already moved to the
document. If the destination tab had its find bar focused, the user loses
it on every tab switch. Only request editor focus when none of the tab's
three nodes already has focus.

## 4. Performance

### P1. O(document) work per keystroke — L (structural)
Every edit re-tokenizes the whole text on the UI thread (including the
regex meta pass), rebuilds all spans, relays out the whole paragraph,
recomputes `lineStartOffsets`, and recounts UTF-8 bytes. With find open,
it also lowercases and re-searches the whole document. The 200,000-char
highlighting cap exists because of this.
The newer inherited report says #28 lowers that cap to "32 KiB" and adds a
Large file status. This is a reported branch change, not verified main behavior;
retain the responsiveness/color tradeoff and check actual units at integration.

Measure before choosing structural work. In profile mode, cover
10k/200k/4 MiB buffers, newline-heavy/single-line text, 1/10/50 tabs,
search on/off, paste, undo, scroll and resize. Record p50/p95 frames, peak
memory, platform and fonts. Highlighting is skipped above its cap, but
other whole-buffer work remains. #5 addresses the measured quadratic CSS
case; FU3/FU11 track assigned caching/notification follow-ups.

Inherited #28 measurements, reported per keystroke in a non-AOT `flutter test`
harness, back-to-back against its local baseline. They were not reproduced here
and are not release-frame predictions or comparable to #5's standalone scan:

| Fixture | Reported time | Reported owner |
|---|---|---|
| 380 KB text | 12.1ms | `lineStartOffsets` + `utf8EncodedLength` in `_updateMetrics` |
| 380 KB text, find open | 175ms | Whole-haystack lowercase/search plus relayout of up to 1,000 match spans |
| 79 KB JSON | about 95ms | 12,001 spans: 11ms tree build, 70ms layout; about 35ms plain-text comparison |
| 787 KB plain text | about 330ms | Single-paragraph TextField layout remained after #28 |

The source also measured 5,001-line gutter work at 59.0ms layout plus 124.3ms
for per-line `getOffsetForCaret`, versus 9.1ms for one `computeLineMetrics`.
Treat these as fixture-specific costs, not an immutable architecture floor.

Candidate steps after profiling, each S–M:
1. Incremental tokenization. Store the scanner state at each line start
   (inside a block comment or multiline string, or not). On an edit,
   re-tokenize from the edited line until the state converges with the
   previous run, and splice the token list. Measure a common-prefix/suffix scan
   as one way to locate the edit rather than assuming it is always cheap.
2. Cache the lowercased haystack per text instance in `EditorController`;
   evaluate one-frame query debounce while preserving immediate navigation.
3. Prefer lazy/once-per-frame metrics first. The latest inherited affix-scan
   prototype below regressed mid-buffer edits; do not repeat it without a
   measured improvement. This does not rule out every incremental design.
4. After #17, verify cached dirty state across tabs/status/title/menu reads.
   The source proposes comparing revision counters; a monotonic edit counter
   alone breaks clean-after-undo. Preserve undo-to-saved and saved-revision
   semantics before choosing a history checkpoint or cached comparison.

Long-term: see P3.

> **Inherited abandoned prototype: incremental document metrics.** Another
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
> replacing.** That affix-verifying implementation incurred the 3.5 ms
> `memcmp` that verifying the shared tail requires. A `Uint32List` would
> make the shift 0.6 ms, and then you are maintaining a bespoke piece table
> with 32-bit offsets and a fallback path. The source describes a 4 GiB ceiling,
> but String offsets count UTF-16 units, not bytes. Its projected savings were
> about 9ms on that 3MB fixture, with added shared-package maintenance cost.
>
> On its 122,161-character fixture, the report puts metrics at 2ms of a
> 173ms keystroke and attributes most cost to the gutter. Its reported 145ms
> overhead disagrees with the 34ms bare-field comparison (139ms difference);
> separate component probes do not sum to the total. Treat this as evidence
> to profile the dominant term, not proof of a universal 1% metric cost.
> The branch was abandoned. Scheduling at most once per frame is the next
> candidate, provided status/save consumers receive current values.
>
> The transferable lesson: **measure which term dominates before optimizing
> one.** The gutter looked like "the highlighting cap", the metrics looked like
> "the dirty check", and both were invisible next to a whole-document
> `TextPainter` layout.

### P2. `IndexedStack` lays out every tab — M (read, Flutter source)
`RenderIndexedStack` lays out all children and paints one. Resizing the
window relays out every open document's full text. **Plan:** keep
inactive editors out of layout only after measuring 1/10/50-tab resize
and retained memory. `Offstage` still lays out its child; a state-preserving
`Visibility` using it is not proof of layout avoidance. Prototype real layout
skipping without losing Flutter-owned undo, selection, scroll or search state.
Instrument layout counts and retain the existing test "tab switches retain
undo, selection and search state". Do not remove mounted owners speculatively.

### P3. A virtualized editor surface — L (idea)
The `TextField` approach bounds document size and responsiveness. A
line-based editor (render only visible lines, keep a piece table or rope,
own the caret, selection and IME client) could raise the 200k and 4 MiB
ceilings and enable minimap, folding and true tab stops. It's a big
project: prototype behind a flag in `planchette_editor`, keeping
`EditorController`'s API.
Treat removing those limits as a measured acceptance target, not an automatic
consequence. Folding, multicursor, project-wide search and LSP require separate
design after document/layout foundations are stable; avoid building a plugin
framework merely to support a small command palette.
The newer inherited review reports that Flutter 3.47 TextField/EditableText
have no `softWrap` parameter, and an inert flag in #28's first draft left
wrapped text paired with incorrect uniform-row gutter geometry. Verify API
availability (D6) and actual layout. Absence of that parameter does not by
itself rule out a measured horizontal-constraint prototype for E6; do not
declare a custom surface the only possible no-wrap approach without testing.

### P4. Load and save off the UI isolate — M
The inherited #39 follow-up reports about 180 ms of CPU to open 3.9 MB on the
UI isolate: three SHA-256 passes (about 50 ms each in AOT), the UTF-8
decode, and line-ending folding. **Plan:** run the pure steps (hash,
decode, census, fold, and encode on save) in `Isolate.run` inside
`planchette_core`. Keep the file I/O and the digest ordering exactly as
they are, since the safety tests inject `sha256Of`. **Done when**
opening a 4 MiB file leaves the UI isolate responsive (no frame over
16 ms in a profile build), and all document-safety tests pass unchanged.
These timings were not reproduced in this session. Remeasure the merged code,
including isolate transfer/startup cost, before adopting the proposed offload;
retain best-effort race guards and coordinate bounded passes with FU12.


The latest inherited B20 proposes removing the pre-read digest, reporting
66ms per 3MB hash and about 200ms per 4MiB open. Its D14 simultaneously says
to retain the guarded passes. These are conflicting proposals, not a proven
redundancy: a file changing from the initial version to the bytes read can
satisfy bytes == after while before differs. Define the promised snapshot
window and preserve injected `sha256Of` race tests before eliminating a pass.

Inherited B21 proposes hashing in-memory output instead of re-reading the
staging file on save/create. That removes an I/O pass but does not verify the
actual staged bytes against interference or corruption. Compare guarantees
and fault-injection coverage first; do not weaken guarded publication solely
because nominal digests match.

### P5. Stream Replace All and preflight expansion — M (read)
`editor_controller.dart:399` allocates an uncapped match list before constructing
output; a one-character query near 4 MiB can allocate millions of ranges.
Use a shared iterator/replacement plan, preflight encoded output size, then
commit one undoable edit. Test shrinking/expanding replacement, no self-rematching,
cap-crossing input, Unicode offsets and peak allocation. Coordinate B19/E5/FU12.
The newer inherited source reports 14ms for Replace All on 769 KB, with
`limit: source.length + 1`; its suggested callback form is one streaming option.
Remeasure allocation/time after integration. If an operation limit is introduced,
make it explicit rather than silently replacing only highlighted matches.
The uncapped `limit: source.length + 1` match list also carries #12's
whole-word matches today; stream the mode along with the plan, and confirm
the find bar's "1000+" display never implies a bounded replacement.

### P6. Profile per-line gutter allocation (after #22/#28) — S (inherited read)
The incoming source reports one TextPainter layout per visible line in
`_LineNumberGutterPainter.paint` (roughly 50 layouts per scroll frame), plus a
new divider Paint. Check the reconciled rendering owner before optimizing.
Candidates: cache line-number paragraphs or a measured digit atlas, and reuse
divider paint. Measure scrolling and invalidate for font/scale/style changes;
do not introduce a second geometry model alongside FU2/FU9.

### P7. Reduce line-ending normalization allocations — S (inherited probe)
The latest report measures 28ms on 3M characters across `_foldToLf`'s two
replace passes and a possible LF→CRLF pass. It claims even unchanged LF is
copied twice; verify actual Dart allocation behavior. Benchmark an early return
for already-normalized input and a single-pass builder against mixed CR/LF,
CRLF, empty input and target conventions. Preserve the documented mixed-EOL
normalization contract and coordinate #39/FU12/P4.

### P8. Per-identifier lowercase allocation in keyword matching — S (read, 2026-09-27)
`caseInsensitiveKeywords` calls `word.toLowerCase()` per scanned identifier
(Dockerfile, INI, SQL, CSS). Keep a pre-lowered keyword set at
`SyntaxLanguage` construction and compare with a length-checked
case-insensitive scan, or a small `HashMap` lookup. Low impact but free.
Also from that pass: `loadTextDocument` runs three digest passes plus a
stat, a UTF-8 decode, two EOL passes and a fold on the caller isolate —
already owned by P4/FU12/P7, confirmed here.

## 5. Editing features

### E1. Validate comment toggle; extend block-only languages — after #23
#23 reports Ctrl+/ line-comment toggling from `lineComments`, preserving
indentation, skipping blank/whitespace-only lines, caret and both selection
directions. Verify Cmd on macOS, editing locks, one-step undo and IME.
Remaining: CSS/XML and other block-only languages need selection wrapping;
languages without either comment form need explicit behavior. For mixed
commented/uncommented lines, define minimum-indent insertion consistently.
Keep transforms in core and reuse the reconciled edit type from E2.

### E2. Line operations — assigned to #47
**Still open:** one shared edit type once #14, #21 and #47 settle (see
Overlaps), and multi-caret versions of each command after B7.

### E3. Auto-close brackets and quotes — partly assigned to #34
**Inherited #34 report:** `( [ { " ' \`` insert their closer with the caret between;
typing the closer again takes back the character the platform inserted and
steps over the pair; a closer with something *else* after it is a real bracket
and is inserted as one; Markdown is excluded, because its brackets are content;
a locked editor does not pair.

**Two decisions that matter more than the feature:**

- **Enter and the bracket keys are not intercepted as shortcuts.** They reach
  the buffer through the platform's text input, so #34 runs on the change the
  platform already made, and accepts it only when it is *a single character
  inserted at a collapsed caret*. The source claims this excludes paste, IME, undo and selection replacement,
  but single-character paste/composition/undo can satisfy that shape. Preserve
  the intended policy and add event-specific regressions before relying on it.
- **A language gate, not a heuristic.** Pairing is decided by
  `pairsBrackets(language)`, which is "not null and not Markdown". Extending it
  to more prose formats is a one-line change to that predicate.

**Still open from this item:** Backspace between an empty pair deleting both;
respecting string and comment context with the tokenizer rather than only the
character after the caret; a setting to turn it off. Test whitespace/end-of-line
insertion boundaries. Coordinate with #37 preferences and the shared host API;
do not widen controller state without a consumer and compatibility review.

### E4. Bracket-match highlight — M
When the caret touches a bracket, find its partner (skipping strings and
comments via tokens) and paint both backgrounds. The decorations render
object from #22 can paint them.
**Do not paint through span backgrounds.** Splitting the two brackets into
their own spans changes the span tree on caret moves, and
`TextSpan.compareTo` then reports a layout change, so every caret move next
to a bracket would re-lay out the whole paragraph (#28 measured layout as
the dominant cost). A paint-only overlay keeps caret moves cheap.
**Matcher:** a pure core function over the tokens `CodeEditingController`
already memoizes per text instance (expose them read-only). Skip only
string and comment tokens (Rust `#[...]` meta tokens hold real brackets),
count depth per bracket type, and prefer the bracket before the caret, then
the one after, so the partner of a just-typed closer shows.

### E5. Search options — regular expressions assigned to #44
**Inherited #44 report:** a `.*` toggle beside the existing `Aa` button, a
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

**Whole word is implemented by open [#12](https://github.com/L-K-M/Planchette/pull/12)**
(`planchette/whole-word-search`): a core `wholeWord` option (ASCII
alphanumerics, `_` and BMP non-ASCII count as word content; astral
surrogates are boundaries, matching `\b`-style editors; CJK/full-width
punctuation stays word content — that classification is still an open
decision), a controller toggle flowing into find and Replace All, and an
underlined-`ab` button beside `Aa` with `isSelected` on both search toggles.
Reconcile its boundary definition with #44's Unicode word-boundary work
rather than shipping two notions of a word.
Deferred follow-up from #12's round-3 review (accepted-in-principle, no
push): enforce each boundary only where the needle's own edge is a word
character, for `\b` parity on pasted queries (`'cat '` in `'the cat sat'`)
and operators (`'=='` in `'a==b'`). Update the doc comment and add those
two regression cases.

**Still open from this item:** "in selection"; highlight all
occurrences of the selected word; capture groups in the replacement (the
current `replaceAll` substitutes a literal string, so `$1` is written out
rather than expanded — a real trap now that patterns exist).
Keep literal mode the default and bound expensive patterns. Specify Unicode
word boundaries and zero-width replacement behavior. Preview affected count
and a small sample before Replace All, especially beyond the painting cap
(B19/P5). Preserve #10 keyboard/localization/IME and responsive input connections.
The 1,000-hit painting cap must not silently bound actual replacement.

### E6. Word wrap toggle — M
The `TextField` always soft-wraps. No-wrap needs a horizontally
scrollable field of intrinsic width (a `SingleChildScrollView` plus
`IntrinsicWidth`, or a very wide constraint), and the gutter must follow
vertical scroll only. Consider doing this with P3 instead.
Profile long-line intrinsic measurement before choosing that layout. Preserve
actual gutter/reveal geometry, scroll anchor, selection and undo; zoom is
already assigned to #30, with persistence/validation in FU4.

### E7. Visible whitespace and indent guides — M
Paint dots for spaces and arrows for tabs in the selection or all text,
and thin vertical guides per indent level. The decorations painter from
#22 can do both.

### E8. True tab stops — M
#14 renders each tab at a fixed width. Tabs after text should align to
the next multiple of the tab width. That needs per-tab measurement of
the preceding column (monospace makes this arithmetic) and a
letter-spacing value per tab.
The newer #21 record reports padding typed indentation to the next stop.
Verify that separately from rendering existing literal tabs before another fix.

### E9. Trim trailing whitespace and final newline — S
Settings: "Trim trailing whitespace on save" and "Ensure final newline".
Honor `.editorconfig` if present (see A1).

### E10a. Validate assigned auto-indent — after #14/#21/#34
#34 reports `indentForNewLine`, `leadingWhitespace` and `indentRange` in core,
with a language-gated block-opener rule. Its colon policy includes YAML, INI,
dotenv, XML, Markdown and CSS, but excludes punctuation cases such as Dart's
`var x:`; the source names a const language set in `code_input.dart`.
Verify that policy against real language syntax before extending it. Preserve
FU7 mobile input and FU14 locks/selection/undo tests. #14 reports Backspace
removes a level; reconcile that behavior with #34 rather than losing it.

### E10b. Search debounce and selection status — see P1/FU13
Evaluate one-frame query debounce with P1's measurements. #33/#44 report
selection status, so reconcile it after merge; #44 reports word/character counts. The incoming proposal to replace
byte count with "N selected" is a presentation choice, not proof that encoded
size is useless; retain discoverability of both where space permits.

### E10. Change line endings, indentation and language from the status bar — M
Make the status segments into menus:
- LF / CRLF converts the document on the next save.
- Spaces / Tabs sets `indentation`, with "Convert indentation".
- The language picker sets the language explicitly.
- BOM is an explicit file-format choice; show its effect on encoded size.

The status row lives in the shared editor, so do this through
`statusBuilder` or new callbacks, not app-only code.
Separate manual language override from autodetection: untitled files need a
choice, and shebang edits should update detection without resetting text.
Warn before mixed-EOL normalization. Test Save As, reload, dirty/undo semantics,
changed shebangs, Unicode and narrow status layouts. Add format tooltips;
#33 already owns encoded-byte and selection status changes (FU13).

### E11. Regex-based symbol outline — M
No parser: list functions, classes and section markers per language from the
existing `SyntaxLanguage` metadata plus small regexes (c-family, Python,
Ruby, `ini` sections). Clicking jumps through the Go to Line scroll path
(#8/FU2). Test commented-out code, nested scopes and files with no symbols.
Keep it out of the file-safety and highlight paths.

### E12. Re-run language detection on first-line edits — S (read, 2026-09-27)
`_detectLanguage` fires only on `_installText` and `displayPath` changes, so
an untitled buffer where the user types `#!/usr/bin/env python` stays plain
text forever — the shebang machinery exists but is unreachable live. In
`_textChanged`, compare the bounded (~4 KiB) first line before and after an
edit and re-detect only when it changed. Pairs with Q25's subtle status-bar
confirmation when detection changes through typing.

## 6. App features

### A1. Settings store — partly assigned to #37 (enables FU4, E9, A3, A4)
**Inherited #37 report:** an `AppSettings` value, a `SettingsStore` interface with
`LocalSettingsStore` and a test double following `DocumentStore`, a
`SettingsController`, and a preferences dialog for theme mode, font size and
indentation.

Preserve these reported contracts when adding settings:

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
restore-session. Extend the existing value/store/controller/dialog rather than adding a
parallel persistence system.

The source reports environment-derived per-user paths instead of
`path_provider`. Its unrelated file_picker/AGP example does not establish that
choice is safer. Verify Windows/macOS/Linux paths, missing environment values,
permissions and sandbox expectations before retaining the dependency decision.
The app owns persistence; hosts inject preferences. Keep unsaved buffer text
out of ordinary settings, and make failed preference writes explicit.

### A2. Session restore and hot exit — L, high priority
Reopen the last session's files, and restore unsaved untitled buffers and
unsaved edits after a quit or crash. Journal dirty buffers to the app
support directory on idle, with owner-only permissions, and clear the
journal on save or close. It must survive a failed save and must not
resurrect discarded edits.
Separate saved-path/active-tab/caret/scroll restoration from protected dirty
buffer recovery. Two-rename saves may leave a missing target or recovery
siblings; journal interrupted publication as well as unsaved text. Offer a
preview/choice and never overwrite disk automatically during recovery.
Test forced termination at each save phase, stale journals, concurrent
processes, missing files, private content, cleanup and newer unsaved revisions.
An opt-in auto-save (on focus loss or after a delay) is separate from hot
exit; put its setting in A1.

### A3. Open Recent and a recent list in the empty state — M
Keep the last 20 paths in settings. Show them in File › Open Recent (on
macOS, prefer `NSDocumentController`'s recents) and in the empty state.
Remove entries whose files are gone.
Allow removal/clearing for privacy; handle moved or temporarily unavailable
paths explicitly rather than silently reopening the wrong identity.

The latest source also proposes remembering the last Save As directory per
file type and supplying `FilePicker.saveFile(initialDirectory: ...)`. Define
precedence against the current document directory and preserve privacy clearing.

### A4. Verify native file-drop intake after #43 — M
#43 reports a `DragTarget<String>` around the shell, newline-separated path
parsing via public `droppedPaths`, lock rejection and primary-color drag chrome,
without new runner registrants. That wiring does not establish OS file-drop
support: Flutter in-app drag targets need a native intake bridge for desktop
file-manager payloads. Verify actual supported platforms before calling this done.
The newline payload claim also needs an explicit source/encoding contract;
filenames themselves can contain newlines on Unix.

Test real Finder/Explorer/Linux drops, multiple files, spaces/Unicode, partial
errors, aliases and pending operations through workspace/OpenDocuments guards.
If a native bridge/plugin is needed, validate all runner registrations and Linux
packaging. D0e records the inherited widget-test difficulty without claiming
Flutter drags are categorically untestable. Do not advertise drop support until
the native flow works.

### A5. Quick Open (Cmd/Ctrl+P) — M
A fuzzy list over recent files and the active file's directory. Enter
opens, and Esc returns to the editor.
Offer an open-tabs mode with distinguishing path suffixes and dirty state;
reuse identity resolution and keep this distinct from A6's command list.

### A6. Command palette — assigned to #50
**Still open:** recently used commands first; commands that take an
argument (typing `:42` for Go to Line after #33, or a file name for A5's
Quick Open in the same field with a prefix); a keyboard shortcut reference.

### A7. Save All and Reopen Closed Tab — S each
#42 reports Close Others/Close All with per-tab consent and Cancel stopping
the sweep; verify through FU5 rather than opening duplicate close features.
Reopen Closed Tab (Cmd/Ctrl+Shift+T) keeps a stack of recently closed
paths. The quit prompt should list the dirty files, with "Save All" and
"Discard All" buttons instead of one dialog per tab.
Reuse existing guards, report partial success and stop safely on cancel.
Do not promise recovery of discarded text merely because its path is in
history. Tab menus, Copy Path and reveal actions belong to FU5's app service.
**Save All command** (2026-09-27): a File › Save All that iterates dirty
tabs through the existing `_save` serialization and aggregates partial
failures using the B15 aggregation shape is the cheap first piece; the
quit-prompt Save All/Discard All flow is the bigger half and stays here.

Open [#18](https://github.com/L-K-M/Planchette/pull/18)
(`planchette/reopen-tab`) implements the Reopen half with text snapshots
rather than bare paths: a 10-deep stack keeps text, save identity, full
selection (with affinity) and dirty state, restored without a disk
round-trip; a path reopened meanwhile is selected instead of duplicated;
the save conflict guard still fires on stale baselines; cancelled closes
enqueue nothing; the restore writes outside undo history. This supersedes
the no-recovery constraint above for closed tabs — recovery is real and
conflict-guarded. What stays open here: Save All / Discard All in the quit
prompt with partial-success reporting.

### A8. Remember window size, position and maximized state — S
Store them in settings (A1). Restore them before `waitUntilReadyToShow`,
clamped to a visible display.
Test removed monitors, high DPI, maximized state and startup jump behavior (B4).

### A9. Encodings — M
Only strict UTF-8 is accepted. Detect UTF-16 LE/BE by BOM, and offer
"Reopen with Encoding…" for Latin-1/CP1252. Save in the document's
encoding. Keep the 4 MiB limit in bytes, and update ARCHITECTURE.md.
Start with BOM-marked UTF-16 only with lossless round-trip fixtures and endian
metadata; reject malformed input. Latin-1/CP1252 reopening must be an explicit
choice, never an automatic guess that silently rewrites bytes. Report precise
unsupported-encoding diagnostics and preserve content on failed conversion.

### A10. Markdown preview — M
A split view for `.md` using `flutter_markdown` or a small renderer, with
scroll sync by heading.

### A11. Print or export to HTML/PDF with highlighting — M
Build HTML from the tokens (colors from the syntax theme), then print or
save through the platform.

### A12. Disambiguate equal filenames — S
After reconciling #11/#35/#43, check whether duplicate basenames still need the
shortest distinguishing parent suffix. Retain full-path tooltip and accessible
label. Test aliases, equal names in different directories, case-sensitive
volumes, long paths and rename/Save As without losing active-tab visibility.

#43's directory beside the strip does not prove each duplicate tab is distinct.

### A13. Open Folder — M–L
Single-file tabs are the current scope; an Open Folder mode (file tree with
fuzzy path open feeding A5) is the most-asked next step. Keep the tree as
navigation only: opening still goes through guarded loads, and the tree
itself owns no file state. Stop before git, debugger and tasks to stay a
focused editor.

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

First add a tested CLI parser: the baseline ignores every dash-prefixed
argument and lacks `--`, line/column targets and `--wait`. Document shell
invocation/options and launcher installation. Preserve spaces, Unicode and
filenames beginning with `-`; define forwarding/wait lifetime before changing
process ownership. Native intake must still pass workspace/modal guards.

The latest inherited B23 specifically identifies `OpenDocuments.start` filtering
all `startsWith('-')` arguments, including `-draft.txt`. Parse only known flags
and support `--`; Finder events use a separate path. Add direct regression
coverage before changing that parser.

### I2. macOS document affordances — S–M
Set `NSWindow.isDocumentEdited` (the dot in the close button) instead of
a "●" title prefix, and `representedURL` for the proxy icon. Add
`public.data`/`public.item` document types so extensionless files
(`Makefile`, `.env`) offer Planchette in Open With
(`macos/Runner/Info.plist`).

### I3. Save-time metadata — M, high priority, risk: medium
Saving replaces the inode and copies permission bits only
(`text_document.dart:267-269`). This session reproduced a Linux
`user.planchette-test` xattr disappearing after save. The inherited review
also identifies hard-link identity, ACLs, Finder tags and creation dates;
ownership/group and Windows custom DACLs need an explicit policy and native
verification. Other hard links continue pointing at the old inode rather
than becoming aliases of the replacement. Windows/macOS effects were not
runtime-verified here. Option: copy xattrs on macOS and Linux (via
`listxattr`/`getxattr`/`setxattr` FFI) before the rename. Document which
metadata survives in ARCHITECTURE.md. Implement native mechanics in the
file-operation layer and specify failure behavior before publication.
Test restricted access and retained metadata, not just ordinary mode bits.

### I4. Directory write permission — S
A writable file in a read-only directory can't be saved, because the
temp sibling can't be created. Explain this in the error, and offer
"Save As…". **Core half in review at #58:** the temp-create failure becomes
a `TextDocumentException` naming the unwritable folder and carrying the
real `osError`. The "Save As…" offer on that error remains open — it is an
app-level decision tied to the dialogs seam.

### I5. Host-neutral wording in core errors — S
Core messages say "the local copy", which is Poltergeist/Séance
vocabulary. Make the messages injectable (like `EditorStrings`), or use
neutral wording, and check both hosts' error adapters first.

### I6. Linux header title synchronization — S (confirmed by reading)
`linux/runner/my_application.cc` sets a `GtkHeaderBar` title once, while
the window plugin changes `GtkWindow:title`. A header-bar titlebar has its
own title label that does not follow the window title, so filename/dirty
updates never appear on GNOME/Wayland — and the window title is the only
dirty indicator outside the tab strip. **In review at #63:** `notify::title`
syncs the header bar; traditional decorations already follow. Manual
GNOME/Wayland verification still open after merge.

## 8. Visual design and theming

### V1. Verify curated themes and expose preferences (after #41) — M
#41 now reports Parchment/Séance palettes, AA syntax colors, warm selection
and an `EditorSyntaxTheme` ThemeExtension. Do not duplicate that implementation.
Verify persisted System/Light/Dark choices through A1; the reviewed baseline
followed system teal Material defaults without a user-facing selector.
Planchette is named after the Ouija pointer, and its icon leans into
that. Preserve the inherited palette design while checking #41's final values:
- **Parchment** (light): paper `#F7F1E3`, ink `#2B2522`, sepia comments,
  oxblood keywords, brass numbers, verdigris strings.
- **Séance** (dark): candle-lit `#1B1716`, warm off-white text, ember
  keywords, brass numbers, moss strings, smoke comments.

Every token color needs AA contrast (4.5:1) against the background and
the current-line band. Add a contrast test in the editor package.
Warm-paper and midnight variants are optional alternatives, not additional
required palettes. Keep token meanings consistent, and distinguish selection,
focus and dirty state without relying on hue alone. Respect high contrast.

### V2. More token classes — M, risk: medium
A follow-up to #41, retaining its host theme-injection contract.
Five classes (comment, string, number, keyword, meta) limit themes. Add
`type` (capitalized identifiers in C-family, Dart, Swift, Kotlin and
Rust), `function` (an identifier before `(`), and `constant`.
`SyntaxTokenType` is used by hosts, so coordinate the enum change or add
optional theme fields with defaults.

### V3. Verify selection and active-search contrast (after #41) — S
The baseline Material selection (primary at 40%) was described as muddy teal;
#41 reports a warm replacement. Verify app/editor selection and host overrides
after merge rather than implementing the same theme change again.
This session calculated light active-match white on `#3D8A78` at 4.11:1;
dark `#10181A` on `#8AD8C8` is 10.91:1 (`EditorSyntaxTheme`). Set an explicit
normal-text contrast target, then adjust the light foreground/background.
Test active/inactive hits over every token, actual app surfaces and system
high contrast. Formula checks do not replace real-font/native inspection.
The newer inherited measurements report other-token ranges of light
5.29–7.06:1 and dark 7.09–10.91:1, and propose `#2F6E5E` for the light active
background. Those extra measurements/candidate were not verified here.
Recheck the merged #41 values before treating this baseline contrast gap as open.

The latest report says #41 adds AA-checked colors but no permanent contrast
regression. Verify that coverage; retain tests against surface and current-line
band so later token/theme changes cannot reintroduce the measured 4.11:1 pair.

### V4. Search bar polish — S
#36 reports field surfaces/outlines/fills/monospace; #44 reports a magnifier,
clear button, boxed query field and error-colored counter. After reconciling
#10/#36/#44, verify the existing count-chip behavior; remaining ideas are one shared
bordered field group and content-sized width. The earlier compact/floating or
tinted-panel suggestion is an alternative style, not another required rewrite.
Preserve #10's responsive keyboard-accessible controls,
selected semantics, focus and live input connection while changing appearance.
Open #12 adds the `ab` whole-words toggle beside `Aa` and `isSelected` on
both search toggles; keep that semantics treatment in the reconciled bar.
Search history is still open.

### V5. Status bar segments — S
The newer #36 record reports aligning status with the text column and avoiding
language claims for unhighlighted large files. #33 reports display names for
raw IDs such as `shell`, `c-family` and `dotenv`. After their integration,
turn the "·"-joined text into distinct, clickable segments
(see E10), and show "Unsaved" as a dot. A colored dirty dot and
hover-only close affordances are styling detail inside this item, not a
second tab-strip design.

### V6. Error banner with actions — S
#21 reports mapping missing/unresolvable-path errors in core so hosts benefit.
After #21/#26, map remaining permission/read-only-directory/conflict errors to
friendly actions (Retry, Save As, Reveal, Dismiss). UTF-16 input still needs an
actionable unsupported-encoding route (A9), not just "not valid UTF-8".
Baseline workspace errors persist after successful retries. Scope errors to
operation/document and clear only the resolved failure. Test retry success,
two documents failing independently and multi-open aggregation (B15); announce
errors accessibly. Never hide an unrelated failure with a generic success.

### V6a. Active-search AA contrast consolidated in V3
Keep the baseline 4.11:1 finding, extra inherited measurements and proposed
background in V3; verify #41 before a separate fix. Do not duplicate the task.

### V7. Scroll past the end — M (not S)
The last line sits at the bottom edge. **Bottom `contentPadding` does not
do this:** the `InputDecorator` padding sits outside `EditableText`'s own
`Scrollable`, so it shrinks the viewport instead of adding scroll extent,
and `RenderEditable` computes its max scroll extent from the text height
alone. Options: a non-expanding field inside an outer scroll view with
trailing space (caret reveal still works through `showOnScreen`, but every
gutter and reveal path that reads `c.scroll` must move to the outer
controller), or the virtualized surface in P3. Do it with P3 or after one
gutter owner is chosen.

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
#36 reports making the empty workspace the launch state, with a subtitle and
three main shortcuts; previously startup opened a blank buffer. Verify that
assigned behavior, then add recent files (A3), a drop hint only once A4 works,
and optional Q2 artwork. New/Open shortcuts must still work with no tab.
The inherited report caught premature "drop a file here" copy before drop
support existed. Do not advertise actions the current build cannot perform.

### V12. Verify the new icon at small sizes — S
Main at `d53f416` integrated the new master/native assets; Linux packaging
reads that master. Do not repeat integration. This session inspected source
artwork and the committed 16px macOS icon: the detailed dark scene loses
distinct shapes at that size. Check 16/32/64px on light/dark surfaces; preserve
the supplied artwork and consider a simplified tiny-size silhouette only if
accepted. Validate Windows ICO, macOS assets, Linux install and task switchers.
No artwork was changed in this session.

### V13. Align buffer-related typography — S (inherited read)
The source reports document monospace versus UI-font gutter/status/counter,
with #36 moving only find fields and globally applying compact density.
Verify actual inherited text styles, then choose deliberate typography for
buffer coordinates/patterns versus commands. Check find-field padding beside
buttons and preserve host fonts and large text; uniformity is a design choice.

### V14. Avoid a white native window before first paint — S (inherited read)
The latest report says DesktopWindow never sets native background color.
Reproduce Windows/Linux dark launch, set the intended surface before show if
needed, and coordinate hidden-until-ready startup with B4. Test light/dark and
settings load timing before assuming one color suits every initial frame.

### V15. Define the tab strip container — S (inherited idea)
After #35/#36/#43 integration, compare a subtle inset border or baseline rule
with the current pills. Keep one chrome owner, active-tab distinction and
accessible contrast; avoid another independent rewrite.

### V16. Empty-state copy shows beside untitled tabs — S (read, 2026-09-27)
The header path label falls back to "A place for your words." whenever the
active tab has no path — so "Untitled 1" can be open while the header still
shows marketing copy (#21 also flagged it). Show the untitled name instead;
one-line label fix, but coordinate the shell file with #36/#43.

### V17. `caretLineColumn` reports (1,1) for an invalid selection — S (read, 2026-09-27)
An unfocused/invalid selection renders "Ln 1, Col 1" in the status bar —
plausible-looking but wrong for a document whose caret was elsewhere. Show
the last valid position or a neutral state; coordinate with FU13's status
semantics. Also worth noting: the window title duplicates the tab's dirty
dot and name; after #63 it is again the only dirty signal on GNOME.

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
  every occurrence of the word under the caret. Reuse E5's occurrence matching.
- **Q5. Ghost text for untitled documents.** Assigned to #52. Still open:
  let hosts (Séance, Poltergeist) supply their own lines through the same
  parameter.
- **Q6. Board words in the status bar.** A one-shot "YES" drifting across
  the status bar after a successful save, and "GOODBYE" when the last tab
  closes. Subtle, and skipped under reduced motion.
  A plain, unobtrusive "Saved" state with an accessible announcement is the
  default alternative. Never announce success for canceled/failed saves or
  while a newer revision is dirty; no sounds/confetti or required animation.
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
- **Q11. Quote and bracket teleport.** Jump to a matching bracket or the
  other endpoint of a string literal. The inherited shortcut proposal is
  Cmd/Ctrl+B plus a modifier variant; check existing bindings first (on
  macOS use Cmd, since Ctrl+B is the Cocoa move-back binding). Reuse
  E4's tokenizer-aware matcher and partner decoration rather than building
  a second matching engine. Build on #47: its `caretRevealRequest` and
  document-only key layer are what a caret jump needs. Keep the jump
  symmetric (from after a bracket to after its partner, from before to
  before) so pressing twice returns; with no bracket at the caret, go to
  the innermost enclosing closer; Shift extends the selection.
- **Q12. Peek the caret's line.** An optional dimmed status row shows the
  logical line, truncated in the middle, and a selection's column span.
  Keep it to one line and hide it in narrow windows; coordinate E10b/FU13.
- **Q13. Quiet disk-change notice.** After #26, consider a dim status-adjacent
  notice and status-bar Revert action for routine changes. Retain FU10's
  conflict/dirty-data choices and V6's actionable errors.
- **Q14. Optional paste normalization.** The incoming idea proposed automatic
  trailing-space trimming and final-newline insertion. Do not silently change
  pasted text: make it opt-in, explicit and one-step undoable, aligned with
  E9's policy. Test whitespace-significant content, tabs, selections and EOLs;
  default paste preserves the supplied text.
- **Q15. Ghost marks for unsaved lines.** A restrained gutter mark shows
  changes since the saved revision; clicking opens a local diff. No network
  or AI service. Bound diff work, clear only saved revisions, and design
  per-hunk restore separately with explicit undo.
- **Q16. Breadcrumb back.** Keep an in-memory trail of deliberate jumps
  (find, Go to Line, tab changes), not every caret movement. Back/Forward
  restores location/scroll; test changed and closed documents.
- **Q17. Named local scratchpads.** Build only after A2 provides recovery,
  so the persistence promise is real. Offer plain styling, keep thematic
  copy out of errors, and combine the empty-state ideas rather than adding
  competing screens.

All decorative motion is optional and respects reduced motion. Focus/coding
feedback must remain quiet and usable without animation or thematic copy.

- **Q18. Idle board animation.** After a quiet delay in the empty state, an
  optional planchette spells a short message along Q2's letters. Disable under
  reduced motion and resume ordinary input immediately.
- **Q19. Ritual commands.** Optionally accept `:wq`/`ZZ` through the command
  palette or Go to Line as Save and Close. Use existing save/close guards;
  distinguish commands from invalid line input and never close after failed save.
- **Q20. Typewriter mode.** Optionally keep the caret line vertically centered
  while typing. Coordinate V7 scroll-past-end, explicit navigation, selection
  and reduced motion rather than forcing every scroll back to center.
- **Q21. Document-word ghost suggest.** After a typing pause, offer the most
  likely next word drawn only from words already in the document (a local
  trigram at most — no network, no model). Accept on an explicit key only,
  never Tab (which inserts text); Esc dismisses. Private by construction.
- **Q22. Hex/offset lens.** Make the status-bar byte count clickable to show
  the caret's byte offset and nearby hex. Cheap and programmer-native;
  coordinate E10/FU13 so units stay UTF-8 bytes.
- **Q23. Local edit timeline.** Scrub session-only undo-stack snapshots with
  timestamps per file. No persistence in v1; design per-hunk restore like
  Q15 before promising more.
- **Q24. Daily word-goal candle.** An optional, subtle progress marker for
  writing goals. Off by default; never thematic pressure or sound.
- **Q25. Shebang wake-up.** E12 turns typing `#!/usr/bin/env …` into the
  file *choosing its own language* — a small moment worth a gentle
  confirmation: when detection changes the language through a first-line
  edit, flash the language segment in the status bar once (subtle,
  reduced-motion aware).
- **Q26. "Saved · verified" trust beat.** The digest guard that runs on
  every save is a real guarantee worth surfacing: after a successful save,
  the status could briefly read "saved · verified" before returning to
  normal. Truthful, programmer-native, zero cost.
- **Q27. Planchette glyph on the close dialog.** `chooseClose` is the one
  place the app asks a yes/no question, and the spirit board's YES/NO/
  GOODBYE semantics already exist implicitly. Keep the copy plain (thematic
  text stays out of errors) but a tiny planchette glyph in the dialog
  corner is a quiet nod — optional art, removable in one line.

## 10. Process and documentation

- **D0a. Review apparently unused shared APIs before removal.** The latest
  local grep reports `reload()` uncalled, `EditorSaveMode.local` never passed,
  `canPublish` used only by a test and `defaultTextDocumentMaximumBytes` an
  unused compatibility alias. Local absence does not prove sibling-host absence.
  Check host consumers and #19/#26/#38 first; Retry is a possible reload consumer.
  Document supported APIs in STATUS and treat removals as compatibility changes.

- **D0b. Consolidate dirty-close policy carefully.** The source reports app
  `_confirmTab` duplicates shared `EditorController.confirmClose`, including
  revision rechecks. Compare differing app busy/save/dialog responsibilities
  before routing through one contract. Retain tests for edits during dialogs,
  native saves and failed window destruction; never delete a safety guard merely
  to reduce duplication.

- **D0c. Identify the authoritative icon source.** The latest source reports
  #4 installed new raster assets while `media-sources/icon.svg` remains old.
  Verify tracked assets; update the editable source or clearly document PNG
  authority so regeneration cannot restore the old design. V12 retains small-size
  and packaged-icon checks.

- **D0d. One first-window size authority.** The reported GTK 1280×720 versus
  DesktopWindow 1080×760 discrepancy is B4, not a separate implementation.
  Coordinate with V14's first-frame background.

- **D0e. Separate native drops from Flutter drag tests.** The source reports
  failed `dragFrom`, `timedDragFrom`, manual pumped gestures and mouse-kind tests
  on Flutter 3.47.2 with a minimal Draggable/DragTarget pair. That failed harness
  does not prove Flutter drag gestures cannot be widget-tested. Preserve parser
  and wiring tests, diagnose gesture geometry/acceptance separately, and require
  actual native file-manager drop verification for A4.

- **D0f. Earlier source ID for Unicode-search investigation.** Consolidated in
  D0 below; do not reopen it as a confirmed native bug.

- **D6. State the no-network promise in product copy.** The app has no
  account, service, telemetry or updater (README); say so explicitly in
  settings/About once either exists. Never add networked features (model
  completion, update checks) without revisiting this promise first — Q21's
  ghost suggest stays local for the same reason.

- **D0. Unicode suspicion checked and dropped.** `findSearchMatches` has
  a fallback when lowercase conversion changes text length. The inherited
  review reports an exhaustive native scan of all 1.1M code points on its
  Dart 3.13.2 baseline: simple case mapping changed no code point's length
  (`İ` → `i`). That exhaustive scan was not rerun here. This session's
  smaller Dart 3.13.4 probe kept `İ Foo FOO foo` at length 13 and found all
  three ASCII hits. No native bug is established; do not schedule a fix for
  the earlier suspicion. The inherited report distinguishes JavaScript's
  full mappings, but web is not a supported target. Any future full-folding
  or locale policy should be an explicit feature with combining/non-BMP
  and replacement-offset tests, not a repair justified by this rejected bug.

- **D1. CHANGELOG.** The earlier inherited group omitted changelog edits to
  avoid conflicts; the newer source reports #21/#28/#36 each add Unreleased
  entries. Preserve their union during integration and add missing entries
  after merge. These ownership claims were not independently checked.
  Remove completed backlog records without losing unresolved acceptance cases.
- **D2. STATUS.md.** Update "Implemented" and "Current limits" after the
  merges: indentation, disk change detection, zoom, Go to Line, fonts,
  the diff language, load/memory improvements, search accessibility, bounded
  CSS/recovery names and tab behavior. Report actual merged validation limits.
  The newer source reports #28 updated three documents to its "32 KiB" cap
  and recorded the remaining few-hundred-ms plain ~800 KB harness cost.
  Preserve the measured limitation, verify units, and attribute branch results.

  The latest inherited source says STATUS verification is macOS-local and names
  Flutter 3.47.3 while CI pins 3.47.2. Verify those revisions/toolchains; do not
  promote local results to cross-platform proof or erase the distinction.
- **D3. Visual regression shots.** The inherited review reports that real-font
  screenshots (Roboto plus DejaVu Sans Mono via `FontLoader` and
  `RenderRepaintBoundary.toImage`) caught the centered menu bar that no test
  noticed. Consider a small golden suite on Linux in CI with those fonts.
  Preserve this session's before/after search/tab cases. Include light/dark,
  narrow widths, large text, wrap boundaries, long tabs/errors, RTL host
  direction, translated labels and the 40px tab height. Passing widget tests
  alone do not establish native layout quality or smooth frame timing (P1).
  The newer inherited pass used Roboto/Roboto Mono from
  `$DART_SDK/bin/resources/devtools/assets/fonts` and MaterialIcons from
  `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`, with `FontLoader` and
  `matchesGoldenFile`. Pin fonts/SDK, cover three tabs, search, empty workspace
  and a long document/visible scrollbar. Assert geometry directly where useful
  (for example flush-left menu `getRect`), and retain reported #36 geometry tests.
- **D4. Focus regressions.** Chrome changes easily break where focus
  lands after dialogs, tab switches and closing search. Keep the app
  tests that assert `editorFocus.hasFocus` after each of those flows, and
  add one whenever a new overlay (palette, Go to Line, notices) appears.
  The newer report says #21 leaves Tab unclaimed when read-only; verify that
  disabled commands do not consume keys they cannot act on. Unmount test
  widgets before disposing attached workspace nodes; do not misdiagnose a
  failed-assertion teardown trace as an application bug (B13).
- **D5a. A native Linux harness works in the dev container.** Install
  `libgtk-3-dev x11-utils xdotool imagemagick`, run `flutter build linux`,
  start `Xvfb :96 -screen 0 1400x900x24`, launch the bundle with a file,
  then drive it with `xdotool key ctrl+shift+p` / `type` and capture with
  `import -window root`. Saving with Ctrl+S and reading the file back gives
  byte-exact end-to-end checks of real X11 key handling; #47 and #49 were
  verified this way. **Gotcha:** switching branches and rebuilding reused a
  stale MaterialIcons subset from `.dart_tool/flutter_build`, so an icon the
  new branch added rendered as a missing-glyph box; delete that directory
  before visual checks. CI builds clean and is unaffected.
- **D5. Desktop verification gap.** The inherited review reports a gap in
  hands-on desktop validation; its performance/source probes should not be
  confused with native interaction tests. This session's CI includes desktop
  builds and native macOS fixtures, while local UI inspection used Linux
  widget captures. Before release, run a manual pass on real macOS,
  Windows and Linux covering fonts (#30), native menus, IME Enter and
  Tab (#14/#21), focus-driven disk checks (#26), and #36's scrollbar/find chrome.
  Add Linux/Windows native keyboard/accessibility smoke tests and profile-mode
  frame measurements; mobile-host behavior still needs FU7/FU17 validation.

- **D6. Verify Flutter APIs and behavior.** The inherited #28 account says an
  unsupported `softWrap` flag left uniform-row gutter assumptions paired with
  wrapped text; it also reports `TextEditingController.userUpdate` was an
  invalid reviewer suggestion. Its measured indent operation remained undoable
  despite another review claim. Check the pinned SDK, reproduce behavior, then
  document it; these PR-history claims were not independently inspected here.

- **D7. Match benchmark provenance.** The newer #28 source reports an initial
  false win from measurements taken minutes apart on a shared machine, then
  repeated its harness comparisons back-to-back. It also reports a 1 MiB
  measurement ceiling regressed a 787 KB fixture by 1.9×. Preserve those
  attributed lessons, not a blanket claim that every timing here shares that
  methodology. Record revision, workload, warmup, mode, machine/load and repeated
  samples; compare like-for-like before asserting a performance improvement.

- **D8. Golden-capture evidence consolidated in D3.** The inherited real-font
  captures exposed centered chrome, bare search fields and a missing scrollbar
  that code/test output missed. Keep D3's permanent visual/geometry work and
  concrete font provenance; do not create a duplicate golden-suite task.

- **D9. Retain regression proof for rejected hypotheses.** The newer source
  reports tests for acted-on findings and non-issues, including D0 and #21's
  undo question. Preserve meaningful behavior tests so future reviewers need
  not rediscover the same result; do not treat that report as our own test run.

- **D10. Screen-reader and keyboard audit.** After #10/#11/#35/#36/#43/#44 integration,
  verify selected search toggles and dirty/busy tabs on VoiceOver, NVDA and
  Orca. Give the document an explicit accessible label; do not rely on a
  dirty bullet alone. Errors need live announcements, all mouse actions need
  keyboard equivalents, and native text-edit shortcuts must survive. Avoid
  announcing the entire status on every keystroke. Existing dirty-dot semantics
  were a minor #11 review follow-up, not a confirmed blocker for that PR.

  The latest inherited V12 reports an unlabelled multiline field, a non-live
  error banner and possible verbose status announcements. The macOS fixture
  covers lifecycle, not necessarily content. Add semantic-tree tests plus real
  screen-reader checks. Avoid a blanket `ExcludeSemantics` that removes useful
  status access; prevent unsolicited chatter while keeping explicit inspection.

- **D11. Self-contained development setup.** AGENTS delegates SDK setup to
  a sibling repository that need not be checked out. Document supported SDK
  versions and native prerequisites locally. `scripts/build.sh` hardcodes
  Linux x64 although packaging recognizes arm64; either enforce/document x64
  or derive the actual built architecture and validate that configuration.

  The latest source observed no unzip/xz in its container; this is not universal.
  Preserve its archive sources: Dart's stable Linux x64 ZIP at
  `https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip`
  and pinned Flutter 3.47.2 Linux tarball at
  `https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.2-stable.tar.xz`.
  Python `zipfile`/`tarfile` (`lzma`) can extract without external unzip/xz, but
  `ZipFile.extractall` does not restore executable bits: restore ZIP `external_attr`
  permissions or use a tested installer before invoking Dart. Put SDK bin paths
  on PATH in the intended order and report standalone versus bundled Dart.
  Pin the tested Flutter version; a >=3.47.2 constraint does not validate all
  later SDKs. Include explicit core package paths and the documented separate
  editor/app pub-get, analyze and test commands. The incoming recipe was not
  independently validated here.

- **D12. Audit inherited packaging claims.** `package-linux.sh` describes
  secure storage and a trash backend absent from this app and adds
  `libglib2.0-bin`. #7 reports correcting section/copyright, checking objdump, removing the
  unused gio dependency and fixing floor_of subshell error propagation. Verify
  that assigned patch rather than duplicating it; check actual ELF/runtime
  dependencies before further removals. Verify installable packages and retain required
  native libraries and pinned download-integrity checks.

- **D13. Consider a formatter CI gate.** The latest source reports analysis
  without format enforcement. Inspect current workflow first, then gate only
  intended Dart paths with `dart format --output=none --set-exit-if-changed`.
  Avoid coupling the gate to an unrelated repository-wide formatting rewrite.
  #20 separately reports Dependabot coverage for both Flutter directories;
  verify its assigned change after merge.

- **D14. Resolve inherited decision-document references.** Map syntax comments
  such as `// 06 §7.3` to accessible docs or remove stale references when touching
  those sections. The duplicate maximum-byte alias is already D0a; remove only
  after host compatibility is checked.

- **D15. Preserve UTF-16 offset contracts.** Dart selections, syntax and search
  ranges use UTF-16 code units. Keep byte counts and grapheme/display columns
  explicit; test astral characters at every transform boundary. LSP defaults
  to UTF-16 but can negotiate other position encodings, so a future adapter
  must convert according to negotiation rather than assume universal UTF-16.
  See the [official protocol definitions](https://github.com/microsoft/vscode-languageserver-node/blob/main/protocol/src/common/protocol.ts#L974-L994).

- **D16. Reconcile hashing proposals before implementation.** The latest source's
  B20 says remove a pre-read hash while its D14 says retain guarded passes.
  P4 records both and requires equivalent safety proof; these are not two
  independent implementation tasks.

Latest-source IDs were reconciled by subject: its B15/B16 became B22/B23;
B17/B18 remain B15/B16 here; B19 joins B18; B20/B21 join P4; B22 is P7;
B23 joins I1. Its V12 joins D10, V13–V15 become V13–V15 here (the old icon
V12 remains). Its Q15 joins Q17; Q16–Q18 become Q18–Q20. Its D10 joins D13,
D11 stays D11, D12–D14 become D14–D16. Stable existing IDs take precedence.

## 11. Review and verification ledger

Only #5/#6/#10/#11 were reviewed and monitored in this session. A parallel
session reviewed and monitored #8/#9/#12/#18; its rounds are recorded below
in the same style. Other PR
records, APIs and measurements above were inherited from the tracked document;
their presence is not independent approval or verification. Leave all recorded
implementation PRs for owner review/merging. Repeated reviews of the same
commit are identified; skipped/cached executions do not count as fresh reviews.

- **#5:** Two fresh same-revision reviews, no applicable important findings.
  Rejected old-Safari lookbehind compatibility as outside supported native
  targets. Deferred the requested 20k→100k timing fixture: the observed old
  code already takes 7.456s against a 1s ceiling; a larger regression would
  stall the suite much longer. The separate fixed 200k probe took about 27ms.
- **#6:** Round 1's minor root/relative spelling and oversized-prefix coverage
  findings were addressed. The relative-path regression failed before fixing;
  the smaller-filesystem limitation is documented. Round 2 had no important
  findings. Defer early rejection of directory targets and an optional
  subprocess test harness: existing create/save reject directory targets and
  leave no entries. Rejected global `Directory.current` mutation because
  parallel isolates share process state. Both temporary and backup paths use
  `_recoverySibling`, so the temporary observer covers shared path construction.
  A configurable filesystem-capability API remains separate future work.
- **#10:** Round 1 found a responsive-layout input-connection regression.
  A failing test preceded the stable-layout fix. All CI passes; three GLM
  reviews completed, the last two without confirmed important findings. The
  final same-revision hybrid audit ran fresh (zero delta/two unchanged sections,
  271.871s), not from cache.
  Its shrink-wrap concern does not apply to the private panel's unbounded-height
  parent; tests cover both layout directions and resize with the keyboard open.
  A claimed missing-font crash used a fixture violating TextField's theme
  contract; valid inherited partial styles receive Theme.of defaults and pass.
  Rejected the final claimed Enter bypass of editing locks: `replaceCurrent`
  guards locked/busy/no-active-match states, and four temporary widget-submit
  probes passed. The optional half-width layout tradeoff remains unchanged.
- **#11:** Two fresh reviews completed without an important finding; all CI
  passes. Rejected the claim that `keepVisibleAtEnd` scrolls backward needlessly:
  the pinned Flutter implementation clamps that direction, and
  `keepVisibleAtStart` handles left overflow. A geometry probe confirmed the
  nearest-left target and full visibility. Existing dirty-dot accessibility
  semantics remain a minor D10 follow-up. The second same-revision review
  executed a fresh hybrid audit. Its claimed `num`/`double` clamp compile error
  was disproved by a typed probe, analysis and three-platform builds. Its
  proposed `textScalerTestValue` APIs do not exist in the pinned SDK; the
  existing text-scale test setter is not deprecated. Coordinate #35/#36/#43.

Native screen-reader operation, mobile-host behavior, macOS/Windows visual
inspection and broad profile-mode frame timing remain unverified locally.

Parallel session (#8/#9/#12/#18), Flutter 3.47.2 / Dart 3.13.2 on Linux,
baselines `e7ec67f`/`d53f416`. Other workers' PRs were not listed or
inspected.

- **#8:** Round 1 minor-only (merged-brace artifact, digits-only input with
  a formatter regression test, shared `_estimatedLineTop` helper) addressed.
  Round 2 raised only a disproved `int.clamp`-returns-`num` compile claim:
  the expression analyzes clean, the clamp tests run green, and CI
  analyze+test passes on the reviewed sha. No valid important findings
  across two rounds; steady, left open.
- **#9:** Round 1 fixed a real style-replacement regression the review
  caught (an app-passed `TextStyle` replaces the editor default, so passing
  only the size silently dropped monospace/1.35), plus numpad bindings,
  clamp/background-tab/macOS coverage and formatting. Two claims declined
  with evidence (`double.clamp` compiles per analyzer and CI; the Shift+=
  binding's guard matches the menu's `unlocked` by construction). Round 2
  minor-only addressed (rendered-style contract test, exact skip reasons).
  Round 3 (comment-accuracy, editor-constants suggestion) accepted-in-
  principle but deferred without push per stopping rules; recorded in FU4.
  Steady, left open.
- **#12:** Round 1 minor-only (astral surrogates as boundaries, `isSelected`
  on both search toggles, reveal parity pinned) addressed. Round 2 single
  minor (exact reveal counts) addressed at `a7af694`. Round 3 single minor
  (needle-edge `\b` parity) accepted-in-principle but deferred without push
  per stopping rules; recorded in E5. Steady, left open. CJK/full-width punctuation stays word content by decision.
- **#18:** Round 1 (false `int.clamp` blocker declined with analyzer and CI
  evidence; full-selection round-trip, cancelled-close and conflict tests,
  undo-noop regression accepted) and round 2 single minor (selection
  affinity) addressed at `6b2786b`. The in-flight-open duplicate-tab claim
  was declined with evidence: `_open` re-checks `_findPath` after loading
  and discards its tab through the duplicate guard. Awaiting confirmatory
  round 3.
- **Test-infra note:** flutter_test cannot synthesize numpad key events
  (`event_simulation` asserts no linux keyCode mapping), so #9's numpad
  bindings stay uncovered with the exact failure cited in-test. Harness
  limits are cited concretely, not generalized — same policy as D0e.
- **2026-09-27 review pass (#57–#63):** baseline `797deb9` on Flutter
  3.47.2; suites green (core 85, editor 19, app 40 + 2 case-insensitive
  skips). #57 and #58 each completed a first GLM round with all findings
  applied — matcher pinning, the NUL code-unit offset and a shared
  `_firstNulIndex` on #57; `osError`/stack-trace preservation, a root-and-
  chmod-hardened read-only test and ENOENT-only conflict reporting on #58.
  #59–#63 await their first rounds. One finding resolved as by-design:
  `OpenDocuments` is intentionally never disposed because its macOS
  channel handler must outlive every document event (recorded under B22).
