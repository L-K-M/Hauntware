# Changelog

## Unreleased

- **The header band lines up.** The inspector's tabs are as tall as the
  panes' tab bars, so the line under them continues the panes' line.
  Tabs now fill their bar from top to bottom. On macOS the sidebar's
  filter field is as tall as the tabs and level with them.
- **Large bookmark backups sync in pieces.** A backup round now sends
  its changes in batches within the limits the sync server advertises.
  Before, one push past a limit was refused whole and failed the same
  way every round. A single record too large for the server stays on
  this device, and the rest still sync.
- **Preview 23 bundled fonts.** The editor's font button opens a
  searchable picker with code, ambiguous glyphs, bold and italics.
  Previewing changes nothing until you choose Use font. Ligatures are on
  by default and can be disabled, including font-specific coding sets.
- **Update from the Alerts tab on Android.** The update alert offers
  Update with the download size. Poltergeist downloads the release APK,
  shows its progress with Cancel, discards it unless its size and
  SHA-256 match the release, and opens Android's installer. If you back
  out of the installer, Install reopens it without downloading again.
  Nothing downloads until you tap Update; desktop builds still link to
  the release page.
- **Choose the editor's font.** Settings → Appearance lists the
  included fonts under the editor's text size, each in its own face,
  with a Ligatures switch. Editor windows and the compare view draw in
  the choice.
- **Fingerprints, keys and logs are fixed-width everywhere.** Host key
  fingerprints, private keys, login scripts, the credential prompt's
  address and the connection panel's log draw in JetBrains Mono on
  macOS, iOS and Windows, where they used to fall back to the
  proportional system font. The connection log uses JetBrains Mono too,
  instead of Menlo or Consolas, and the grep cheat sheet in the editor's
  find bar uses the document's font.
- **Every name on an ssh_config `Host` line gets a row.** `Host web db`
  offers `web` and `db` with the block's settings and notes, where only
  `web` appeared before. Wildcard and `!` patterns still get no row.
- **A typo in an ssh_config `Port` no longer imports as port 22.** A
  `Port` other than a number from 1 to 65535 or `ssh`, `http` or
  `https`, such as `22a` or `0x16`, makes the row unimportable, as a
  port outside 1–65535 already did. The preview shows the port as
  written, with a chip naming the ports import accepts. `Port ssh`,
  `http` and `https` read as 22, 80 and 443.
- **ssh_config import reads lines as ssh does.** `HostName = example.com`
  imports `example.com`, not `= example.com`, and `Include = extra.conf`
  reads `extra.conf`. Single and double quotes and backslash escapes are
  removed, and a `#` inside quotes or inside a value no longer cuts it
  short.
- **Two syncs can claim a new trash folder at once.** When two syncs
  started together on the same new trash folder, one could fail with
  "The sync-trash ownership marker is invalid". A sync interrupted while
  claiming its trash folder could also leave the folder unusable. Both
  now settle on one owner.
- **Skip `.git/` and `node_modules/` in one click.** The advanced pair
  editor offers both as chips under the exclude rules. Clear a chip to
  remove its rule again.
- **Reuse skip rules across syncs.** Save a sync's skip rules as a named
  rule set, then add the set to another sync from Edit Rules… or the
  advanced pair editor. Adding a set copies its patterns after the rules
  already there and leaves out any that are already present, so later
  changes to the set don't change syncs that used it. Manage Rule Sets…
  renames, edits and deletes sets. Rule sets stay on this device.
- **See what changed between two files.** The compare view now marks the
  lines that differ: removed lines on the left and added lines on the
  right, with blank space opposite them. Step through the changes with
  the arrow buttons or N and Shift+N, switch to one unified column, or
  pick Separate to scroll each file on its own and use Find. Files over
  20,000 lines open side by side without marks. The text follows your
  editor text size, and Help ▸ Keyboard Shortcuts lists N and Shift+N.
- **Rename several items at once.** Select two or more items and choose
  File ▸ Rename Items… to replace text in their names, add text before
  or after them, or give them a name and a number. A preview shows every
  new name and marks any that would collide with another item, be
  invalid or hide the item, and nothing is renamed until all of them are
  fixed. Nothing is ever overwritten. If some items cannot be renamed,
  the dialog says which and why.
