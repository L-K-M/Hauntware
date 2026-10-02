# Text tools plan

Original proposal, 2026-09-30. Implementation status is below. Two questions: which
BBEdit text features belong in Planchette, and how to expose them without a
40-row menu or a palette nobody browses.

Sources: BBEdit 15.5.x and 16.0.3 manuals and the 15.5.x application's menu
tables; peer editors (CotEditor, Sublime Text, VS Code, Notepad++, Nova, Zed,
Kate, TextMate, Emacs, Vim, Boop, CyberChef); Apple, Windows and GNOME menu
guidance; this repository and both hosts at their current pins. Statements
marked *checked* (sort stability, case-mapping length, `^` and `$` at a lone
CR) were run as a throwaway probe on Flutter 3.47.2 / Dart 3.13.2; slice 1
turns them into tests. Ids such as B8 or E5 are entries in
[ANALYSIS.md](../ANALYSIS.md); this plan is E13 and A16 there.

## Implementation status, 2026-10-01

Slices 1 to 5b are merged (#108 to #112 and #114). Slice 6 adds file-format
choices, save cleanup and Normalize Line Endings. Slice 8 (Unicode/ASCII
and JSON) adds Compose Accents, Decompose Accents, Strip Diacritics,
Convert to ASCII, Format JSON and Minify JSON. The catalog now contains
48 menu tools, plus Extract Matches in Find: 49 catalog entries. The two
deferred menu tools are Hard Wrap and Convert Tabs to Spaces.

### Slice 6 contracts

- The app's status menus choose indentation, LF/CRLF and UTF-8 with/without
  BOM. File-format changes apply on the next save and make the document dirty,
  including empty untitled buffers. Choosing the saved format again clears
  that part of dirty state. Indentation settings neither rewrite nor dirty
  text; the status menu also offers explicit conversion commands.
- Save and Save As preserve the chosen format. Failed writes retain dirty
  state and the old conflict digest; reload restores the file's format.
  Format changes are blocked while loading, saving or locked.
- Trim trailing whitespace and ensure final newline are independent,
  persisted settings, both off by default. Cleanup changes the live buffer
  in one undo step before writing. A failed write keeps that visible edit;
  undo restores it. Empty files stay empty; existing final breaks stay.
- Normalize Line Endings ignores the selection and fixes CRLF/lone CR across
  the document. It uses LF for normalized buffers. Raw-preserving hosts must
  pass `normalization: TextNormalization.preserve` to the controller; the
  tool then uses the selected file ending. The host's loader and saver must
  use the same policy. The default remains normalized.
- Tool size preflight includes the selected EOL and BOM. Removing text can
  still run on a buffer that already exceeds the limit.

### Remaining work: slices 5c, 7 and 8

| Slice | Status and next step |
|---|---|
| 5c | Replacement backslash escapes declined by owner: replacements keep backslashes literal, only `$1`, `${1}`, `${name}` and `$$` expand. Active-match replacement preview built (worker-backed, bounded one line) |
| 7 | Built in Planchette: `openTextTools()` with a list state (Repeat and
Recent first, seven groups, keyword filter), verified at 320 px and doubled
text scale. Host adoption is one header icon per host at the same reviewed
revision, still to do. Poltergeist needs ARB keys or a recorded exception |
| 8: wrap and interior tabs | Deferred until B8 defines display columns and tab stops |
| 8: Unicode/ASCII | Built. `unorm_dart` in core (decision 4); Convert to ASCII uses a reviewed Latin table, keeps unmapped non-ASCII literal with a count |
| 8: JSON | Built. Whitespace-only strict-JSON reformat (decision 7), values verbatim, invalid input refused with line/column, size capped by the runner |
| 8: search | Built: regex hints (leading `(?i)`/`(?s)`/`(?m)` accepted, PCRE habits explained), inline grep cheat sheet with a BBEdit section, active-match replacement preview, Use Selection for Find, Find Selected Text, session-only search history. Find in Selection and Extract already shipped. Compare with Saved is main-owned work, unstarted |
| 8: Edit/File | Shipped: Select Line, Select Paragraph, Select Enclosing Brackets, Insert Line Above/Below, Paste and Match Indentation, Increment/Decrement Number, Copy/Cut Line, Toggle Comment block fallback and File-menu Copy Path. Go to Matching Bracket and tab-menu Copy Full Path already existed |
| 8: menu keyboard access | Alt mnemonics remain unbuilt; validate AltGr and desktop/input-method conflicts before assigning them |

No host pins were changed for slice 6. On a later pin bump the shared API
gains format/save options and normalization; clickable status menus and the
save-settings UI belong to the standalone app. Hosts still gain the shared
find-bar actions from slice 5. A pin bump alone does not expose the full
catalog. Broader E10 language selection and `.editorconfig` support (A1)
remain separate work.

## 1. Recommendation

1. **A generated Text menu.** One new top-level menu of 9 rows: Repeat,
   Recent and seven submenus. Every catalog tool is a menu item one level
   down, 10 or fewer per submenu.
2. **Variants are options, not items.** One Sort Lines with options, not
   Notepad++'s 14 sort items. The catalog is 48 tools: about half descend
   from BBEdit's Text menu, the rest come from peers.
3. **One inline tool bar for options**, in the find bar's slot: options
   prefilled with the last used, the scope, and a count of what will change.
   No modal dialogs.
4. **Repeat and Recent replace BBEdit's Option-key short forms.** "Repeat Sort
   Lines (Z to A)" reruns the last tool with its options. Recent lists the
   last five, options spelled out.
5. **The find bar is the parameter UI for pattern tools.** Keep and Delete
   Lines Matching and Extract Matches reuse its pattern field and highlights.
6. **The palette stays a locator.** It gains synonyms ("dedupe" finds Remove
   Duplicate Lines), a description, and the menu path, so a search teaches
   where the item lives.
7. **One catalog drives all of it**: a const list in `planchette_core`.

What this does not solve:

- The bulk is the same as BBEdit's; it sits one hover down. The gain is that
  no column is longer than 10 today, and never longer than 12.
- A user who never opens the Text menu learns nothing.
- Tools without options run with no preview, as in BBEdit. A menu click,
  Repeat or Recent with nothing selected can rewrite the whole document. The
  guards are the result notice and undo.
- What "nothing selected" means differs per tool (section 4); the menu does
  not show which.
- The tool bar shows counts, not which lines will change.
- Five of seven submenus exceed both Apple's guideline of about five items
  and GNOME's six. CotEditor ships the same shape.
- Group assignments are untested. The palette's menu path is the fallback
  for a wrong guess.

## 2. Exposure design

Six designs were drafted (menu, picker panel, palette-only, contextual,
recipe workbench, first principles) and scored by three agent reviews (HCI
evidence, engineering fit, platform conventions). All three put the same two
first: menu and first principles, which share a skeleton and are merged
here.

| Design | Verdict |
|---|---|
| Two-level generated Text menu plus inline tool bar (menu, first principles) | Chosen. The only shape where an unaware user, a BBEdit veteran and a daily user all succeed on the primary surface |
| Picker panel with live preview (Boop, Filter Gallery) | Best preview and host reach. Rejected: all but a few pinned tools leave the menu bar; a docked side panel re-wraps the whole document on open |
| Palette only, improved | Best wrong-word search. Rejected: no tool is a menu item; a modal overlay for one-second tasks |
| Contextual (status segments, notices, context menu) | Rejected as a whole: about 20 tools have a trigger, and proactive notices are unproven. Two parts kept: status segments for indentation and line endings, find bar for pattern tools |
| Recipe workbench (Text Factories, CyberChef) | Rejected: days of work for chaining nobody asked for |

Evidence, with its limits:

- Experiments favour breadth over depth. The best measured layout is one
  grouped level (Snowberry 1983), close to BBEdit's shape; among hierarchies,
  two levels of about 8 by 8 did best (Miller 1981, read through a survey).
  Seven groups of up to 10 is in that range.
- Apple and Windows both say a submenu hides its items. That is the price
  of the shorter column.
- Stable positions matter (CommandMaps 2012). System-adaptive hiding failed
  in Office 2000.
- Apple says to keep every command in the menu bar; Windows says never
  context-menu-only. Both say disable, do not remove.
- Grossman 2009 separates awareness of a function from locating it. A typed
  palette serves locating; that it fails awareness is an argument from
  recognition over recall, not a measured result.

### Layers

```
planchette_core      tool catalog (const): id, group, scope, options, run()
        |            run() is pure: text, selection, options, and a context
        |            (case folder, indentation, clock, random)
planchette_editor    runTextTool(): gate, size check, one assignment, outcome
  (reaches hosts)    tool bar: options, scope, dry-run count
        |            find bar: Keep / Delete Lines Matching, Extract Matches
        |            result notice; TextToolHistory (last options, recents)
app                  Text menu (generated) on both menu bars
                     palette rows: keywords, description, menu path
                     Repeat and Recent rows; saves the history
```

### Text menu

```
File  Edit  Text  Find  View  Window
            Repeat Sort Lines (Z to A)      Shift+Cmd/Ctrl+R
            Recent                        >
            -----------------------------
            Lines                         > --+  Sort Lines…
            Case                          >   |  Reverse Lines
            Whitespace                    >   |  Shuffle Lines
            Clean Up                      >   |  ------------------------
            Wrap                          >   |  Remove Duplicate Lines…
            Encode                        >   |  Remove Blank Lines
            Insert                        >   |  Collapse Blank Lines
                                              |  ------------------------
                                              |  Keep Lines Matching…
                                              |  Delete Lines Matching…
                                              |  ------------------------
                                              |  Prefix/Suffix Lines…
                                              +  Number Lines…
```

| Submenu | Items (`*` = deferred, section 6) |
|---|---|
| Lines (10) | Sort Lines… · Reverse Lines · Shuffle Lines · Remove Duplicate Lines… · Remove Blank Lines · Collapse Blank Lines · Keep Lines Matching… · Delete Lines Matching… · Prefix/Suffix Lines… · Number Lines… |
| Case (9) | UPPERCASE · lowercase · Title Case · Sentence case · camelCase · PascalCase · snake_case · kebab-case · CONSTANT_CASE |
| Whitespace (7) | Trim Trailing Whitespace · Trim Leading Whitespace · Normalize Spaces · Convert Indentation to Spaces · Convert Indentation to Tabs · Convert Tabs to Spaces…`*` · Normalize Line Endings |
| Clean Up (7) | Zap Gremlins… · Straighten Quotes · Remove ANSI Escape Codes · Convert to ASCII`*` · Strip Diacritics`*` · Compose Accents`*` · Decompose Accents`*` |
| Wrap (3) | Hard Wrap…`*` · Unwrap Paragraphs · Join Lines With… |
| Encode (8) | URL Encode · URL Decode · Base64 Encode · Base64 Decode · Encode HTML Entities · Decode HTML Entities · Escape as JSON String · Unescape Backslash Sequences |
| Insert (4) | Date · Date and Time · UTC Timestamp · UUID |

Rules:

- From slice 2 on, items never move and are never hidden. A tool not yet
  built is absent.
- Tools follow the existing line commands' gate (document ready and in use,
  `canEditText`). A tool that needs a selection stays enabled and reports
  "not applied, nothing selected": the shell does not receive selection
  changes. The find-bar items use Find's gate.
