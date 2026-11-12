# Changelog

All notable changes to Planchette are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Settings and window state files use the shared atomic writer and
  write through symbolic links.

### Added
- The workspace server list offers Keep this device's key and Trust the new
  key when another device synced a different host key, so the conflict can be
  resolved instead of only warned about.
- Settings › About shows the running build's version, and the open-source
  licenses page repeats it under the app name.
- `ghost_keepalive` package: the Android background keep-alive (a
  dataSync foreground service and its `ghost_keepalive` channel) shared
  by Séance and Poltergeist, moved out of Séance's app-private
  implementation. The apps pass the notification channel id and every
  user-facing string.
- Hide or show the folder sidebar from View, its toolbar buttons or
  `Ctrl+Alt+S` (`Control+Command+S` on macOS). Hiding keeps the workspace
  connected. Its visibility and width survive a restart, and the divider
  supports keyboard resizing.
- Settings › Text › Font opens a searchable catalog of 23 bundled fonts.
  Preview code, ambiguous glyphs, bold and italics before applying a
  choice. Ligatures default to on and can be turned off in the picker.
- Settings › Text › Font picks the document's font from the fonts that
  ship with Planchette, each shown in its own face, and Ligatures turns
  joined symbols such as `->` and `!=` off. A font named in a
  hand-edited settings file stays selected.
- Mistakes in common config files are underlined as you type: JSON that
  doesn't parse, a key set twice in a `.env`, JSON, YAML or TOML file,
  broken XML tags, and leftover merge-conflict markers. The status bar
  counts them and describes the one on the caret's line. F8 and
  Shift+F8, or Find › Next Problem and Previous Problem, move between
  them.

### Changed
- The Linux package build uses the suite's shared packager and fails early
  with a clear message when `objdump` is missing, instead of partway through.
  The built `.deb` and AppImage are unchanged.
- Closing an unsaved document, and the quit question that covers several,
  use the shared Ghost close dialog: Save, Don't save or Cancel, with Save
  as the default. The discard button reads "Don't save", as in Séance and
  Poltergeist.


### Fixed
- A stored key passphrase that does not open the key is asked for again,
  with a prompt that says the first one failed, instead of failing the
  connection with the same passphrase.
- Opening a remote server workspace verifies its host key before asking for
  credentials, so the first-use trust prompt comes first. Pinned keys and
  jump-host routes keep their existing order.
- Windows bounds the wait when handing a file to the running app and
  requires its acknowledgement. Failed or blocked delivery shows a retryable
  error instead of claiming the request succeeded.
- Host-key fingerprints and key paths in the server prompts draw in the
  bundled code font on macOS and Windows, as in Séance and Poltergeist.
  They were in the proportional system font there.
- A damaged settings file is kept beside it as
  `settings.json.corrupt-<time>`, and a notice says where, instead of
  being replaced by the next save. One Planchette cannot read at all
  stays where it is, with a notice. Planchette still opens with its
  default settings, as the other apps do.
- Overlapping changes to the sync state, such as two trusted-key verdicts
  or notices at once, no longer drop one another, and two first reads of
  the device id agree on one id.
- The document and the font picker draw one scrollbar on macOS, Windows
  and Linux; they drew two side by side.
- The folder sidebar takes Home, End, Page Up and Page Down, and
  Command+Up (Alt+Up or Backspace elsewhere) opens the parent folder.
  Up with nothing selected starts at the last item, and a move scrolls
  the item into view.
- Sign In and Open wait for valid fields; Return submits the forms.
- The grep cheat sheet in the find bar shows its patterns in the
  document's font. On macOS and Windows they were in the proportional
  system font.
- Selected text stands out in the dark look. Its indigo highlight was
  barely lighter than the page; it is now lighter and bluer, and comments
  are a little lighter so they stay readable on it.
- Password, passphrase and pasted-key fields in the server prompts and
  the workspace server forms turn off autocorrect, suggestions and
  keyboard learning, so your keyboard does not learn or offer your
  secrets.