- **Compare two files side by side.** File ▸ Compare Files opens two
  selected files, one in each pane or both in one pane, in the same
  read-only side-by-side view the sync plan uses. Remote files download
  through the preview cache and ask first when they are large.
- **Servers that offer only chacha20-poly1305 connect.** Poltergeist now
  uses dartssh2 4.1.0 (was 3.0.2), which adds that cipher. Servers that
  require post-quantum ML-KEM key exchange still cannot connect.
- **Steadier, safer connections.** Poltergeist negotiates strict key
  exchange, the Terrapin countermeasure, with servers that offer it. If a
  server's host key changes during a rekey, the connection ends instead of
  carrying on. On Android, the key exchange no longer takes long enough
  for the server to time it out and drop the connection before login. An
  SSH channel no longer stalls for good when data arrives before
  Poltergeist starts reading it, and a request on a connection that drops
  fails instead of waiting forever.
- **Older servers still connect.** Other servers negotiate the same
  cipher and host key as before, so transfer speed and pinned host keys
  are unchanged. Servers that offer only SHA-1 key exchange, `ssh-rsa`
  host keys or AES-CBC ciphers keep working; Poltergeist uses those only
  when a server offers nothing newer. Servers that offer only
  `diffie-hellman-group1-sha1`, `hmac-md5` or truncated `hmac-sha2-*-96`
  MACs no longer connect.
- **Double-click to copy to the other pane.** With Double-click action
  set to Transfer to other pane, opening a file copies it into the
  folder the other pane shows, like Copy to Other Pane does for a
  selection. If the other pane is hidden or has no folder open, the
  pane says so instead. The preview's Open button now always opens the
  file, whatever this setting says.
- **Choose what opening a file does.** Settings → Editing has a
  Double-click action setting: Open (the default), Edit in Poltergeist,
  Transfer to other pane or Do nothing. It also applies to opening a file
  from the keyboard, in every pane and window at once.
- **Dialogs from menus and shortcuts stay one at a time.** While
  Settings, an import, Synchronize or Connect is open, the other dialog
  commands stay unavailable until it closes, whether it was opened from
  a menu or a keyboard shortcut and even if you use another menu command
  such as Show/Hide Second Pane meanwhile.
- **Keep folders on top, or mix them in.** Settings → General has a Keep
  folders on top switch, also in the View menu as Keep Folders on Top.
  Turn it off and folders sort in among files by the same column, in
  every pane and window at once.
- **Choose where a server opens.** A server's new Start folder setting
  (Edit Server) picks the folder you land in when you connect from the
  sidebar's Servers list: an absolute path such as `/var/www`, or one
  relative to your home such as `~/sites`. It syncs with the server, so
  every device opens the same folder. Favorites still open their own
  folder.
- **The editor flags mistakes in config files.** JSON that doesn't
  parse, a key set twice in a `.env`, JSON, YAML or TOML file, broken
  XML tags and leftover merge-conflict markers are underlined as you
  type. The status bar counts them and describes the one on the caret's
  line; click it or press F8 to go to the next one, Shift+F8 for the
  previous.
- **More remote programs stay unlaunched.** Opening a remote app package
  or installer (`.msix`, `.appx`, their bundles, `.appinstaller`,
  `.appref-ms`, `.vsto`, `.ppkg`) on Windows, a preference pane, screen
  saver or Automator action on a Mac, or a `.deb` or `.rpm` package on
  Linux no longer hands it to the system's default app, which would
  install and run it. Open With an editor still opens it.
- **Escape cancels a drag.** Pressing Escape while dragging files ends
  the drag: nothing is copied or moved when you let go, and no folder or
  tab opens under the pointer.
- **Drop on a pane's header or beside a folder.** Dropping files on a
  pane's header (its folder name, item count or column header) puts them
  in that pane's folder. The margin left of a folder's icon drops beside
  the folder rather than into it. A listing of folders too long to leave
  empty space still takes a drop.
- **Folders spring open more slowly.** Holding a drag over a folder opens
  it after 1.5 seconds instead of 1, so passing over folders opens them
  less often by accident.
- **⌘← and ⌘→ go back and forward on a Mac**, like ⌘[ and ⌘]. In a text
  field they still move to the start or end of the line.
- **Context menus open ready to use.** A file's context menu could open
  with its entries greyed out, set for the other pane, until you moved
  the pointer over them. Clicking in a pane now always makes it the
  active one.

