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
  UI isolate (CN-19).
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
  engine isolate starts. It holds `klabautermann.settings.version` (1),
  `klabautermann.sync.deviceId` and `klabautermann.appearance`; keys it
  does not know are kept on every write. The device id is a UUID v4
  (`seance_core`'s `uuidV4`, as the catalog library's enrollment
  expects), minted and saved on the first launch and never regenerated;
  nothing reads it yet. The theme is restored at startup and saved on
  every change; the desktop settings window (D32) will reach the same
  `AppearanceController`, so its changes are saved by the app, not by
  the window. Writes are atomic (temp file, flush, rename, directory
  sync). A damaged file is copied aside as
  `settings.json.corrupt-<UTC time>` before the defaults replace it,
  keeping its device id when the text still shows one (Séance's
  recovery, Poltergeist's copy name); an unreadable file, one whose copy
  fails, or one from a newer schema is left untouched and nothing is
  saved that session. Each case is told once in a top toast at startup;
  a theme change that cannot be saved stays for the session and says
  so. The monitor set and per-server device preferences have no
  consumers yet and are not stored. No real build has run it yet: the
  tests restart against a temporary folder, not the platform's support
  directory (a sandboxed macOS container, the Flatpak's `~/.var/app`).
- Local-only import (FL-02, first part): desktops offer "Import from
  ~/.ssh/config" in the rail's add menu (in the app bar when the window
  is narrower than the desktop breakpoint); phones have no ssh_config and
  no entry. The app reads the file, the engine parses it, and the rail
  lists the hosts; a missing, unreadable or oversized file gets a
  localized message. Imported entries live in the engine's memory only
  and are gone after a restart: D13's device-local store arrives with
  the catalog library. `Include` is not followed (`SshConfigImporter`
  drops it), and `ProxyJump` and `IdentityFile` are not carried yet: the
  rail needs neither until links land (M2).
- Packaging: `scripts/build.sh`, `scripts/package-linux.sh` (.deb and
  AppImage through the shared `scripts/package-linux-common.sh`) and
  `scripts/build-flatpak.sh` with `flatpak/ch.lkmc.klabautermann.yml`.
  The flatpak grants read-only `~/.ssh` for the FL-02 import, which
  04 §12.1 records, pending owner confirmation. The scripts have only run
  on stub bundles so far; a real Flutter bundle, appimagetool and
  flatpak-builder first run in the client CI legs.

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3),
persistence for imported ssh_config entries (with the catalog library),
reachability dots and the `ghost_servers` rail (F4), theme editing and
presets (F4b's editor), the monitor set and per-server device preferences
in `settings.json`, the desktop settings window and its native runners
(D32), and the five client CI legs and release job.

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

None applies to M1a yet; they gate the milestones that ship the matching
behavior; this list keeps them visible so they are not lost between PRs.

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