- A new behaviour of an existing tool is an option. A new item needs a new
  noun, or a direction users search by name (Encode and Decode, Keep and
  Delete).
- A submenu that would pass 12 items splits; none has more than 10 today.
  Depth stays 2.
- Case items are written in their own result, so the menu is the preview.
- "…" opens the tool bar. The two pattern items in Lines open the find bar.
- Existing line commands (Duplicate, Move, Delete, Join, Toggle Comment) stay
  in Edit with their chords.
- Alt mnemonics on the in-window menu bar (Windows, Linux) are a late small
  slice, after an AltGr check.
- The Repeat chord is provisional: free in this repository and in Flutter's
  defaults, unchecked against desktop environments and input methods.
- No per-tool shortcuts, no hide-item preference and no pins until the
  shortcut table (A6) exists and the catalog passes about 70 tools.

### Tool bar

Same slot as the find bar, below the host banner. Opening it closes find and
Go to Line. The document stays visible.

```
+------------------------------------------------------------------------------+
| Sort Lines   Order [A to Z v]  [x] Ignore case  [ ] Numbers by value [Close] |
| Applies to   (o) 12 selected lines   ( ) Whole document, 310 lines  [ Sort ] |
| 9 of 12 lines will move                                                      |
+------------------------------------------------------------------------------+
```