## 1.9.0 — first suite release (2026-10-04)

- **Import server bookmarks from other apps.** The Server menu now imports
  FileZilla, WinSCP and Cyberduck bookmarks through a bounded review screen.
  Saved passwords stay behind; unsafe or unsupported entries remain visible
  but cannot be selected.
- **⌘W closes Settings on a Mac.** With the Settings window in front, ⌘W
  and ⇧⌘W close it. ⌘W used to close a tab in the workspace window behind
  it, and ⇧⌘W the workspace window itself.
- **SSH-agent authentication.** New servers default to the system SSH agent,
  with no private key stored by Poltergeist.
- **The built-in editor is the one Planchette and Séance use.** It gains
  line numbers, find and replace with whole-word and regular-expression
  search, Go to Line (⌘L on a Mac, Ctrl+G elsewhere), Tab and Shift+Tab
  to indent and outdent (Enter keeps the indentation, learned from each
  file), line commands (duplicate, move, delete and join lines), Toggle
  Comment, Go to Matching Bracket, and highlighting for Go, diffs and
  more. Saving, uploads and conflict checks work as before.
- **Lines meet at the region edges.** The line under the header and the
  active pane's accent line stopped a few pixels short of the sidebar's
  edge, the divider between the two panes and the inspector's edge. They
  now run all the way to those lines.
- **Folders open in place.** Folder rows have a small triangle on the
  left, as in Finder and Transmit: click it, or press → and ←, to show a
  folder's contents indented below it without leaving the folder you
  are in. You can select rows at any level. When a folder and something
  inside it are both selected, delete, duplicate, copy, move and drag
  act on the folder once instead of on its contents twice, and a row
  inside an unselected folder is handled on its own. Duplicate now puts
  each copy next to its original.
- **The active pane's accent line is above its tabs.** The coloured line
  that shows which pane is active now runs along the top of that pane's
  tab bar instead of under the tabs, so it no longer sits between a tab
  and the folder it shows.
- **Simultaneous transfers per server.** The Transfers popover, next to
  the bandwidth limits, sets how many files move to or from each server
  at once: Automatic (up to 6, the app's total) or 1 to 5. A server's
  editor can give it its own number. Browsing, editing, previews and sync
  runs are never held back by it, and while one server is at its limit,
  transfers to other servers go ahead instead of waiting behind it.
- **Better on phones and tablets.** Local panes on Android open in the
  app's own documents folder instead of failing on "/~". The inspector
  starts hidden on touch screens so the panes get the width; the header
  toggle brings it back. The sidebar's filter field is full height, and
  compact rows on touch are 40 dp instead of 48.

- **Tabs switch in place.** Settings and the server mark picker showed
  the new tab by scrolling the content sideways to it, and a sideways
  swipe or trackpad scroll flipped between tabs. The new tab now simply
  appears, a swipe no longer changes tabs, and each tab keeps what you
  left in it: a half-typed search or form, the scroll position.

- **Colour that means something.** Icons get their colour back, and
  each colour means one thing in both Poltergeist and Séance, so you can
  find things by colour before you read them:
  - Folders are blue, code orange, images pink, audio and video purple,
    archives brown, PDFs red and links cyan, in the listing, the
    inspector, Quick Look and Transfers.
  - Sidebar places lead with a coloured tile: Home blue, disks
    graphite, a USB stick brown, a workspace teal, a saved sync indigo.
    Desktop, Documents, Downloads, Pictures, Music and Movies get their
    own icons.
  - Toolbar verbs are coloured while you can use them (New Folder blue,
    Move to Trash red, Copy to Other Pane cyan, Sync indigo, Connect
    green) and turn grey when you can't. The same colours mark them in
    right-click menus and the command palette.
  - The inspector's Info, Transfers and Alerts tabs are blue, cyan and
    yellow, and the open one lights up in its colour.
- **Themes.** Settings has an Appearance section (a tab of its own in the
  Settings window, and after General on phones and tablets). Pick one of
  ten themes (Poltergeist, Graphite, Paper, Newsprint, Solarized,
  Midnight, Terminal, Vapor, Bubblegum, High contrast) as a starting
  point, then change any colour, the four server status colours, the
  interface font and how round the corners are; the app repaints as you
  go. Colours left on Automatic follow light or dark as you choose. Copy
  theme and Paste theme carry a theme between devices, and between
  Poltergeist and Séance; themes do not sync. The app starts in Vapor,
  magenta and cyan over violet-black; pick Poltergeist for the teal look
  it had before themes.
- **A new workspace.** The window is rebuilt in the style of ForkLift and
  Transmit:
  - A calm header: back and forward, the current location, New Folder,
    Move to Trash and Copy to Other Pane, labelled Sync and Connect
    buttons, an activity ring, a filter field, and (on Linux and
    Windows) a ☰ menu with everything else. The toolbar that showed
    every command as an icon is gone.
  - A resizable sidebar with DEVICES (home, volumes, free space),
    FAVORITES and SERVERS (live status dots, filter, and a bottom bar
    for adding things, sync status and Settings).
  - An inspector column with Info, Transfers and Alerts tabs, in place
    of the bottom activity panel, the Get Info overlay and the status
    bar. Sidebar and inspector widths are remembered, and both give way
    gracefully as the window narrows.
  - Panes get a location header with a menu of enclosing folders,
    sortable columns, denser rows with file-kind icons, selection on
    press, and right-click menus everywhere.
- **Two sidebar views.** The sidebar's rows come in two densities:
  comfortable, the default, with a larger mark and the path, free space
  or `user@host` (with the state first when a server is connecting,
  failed or blocked) spelled on a second line, and compact, one line
  with those details in the tooltip. Switch at the foot of the
  sidebar, on the phone's Home, or with View ▸ Use Compact/Comfortable
  Sidebar Rows; the choice is kept per device.
  - A server's colour leads its row as a line again, a connected server
    wears a green ring, a blocked host key has its own mark, and an
    unreachable host shows a red ring.
  - Saved remote folders are favorites again, listed under Favorites
    beside local folders; "Save to Servers…" is now "Save to
    Favorites…". Servers lists your Séance account's servers (marked as
    such) and live Quick Connect sessions, and a Pinned section keeps
    the ones you pin at the top.
  - Pinned is the sidebar's first section, and saved remote folders pin
    too ("Pin to top" in their menu), so it works without a Séance
    account.
  - A folded group or a filter never hides a live connection: the
    header shows its dot, and a screen reader hears it with the header
    ("Connected server hidden", or "Connecting server hidden"). The
    filter appears at five servers again,
    says "↵ opens the first", and offers Clear filter.
