# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- File › Revert to Saved reads the file again, asking first when there
  are unsaved changes (Cancel is the default). It keeps the document on
  screen while it reads, keeps the edits if the read fails, and cannot be
  undone: Undo stops at the reverted text.
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
- Saving over a read-only file asks first: Save As… (the default), Save
  Anyway or Cancel. Save Anyway covers that file for the tab once the write
  succeeds, and on Windows the read-only attribute survives the save.
- Quitting with several unsaved documents asks one question that lists them
  (Don't Save, Cancel or Save All) instead of one dialog per document. Its
  Save All reports a partial failure the way File › Save All does.
- Diff and patch highlighting, plus Rust attributes and lifetimes, Go raw
  strings, JSON and YAML keys, C preprocessor lines and Python decorators.
- Tab and Shift+Tab indent and outdent the document instead of moving focus
  out of it, Enter keeps the line's indentation (one level more after an
  opening bracket), and Backspace in leading spaces removes a whole level.
  The level is learned from each file, and Makefiles and Go keep tabs.
  Hosts choose what Tab does (`PlanchetteEditor.tabKeyBehavior`), a level
  for one document (`EditorController.indentation`) or a fallback for files
  that have none yet (`EditorController.indentationPreference`).
- Line commands in the Edit menu: Duplicate Line (`Cmd/Ctrl+Shift+D`),
  Move Line Up/Down (`Option/Alt+↑/↓`), Delete Line (`Cmd/Ctrl+Shift+K`)
  and Join Lines (`Cmd/Ctrl+J`). They keep a CRLF line's break intact.
- Edit › Toggle Comment (`Cmd/Ctrl+/`) comments or uncomments the touched
  lines with the language's line-comment marker, keeping indentation; it is
  offered only for languages that have one.
- Find › Go to Matching Bracket (`Cmd/Ctrl+B`, with Shift to select) jumps
  to the partner of the bracket beside the caret, skipping brackets in
  strings and comments.
- Find › Go to Line (`Cmd+L` on macOS, `Ctrl+G` elsewhere, or a click on
  the caret position in the status bar) jumps to a line or `line:column`,
  and says what it takes when the input is not a number. The status bar
  also shows the selection's size and lines, the size the file has once
  saved, the indentation and the language.
- Past 200,000 characters, where syntax colours stop, the status bar says
  "Large file: no highlighting".
- View › Zoom In (`Cmd/Ctrl+=`), Zoom Out (`Cmd/Ctrl+-`) and Actual Size
  (`Cmd/Ctrl+0`) resize the text in every tab, from 9 to 48 points, and
  the size is remembered.
- Settings (`Cmd/Ctrl+,`; in the application menu on macOS, the File menu
  elsewhere) choose the theme (system, light or dark), the text size and
  the indentation for new documents, previewed live and put back by
  Cancel. They are saved per user and survive a damaged settings file.
- Find Next and Find Previous reach every match in a large file: past the
  1,000 matches the find bar highlights, they page on, and the counter
  numbers each match within the whole document.
- The find bar's Whole words toggle (`ab`) skips hits that run on into a
  word, in find, paging and Replace All. Letters of any script are part of
  a word; curly quotes, dashes, no-break spaces and emoji end one.
- Every find and replace control can be reached with Tab and tells screen
  readers whether it is on, and on a narrow window the bar puts its
  controls under the field.
- Planchette has its own looks: Parchment for light mode and Séance for
  dark, with syntax colors that keep 4.5:1 contrast on the page, the
  current line and the selection. Hosts can style the shared editor through
  `ThemeData.extensions`, since `EditorSyntaxTheme` is a `ThemeExtension`.
- A faint band marks the caret's line. It is on by default in the shared
  editor too; hosts can set `PlanchetteEditor.currentLineColor`, or pass
  `Colors.transparent` to turn it off.

### Changed
- One tab strip replaces the header and toolbar: tabs, a + button, and
  Open and Save at its trailing edge, with the menu bar and tabs starting
  at the window's leading edge. Tabs take keyboard focus and speak to
  screen readers, `Cmd/Ctrl+1` to `9` select them, a dirty tab shows a dot
  that turns into its close button under the pointer, a middle click
  closes a tab, and the active tab stays in view through resizing, text
  scaling and renames. Two tabs for files with the same name show their
  folders. A right click on a tab offers Close, Close Others, Close All
  Tabs and Copy Full Path.
- Untitled documents are named "Untitled", "Untitled 2" and so on, taking
  the lowest number no open tab shows, and opening a file from an
  untouched untitled tab replaces that tab.
- Loading and saving a large file takes about half the time and a third of
  the peak memory.
- Typing no longer rebuilds the whole window: the tabs, menus and window
  title update only when what they show changes.
- Save errors name their cause: an unwritable or deleted folder, or the
  operating system's error code when the original cannot be moved aside.
- A refused quit says what it is waiting for (a save, an open, a close or a
  dialog), and the notice clears itself once nothing blocks the quit.
- Opening several files reports every failure in one message; a single
  failure clears once that file opens.
- File › Close Tab follows the tab's close button: a loading or failed tab
  can close, a saving one cannot.
- The status bar says "1 line" and "1 byte".
- On Linux and Windows the window opens at its final size and position.
- The shared editor keeps a host's lock (`EditorController.setEditingLocked`)
  apart from a view's `editingLocked` parameter, so rebuilding a view no
  longer unlocks a document the host locked. A view lock clears only when
  the view rebuilds, so a host should lock through one of the two: the app
  now locks through the controller alone, which also fixes saves answered
  before the next frame after a dialog being refused.

### Fixed
- A file whose name nearly fills the 255-byte limit can be saved.
- Saving text that contains a NUL character is refused instead of writing a
  file the editor would then refuse to open.
- A Save As requested while a save is running writes to the chosen file,
  and saves for one document run in the order they were requested.
- Startup arguments naming files that begin with `-` open, while options
  such as `--help` and those macOS injects are no longer opened as files.
- CSS and Rust highlighting no longer stall on a long line with no closing
  token.
- A case-insensitive find whose fold erases the whole query finds nothing
  instead of matching at every position.
- The Linux package's metadata describes Planchette, and a failed
  `objdump` stops the build instead of passing silently.
- Line numbers stay on their lines when lines soft-wrap, at any document
  size, and typing no longer lays the whole document out a second time for
  the gutter. Find reveals a match on its real row in large wrapped files.
- On macOS, `Ctrl+F`, `Ctrl+H` and `Ctrl+G` keep their text-editing meaning
  instead of opening find, replace or Go to Line.
- Documents use a monospace font on macOS (Menlo) and Windows (Cascadia
  Mono, or Consolas where it is missing). The generic `monospace` name the
  editor used to request resolves only on Linux and Android, so the text
  fell back to the proportional system font. `PlanchetteEditor.textStyle`
  now merges over the platform's family (`editorMonospaceFor`), and a host
  passing the generic name gets that family too.
- Find Next and Find Previous work after the find bar is closed: they
  reopen it on the last query and move from the caret, leaving the cursor
  in the document.
- Undo stops at a load or reload: it can no longer bring back the text a
  document had before its file was read again, which then saved over the
  newer file without a conflict warning. `EditorController` exposes
  `installGeneration`, and the view gives each installed buffer its own
  document field.
- Opening a file that no longer exists says so, instead of showing
  `dart:io`'s `PathNotFoundException` with its errno.
- The window opens on the app's own background in the current light or
  dark mode, instead of the platform's default colour before the first
  frame and while resizing.
