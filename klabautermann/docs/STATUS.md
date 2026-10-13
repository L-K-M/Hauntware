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
  the appearance is held in memory), and the English ARB catalogue (D35,
  A11Y-05).
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
  04 §12.1 records, pending owner confirmation. Locally they have only
  run on stub bundles; CI's Linux client leg runs them on the real
  release bundle, with appimagetool and flatpak-builder.
- Client CI legs: `klabautermann_client` in the root `ci.yml` builds
  Android, Linux, macOS, iOS and Windows on every PR, launches the three
  desktop release builds, checks the APK's version code and the macOS
  bundle's signature, packages the .deb, AppImage and Flatpak, and runs
  the macOS fixtures. No release job ships these builds before M4
  (decision 16).

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3),
persistence for imported ssh_config entries (with the catalog library),
reachability dots and the `ghost_servers` rail (F4), theme editing and
presets (F4b's editor), persisting the appearance (the device settings
store), the desktop settings window and its native runners (D32), and the
release job (M4).

The macOS launch check is weaker than the siblings': the runner's window
is still the template's, visible before Dart runs, and the app installs
no Dart menu, so the check proves only that the release app stays up
without an unhandled Dart exception. The Linux and Windows runners show
their window on the first frame, so a startup that never reaches `runApp`
fails there.

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
to fail. They need macOS: CI's `klabautermann_client` macOS leg runs
both after building the release app, and that build is the first to
compile the copied Objective-C and the Swift bridging.
`app/klabautermann_app/test/macos_runner_test.dart` also guards the
wiring on Linux.

Follow-up: this is the suite's fourth copy of the controller. The D32
review in [SHARED.md](SHARED.md) defers a shared macOS plugin to a
separate suite PR, which must land before any product makes a fifth.