- **New verbs.** Connect (⌘K), New Folder, New File, Duplicate, Move to
  Trash with a clear confirmation, Copy and Move to Other Pane (F5, F6),
  Show in Finder / File Manager / Explorer, and Help ▸ Keyboard
  Shortcuts.
- **Sync like Transmit.** Sync opens a sheet that states in plain words
  what will happen ("…will be updated from…, 2 files will be deleted"),
  with Simulate and Synchronize. A plan that only adds files runs
  straight away; anything that replaces or deletes stops on a review
  grouped by action, with per-row checkboxes.
- **Android is supported.** The release APK is a supported build now,
  not a rehearsal artifact; `docs/INSTALL.md` covers sideloading it, and
  the README lists what it does not do yet. On phones the sidebar is the
  home screen and the browser shows one pane at a time with an A·B
  switcher. Long-press selects, and the inspector is a bottom sheet.
  System back steps through selection, sheets, folders and home.
- **Drag files out of Poltergeist.** Dragging rows past the window's
  edge hands them to the system, so they can land in a file manager or
  another app; several selected items travel together, and they arrive
  as copies (or links). A drag out never moves or deletes the
  originals, so the Trash and the Recycle Bin refuse it; drags between
  the two panes still move. On Linux this carries local files today,
  and so does Windows (built, awaiting its first run on Windows). On
  macOS local files travel as file URLs, and remote files and folders
  as file promises that download straight to where you drop them
  (built, awaiting its first run on a Mac); on Linux and Windows a
  remote drag shows a hint and stays inside the window. A drag that
  comes back into Poltergeist lands like any in-app drag. Pausing a
  dragged remote item's download in Transfers stops the drop and says
  so under Alerts, and a drag that has to leave links or names that
  aren't valid UTF-8 behind says how many.
