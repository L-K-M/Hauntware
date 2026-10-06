# Changelog

## Unreleased

- A server's colour runs along the top of the terminal's tab strip,
  above the tabs, where Poltergeist marks its active pane. Under the
  tabs, the terminal's first line could be drawn over it.
- Terminal text stays inside the terminal. With scrollback, the partly
  hidden top line was drawn over the tab strip above it.
- Files: double-clicking a file opens it in the built-in editor, in a new
  tab beside your terminals. The built-in editor is now the default editor
  on desktop too, where files used to open in the system's default app.
  On desktop, files it can't open, such as images or text over 4 MB,
  still open in the system's default app. To open every file there,
  choose System default under Settings > Files > Default editor. A
  desktop editor you added and made the default stays the default;
  files it does not accept are handled as above.

## 1.9.0 (2026-10-04)

- Built-in editor: the shared Planchette editor brings its text tools. A
  header button opens the tool browser (Repeat and Recent, seven groups,
  a keyword filter); tools run from an options bar or at their defaults,
  each behind a one-line result notice and its own undo step. The find
  bar gains Keep and Delete Lines Matching, Extract Matches, Find in
  Selection, regular-expression hints, a replacement preview and a
  session search history. The buffer keeps line endings exactly as the
  file has them, and files save with the same bytes as before.
- Terminal and editor tabs look like Poltergeist's pane tabs and
  Planchette's document tabs. The tabs are flat on the header's colour,
  with a hairline after each, and the open tab takes the pane's colour
  and a bold label, without the coloured underline. Other
  tabs' labels are dimmed, and a tab under the pointer is filled. A
  tab's close button shows on hover, on keyboard focus and on the open
  tab, and an unsaved file's dot stays in its place. Screen readers can
  still close any tab.
- On a Mac, ⌘W and ⇧⌘W close the Settings window when it is in front.
  ⌘W used to close a terminal tab in the window behind it and leave
  Settings open.
- The side panel's tabs look like Poltergeist's inspector tabs: a
  centred row of icons in their colours, each named by its tooltip,
  with the open tab's icon filled on a tint of its colour. They replace
  the icons over labels and the coloured underline.
- Command inbox: a bot or script can propose commands for your servers,
  and you decide whether to run them. Connect it under Settings > Inbox;
  it gets a pairing string to use with your sync server, which lets it
  add proposals and nothing else. A banner above the server list says
  when proposals are waiting. Each one shows the server it is for, why,
  the whole script (invisible and control characters shown as
  `<U+…>`) and the danger checker's warnings per line. Stage uploads the
  script to `~/.seance/inbox/` on that server and puts the one line that
  runs it in the prompt; nothing runs until you press Enter. Proposals
  are encrypted with a key only the app and your vault hold, so the sync
  server can neither read nor forge them. Handled proposals stop showing
  on your other devices, and two devices cannot both stage one. The
  sync server documents the format at `/llms.txt` and serves a reference
  client, `/v1/inbox/seance-propose.py`. The sync server needs updating
  for this.
- Built-in editor: the shared Planchette editor brings Tab and Shift+Tab
  to indent and outdent (Enter keeps the indentation, learned from each
  file), line commands (duplicate, move, delete and join lines), Toggle
  Comment, Go to Matching Bracket, Go to Line (click the caret position
  in the status bar, or Cmd+L on macOS and Ctrl+G elsewhere), whole-word
  and regular-expression search, and highlighting for Go, diffs and
  more. The status bar also shows the selection's size, the indentation
  and the language, and says when a file is too large to highlight.
- The lines between the server list, the terminal and the side panel
  now meet the lines across them. The header's bottom edge, the tab
  bar and the panes' bottom borders used to stop a few pixels short of
  the vertical dividers. The dividers are still as easy to grab, and
  the terminal is 18 pixels wider.
- On macOS the window no longer has a separate title bar. The traffic
  lights sit over the server list, and a header across the terminal and
  side panel shows the server you are on (name and `user@host`) with
  Generate command beside it, the way Poltergeist's window looks. Drag
  the header's empty space to move the window; double-click it to zoom.
  In full screen the header stays and the title bar slides in with the
  menu bar. Linux and Windows keep their title bars.