- Four option kinds: toggle, choice, text, integer. A tool that does not fit
  is not built. The mock shows three of Sort's six options.
- The count comes from the function that performs the edit. It reruns when
  an option changes or the selection settles. Above a size threshold it is
  computed on Apply and reported in the notice.
- With nothing selected the scope line says so: "Nothing selected: whole
  document, 310 lines".
- Options wrap; below 600 px the bar stacks like the find bar.
- Focus (D4): opens from the document into the first option. Enter applies,
  closes, returns focus to the document. Escape closes, returns focus to the
  document and leaves the selection as it is. Clicking the document keeps the
  bar open and updates the scope line. If editing becomes locked, Apply
  disables and says why.
- Its text fields join `controller.textFocusNodes`, so Cut, Copy and Paste
  routing and the app's document-in-use gate see them.

### Result notice

One line over the bottom edge of the document after every run, announced to
screen readers, never focused, gone on the next edit. It is an overlay with
its own safe-area inset, so the viewport height does not change.

```
Remove Duplicate Lines: removed 25 of 310 lines in the whole document.   Undo
Sort Lines: nothing to change, 12 selected lines already in order.
Base64 Decode: not applied, the result is binary, not text.
```

It is the only message surface hosts need.

### Repeat and Recent

- `Repeat <tool> (<options>)`: reruns the last tool on the current selection,
  or on the tool's no-selection scope; pattern tools use the find bar's
  scope. The row never moves.