- **More than one window.** File ▸ New Window (⌘N on macOS, Ctrl+N on
  Linux and Windows) opens another workspace window, so different
  folders, servers and transfers can sit side by side. Each window has
  its own tabs, panes, sidebar and inspector; bookmarks, connections,
  Settings and the transfer queue are shared, so a transfer keeps
  running after the window that started it closes, and every window's
  Transfers tab shows all of them. File ▸ Close Window (⇧⌘W, Ctrl+Shift+W)
  or the close button closes one window; closing the last one quits,
  asking first if transfers are running. The next launch reopens every
  window you had open. For now an extra window does not take files
  dropped from other apps or drag files out, and on macOS it has a
  standard title bar, in-window Quick Look and no screen-reader
  support. Run on Linux; built for macOS and Windows.
- **Settings in its own window.** On macOS, Linux and Windows, Settings
  opens in a window of its own instead of over the workspace, with
  General, Editing and Sync tabs. Settings, Back up and sync… and
  Configure Editors… each open it on their tab, and bring it forward if
  it is already open. Closing it discards anything typed but not saved,
  and quitting from it goes through the same checks as quitting from
  the workspace. Phones and tablets keep the dialogs. Built on all
  three desktops; run so far on Linux only.
- **Download To….** File ▸ Download To… and the row menu download the
  selected remote items into a folder you pick.
- **Shares an account with Séance.** Bookmark sync now preselects the
  Séance sync account, so both apps show the same servers.
- **Remote transfers work.** Uploads, downloads, remote→remote copies,
  remote managed checkouts, previews, and remote sync endpoints now run
  through the engine's bridged transfer lease. 1.0.0 failed these tasks
  with `unsupported`.
- **Edited servers connect where you pointed them.** Changing a server's
  host, port or user name used to take effect only after Disconnect or a
  restart: new tabs, transfers and syncs kept connecting to the old
  address. They now use the new details, and tabs and transfers already
  open on the old address keep working until they close. A new key file
  or password is used the next time the server connects.
- **Trust before secrets.** Connecting to a server for the first time now
  asks you to approve its host key before it asks for a password. An
  unreachable server fails without asking for a password at all.
- **Large transfers stay responsive.** A transfer of more than a few
  thousand files no longer rewrites the transfer journal after every
  file, which slowed the app, delayed quitting and wore the disk. The
  journal is compacted only when finished transfers free more space than
  the rewrite costs.
- **Fixes:**
  - On a Mac in full screen, the titlebar no longer covers the top of
    the window. It slides in with the menu bar, as in other apps, and
    the header uses the room the traffic lights left.
  - Remote panes refresh when a transfer, move or delete lands in the
    folder they show.
  - A file that fails to open no longer disables the rest of its pane.
  - Opening a local file on Linux works without xdg-utils, falling back
    to `gio open`.
  - Edits to files opened from a Quick Connect session can be uploaded,
    and those servers show their address instead of an internal id.
  - The editor keeps a second leading byte-order mark as content, and
    Perl's `$#array` and `s#…#…#` no longer highlight as comments.
  - Delete, Shift+Delete and ⌘⌫ act only while the file list has
    focus. Pressed in the sidebar or the inspector, they no longer send
    the pane's selection to the Trash.
  - A local file dropped on a device copies unless Move is held.
  - The workspace is saved and restored again after connecting to a
    server at its home folder (a Quick Connect to `sftp://user@host`,
    or a server opened from SERVERS). Such a tab used to stop every
    later save and lose the layout on the next launch, and its recent
    entry disappeared.
  - A hung network mount no longer freezes or hides DEVICES.
  - Screen readers can activate every header button, inspector tab and
    Sync control, and hear the alert and transfer counts.
  - On a Mac, Control-click opens a sidebar row's menu. The app menu
    gains Check for Updates…, and Linux and Windows gain File ▸ Quit.
  - Pinned servers and folded sidebar sections survive a launch that
    could not read the settings file. Pinning or folding afterwards
    used to replace all of them with just that one change; now the
    sidebar keeps them and shows them again.
- **Mirror leaves alone what it cannot see.** When the source has a
  symbolic link where the destination has a real folder, a Mirror no
  longer deletes that folder's contents, and it no longer copies into a
  link on the destination. Everything under the link is skipped, as the
  exported rsync command already did. When a folder is to be replaced
  by a file, its contents belong to that one row: they are no longer
  deleted while you leave the choice open or keep the folder, no longer
  count twice toward the deletion limits, and no longer show "changed
  since preview" after the replace.
