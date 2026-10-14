# Status & next steps

Living snapshot of where Klabautermann is, what's proven, and what to pick
up next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[../docs/design/klabautermann/](../../docs/design/klabautermann/) for the
normative plan (`03-ARCHITECTURE.md` §2 is the decision log).

## Where things stand

M1a, the app scaffold and its registration, is the current milestone
slice:

- `klabautermann_host`: HWS/1 program, frame protocol, capability probe,
  parsers and snapshot/rate models with per-platform fixture goldens.
- HWS/1 reader (M2): the frame parser skips login-shell output before
  READY up to 64 KiB and reads an empty `B` uptime as unknown;
  `HwsTickAssembler` turns frames into replies (READY version check, a
  reply lost to a framing error, out-of-order markers ending the
  session), and `kSamplerStartCommand` is the start line. No engine code
  uses them yet; the real-shell test runs on them.
- Sampler session (M2): `klabautermann_core`'s `SamplerSession` runs one
  sampler over an `SshLink`: the start command, the program with a fresh
  nonce, a READY deadline, one request at a time (an overlapping tick
  is skipped and counted), slow deadlines from the guarded commands
  (D47), and on a missed deadline or a broken stream
  `RemoteProcess.close()` and a restart after 1 s to 30 s of backoff.
  Tested against a scripted process and local dash and bash (a SIGSTOP
  stall included); nothing starts it yet, and no SSH fixture test
  covers it.
- Access rules (M2, `klabautermann_host` `access/`): the CN-24 rows from
  a `HostProfile` (passwordless sudo, journal group with the LOG-04
  notice, Docker socket rights with the SAF-08 flag, systemd version,
  runtimes per host for CN-09), each `ok`, `missing` or `unknown` with
  an enum reason. Only the journal and Docker socket rows can carry a
  copyable fix argv, which is never run; sudo has none until SAF-17.
  Streamlocal and the compose plugin stay unknown until M3. Panel
  capability declarations for the M2 host panels (the probe now also
  checks `dmesg` and `tail` for LOG-03 and LOG-22) and an
  external-monitor rule over the units list. Nothing reads them yet.
- `klabautermann_docker`: pure-Dart HTTP/1.1 client, NDJSON/JSON-seq
  scanning, stdcopy, versioned API models and negotiation, compose labels
  and grouping.
- `klabautermann_core`: the D18 engine isolate skeleton: the plain-data
  request/event protocol of 03 §10.1 as sealed classes, `engineMain`
  answering `Hello`/`Subscribe`/`Unsubscribe` and rejecting the rows whose
  milestones have not landed, and `IsolateEngineClient` for the UI side.
  Protocol v2 types `CatalogReplaced` as a list of plain `FleetEntry`
  values and adds `ImportSshConfig`/`SshConfigImported`: the engine
  parses ssh_config text with `seance_core`'s `SshConfigImporter` off the
  UI isolate (CN-19). Spawning takes the app's support directory, where
  the engine keeps the imports (below); `EngineReady` reports a problem
  with that file and `SshConfigImported` says whether the import was
  saved, both added within v2.