- `Recent`: last five tool-and-options pairs. Choosing one runs it, no bar.
- Opening a "…" tool and pressing Enter is the third short path.
- `planchette_editor` exports a `TextToolHistory`. A host may create one and
  pass it to every controller; without one a controller keeps its own.
  `runTextTool` records into it, so runs from the tool bar and the find bar
  count. The app listens to it for the Repeat label and saves it.
- Saved: toggle, choice and integer options. Text options and patterns are
  kept for the session only, like search history: they can hold secrets. An
  entry with a non-default text option is not saved.

### Find bar additions

A Lines control in the find bar opens a line-action row. `Text > Lines > Keep
Lines Matching…` and `Find > Extract Matches…` open the find bar with that row
showing. Pattern, toggles, highlights and error line are the existing ones.

```
| Find [ ^ERROR\b                 ] [Aa] [W] [.*] [Lines]   38 lines match    |
| Lines  [ Keep 38 ]  [ Delete 38 ]        Matches  [ Extract… ]              |
```

- Scope: the Find in Selection range if one is set (E5), else the whole
  document. Never the live selection, which is the active match.
- The line count is a debounced counting request, run only while the row is
  open.
- Extract: every match, one per line, optionally through the replacement
  template; option for whole lines. Destinations: in place or clipboard; new
  document in the app.
- Needs two new worker requests: line filter and extract.
- Focus stays in the pattern field; Escape closes the bar as today.

### Palette

```
| Remove Duplicate Lines…                           Text > Lines   |
|   Deletes repeated lines, keeping the first.   matches "dedupe"  |
```

Keywords are matched and the reason is shown. Disabled commands are listed
greyed; today they are omitted. Commands get stable ids: today the palette
identifies a command by menu label and item label, which breaks on "Repeat
Sort Lines".

### Status bar segments

Line ending, BOM and the indentation setting are document properties, not
transforms. They become clickable status segments in the app (E10, V5), as
in VS Code. This needs a metadata setter on the controller and a dirty state
that compares line ending and BOM with their values at load or last save;
today dirty compares text only. The indentation setting is not written to
the file and does not make a document dirty.

### Hosts

Séance and Poltergeist expose no line command in any menu today. On a phone
without a hardware keyboard none is reachable.

What a pin bump shows in the hosts:

| Slice | Visible in hosts |
|---|---|
| 1 to 4 | Nothing. New API and `EditorStrings` members only |
| 5 | The find bar's Lines control, action row and preview line; changed replacement escapes |
| 6 | Nothing: Poltergeist hides the shared status bar, Séance draws its own |
| 7 | Nothing until each host adds one header icon; then the tool list and tool bar |

Slice 7 gives the tool bar a list state (Repeat and Recent first, then the
seven groups with descriptions and a keyword filter) opened by
`controller.openTextTools()`. On narrow widths it is a scrolling surface in
the find bar's slot, verified at 320 px and doubled text scale. Without
slice 7 the hosts gain the find-bar actions and nothing else.

Strings come from a few `EditorStrings` lookups keyed by id: names,
descriptions, keywords, option labels, count and notice text. Poltergeist
then overrides a handful of methods, not one per string. Its rule that every
string lives in ARB still costs a key per visible string, or a recorded
exception.

## 3. BBEdit's Text menu, item by item

Port = same behaviour. Adapt = changed. Exists = shipped. Defer = blocked.
Skip = not planned.

