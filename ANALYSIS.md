# Planchette analysis and backlog

A working backlog for Planchette: review findings, follow-ups, and ideas.
Each open item is written so that an agent can pick it up without
rediscovering the context: why it matters, where the code is, what to
change, and how to know it is done. Read [AGENTS.md](AGENTS.md) first.

- Baseline reviewed: `main` at `d53f416` (2026-09-27). Toolchain: Flutter
  3.47.2 / Dart 3.13.2. At that commit, core has 84 tests, the editor 19
  and the app 38, all green.
- Evidence labels: **confirmed** means reproduced with a test or probe.
  **Read** means found by reading code or Flutter/Skia sources but not
  observed on a real desktop. **Idea** means a suggestion.
- Effort: S (under an hour), M (half a day), L (days). Risk is the chance
  of regressions in hosts (Poltergeist, Séance) or native behavior.
- When you finish an item, delete it here in the same PR, and add a
  CHANGELOG line.

## Contents

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

---

## 1. In review

These findings have PRs open against `main`, left for the owner's review.
If a PR is closed without merging, move its findings back into the
sections below. The problem statements live in the PR descriptions.

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
| [L-K-M/Planchette#35](https://github.com/L-K-M/Planchette/pull/35) | The Linux/Windows menu bar and tab strip were centered mid-window (**confirmed**). Merges the toolbar into one tab strip with a dirty dot and close on hover, middle-click close, Cmd/Ctrl+1…9, the active tab kept in view, wheel scrolling, and "Untitled"/"Untitled 2" naming |

**Merge-order notes.** All eight branches start from `d53f416`. These pairs
touch nearby lines and will need a small conflict resolution for whichever
merges second:

- #14 and #33 both edit the status list in `editor_view.dart`. Keep both
  the indentation segment and the language display name.
- #30 and #33 both add to the app's Find/View menus in
  `planchette_app.dart`.
- #22, #30 and #33 touch other parts of `editor_view.dart`, as do #26,
  #30, #33 and #35 in `planchette_app.dart`. Their hunks are separated, so
  expect clean merges, but re-run all three test suites after each merge.

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
Planned in #35 but not built:
- A right-click menu on tabs: Close, Close Others, Close to the Right,
  Copy Path, Reveal in Finder/Explorer/Files.
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

### B6. Only the last error survives a multi-file open — S (read)
`DocumentWorkspace.openDialog` overwrites `error` for each failing file.
Collect the failures and show "2 files could not be opened: a.bin (binary),
b.txt (not UTF-8)".

### B7. Opening a file that is already open should flash its tab — S (idea)
Today the existing tab is simply activated. Add a short highlight
animation on that tab so it's clear why nothing new appeared.

## 4. Performance

### P1. O(document) work per keystroke — L (structural)
Every edit re-tokenizes the whole text on the UI thread (including the
regex meta pass), rebuilds all spans, relays out the whole paragraph,
recomputes `lineStartOffsets`, and recounts UTF-8 bytes. With find open,
it also lowercases and re-searches the whole document. The 200,000-char
highlighting cap exists because of this.

Short-term steps, each S–M:
1. Incremental tokenization. Store the scanner state at each line start
   (inside a block comment or multiline string, or not). On an edit,
   re-tokenize from the edited line until the state converges with the
   previous run, and splice the token list.
2. Cache the lowercased haystack per text instance in `EditorController`.
3. Update `lineStarts` and `byteCount` incrementally from the edit range
   (`TextEditingValue` deltas), or at least lazily.

Long-term: see P3.

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
own the caret, selection and IME client) would remove the 200k and 4 MiB
ceilings and enable minimap, folding and true tab stops. It's a big
project: prototype behind a flag in `planchette_editor`, keeping
`EditorController`'s API.

### P4. Load and save off the UI isolate — M
After #39, opening a 3.9 MB file still costs about 180 ms of CPU on the
UI isolate: three SHA-256 passes (about 50 ms each in AOT), the UTF-8
decode, and line-ending folding. **Plan:** run the pure steps (hash,
decode, census, fold, and encode on save) in `Isolate.run` inside
`planchette_core`. Keep the file I/O and the digest ordering exactly as
they are, since the safety tests inject `sha256Of`. **Done when**
opening a 4 MiB file leaves the UI isolate responsive (no frame over
16 ms in a profile build), and all document-safety tests pass unchanged.

## 5. Editing features

### E1. Toggle line comment (Cmd/Ctrl+/) — S
Use the language's `lineComments.first`. If every selected line is
commented, uncomment; otherwise comment at the minimum indentation. For
`blockComments`-only languages (CSS, XML), wrap the selection. Put the
pure function in `planchette_core` next to `indentation.dart`.

### E2. Line operations — S each
Duplicate line or selection (Cmd/Ctrl+Shift+D), move line up/down
(Alt+↑/↓), delete line (Cmd/Ctrl+Shift+K), join lines (Cmd/Ctrl+J).
Write pure core transforms returning text and selection, the same shape
as `IndentEdit`.

### E3. Auto-close brackets and quotes — M
Insert the closer after the caret when typing `( [ { " '` before
whitespace or end of line. Type over a closer that was auto-inserted.
Backspace between an empty pair deletes both. Respect string and comment
context using the tokenizer, and add a setting to turn it off.

### E4. Bracket-match highlight — M
When the caret touches a bracket, find its partner (skipping strings and
comments via tokens) and paint both backgrounds. The decorations render
object from #22 can paint them.

### E5. Search options — M
Whole word, regular expression (with capture groups in the
replacement), "in selection", and highlight all occurrences of the
selected word. Add toggles next to the existing `Aa` button, and keep
the 1000-match display cap.

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