- A key passphrase you type to open a remote workspace is no longer kept
  in memory for as long as the connection stays open.
- On Windows, the app's file properties name the Unlicense, and a font
  installed or removed while a window closes no longer crashes
  Planchette.
- The server sign-in prompt says the password is used for this workspace
  session and never saved. It said this connection only, although
  reconnects in the same session use it again.
- Folder paths in the folder browser's header and the Open Folder on
  server field draw in the bundled code font, as Séance's path bar does.
- On Linux and Windows, Planchette runs once. Opening a file while it
  runs hands the file to the running Planchette, and launching it again
  raises its window, instead of starting a second copy that writes the
  same settings and window state.

### Security
- Files Planchette writes from a remote workspace, including remote
  checkouts, a Save-a-Local-Copy of a remote document and an HTML export
  of one, now carry a Windows Mark-of-the-Web stream or a macOS
  quarantine attribute, as Séance's downloads do. Marking is best effort
  and only logged on failure.

## [1.9.0] - 2026-10-04

### Added
- A command palette (`Cmd/Ctrl+Shift+P`) finds any available menu command
  by a few letters of its name or its menu's.
- File › Export as HTML… writes the document, unsaved edits included, as a
  page in the colours the editor shows, and never over an open document.
- File › Reopen Closed Tab (`Cmd/Ctrl+Shift+T`) opens the last closed file
  again from disk, up to twenty back, with the caret where it was.
- File › Revert to Saved reads the file again, asking first when there
  are unsaved changes (Cancel is the default). It keeps the document on
  screen, locked, while it reads, keeps the edits if the read fails, keeps
  the caret and scroll position, and cannot be undone: Undo stops at the
  reverted text.
- Files changed by other programs are noticed when the window comes back
  to the front. A document without edits takes the new version in place,
  keeping the caret and scroll position. A document with edits shows a
  notice to Reload (drop the edits) or Keep Mine (the next save replaces
  that version, and a later outside change is still caught). A deleted or
  moved file shows a notice, and Save creates it again. A save that fails
  because the file changed shows the notice instead of an error, and a
  file that cannot be read is reported once rather than on every focus.
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
- File Save All (`Cmd+Opt+S` on macOS; menu-only on Windows and Linux, where
  Ctrl+Alt is AltGr on many layouts) writes every dirty document in one action
  and reports partial failures as a single message naming what was written
  and what was not.
- Repo scaffolding: Dart pub workspace, `packages/planchette_core` package
  skeleton, CI/release/review workflows, build/release/package scripts, and
  the agent operating manual.
- Saving over a read-only file asks first, a Save As onto one included: Save
  As… (the default), Save Anyway or Cancel. Save Anyway covers that file for
  the tab once the write succeeds, and the file stays read-only. Declining is
  not reported as a failed save.
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
- The find bar's Regular expression toggle (`.*`) searches with a
  pattern. It matches in the background and gives up after a second, so
  a runaway pattern says "Pattern took too long to search" instead of
  freezing the editor; one that does not compile says why. Replace and
  Replace All expand `$1`, `${1}`, `${name}` and `$$`, and a selection
  opens the bar escaped so it finds the text as written.
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
- Tabs look like Séance's and Poltergeist's: flat, starting at the
  window's edge, with a hairline between them and a rule under the strip.
  The active tab takes the page's colour, with no accent line. The +
  button stays at the trailing edge beside Open and Save, so a crowded
  strip no longer scrolls it out of reach.
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
- On Linux, Open and Save As work on desktops that run no XDG desktop
  portal, such as a bare window manager: the dialogs now come from
  Flutter's `file_selector`, which shows GTK's own chooser there, instead
  of `file_picker`, which needed the portal.
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
  document field, carrying focus, the caret and the scroll position over.
- Opening a file that no longer exists says so, instead of showing
  `dart:io`'s `PathNotFoundException` with its errno.
- The window opens on the app's own background in the current light or
  dark mode, instead of the platform's default colour before the first
  frame and while resizing.
