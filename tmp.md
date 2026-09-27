# Planchette — review

Working notes, 2026-09-27. Not a verdict, a map.

## How this was checked

Read every Dart source file in the repo (7,179 lines including tests), all
scripts, the three CI workflows, and both platform runners. Installed Dart
3.13.4 and Flutter 3.47.2 and ran everything:

| Suite | Result |
|---|---|
| `planchette_core` `dart analyze` | clean |
| `planchette_core` `dart test` | 84 passed |
| `planchette_editor` `flutter analyze` | clean |
| `planchette_editor` `flutter test` | 19 passed |
| `planchette_app` `flutter analyze` | clean |
| `planchette_app` `flutter test` | 40 passed (2 skipped: case-sensitivity of the temp volume) |

Baseline is green. Everything below is either a defect, a measured cost, or an
opinion about what a programmer wants.

Measurements are from a 3,060,000-character Dart source file (60,000 lines of
`  final value = someFunction(alpha, beta); // note`) and a 169,149-character
one just under the 200,000-character highlighting cap, in the Flutter test
harness. A widget-test `pump()` does more work than a real frame, so treat the
absolute numbers as an upper bound and the ratios as the finding.

---

## 1. The headline: typing is unusable above ~50 KB

| Operation (169k chars, under the highlight cap) | Cost |
|---|---|
| One keystroke: full `pump()` (layout + paint + gutter) | **2,159 ms** |
| Same, amortized over 5 edits | **703 ms / keystroke** |
| Same file, above the cap (no tokenizing) | 123 ms / keystroke |
| `tokenizeSyntax` alone | 38 ms |
| `lineStartOffsets` + `utf8EncodedLength` (status bar) | 9 ms |
| One keystroke, 68k chars | 123 ms |

703 ms/keystroke is 1.4 fps. Even the cheap path is 123 ms — 8 fps. The
five-and-a-half-fold gap between "under" and "over" the highlighting cap is the
tell: something proportional to the whole document runs on every keystroke
whenever the file is under 200,000 characters, and the highlighting cap
happens to switch it off.

### 1.1 The gutter lays out the entire document on every keystroke

`editor_view.dart:507` `_ensureGutterLayout` builds a `TextPainter` over the
whole buffer and calls `getOffsetForCaret` once per line to build `_gutterTops`:

```dart
final painter = TextPainter(
  text: c.text.buildTextSpan(...),   // whole document
  ...
)..layout(maxWidth: width > 1 ? width : 1);
_gutterTops = [
  for (final offset in c.lineStarts)
    painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
];
```

It is called from the `LayoutBuilder` in `_body()` (line 419), so it runs on
every layout, and its memo key is the text — which changes on every keystroke.
Full-document paragraph layout, 4,975 `getOffsetForCaret` calls, then the real
`TextField` lays the same text out a second time. This is the 2,159 ms.