### E10. Change line endings, indentation and language from the status bar — M
Make the status segments into menus:
- LF / CRLF converts the document on the next save.
- Spaces / Tabs sets `indentation`, with "Convert indentation".
- The language picker sets the language explicitly.

The status row lives in the shared editor, so do this through
`statusBuilder` or new callbacks, not app-only code.

## 6. App features

### A1. Settings store — M (enables FU4, E9, A3, A4)
Add a small JSON settings file in the app support directory (use
`path_provider`), read at startup and written on change. Candidate
settings: font family and size, theme, tab behavior, trim and
final-newline rules, current-line band, line numbers, status bar, and
restore-session. Expose it as a `SettingsStore` service with a fake for
tests, following `DocumentStore`.

### A2. Session restore and hot exit — L
Reopen the last session's files, and restore unsaved untitled buffers and
unsaved edits after a quit or crash. Journal dirty buffers to the app
support directory on idle, with owner-only permissions, and clear the
journal on save or close. It must survive a failed save and must not
resurrect discarded edits.

### A3. Open Recent and a recent list in the empty state — M
Keep the last 20 paths in settings. Show them in File › Open Recent (on
macOS, prefer `NSDocumentController`'s recents) and in the empty state.
Remove entries whose files are gone.

### A4. Drag and drop files onto the window — M
Use the `desktop_drop` plugin. Open each dropped file through
`DocumentWorkspace.open`. Show a drop highlight over the editor area.
Registering the plugin changes all three runners' generated registrants;
check Linux packaging still passes.

### A5. Quick Open (Cmd/Ctrl+P) — M
A fuzzy list over recent files and the active file's directory. Enter
opens, and Esc returns to the editor.

### A6. Command palette (Cmd/Ctrl+Shift+P) — S–M
The shell already models menus as `_ShellMenu` / `_Command`. List every
enabled command with its shortcut, filter by fuzzy match, and run it on
Enter.

### A7. Save All, Close All, Close Others, Reopen Closed Tab — S each
Reopen Closed Tab (Cmd/Ctrl+Shift+T) keeps a stack of recently closed
paths. The quit prompt should list the dirty files, with "Save All" and
"Discard All" buttons instead of one dialog per tab.

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

### V1. Curated themes — M (idea)
Planchette is named after the Ouija pointer, and its icon leans into
that. Offer two themes beside the Material seed:
- **Parchment** (light): paper `#F7F1E3`, ink `#2B2522`, sepia comments,
  oxblood keywords, brass numbers, verdigris strings.
- **Séance** (dark): candle-lit `#1B1716`, warm off-white text, ember
  keywords, brass numbers, moss strings, smoke comments.

Every token color needs AA contrast (4.5:1) against the background and
the current-line band. Add a contrast test in the editor package.

### V2. More token classes — M, risk: medium
Five classes (comment, string, number, keyword, meta) limit themes. Add
`type` (capitalized identifiers in C-family, Dart, Swift, Kotlin and
Rust), `function` (an identifier before `(`), and `constant`.
`SyntaxTokenType` is used by hosts, so coordinate the enum change or add
optional theme fields with defaults.

### V3. Selection color per theme — S
The Material default (primary at 40%) reads as muddy teal on the current
seed. Set `TextSelectionThemeData` in the app theme, and pass it through
for the editor.

### V4. Search bar polish — S
The find bar is a borderless row with 16 px padding. Make it a compact
floating panel at the top right, or tint its background, and show the
match count as a chip.

### V5. Status bar segments — S
After #33, turn the "·"-joined text into distinct, clickable segments
(see E10), and show "Unsaved" as a dot.

### V6. Error banner with actions — S
The workspace error bar shows raw `FileSystemException` text. Map known
failures to friendly text with actions (Retry, Reveal, Dismiss), in the
style of the disk notice in #26.

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
The empty state says "Start with a blank page" with New and Open buttons.
Add recent files (A3), a "drop a file here" hint (A4), and a short list
of the main shortcuts. Keep focus handling: New and Open shortcuts must
keep working with no tab open, as covered by the existing test.

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

## 10. Process and documentation

- **D0. Checked and dropped.** The initial review suspected that one `İ`
  in a document would make case-insensitive search case-sensitive,
  because `findSearchMatches` falls back when lowercasing changes the
  length. That can't happen on Planchette's targets: on the Dart VM,
  `toLowerCase` uses simple case mapping and changes the length of no
  code point (all 1.1M were checked; `İ` → `i`). It would only matter
  for a web build, where JavaScript applies full mappings.

- **D1. CHANGELOG.** None of the eight PRs edits `CHANGELOG.md`, to avoid
  eight-way conflicts. After merging, add one "Unreleased" entry per
  merged PR.
- **D2. STATUS.md.** Update "Implemented" and "Current limits" after the
  merges: indentation, disk change detection, zoom, Go to Line, fonts,
  and the diff language.
- **D3. Visual regression shots.** Real-font screenshots (Roboto plus
  DejaVu Sans Mono via `FontLoader`, `RenderRepaintBoundary.toImage`)
  caught the centered menu bar that no test noticed. Consider a small
  golden suite on Linux in CI with those fonts.
- **D4. Focus regressions.** Chrome changes easily break where focus
  lands after dialogs, tab switches and closing search. Keep the app
  tests that assert `editorFocus.hasFocus` after each of those flows, and
  add one whenever a new overlay (palette, Go to Line, notices) appears.
- **D5. Desktop verification gap.** Everything above was verified with
  widget tests only. Before a release, run a manual pass on real macOS,
  Windows and Linux covering fonts (#30), native menus, IME Enter and
  Tab (#14), and focus-driven disk checks (#26).