- Themes: Settings has an Appearance tab. Pick one of ten themes
  (Séance, Graphite, Paper, Newsprint, Solarized, Midnight, Terminal,
  Vapor, Bubblegum, High contrast) as a starting point, then change any
  colour, the status colours, the terminal's colours, the interface font
  and how round the corners are; the app repaints as you go. Colours left
  on Automatic follow light or dark as you choose. Copy theme and Paste
  theme carry a theme between devices; themes do not sync. The app starts
  in Terminal, green on black; pick Séance for the violet look it had
  before themes.
- On phones and tablets, the server filter field is full height again
  instead of a thin strip above an empty gap, and compact server rows
  are 40 dp instead of 48.
- Sync: a snippet or server too large for the sync server no longer cuts
  this device off from your other devices. Their edits and deletions
  still arrive, and the sync status names the record that stays behind,
  so you know what to make smaller.
- Tabs switch in place. Settings, the side panel and the server mark
  picker showed the new tab by scrolling the content sideways to it, and
  a sideways swipe or trackpad scroll flipped between tabs. The new tab
  now simply appears, a swipe no longer changes tabs, and each tab keeps
  what you left in it: a half-typed message, a search, the scroll
  position.
- Settings opens in a window of its own on macOS, Linux and Windows,
  instead of covering the app. Choosing Settings again (⌘, or Ctrl+,, the
  gear, "Sync off") brings it forward on that tab; closing it keeps the
  app as it was. Phones and tablets keep the full-screen Settings. A
  change on General or Files that cannot be saved now says so.
- Colour that means something, shared with Poltergeist: each colour
  names one kind of thing in both apps, so you find things by colour
  before you read them. The side panel's tabs are the Assistant purple,
  Snippets teal, Files blue and Git orange, each icon above its label,
  with the underline in the open tab's colour. Files shows folders
  blue, code orange, images pink, audio and video purple, archives
  brown and PDFs red, and a finished transfer is green, a failed one
  red. Git's Stage is green and Discard red. The assistant's sparkle and
  the command wand are purple, and Settings' tabs are coloured too.
- Server list: rebuilt on the sidebar Séance now shares with Poltergeist.
  On desktop the list is a rail with no app bar: PINNED, then SERVERS with
  groups as nested disclosure rows (folds persist), rows with the server's
  mark and one status dot (green connected, amber connecting, red failed,
  a hollow ring for what the probe saw), a filter at five servers or on
  ⌥⌘F (Ctrl+Alt+F elsewhere), and a bottom bar with a "+" menu (New
  server, Import SSH config), the sync status (a click on "Sync failed"
  retries), the density switch and Settings. Right-click, Shift+F10 or
  the Menu key open a row's verbs; ⌘- or Ctrl-click opens another tab. On
  a phone the list is the home screen with a "⋮" and long-press for the
  same verbs, and a "+" button; back to the list keeps the filter and
  scroll position. The sidebar kit is ported from Poltergeist.