The design is sound (soft wrap means a line's y depends on every row above it).
The implementation is not: it recomputes the whole map to answer "where is line
N", when the only consumer is "which line numbers are on screen right now".

Fix, in order of value:

1. **Do not soft wrap by default.** Every real code editor (VS Code, Sublime,
   Zed, Kate) defaults to horizontal scrolling. With a fixed line height and no
   wrap, `_gutterTops[i] == i * lineHeight` exactly — no `TextPainter`, no
   allocation beyond a `List.generate`, correct by construction.
2. When wrap *is* on, keep the `TextPainter` path but move it off the keystroke
   frame: coalesce into a post-frame callback, keep painting the previous
   `_gutterTops` meanwhile, and skip it entirely while a scroll animation or
   IME composition is in flight.
3. Paint only the visible window, which `_LineNumberGutterPainter` already
   does (it binary-searches `lineTops`) — the waste is upstream of the painter.

### 1.2 `isDirty` is a full string comparison, read from the build

`editor_controller.dart:93`:

```dart
bool get isDirty => !_loading && text.text != _savedText;
```

It is read by the status bar, the tab label, the window title, `save()` and
`confirmClose`. It also permanently duplicates the whole buffer in `_savedText`
— for a 4 MiB document that is a second copy of the file, per open tab, which
`IndexedStack` then keeps alive forever.

A revision counter answers this in constant time. The controller already keeps
`_revision`; it needs a `_savedRevision` set when the save commits, and
`_installText` has to bump `_revision` so a re-install is never "clean".

### 1.3 Metrics are recomputed from scratch on every keystroke

`editor_controller.dart:198` `_updateMetrics` rebuilds `lineStartOffsets` and
`utf8EncodedLength` over the entire document whenever the text object identity
changes. Measured at 10.2 ms and 5.2 ms respectively on 3M characters, plus a
fresh `List<int>` of 60,000 line offsets allocated and thrown away per keystroke.

The status bar (`_statusBar` reads `lineStarts.length` and `byteCount`),
`caretLineColumn`, and the gutter width measurement (`'0' * c.lineStarts.length
.toString().length`) all read it, so it cannot simply be made lazy.

The fix is the one every editor uses: line starts and byte count are functions
of the text, and an edit only changes a bounded window of them. Find the common
prefix and suffix between the old and new text, keep the line-start entries
before the prefix, rescan only the touched region plus the new suffix, and
adjust the byte total by the region delta. `String` prefix/suffix comparison is
native `memcmp`, not a Dart loop, so the common case (a one-character edit)
costs a memcmp plus a short rescan. This belongs in `planchette_core` as a pure
function so Poltergeist and Séance get it too.

### 1.4 Search re-scans and re-lowercases the document on every keystroke

`findSearchMatches` (`editor_syntax.dart:1163`) lowercases the entire haystack
on each call, allocating a full copy: 7.0 ms measured on 3M characters, plus
7.3 ms of `indexOf` scanning. It is called from `_queryChanged` (every
keystroke in the find field) and from `_textChanged` (every keystroke in the
document, whenever the find bar is open — line 210).

Three separate problems: no debounce, no cached lowered haystack, and a
literal-only matcher that cannot do anything smarter. Debouncing the query to
one search per frame is the cheap 80% win.

### 1.5 `replaceAll` can hang the app

`editor_controller.dart:399` calls `findSearchMatches(..., limit: source.length + 1)`.
For a 4 MiB file of `a` with the query `a`, that is ~4,000,000 `TextMatch`
objects plus 4,000,000 `substring` calls into a `StringBuffer`. The core
function has a `searchMatchLimit` precisely to avoid this, and `replaceAll`
deliberately removes it — correctly, since replace-all must not stop at the
display cap, but with no bound at all it is a multi-second freeze with a
matching memory spike. The behaviour is right; the ceiling is missing.

### 1.6 Everything above is O(open tabs) per keystroke

`IndexedStack` (`planchette_app.dart:629`) builds every open tab's
`PlanchetteEditor` on every shell rebuild, and the shell calls `setState(() {})`
from a listener on the active `EditorController` — so every keystroke rebuilds
the whole tab list, `_menus()` (~30 freshly allocated `_Command` objects), the
shortcut map, and every background editor's `TextField` and `CustomPaint`.
Background tabs are memoized inside `_ensureGutterLayout` so they do not re-lay
out, but the widget subtree is still rebuilt and every gutter still paints.

Separately, `main.dart:31` calls `desktop.setTitle(...)` on every workspace
notification, i.e. a `windowManager.setTitle` platform-channel round trip on
every keystroke. The title only changes when the tab or its dirty state changes.

The shell should listen to what it actually displays. `ListenableBuilder` around
the status bar, the tab labels, and the menus keeps a keystroke from
reconstructing the window.

---

## 2. The editor cannot be used to write code

Three separate probes, same result.

**Tab does nothing.** With the caret in the document, `Tab` leaves the text
unchanged (`text=x` after pressing Tab in `x`). There is no `Tab` binding
anywhere in the app or the editor, so the keystroke falls through to focus
traversal or is dropped. A programmer's text editor in which you cannot indent
is missing its most-used key. There is also no "insert spaces instead of tabs"
setting, no configurable tab width, and no indent guides.

**Enter does not auto-indent.** Pressing Enter at the end of `    indented`
yields `\nindented` with no carried indentation. Multi-line YAML blocks, shell
here-docs, and Python function bodies all become progressively harder to type.

**Brackets and quotes do not auto-pair.** Typing `{` inserts one character.
Every bracket, brace, paren, and quote should be a pair, with a type-over
behavior when the caret sits between a closing pair.

All three are the same missing feature: the editor has no input layer between
the platform's `TextInputClient` and the buffer. `EditorController` is a
`TextEditingController` wrapper, and Flutter's `EditableText` inserts exactly
what the keyboard produced.

**What a programmer's editor is missing entirely:**

- Regex search, and whole-word search. `findSearchMatches` is literal-only
  (`editor_syntax.dart:1163`). This is the single most-requested find feature
  in every editor ever written.
- Go to line. Not present in any form. `Cmd+I` / `Ctrl+G`.
- Current-line highlight. The gutter brightens the caret's line number
  (`editor_view.dart:619`) but the text behind the caret gets no treatment.
- Bracket matching, and a configurable right margin ruler at 80/100 columns.
- Render whitespace toggle, so tabs versus spaces are visible.
- Word wrap toggle (see 1.1 — the absence of one is also the bug).
- Multi-cursor / select-all-occurrences. `replaceAll` covers the mechanical case
  but not "edit all these at once".
- Recent files. The app has none; `Open…` always starts at the system default
  directory (`document_dialogs.dart:21` passes `initialDirectory` only for
  absolute suggestions, which an untitled document never has).
- Session restore. `docs/STATUS.md` admits it. Every crash, quit or reboot loses
  the tab set.
- Drop a file on the window to open it. Nothing handles
  `DesktopDropTarget`; this is table stakes.
- Detect that a file changed on disk while open. The digest guard only fires
  during a save (`text_document.dart:261`), so an SSH-edited config that
  collides with a local edit is discovered only when the save fails.
- Jump to a line/column from an error message, and from `File ▸ Go to…`.
- File-type override. Language is inferred from the path
  (`syntaxLanguageFor`); a `.conf` that is really nginx syntax cannot be
  declared. A dozen lines of picker would fix it.

---

## 3. Cheaper open and save

The core is careful and correct — the two-rename replacement, the no-replace
publication, the digest guards, the owner-only temporary, the permission
restore are all thoughtful and well tested. The costs are incidental.

**The file is read three times to open it.** `loadTextDocument`
(`text_document.dart:96-110`) computes a `before` digest by streaming the whole
file, then streams it again into `bytes`, then computes an `after` digest by
streaming it a third time. Measured sha256 cost is 66 ms per 3 MB, so a 4 MiB
file pays ~200 ms of hashing plus two extra full reads. The `before` digest is
redundant: the existing `crypto.sha256.convert(bytes) != after` check already
detects any change that happened during the read, and it is strictly stronger
because it compares the bytes actually returned. One fewer pass.

**A lookbehind regex over the whole document to pick a line ending.**
`text_document.dart:132-133` runs `RegExp(r'\r\n')` and `RegExp(r'(?<!\r)\n')`
as `allMatches` counts. The lookbehind one measured **114 ms** on 3M characters
— 40× the cost of the CRLF scan next to it, for a two-counter problem that a
single hand-written loop answers in one pass with no intermediate objects.

**The save re-reads the temporary it just wrote.** `_writeTextDocument`
(`text_document.dart:240`) calls `textDocumentSha256(temporary)`. The bytes are
already in memory in `bytes`; hashing the list is free by comparison.

**Line-ending normalization is three full string allocations.**
`_normalizeLineEndings` runs `_foldToLf` (two `replaceAll` passes) and then
possibly a third `replaceAll('\n', '\r\n')`. Measured 28 ms on 3M characters,
per save. A single pass that appends into a `StringBuffer` — or nothing at all
when the buffer is already LF and the target is LF, which is the common case
and currently still copies the whole document twice.

**`loadTextDocument` accumulates bytes into a growable `List<int>`.** For a
4 MiB file that is a 4 MiB `List<int>` of boxed-or-unboxed SMIs plus the
growth copies. `Uint8List` with a known length, or `utf8.decoder.bind(...).join()`,
avoids it.

---

## 4. Visual and layout problems

**The tab label re-flows when the document becomes dirty.**
`planchette_app.dart:535`:

```dart
Text('${tab.editor.isDirty ? '● ' : ''}${tab.name}', ...)
```

The dirty marker is prepended to the string, so the label's width changes the
instant you type and again the instant you save. Every tab visibly jitters
twice per save cycle. It should be a separate widget with a fixed slot, and it
should not be a raw bullet either.

**Two stacked bars of chrome before any text.** The header row
(`planchette_app.dart:440`) is icon + "Planchette" wordmark + three icon
buttons + the active path. Directly below it is a 40px tab bar showing the same
basename again. Above that on Linux and Windows is a 48px Material `MenuBar`.
That is ~130px of chrome, two of the three rows redundant, before the first
character of the document. Every real editor puts the window controls, tabs,
and the document in one strip. The `Edit` menu in particular is pure duplicate
— it is the platform's own menu, and the app already excludes it from its own
shortcut map (`planchette_app.dart:426`) precisely to let the native menu work.

**The find bar has no field.** `editor_view.dart:239-251`: `isDense: true`,
`border: InputBorder.none`, no prefix icon, no clear button, no rounded
container. The query text floats in the toolbar with no affordance saying "this
is a text input". Compare `TextField(decoration: InputDecoration(hintText: …))`
as used everywhere else in the same file, which does render a box.

**Tab labels are basename-only.** `DocumentTab.name` is `paths.basename(path)`.
Ten open `index.js` files produce ten identical tabs. At minimum, elide the
middle of the path; at best, show enough parent directories to disambiguate.

**The active tab can scroll out of view.** The tab bar is a
`SingleChildScrollView` with no scroll-to-active. Open 20 files and switch tabs
from the Window menu: the newly active tab may be off-screen.

**The error banner is inserted into the column.** `planchette_app.dart:572`
splices a `Material` between the tab bar and the editor, so an error pushes the
document down and back up. A snackbar or an overlay would not reflow the
document. It is also a single slot: a second error while one is showing
silently replaces the first, and nothing ever auto-clears it.

**The load-failure screen has no way out.** `editor_view.dart:397` shows the
error text and nothing else. `EditorController.reload()` exists
(`editor_controller.dart:145`) and **is called from nowhere** — not by this
error view, not by the app, not by a test. The recovery path was written and
never wired up.

**The empty state is nearly unreachable.** `main.dart:34` creates an untitled
document whenever the app starts with no files, so "Start with a blank page" is
only visible after closing the last tab. That is a wasted design, or a startup
behaviour that should change, not both.

**Linux/Windows title-bar sizes disagree with the runner.** The GTK runner sets
`gtk_window_set_default_size(window, 1280, 720)`; `window_manager` is told
`Size(1080, 760)`. Two sources of truth for the first window's size, and they
disagree.

**No Linux icon ships in the tree.** `scripts/build.sh:53` copies
`media-sources/icon.png` into the bundle at install time. There is no
`linux/` icon directory, so the AppImage and the `.deb` get whatever
`package-linux.sh` invents, if anything.

---

## 5. Theming and aesthetics

**One hardcoded seed, no choice, no toggle.** `planchette_app.dart:39`:
`ColorScheme.fromSeed(seedColor: const Color(0xff245b5c), …)`. `main.dart` hardcodes
`ThemeMode.system`. There is no way to force light or dark, no way to pick an
accent, and no settings surface at all. Everything user-adjustable is a compile
constant: `_padding = 14.0`, `fontSize: 14`, `height: 1.35`, `fontFamily:
'monospace'`, the gutter inset.

**Two fixed syntax palettes.** `EditorSyntaxTheme.dark` and `.light` are
`const` structs with no third option. A high-contrast variant and one or two
named palettes (a warm "paper" light theme to sit beside the teal dark one)
cost about twenty lines each and are the cheapest possible delight.

**The palettes are not contrast-checked against their own surfaces.** The dark
comment colour `#91A3AB` and the light `#5F6B72` were presumably picked by eye.
Neither is paired with a declared surface colour anywhere, so a host that
supplies a different `brightness` gets colours that may not clear 4.5:1.

**No current-line highlight, no indent guides, no margin ruler.** See §2. The
gutter already knows the caret's line; the text area does not use the
information.

---

## 6. Novel and delightful ideas

**A hygiene strip in the status bar.** Trailing-whitespace count, tabs-vs-spaces,
missing final newline, mixed line endings, lines over 100 columns. The
line-ending, byte-count and line-count metadata all already exists in the
document model. For an editor whose stated job is "config files and scripts",
quietly telling you that your YAML has mixed endings and three lines over 120
columns is more valuable than a minimap. It could be a single right-aligned
cluster in the existing status bar, with the offending count in a
`Tooltip`.

**A structure outline for declarative formats.** The tokenizer already
understands JSON, YAML, INI and dotenv well enough to find top-level keys. A
sidebar listing `docker-compose.yml`'s services, or a `.env`'s variable names,
with the caret's node highlighted, is a real differentiator for a config editor
and reuses `SyntaxToken` output with no new parsing.

**Watch mode for the file behind the buffer.** Poll the mtime and the digest
every few seconds for the active document. On a change, show a quiet
"changed on disk" affordance with Reload / Keep mine / Show differences. The
digest is already tracked and compared on save; this surfaces the same fact
before the collision instead of after it.

**Crash-recovery drafts, from files you already write.** Every save leaves
`.planchette-<uuid>.edit` and `.backup` siblings
(`text_document.dart:224-229`) and the hosts already sweep them. Nothing
surfaces them. A "Recovered" list at startup, offering the orphan `.edit`
files, turns an existing mechanism into a user-visible safety net.

**A command palette over the menu that already exists.** `Cmd+Shift+P`, fed by
the same `_Command` list the menus and the shortcuts are built from, plus "Go
to line". Roughly 60 lines, and it makes the command set discoverable without
adding a single new command.

**Zen mode.** One keystroke collapses the tab bar and the status bar. Cheap, and
it is the single most-requested thing in every text editor's issue tracker.

**Restore a middle-truncated tab label and make tabs reorderable.** Two small
changes that remove the most common complaints about the tab bar.

**Right-align the numbers, then dim them further.** The gutter already prints
`onSurfaceVariant`; making non-caret lines noticeably quieter than the caret's
is a one-colour change that reads as a much more finished product.

---

## 7. Code health

**The app shell has no strings abstraction.** `EditorStrings` exists for the
editor and both host apps use it. Every label in `planchette_app.dart`,
`document_dialogs.dart` and `desktop_window.dart` is an inline English
literal — including menu titles, the empty state, both error banners and all
tooltips. The shell is the least localizable surface in the repo, which is
backwards given the editor package's whole reason for existing.

**The dirty-close decision is implemented twice.** `EditorController.confirmClose`
(`editor_controller.dart:263`) is the shared, tested contract for "may this
discard happen". `DocumentWorkspace._confirmTab` (`document_workspace.dart:262`)
reimplements it with its own revision check. The app never calls the shared one,
so the shared one is only exercised by its own tests. Two implementations of
the same safety rule is exactly the shape that produces a future divergence bug.

**Dead or unreachable members, all in the shared public API:**

| Member | Status |
|---|---|
| `EditorController.reload()` | called from nowhere |
| `EditorSaveMode.local` | never passed by any caller |
| `EditorController.canPublish` | only read by a test |
| `DocumentWorkspace.openDialog`'s own guard | fine, but `open` also guards |
| `defaultTextDocumentMaximumBytes` | a redundant alias of `textDocumentMaximumBytes`, used nowhere |

`EditorController` is a host-facing API shared by three applications, so unused
members are not dead code in the usual sense — but they are untested-in-anger
and undocumented in `docs/STATUS.md`.

**`_saveTargets` is declared in the middle of `DocumentWorkspace`,** between
`_makeTab` (which reads it) and `select` (`document_workspace.dart:112`). Field
declarations belong together.

**`DocumentTab` leaks mutable state.** `baseline`, `path` and `busy` are public
mutable fields on a `final class`, and `editor` is `late final` assigned from
outside. Nothing enforces "a tab's path only changes after a successful save",
which the doc comment claims as an invariant.

**`OpenDocuments.start` filters argv by `startsWith('-')`.** On Windows a
legitimate path cannot start with `-` at the drive-letter position, so this is
safe, but a file literally named `-draft.txt` in the working directory would be
dropped. The comment does not note the limitation.

**Two competing window-size authorities** (see §4).

**The new icon is not wired into any build.** `media-sources/new-icon.png` is a
2,166,371-byte 1254×1254 PNG added by `e7ec67f` and used by nothing. The macOS
`app_icon_1024.png` is byte-identical to the *old* `media-sources/icon.png`
(40,468 bytes, same md5), the Windows `.ico` is unchanged, and
`media-sources/icon.svg` — the vector source of truth — was not updated either.
So: 2.1 MB of git for an orphan bitmap, and the shipped app still wears the
previous icon on all three platforms. `scripts/build.sh:53` still copies the
old `icon.png`.

**`docs/STATUS.md` verification claims are stale in one place.** It says the
shared editor's "19 controller/view tests" and the app's "40" — both still
accurate, verified above. The core's "84" is also accurate. No correction
needed; recording it because I checked.

---

## 8. What I intend to build, in order

Each on its own branch, each with a PR, each independently mergeable.

1. **Incremental document metrics** (`planchette_core`). A pure function that
   updates line starts and the byte total from a text edit using the common
   affix, replacing the two O(n) rescans. Tests for insertion at the head,
   middle and tail, deletion, paste, and an edit that adds and removes lines.
2. **O(1) dirty tracking** (`planchette_editor`). Replace the string compare
   with a saved-revision marker, and drop the permanent second copy of the
   buffer. Tests for the save/edit/redo interleavings that currently depend on
   the string comparison being correct.
3. **The gutter without a whole-document layout** (`planchette_editor`). A
   `wordWrap` option, default off, with exact `lineTops` from the line-height
   model; when wrap is on, coalesce the `TextPainter` pass off the keystroke
   frame. Tests asserting the gutter still lines up under both modes, and a
   test that pins the "one edit does not re-lay-out the document" property.
4. **Code-style input** (`planchette_editor`). A new input layer: Tab and
   Shift-Tab indent and dedent by a configurable width, Enter carries the
   current indentation, brackets and quotes auto-pair with type-over.
   Tab-width and auto-indent as injected settings so hosts choose their own
   defaults. Tests for each.
5. **Cheaper open and save** (`planchette_core`). Drop the redundant `before`
   digest, hash the in-memory bytes instead of re-reading the temporary, count
   line endings in one hand-written pass, normalize in a single pass with a
   fast path for the already-correct case, and accumulate into a `Uint8List`.
   Tests must keep proving every safety property in `document_safety_test.dart`
   — those are the valuable ones.
6. **Theme mode, settings, and a preferences dialog** (`planchette_app`). A
   `ThemeMode` the user can actually change, persisted; font size, tab width,
   word wrap, and the theme as real settings; a Preferences dialog. Wire the
   shared editor's `strings` through the shell at the same time so the app-level
   literals stop being hardcoded English.
7. **Shell chrome** (`planchette_app`). One combined strip instead of two bars,
   a stable dirty-dot slot, middle-elided and scroll-into-view tabs, the error
   banner as an overlay, and drag-and-drop file opening.

Deferred to `ANALYSIS.md` rather than built now: regex search, go-to-line,
outline, watch mode, recovery drafts, command palette, zen mode, current-line
highlight, icon pipeline.

---

## Appendix: things I checked that are fine

Recording these so nobody re-derives them.

- The no-replace rename via `renameat2` / `renamex_np` / `MoveFileExW`, the
  Android hard-link fallback with its `HardLinkCleanupException`, and the
  `errno`-before-call discipline. Correct, and tested for the partial paths.
- `localized canonicalSavePath` and the case-variant Save As story, including
  the directory-alias and dangling-link cases. Genuinely well covered.
- The quit/close decision graph: memoized `_quitDecision`, the revision
  re-check so a discard cannot authorize a later edit, saves held open during
  a pending decision, the `interactionLocked` completer that lets native
  opens queue behind a dialog. This is the most carefully reasoned code in the
  repo and I found no defect in it.
- The dotenv tokenizer's "quotes open only right after `=`" rule, which is the
  kind of detail that usually gets wrong.
- `_mergeMetaTokens`'s documented constraint about a grouped `metaPattern`'s
  group not occurring in its own prefix, and the null-group skip.
- `utf8EncodedLength`'s unpaired-surrogate rule matching what `utf8.encode`
  actually writes.
- `EditorController.save`'s post-commit callback ordering: `onSaved` runs even
  when the route was removed mid-write, and `_savedText` advances only for the
  revision actually written, so later edits stay dirty. Correct and tested.
- The IME-composition fallback to the default span.
- The line-number painter's binary search, its viewport-rows backoff, and the
  comment explaining why it exists.
