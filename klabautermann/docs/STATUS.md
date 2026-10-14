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
  yet. Only one process is guarded: two instances that start together on
  a first launch (the Linux runner allows several) each mint an id, and
  the last write wins. An advisory lock across read, mint and write, or
  a single desktop instance, must land before enrollment reads the id.
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
  identity-file reads and the owner's sign-off. The scripts have only run
  on stub bundles so far; a real Flutter bundle, appimagetool and
  flatpak-builder first run in the client CI legs.
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
  [SHARED.md](SHARED.md). No CI job compiles the client runners yet, so
  `SettingsWindow.swift`, `settings_window.cc` and `settings_window.cpp`
  are unbuilt until the client legs land;
  `app/klabautermann_app/test/settings_window_runner_test.dart` guards
  their wiring on Linux. `ghost_desktop` brings the `window_manager` and
  `screen_retriever` plugins, which the main window registers but nothing
  uses until the window lifecycle moves onto `ghost_desktop`; meanwhile
  `window_manager`'s Linux and Windows code reports window events nobody
  listens to, which debug builds log as discarded channel messages. On
  Linux its registration also replaces the main view's delete-event hook,
  so closing the main window no longer asks Dart whether to quit; a later
  exit hook must use `window_manager`'s prevent-close path, which
  `ghost_desktop`'s window lifecycle wraps. The macOS menu's
  "Preferences…" item is not wired to Settings yet; the menus come from
  the command registry (03 §10.2).

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3),
reachability dots and the `ghost_servers` rail (F4), theme editing and
presets (F4b's editor), the monitor set and per-server device preferences
in `settings.json`, the macOS integrated titlebar, window-state restore
and menus through `ghost_desktop` (03 §10.2), and the five client CI legs
and release job.

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
between PRs. M1 adds one gate of its own:

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

## macOS native fixtures

The macOS runner uses Séance's keyboard and accessibility compatibility
controller (`KlabautermannFlutterViewController`, ledgered in
[SHARED.md](SHARED.md)). `scripts/test-macos-keyboard.sh` and
`scripts/test-macos-accessibility.sh` compile it against the cached
Flutter engine and run the native fixtures modelled on Séance's. With
`--stock-engine` they test the stock controller instead and are expected
to fail. They need macOS and have not run yet. No CI job builds
Klabautermann for macOS yet either, so nothing has compiled the copied
Objective-C or the Swift bridging: both wait for the Klabautermann client
legs in the root workflows. Until then
`app/klabautermann_app/test/macos_runner_test.dart` guards the wiring on
Linux.

Follow-up: this is the suite's fourth copy of the controller. The D32
review in [SHARED.md](SHARED.md) defers a shared macOS plugin to a
separate suite PR, which must land before any product makes a fifth.