- Server list: the two views are back, on the desktop rail, on tablets
  and on the phone home. Comfortable, the default (and what an existing
  install's stored choice already says), draws two lines under the 32 px
  badge: the address, led by the state when a session is connecting,
  failed or blocked or the host is unreachable ("Connection failed ·
  deploy@host"). The server's colour runs down the row's edge again, a
  connected server's badge wears its green ring, the "⋮" is in view, and
  group counts, chevrons and SERVERS' "+" show at rest. Compact keeps the
  one-line rail. Switch with the control in the rail's bottom bar or the
  phone home's app bar, or on macOS with View ▸ Use Compact Sidebar Rows
  (Use Comfortable Sidebar Rows). Also: a folded group, or a filter, that
  hides a connected server shows its dot on the header, and a screen
  reader hears it with the header ("Connected server hidden"); a filter
  that hides a whole section keeps its header for that, as Poltergeist's
  does; a changed host key you declined marks the row blocked rather
  than failed (a key-exchange signature that fails on an unchanged key
  is an ordinary failure, not a block); the filter's count says "↵ opens
  the first" again; the long-press sheet shows the row's second line
  under its name; and the filter chord no longer latches the field open
  on an empty list.
- Sync server: registration, prelogin and login read at most 16 KiB of
  request body, so a client that has not signed in can no longer make the
  server buffer megabytes per request, and every body is buffered more
  compactly. New usernames must be 1 to 256 bytes with no control
  characters (accounts created before still sign in), a username that is
  not a string is a 400 instead of a server error, and registration checks
  the verifier and salt lengths every client sends.
- Android: the system back button on the narrow terminal screen returns to
  the server list instead of closing the app, which had ended every live
  SSH session. In Files, back climbs one folder at a time before leaving
  the screen. The app opts into predictive back.
- Assistant: turning off "Include terminal output" now stays off. It used
  to switch itself back on whenever the assistant was rebuilt: each time
  the phone drawer reopened, or when the window crossed the wide/narrow
  breakpoint. The next message then sent the terminal output you had
  chosen to withhold. The choice is now saved on this device. The command
  generator's "Use recent terminal output as context" is the same
  setting, so turning it off in either place turns it off in both. It
  still starts on.
- Built-in editor: saving keeps the local copy's permissions (an owner-only
  0600 checkout stays owner-only, a script keeps its execute bits), and the
  replacement file is owner-only while it is written. Symlinked copies are
  refused on open as well as on save. Errors read as plain sentences,
  without "Bad state:" prefixes. A save that finishes after its tab closed
  still reconciles or uploads the copy. Ported from Poltergeist's hardened
  copy of this editor.
- Files: local copies of server files are no longer deleted when the
  record of them is lost or unreadable. They used to be kept for one
  launch and then removed, unsaved edits included; they now stay in the
  app's `sftp-checkouts` folder until you remove them. A local copy that
  cannot be read or deleted, for example because another program has it
  open, no longer stops Séance from starting.
- Built-in editor: syntax highlighting for CSS/SCSS/LESS, Ruby, Perl and
  Lua, `.htaccess`/`.htpasswd` as ini, and Ruby/Perl/Lua shebangs, ported
  from Poltergeist. Language detection also finds the file name after a
  backslash.
- A new tab for a server you edited while one of its tabs was open (⌘T,
  Ctrl+Shift+T, the tab strip's "+" or the macOS New Tab item) now
  connects with the saved settings. It used to dial the host, port and user
  the open tab had connected with.
- Linux: the window is titled "Séance" and first opens at 1280x800.
- Security: the Git tab and the staged `cd` now quote paths and arguments
  so fish reads them literally too. Before, when your login shell was fish,
  a directory name with a backslash and a quote could run commands on the
  server, and ordinary terminal output could report such a name to the Git
  tab, which probes it automatically. Reported directories that contain
  control characters are now ignored.
- Files: an upload no longer replaces a symbolic link on the server. Choosing
  Replace over a link used to swap the link for a regular file anyone could
  write (mode 0777) and leave its target unchanged; the upload now stops and
  says the item is a link. FIFOs, sockets and devices are refused the same
  way, and so is a folder, before any bytes are sent. A file whose mode
  keeps others from reading or writing it, such as a 0600 key or an
  ordinary 0644 file, is staged owner-only while it uploads, so other users
  on the server can neither read the new bytes nor write into them.
- Keyboard shortcuts for tabs: close the current tab with ⌘W (Ctrl+Shift+W
  on Linux and Windows), step through a server's tabs with Ctrl+Tab and
  Ctrl+Shift+Tab (also ⇧⌘] and ⇧⌘[ on a Mac, Ctrl+Page Down and Ctrl+Page
  Up elsewhere), and jump to a tab with ⌘1 to ⌘9 (Alt+1 to Alt+9 on Linux
  and Windows; 9 is always the last tab). They work in the terminal and
  anywhere else in the window, and closing asks about unsaved edits and
  local copies just as the close button does. Plain Ctrl+W, Ctrl+C and
  Ctrl+A still go to the shell; Alt+digit now switches tabs instead of
  reaching readline. The terminal's right-click menu lists every shortcut.
- Terminal: find in the scrollback with ⌘F on a Mac or iPad and
  Ctrl+Shift+F elsewhere, or Find… in the terminal's right-click menu;
  plain Ctrl+F still goes to the shell. A small bar at the top right
  searches the whole scrollback, matching text that wraps across rows,
  highlights every hit and marks the current one, and counts them ("3 of
  17"). Enter and Shift+Enter, ⌘G and ⇧⌘G, or F3 and Shift+F3 move between
  hits, the terminal scrolls to the current one, Aa makes the search match
  case, and Escape closes the bar and returns you to the shell. New output
  updates the hits while the bar is open, and the terminal does not resize
  when it opens.

Earlier history lives in the commit log and any GitHub releases.