| BBEdit | Verdict | Planchette |
|---|---|---|
| Apply Text Filter, Run Unix Command | Skip | Subprocesses. Core must not spawn them, and both hosts also ship on Android |
| Apply Text Transform… | Skip | Multi-file batch |
| Exchange Characters / Words | Skip | Flutter binds Ctrl+T transpose on macOS already; words are too rare |
| Change Case… and submenu | Adapt | Case submenu, no sheet. Title Case capitalizes every word (BBEdit's Capitalize Words; its English title rules are dropped). Sentence case is Capitalize Sentences. Adds identifier cases. Drops Capitalize Lines and Alternate Case |
| Shift Left / Right | Exists | Tab and Shift+Tab. The one-space variants are skipped |
| Un/Comment Lines | Exists | Toggle Comment |
| Un/Comment Block | Defer | E1: Toggle Comment should fall back to block markers in XML and CSS. Today it is disabled there |
| Hard Wrap… | Defer | Width and paragraph fill only. Needs a column rule (B8) |
| Add Line Breaks | Skip | Depends on the rendered wrap width |
| Remove Line Breaks | Adapt | Unwrap Paragraphs |
| Educate Quotes | Skip | Breaks code and config |
| Straighten Quotes | Port | |
| Reformat Document / Selection | Defer | Format JSON and Minify JSON only (decision 7) |
| Add/Remove Line Numbers… | Adapt | Number Lines… |
| Prefix/Suffix Lines… | Adapt | Adds "skip blank lines", on by default |
| Sort Lines… | Adapt | Code-point order, not Unicode collation. Randomize becomes Shuffle Lines. No output destinations. Pattern sort key becomes a field key, later |
| Process Duplicate Lines… | Adapt | Remove Duplicate Lines…; no pattern key, no destinations |
| Process Lines Containing… | Adapt | Keep / Delete Lines Matching… in the find bar. Copying lines out is Extract with whole lines |
| Remove Blank Lines | Port | Plus Collapse Blank Lines |
| Canonize…, Text Merge… | Skip | Need a parameter file; rare |
| Increase / Decrease Quote Level, Strip Quotes | Skip | Prefix/Suffix Lines with `>` adds or removes one level on selected lines. No strip-all |
| Zap Gremlins… | Adapt | Classes redefined for UTF-8 (section 4) |
| Convert Escape Sequences… | Adapt | Split by family: Unescape Backslash Sequences, URL Decode, Decode HTML Entities. Adds the encoders BBEdit lacks |
| Convert Tabs to Spaces… | Adapt | Convert Indentation to Spaces (leading whitespace) first; all tabs after B8 |
| Convert Spaces to Tabs… | Adapt | Convert Indentation to Tabs. Interior runs: skipped, it corrupts strings and aligned data |
| Strip Trailing Whitespace | Port | Trim Trailing Whitespace; the same function serves E9's on-save setting |
| Normalize Line Endings | Adapt | Fixes stray CR and CRLF in the buffer. LF or CRLF for the file is a status segment |
| Normalize Spaces | Port | |
| Precompose / Decompose Unicode, Strip Diacriticals | Defer | Dart has no normalization API; decision 4 |

Not on BBEdit's Text menu, added from peers: Reverse Lines (seven editors),
identifier case (Sublime, VS Code, Zed), URL and Base64 encoding, HTML entity
and JSON string encoding, Collapse Blank Lines, Trim Leading Whitespace, Join
Lines With (Kate), Remove ANSI Escape Codes (CyberChef only). CONSTANT_CASE
is Planchette's own.

## 4. Tool notes

"No selection" column: D = whole document, P = paragraph at the caret,
W = word at the caret, S = selection required, I = insert at the caret.

| Tool | No selection | Options and rules |
|---|---|---|
| Sort Lines… | D | Order (A to Z), ignore case (on). Off by default: numbers by value, by length, ignore leading whitespace, leave the first line of the range in place (header row). Code-point order with an index tiebreak: `List.sort` is not stable (*checked*). Ignore case uses the controller's case folder, as find does |
| Reverse, Shuffle Lines | D | Shuffle takes an injected random source |
| Remove Duplicate Lines… | D | Keeps the first. Options: adjacent only, ignore case, ignore surrounding whitespace, keep blank lines (default on), remove every copy |
| Remove / Collapse Blank Lines | D | Blank is empty or spaces and tabs only |
| Keep / Delete Lines Matching… | D, ignores the live selection | Literal or regex from the find bar. Each line tested alone, so a pattern that contains a line break matches nothing. The Find in Selection range narrows it once slice 5b lands |
| Prefix/Suffix Lines… | D | Insert or remove; prefix; suffix; skip blank lines (default on) |
| Number Lines… | D | Add or remove; start; step; separator; pad with spaces or zeros |
| Join Lines With… | S | Separator (default `, `); trim; skip blank lines |
| Unwrap Paragraphs | P | Joins each run of non-blank lines; blank lines stay |
| Hard Wrap… | P | Width, fill. Repeats quote and comment prefixes; leaves lists alone |
| Case (all) | W | Dart case mapping never changes UTF-16 length: 0 of 1,112,064 code points in either direction (*checked*). ß stays ß; no Turkish i. UTF-8 size can grow, so the size rule applies |
| Trim Trailing / Leading | D | Spaces and tabs only |
| Normalize Spaces | D | No-break and other Unicode spaces become U+0020 |
| Convert Indentation | D | Leading whitespace only, so no column model is needed. Width: the document's; for a tab-indented file, the preference width. Then sets the document's indentation setting to match; undo does not restore it. To Spaces is refused where the format requires tabs (Makefile, Go) |
| Normalize Line Endings | D, ignores the selection | CRLF and lone CR become the buffer's line ending. Needs the controller to know the normalization mode (Séance loads line breaks as they are); lone CR per B35 |
| Zap Gremlins… | D | Classes: control characters (C0 except tab, LF, CR; DEL; C1); zero-width and invisible (U+200B, U+2060, U+FEFF, U+00AD); bidirectional controls (U+202A to U+202E, U+2066 to U+2069); damaged (the replacement character U+FFFD, lone surrogates); all non-ASCII. Defaults: the first three, deleted. U+200C and U+200D are kept: emoji and several scripts need them. Other actions: replace with `\u{…}`, with a character, with an HTML entity. A pasted NUL blocks saving today |
| Straighten Quotes | D | Curly single and double quotes only |
| Remove ANSI Escape Codes | D | CSI, OSC and escape sequences with a real ESC |
| Convert to ASCII | D | Quotes, dashes, ellipsis, ligatures, accented Latin to look-alikes; reports what has no equivalent. Shares a Latin table with Strip Diacritics |
| Encoders and decoders | S | Decoders leave what they cannot decode and never emit NUL. Base64 Decode refuses binary output |
| Insert Date, UUID | I | ISO forms only; Dart has no locale formats without `intl`. UUID v4 (`uuid` is already a dependency). Clock injected |

Shared rules:

- **One edit type.** Every tool returns an outcome: changed (the existing
  `LineEdit` plus a count), unchanged, or refused (a reason). A skipped
  operation is never reported as done.
- **Line tools** widen a selection to the lines it touches; a selection
  ending at column 0 does not touch that line.
- **Line breaks.** Tools that reorder move line contents and leave separators
  in their slots. Tools that remove lines drop the line's separator and keep
  whether the range ended with a break. `\r\n` is one separator.
- **Selection afterwards.** A run on a selection reselects the result,
  direction kept. A run on the whole document keeps a caret.
- **Size.** Refused when the saved size would exceed core's 4 MiB limit and
  the result is larger than the input. The limit is a new optional controller
  parameter. The check lives in `runTextTool`, not in `_applyLineEdit`, which
  also serves Enter and Tab. It is P5's preflight and a new policy: typing
  and paste are uncapped today.
- **Regex.** User patterns run only in the pattern worker. The result is
  applied only if the buffer still equals the text the worker was given: the
  check regex Replace All uses. In Dart, `^` and `$` also match at a lone CR
  (*checked*), so line tools test each line's content on its own.
- **Isolate.** Other tools run on the UI isolate, as every edit does. Large
  files would need P4's isolate approach extended to transforms; not planned.
- **Undo.** One assignment is one undo entry, but Flutter pushes history
  through a 500 ms throttle (`undo_history.dart`) and exposes no way to flush
  it: a change within 500 ms of another shares its undo step. `runTextTool`
  therefore waits until the last change is 500 ms old before its assignment;
  a change during the wait restarts it. Undo then reverts the tool and keeps
  the typing before it. The cost is up to 500 ms of delay for a tool run
  right after typing. Typing within 500 ms after a tool still merges with
  it. Slice 1 pins both with tests.

## 5. Beyond the Text menu

### Grep

Shipped: live find bar, case, whole word, regex in a worker with a time
budget, paging past 1,000 highlights, Replace, Replace All, `$1`, `${name}`.

| Gap | Plan |
|---|---|
| Find in Selection, Replace All in Selection | Build (E5). A stored range, shown tinted, that survives stepping through matches |
| Replacement `\U \L \E \u \l`, `\n`, `\t`, `\1`, `\0` | Declined by owner: backslashes stay literal, only `$1`, `${1}`, `${name}` and `$$` expand. `&` and `\P<name>` stay literal |
| Extract | Extract Matches… (section 2) |
| Pattern Playground | Built: one preview line in the find bar (active match, arrow, expanded replacement, capture groups, truncated). Regex runs in the worker with stale-result and time-budget guards. No window |
| PCRE habits | Built: BBEdit is PCRE; Dart is ECMAScript. Hints on the error line for `(?P<n>…)`, `(?>…)`, possessive quantifiers, POSIX classes, `\A`, `\z`, `\Z`, `\x{NNNN}`, `(?x)`, and `\r` as "line break"; a leading `(?s)`, `(?i)`, `(?m)` is accepted and stripped |
| Grep cheat sheet | Built: inline sheet in the find bar (regex mode) describing Dart syntax, with a "coming from BBEdit" section |
| `^` or `$` alone | Empty matches are skipped today, so "replace `^` with `> `" does nothing. Point to Prefix/Suffix Lines; allowing empty matches would split CRLF pairs |
| Use Selection for Find (Cmd+E on macOS; Ctrl+Shift+E elsewhere avoids the Emacs/GNOME Ctrl+E line-end conflict), Find Selected Text | Built on the existing matching and focus flow |
| Search history | Built (V4): session-only, bounded, never written to disk; Up recalls older, Down newer |
| Saved grep patterns | Later; app only |
| Replace to End | Skip: select to the end, then Replace All in Selection |
| Find All results list | Later. Needs a list surface |
| Find & Select All | Blocked on multiple selections (B7) |
| Multi-file search, file filters | A15 |
| Find Differences | Later: Compare with Saved as a unified diff in a new tab, on the existing Diff highlighter, off the UI isolate. No merge window |

### Edit and File menus

Caret and file commands, not catalog tools. Shipped (slice 8):

- Select Line, Select Paragraph, Select Enclosing Brackets (BBEdit's
  Balance). Selection only: no edit, allowed when locked.
- Insert Line Above / Below (BBEdit's New Line Before / After Paragraph).
- Paste and Match Indentation. An explicit command, so default paste is
  untouched (Q14). Needs an async clipboard read with a stale-text check.
- Increment / Decrement Number.
- Copy Line, Cut Line.
- Toggle Comment's block fallback (E1).
- Copy Path, added to the File menu (FU5); the tab context menu keeps
  its Copy Full Path, and both share one copy routine.

### Later

Inspect Character (code point, bytes, escapes of the character at the
caret), Highlight Occurrences of the selection (Q4), Align on a separator
(B8), Delete or Keep a delimited field with Sort by field.

### Not planned

| Feature | Reason |
|---|---|
| Text Factories, Text Filters, scripts, AppleScript, Automator, worksheets, CLI tools | Subprocesses or multi-file batch. Every tool is a pure function, so chaining stays possible |
| AI worksheets, Writing Tools | No-network rule |
| Six clipboards, Paste Previous, append, Paste Using Filter | Needs a clipboard model over an async plain-text clipboard; OS clipboard managers do it |
| Copy as Styled Text / HTML | Needs a native clipboard plugin. Export as HTML exists |
| Rectangular selection, Select Columns | No multi-caret model (B7) |
| Paste Column, Rearrange Columns | Rare; spreadsheet work |
| Folding, markers, clippings, cheat-sheet palettes, completion, spelling, speech | Each needs a model or storage Planchette lacks |
| Markup menu, Tidy, preview | Web authoring |
| Insert File Contents, paths, folder listing; Hex Dump; Scratchpad | File-system or window features, not text tools |
| Swap Case, Surround Selection, Markdown emphasis, ROT13, Lorem Ipsum, hashes, hex codecs, Use Selection for Replace | Too rare for a row in three apps |
| Ensure Final Newline as a command | On-save setting only (E9) |
| Menus & Shortcuts preference | After A6's shortcut table, if the menu proves too long |

## 6. Build order

Sizes: S under an hour, M half a day, L days. Slices 1 to 7 change the
shared packages; each PR lists what hosts will see on the next pin bump.

| # | Slice | Size | Delivers |
|---|---|---|---|
| 1 | Core line and range helpers, catalog entries, outcome type, `runTextTool`, result notice, flat Text menu with 10 tools run at defaults: Sort Lines, Remove Duplicate Lines, Remove Blank Lines, Trim Trailing Whitespace, Convert Indentation to Spaces and to Tabs, UPPERCASE, lowercase, Straighten Quotes, Zap Gremlins | L | Four of the owner's six named tools (sort, trim, tabs and spaces, gremlins), in the menu and the palette. Pins the undo throttle |
| 2 | Submenu entry type, command ids, generated menu. Five places walk the menu: `_nativeItems`, `_menuBar`, the shortcut map, `_openPalette`, `_runCurrent`. Palette keywords, descriptions, path, greyed rows | M to L | The menu structure |
| 3 | Tool bar, option declarations, `TextToolHistory`, Repeat, Recent. Options for Sort, Remove Duplicates, Zap Gremlins; Prefix/Suffix Lines, Number Lines, Join Lines With | L | Prefix/Suffix. Parameters and the short form. Option tools gain their "…" |
| 4 | Remaining tools without options, in batches: Reverse, Shuffle, Collapse Blank Lines, Trim Leading, Normalize Spaces; case family; four codec pairs (URL, Base64, HTML entities, string escapes); Remove ANSI; Insert; Unwrap Paragraphs | M each batch | 26 more tools |
| 5a | Find bar line actions, Extract Matches, two worker requests | M to L | Keep and Delete Lines Matching, Extract |
| 5b | Find in Selection (E5) | L | Scope for find, replace and 5a |
| 5c | Replacement escapes, preview line | M | If decision 5 is yes |
| 6 | Metadata setter and dirty state; status segments for indentation, line ending, BOM (E10, V5); trim and final newline on save (E9); Normalize Line Endings | L | Document properties. 42 of 48 tools built |
| 7 | Tool list state, `openTextTools()`; then a pin bump and one icon in each host | L, three PRs | Built in Planchette (decision 2: yes, both hosts including phones); host icons pending |
| 8 | Not scheduled: Hard Wrap and Convert Tabs to Spaces (B8); Convert to ASCII (needs a Latin table); Strip Diacritics, Compose and Decompose Accents (decision 4); Format and Minify JSON (decision 7); regex hints and cheat sheet; Use Selection for Find; search history; Edit and File menu commands; Alt mnemonics; Compare with Saved | | |

Slices 1 and 2 need no bar; the only new surface is the result notice.
Slice 1 depends on decision 1, slice 2 on decisions 3 and 6. Until answered,
build to the recommended option.

## 7. Decisions for the owner

1. **Scope with nothing selected.** Recommended: per tool (section 4), so
   UPPERCASE changes one word and Sort Lines sorts the document. Alternatives:
   BBEdit's default, the whole document for nearly everything; or do nothing
   and say so.
2. **Hosts.** Should Séance and Poltergeist, including phones, get text
   tools? If not, drop slice 7; they still gain the find-bar actions. If so,
   Poltergeist needs ARB keys or an exception for the shared strings.
3. **Submenu size.** Seven submenus of up to 10 (recommended), or more and
   smaller ones to meet Apple's guideline of about five.
4. **Unicode dependency.** `unorm_dart` (MIT, no dependencies, 175 KB of
   tables) as a fourth core dependency, inherited by both hosts, enables
   Compose and Decompose Accents and a correct Strip Diacritics. Without it
   they stay out.
5. **Replacement escapes.** Declined by the owner: backslashes stay
   literal in replacements, and making backslash special would change
   existing templates that contain a literal `\n` or `\U`, in the hosts
   too. Only `$1`, `${1}`, `${name}` and `$$` expand.
6. **Edit menu.** Leave the five line commands in Edit (recommended), or move
   them under Text. Lines would reach 15 items and split, and the shell's
   skip-the-Edit-menu shortcut rule would become a per-command flag.
7. **Format JSON, Minify JSON.** The triage rated them high value; all three
   design reviews cut them as scope creep. If in: whitespace-only reformat of
   strict JSON, output capped, invalid input refused with line and column.