- **Servers behind a jump host stay behind it.** Saved ProxyJump chains
  resolve completely before connecting, dial only the outer host, and
  authenticate and verify every hop. Editing preserves the route, Test
  connection exercises it, and the raw sidebar probe never bypasses it.
  If sync changes a hop or removes a connected server, existing work may
  finish, but the old route cannot reconnect.
- **Copy as rsync Command is right for server pairs.** For a pair with a
  server side, the copied command backslash-escaped its exclude
  patterns, so rsync ignored them: a pasted Mirror could delete the
  server's `.poltergeist-trash` folder, and an exclude with a space
  uploaded what it should skip. Patterns are now passed as written. The
  command also starts with `RSYNC_OLD_ARGS=2 RSYNC_PROTECT_ARGS=0`, so
  rsync 3.2.4 and later no longer escape the server path a second time
  and sync into a wrongly named folder. When a pull's trash folder has
  a name the server's shell would misread, backups go to
  `.poltergeist-trash` instead, and a note in the command says so.
- **Remote program files are never run by opening them.** Opening a
  remote file whose type your computer runs rather than opens (such as
  `.exe`, `.js`, `.hta` or `.lnk` on Windows, `.command` or `.terminal`
  on macOS, `.desktop` on Linux) no longer hands it to the system
  default app. You see why, with an Open With button to pick an editor
  instead.
- **Keyboard browsing keeps your place.** Esc, Enter or ↓ in the
  header filter now return you to the listing, so the arrow keys, Space
  and Enter work on the results straight away (Enter selects the first
  match, ↓ the first row). Going up a folder selects the folder you came
  from and scrolls it into view, and Back and Forward select the item
  you last had selected there, as Finder and ForkLift do.
- Pre-1.0 history lives in the commit log and the GitHub pre-releases
  (v0.1.0, v0.2.0).

## 1.0.0 — first stable release (2026-09-23, shipped)

The ghost is out of the sheet. Poltergeist 1.0 is a two-pane file browser
for people who live on SFTP: each pane browses a local folder or a remote
server, tabs everywhere, a ForkLift-style favorites sidebar, a previewable
sync planner, an activity panel that journals every job across restarts,
and a built-in text editor — all keyboard-first, all localizable-ready,
all paranoid in the right places.

Highlights:

- **Panes.** Two independent panes with tabs, per-location view
  preferences, Quick Select (type to jump), Quick Open palette,
  filter-as-you-type, and workspace bookmarks that restore a whole
  window's layout.
- **Transfers.** A real queue — reorder, pause, per-item retry, bandwidth
  limits, a five-verb conflict dialog, and a journal that survives the
  app being killed mid-copy. Local↔local transfers are fully working.
- **Remote browsing over SSH.** Connect with keys, agent-less passwords,
  or keyboard-interactive auth; host keys pin on first use (TOFU) and a
  changed key is a hard stop. `~/.ssh/config` imports with a preview and
  dedupe.
- **Sync.** Saved pairs with Update / Mirror / Additive modes, a plan
  view that shows every action before anything moves, trash-first
  deletes with restore, and a copy-as-rsync-command exporter for when
  you want the shell instead.
- **Bookmarks.** Groups, drag-to-reorder, per-device view state, and
  opt-in end-to-end-encrypted backup through a Séance sync server (your
  own, if you self-host one).
- **Editor.** Built-in text editor with syntax highlighting and
  conflict-checked saves, plus "Open with" for your own editors.

Know before you install:

- **Remote transfers are not wired yet.** The engine proves them —
  remote→remote piping included — but the UI-side queue has no protocol
  verbs to reach it, so uploads, downloads, remote sync runs, and remote
  managed checkouts fail fast with a visible `unsupported` error. Local
  work is unaffected. This is the headline fast-follow.
- Linux screen-reader support is blocked upstream in Flutter
  (flutter/flutter#159460); Windows IME uses the legacy IMM32 path with
  known upstream defects. See the README's known-issues section.
- Desktop builds are unsigned by design — first launch takes one extra
  step per platform; see `docs/INSTALL.md`.
- The Android APK and iOS IPA in every release are rehearsal artifacts
  of the desktop codebase, not supported builds.

No telemetry, no account, no crash reporting. The only outbound call the
app ever makes unprompted is a link-only check that a newer release
exists, and it is one setting away from off.