- `klabautermann_app`: `flutter create`d for the five platforms with the
  04 §12.3 identities, generated launcher icons, the desktop three-pane
  shell (fleet rail, workspace, inspector) at 960 px and up, the phone
  master-detail stack below 600 dp, the settings route with its seven
  planned tabs (Appearance's theme switch works), light and dark themes
  built through `ghost_theme` from the Klabautermann brand preset (D9;
  the appearance persists in `settings.json`, below), and the English
  ARB catalogue (D35, A11Y-05).
- Sortable table (M2): the app's `SortableTable`, which the M2 lists
  build on. The caller owns the sort (a header click flips it; ties keep
  the caller's order and unknown values sort last). A screen reader hears
  each cell with its column name and gets the row's verbs as actions
  (A11Y-03, 03 §10.10). The body is one keyboard stop with an active row
  (arrows, paging, Home, End, Enter, Shift+F10), and rows keep the
  listing's fixed extent at the text scale. No panel uses it yet.
- Device settings (03 §4.10): `settings.json` under the app's
  `getApplicationSupportDirectory()`, through `klabautermann_core`'s
  `DeviceSettingsStore`, which the composition root opens before the
  engine isolate starts (and never in the settings window's engine). It
  holds `klabautermann.settings.version` (1),
  `klabautermann.sync.deviceId` and `klabautermann.appearance`; keys it
  does not know are kept on every write. The device id is a UUID v4
  (`seance_core`'s `uuidV4`, as the catalog library's enrollment
  expects), minted and saved on the first launch and never regenerated
  while the file can be read; a damaged file whose text shows no id gets
  a new one (the old bytes stay in the corrupt copy). Nothing reads it
  yet. A second desktop instance stops at the instance lock (below)
  before the store opens, so two launches no longer race to mint it
  unless the lock cannot be taken.
  The theme is restored at startup and saved on every change; the
  desktop settings window (D32) reaches the same `AppearanceController`
  over the settings link, so its changes are saved by the app, not by
  the window. Writes are atomic (temp file, flush, rename, directory
  sync). A damaged file is copied aside as
  `settings.json.corrupt-<UTC time>` before the defaults replace it,
  keeping its device id when the text still shows one (Séance's
  recovery, Poltergeist's copy name; when the defaults cannot be written,
  the toast says the copy was kept but the file was not reset); an
  unreadable file, one whose copy fails, or one from a newer schema is
  left untouched and nothing is saved that session. Each case is told once
  in a top toast at startup; a theme change that cannot be saved stays for
  the session and says so, in the settings window too: the app answers the
  window's call as applied but not saved (`SettingsLinkError.notSaved`),
  which the window words apart from a change the app did not take. The
  monitor set and per-server device preferences have no consumers yet and
  are not stored. No real build has run it yet: the tests restart against
  a temporary folder, not the platform's support directory (a sandboxed
  macOS container, the Flatpak's `~/.var/app`).
- Local-only import (FL-02): desktops offer "Import from
  ~/.ssh/config" in the rail's add menu (in the app bar when the window
  is narrower than the desktop breakpoint); phones have no ssh_config and
  no entry. The app reads the file, the engine parses it, and the rail
  lists the hosts; a missing, unreadable or oversized file gets a
  localized message. The imports persist: the engine keeps them in
  `ssh_config_imports.json` (D13's device-local store, 03 §4.10) in the
  support directory the app passes it at spawn, and its first fleet
  snapshot after a restart lists them. Each import replaces the whole
  stored set rather than merging into it: `~/.ssh/config` is the one
  source, and until the editor (FL-03, v1) a merge would keep a host the
  user removed from the file with no way to drop it. The set is saved
  atomically (the settings store's writer) before the fleet changes; an
  import that cannot be saved still shows for the session, and a second
  toast says it will not be kept. A damaged file is renamed to
  `ssh_config_imports.json.corrupt-<UTC time>` and the engine starts
  without imports; a file it cannot read or rename, or one from a newer
  schema, is left as it is and no import is saved that run. Each case is
  told once in a top toast at startup. As with `settings.json`, no real
  build has run it yet: the tests restart the engine isolate against a
  temporary folder. `Include` is not followed (`SshConfigImporter` drops
  it), and `ProxyJump` and `IdentityFile` are not carried or stored yet:
  the rail needs neither until links land (M2).
- Packaging: `scripts/build.sh`, `scripts/package-linux.sh` (.deb and
  AppImage through the shared `scripts/package-linux-common.sh`) and
  `scripts/build-flatpak.sh` with `flatpak/ch.lkmc.klabautermann.yml`.
  The flatpak grants read-only `~/.ssh/config` for the FL-02 import and
  nothing else under `~/.ssh` (04 §12.1); widening it waits for M2's
  identity-file reads and the owner's sign-off. Locally the scripts have
  only run on stub bundles; CI's Linux client leg runs them on the real
  release bundle, with appimagetool and flatpak-builder.
- Client CI legs: `klabautermann_client` in the root `ci.yml` builds
  Android, Linux, macOS, iOS and Windows on every PR, launches the three
  desktop release builds, checks the APK's version code and the macOS
  bundle's signature, packages the .deb, AppImage and Flatpak, and runs
  the macOS fixtures. No release job ships these builds before M4
  (decision 16).
- Desktop settings window (03 §10.2, D32): on macOS, Linux and Windows,
  Settings opens in a native window of its own through `ghost_desktop`'s
  `GhostSettingsWindowHost`; phones, and a desktop runner that cannot
  open the window, keep the settings route. The window is a second
  Flutter engine: `main` hands it the settings window's app before the
  device settings store opens and the engine isolate starts, so it never
  opens `settings.json` and runs no engine isolate (D18), store or sync,
  and everything it shows or changes crosses
  `klabautermann/settings_link` (the Appearance tab's theme switch acts
  on the app's `AppearanceController` and both windows re-theme). The
  three runners are copies of Séance's, ledgered in
  [SHARED.md](SHARED.md). The client CI legs compile
  `SettingsWindow.swift`, `settings_window.cc` and `settings_window.cpp`;
  `app/klabautermann_app/test/settings_window_runner_test.dart` also
  guards their wiring on Linux. `ghost_desktop` brings the
  `window_manager` and `screen_retriever` plugins, which the main
  window's state now uses (below). On Linux `window_manager`'s
  registration replaces the main view's delete-event hook, so closing the
  main window does not ask Dart whether to quit; the window lifecycle
  observes the close and never holds it, and a later exit hook must use
  `window_manager`'s prevent-close path, which `ghost_desktop`'s
  lifecycle wraps (`GhostClosePolicy.intercept`).
- Desktop chrome (03 §10.2), all three parts modelled on the siblings:
  - macOS integrated titlebar: content under a transparent titlebar with
    an empty unified toolbar, so the traffic lights sit in a 52 pt band
    (`lib/services/macos_titlebar.dart`, Séance's install through
    macos_window_utils). ghost_desktop's `MacosToolbarBandChannel`
    follows the band over `klabautermann/window`; the band is reserved
    above every route, the desktop shell paints its rail and inspector up
    behind the traffic lights and starts their content below the band,
    and full screen drops the band. A failed install keeps the standard
    titlebar and reserves nothing. The settings window keeps a plain
    window.
  - Window state: `window_state.json` beside `settings.json`
    (`lib/services/window_state.dart`), in Séance's shape, restored in
    `main` before `runApp` through ghost_desktop's `GhostWindowLifecycle`
    and saved on every settled move or resize and on close. A frame that
    no longer fits the connected displays is clamped onto the one it
    overlapped most, or centred on the primary one (Poltergeist's rule);
    Windows frames are physical pixels (Séance's). The macOS runner keeps
    the window hidden until Dart has placed it. The file is kept out of
    `settings.json` so drag saves never rewrite the device id's file (03
    §4.10 records the file).
  - Menus from one command registry (`lib/ui/menus/`, Poltergeist's
    shape): `PlatformMenuBar` on macOS, a Flutter menu bar strip on Linux
    and Windows, none on phones. Registered: Settings… (⌘, on macOS,
    Ctrl+, elsewhere; in the application menu on macOS, File elsewhere),
    Import from ~/.ssh/config (File, desktops, disabled while an import
    runs) and Quit (File, Linux and Windows, the close button's path). On
    macOS AppKit adds About, Services, the hide trio, Quit (⌘Q), Enter
    Full Screen (View) and Minimize, Zoom and Bring All to Front (Window).
    The same registry binds the shortcuts. No command is a toggle, so
    `klabautermann/menu_checks` stays reserved.

  The macOS runner lines are copied from Séance and ledgered in
  [SHARED.md](SHARED.md); Linux and Windows need no runner code. The
  client CI legs compile the macOS runner;
  `app/klabautermann_app/test/desktop_chrome_runner_test.dart` also
  guards its wiring on Linux.
- Single desktop instance (03 §4.10): on macOS, Linux and Windows the
  composition root takes an exclusive, non-blocking advisory lock on
  `instance.lock` in the support directory (`klabautermann_core`'s
  `InstanceLock`) after the settings window's branch and before the
  macOS titlebar, `settings.json`, `window_state.json` and the engine
  isolate, and holds it while the process lives; the system drops it when
  the process ends, a crash included. A second instance touches none of
  them: its window keeps the runner's frame and standard titlebar (on
  macOS Dart shows it, since the runner keeps it hidden) and shows only
  that Klabautermann is already running, with a Quit button, which closes
  the first-launch device-id race. A lock that cannot be taken for another
  reason (an unwritable support directory, a file system without locks)
  lets the app run unguarded and says so in a startup toast. Phones take
  no lock. A relaunch does not bring the running window forward (the
  Linux runner stays non-unique, the Windows runner has no mutex), and
  only Linux's lock conflict is exercised across two processes; the
  macOS and Windows error codes are unit-tested. No real build has run it
  yet.

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3),
reachability dots and the `ghost_servers` rail (F4), theme editing and
presets (F4b's editor), the monitor set and per-server device preferences
in `settings.json`, and the release job (M4).

The macOS runner now keeps its window hidden until Dart has placed it,
so the CI launch check's wait for a visible window also proves that
startup reached the window restore. The check does not yet pass
`--menu File` as Planchette's and Poltergeist's do, and the `ci.yml`
comment above it still describes the template runner; both are a
root-lane follow-up. The Linux and Windows runners show their window on
the first frame, so a startup that never reaches `runApp` fails there.

## Open manual gates

The milestone sign-off gates are tracked in
[06-EXECUTION.md](../../docs/design/klabautermann/06-EXECUTION.md#manual-sign-off-gates);
the plan's manual checklist (03 §11.1) is reproduced below. Each item
stays open until it is exercised on real targets; automated compilation
is not a device smoke test:

- iOS background disclosure and the return banner (PLT-04).
- Android battery and data use.
- macOS keychain prompts.
- VM passes on Debian 12, Ubuntu 24.04 and 26.04 (sudo-rs), RHEL 8 and 9,
  Alpine and a BusyBox NAS, plus a Synology host (11.3).

None of those applies to M1a yet; they gate the milestones that ship the
matching behavior; this list keeps them visible so they are not lost
between PRs. M1 adds gates of its own:

- Desktop settings window (D32), once per desktop OS: macOS, Windows,
  and Linux in a GNOME Wayland session and an X11 session, from a build
  that includes the window. Open Settings from the rail's gear: a
  separate settings window opens on General, and the main window shows
  no settings page. Switch Appearance to Dark, Light and System: both
  windows follow each time; quit and relaunch, and the app starts in the
  mode last chosen there. Close the window (close button; on macOS
  also ⌘W and ⌘⇧W) and open Settings again: it reappears at once on a
  fresh screen, and the app keeps running. Choose Settings while the
  window shows: it comes forward. Close the main window with Settings
  open, and again with it hidden: the app quits each time, without a
  crash (on Linux, without an X error). On macOS, ⌘Q with Settings in
  front quits the app, and opening and closing the window twice with
  VoiceOver on does not crash. Open: needs a person on each OS; the
  widget and runner-source tests do not open a native window.
- macOS integrated titlebar (03 §10.2), on macOS from a build that
  includes it, in light and dark mode. Launch: the window never shows a
  standard titlebar first and has no title text. The traffic lights sit
  centred in the top band, over the rail's colour, and nothing of the
  rail, workspace or inspector (section header, rows, tab strip, inspector
  title) sits under or beside them. Dragging the empty band moves the
  window and double-clicking it zooms. Enter full screen (green button
  and View ▸ Enter Full Screen): the content moves up to the top edge and
  the titlebar only slides in with the menu bar; leave it: the band comes
  back. Narrow the window below 960 px: the app bar sits below the band.
  The Settings window keeps a standard titlebar. Open: needs a person on
  a Mac; no CI job compiles the Swift yet.
- Window state across launches (03 §10.2), on macOS, Windows, and Linux
  in a GNOME Wayland and an X11 session. Move and resize the main window,
  quit and relaunch: it opens at the same size and, where the window
  system lets apps place windows (not Wayland, which only keeps the
  size), the same place. Maximize it, quit and relaunch: it opens
  maximized, and un-maximizing returns the earlier frame; the same for
  full screen. With two displays, close it on the second, disconnect that
  display or rearrange the displays, relaunch: it opens fully on a
  connected display, never off screen. On a mixed-DPI Windows desktop
  (100 % and 200 %), close it on each display in turn and relaunch: same
  place and physical size. Move it, wait a second, and quit through File
  ▸ Quit (Linux, Windows) or ⌘Q (macOS): the moved frame is kept too.
  Open: needs a person with the displays; the tests drive scripted
  displays, not a window system.
- Menus and shortcuts (03 §10.2), once per desktop OS. macOS: the menu
  bar shows Klabautermann (About Klabautermann, Settings… ⌘,, Services,
  Hide Klabautermann, Hide Others, Show All, Quit Klabautermann ⌘Q),
  File (Import from ~/.ssh/config), View (Enter Full Screen) and Window
  (Minimize, Zoom, Bring All to Front), with no tab commands; each item
  does what it says. ⌘, opens Settings from the main window, from a
  focused text field, and with Settings in front (it comes forward).
  There is no Edit menu yet: ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z still work in a text
  field in both windows. Linux and Windows: a File menu strip above the
  content with Import from ~/.ssh/config, Settings… (Ctrl+, shown and
  working) and Quit, which closes the app the way the close button does.
  The import item is dimmed while an import runs. Phones and tablets show
  no menu. Open: needs a person on each OS; the widget tests check the
  model and the Flutter side of `PlatformMenuBar`, not AppKit's menu.
- Single desktop instance (03 §4.10), once per desktop OS from a build
  that includes the lock. With Klabautermann running, launch it again
  (on macOS with `open -n`, since Finder would only activate the first):
  the second window shows only that Klabautermann is already running,
  keeps the standard titlebar and size on macOS, and Quit closes it while
  the first keeps running with its settings and window state untouched.
  Quit the first, then launch again: it starts normally. Kill the first
  with SIGKILL (Task Manager on Windows) and launch again: it starts
  normally, because the system dropped the lock. Open: needs a person on
  each OS; the tests take the lock from Dart processes, not from two
  native app instances.

## macOS native fixtures

The macOS runner uses Séance's keyboard and accessibility compatibility
controller (`KlabautermannFlutterViewController`, ledgered in
[SHARED.md](SHARED.md)). `scripts/test-macos-keyboard.sh` and
`scripts/test-macos-accessibility.sh` compile it against the cached
Flutter engine and run the native fixtures modelled on Séance's. With
`--stock-engine` they test the stock controller instead and are expected
to fail. They need macOS: CI's `klabautermann_client` macOS leg runs
both after building the release app, and that build is the first to
compile the copied Objective-C and the Swift bridging.
`app/klabautermann_app/test/macos_runner_test.dart` also guards the
wiring on Linux.

Follow-up: this is the suite's fourth copy of the controller. The D32
review in [SHARED.md](SHARED.md) defers a shared macOS plugin to a
separate suite PR, which must land before any product makes a fifth.
