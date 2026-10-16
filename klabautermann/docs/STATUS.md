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
  session), and `kSamplerStartCommand` is the start line. The sampler
  session below and the real-shell test use them.
- Sampler session (M2): `klabautermann_core`'s `SamplerSession` runs one
  sampler over an `SshLink`: the start command, the program with a fresh
  nonce, a READY deadline, one request at a time (an overlapping tick
  is skipped and counted), slow deadlines from the guarded commands
  (D47), and on a missed deadline or a broken stream
  `RemoteProcess.close()` and a restart after a backoff of 1 s doubling
  to a 30 s cap, less up to 30 % of downward jitter (so the first
  restart comes after 0.7 s to 1 s). Tested against a scripted process
  and local dash and bash (a SIGSTOP stall included); nothing starts it
  yet, and no SSH fixture test covers it.
- Spike S2 part 1: `klabautermann_core/tool/capture_fixtures.dart
  measure` runs the real program locally under dash and bash (as
  `sh -s`, and as `<login shell> -c '<start command>'` the way sshd
  runs a command) and records [the evidence](evidence/s2/README.md):
  output before READY, fast-tick bytes and CPU, `procs` beyond 1,000
  processes and slow-tick times. The unguarded `procs` loops reach the
  10 s guarded budget near 2,000 processes under dash, where passing
  the D47 deadline depends on its margin, not yet fixed, and pass it by
  1,079 under bash; a `procs` bound, which K15 left out, has to resolve
  that. Fixture capture with its redaction review, SSH mode, the other
  shells (CI images, else the manual list) and systemd collectors
  (runner VM) remain.
- Payload filter (M2, 03 D48, K15, #199): collector-set version 4 filters
  `overview` and `core` on the host with builtins only. Both send the
  total `cpu` line, the meminfo subset, the load average and the rx and
  tx bytes, picking interfaces in this order: device-backed NICs that
  are not Xen netback ports and whose master, if any, has no device;
  then interfaces that are neither a bridge nor enslaved; then all but
  `lo`.
  `core` adds per-core busy and idle sums (eight raw counters from shells
  with 32-bit arithmetic such as mksh), `btime`, four I/O counters per
  whole disk (no partitions, stacked devices, loop, ram, zram or zd
  devices, nor NVMe path rows whose head counts the same I/O), PSI
  averages without `total`, the uptime and, where arcstats exists, the ZFS
  ARC's `c_min` and `size`. `Collector.guardedCommands` feeds the D47 slow
  deadline, and the engine protocol's `CoreResult.perCpu` holds busy
  percent per core. On synthetic trees [U] a `core` reply is 1,880 B at 32
  CPUs plus 26 B per further CPU; 03 §11.4 allows 30 B for each CPU beyond
  32 and exempts shells with 32-bit arithmetic, whose replies pass 2.5 KB
  from 22 CPUs. The `procs` bound (S2 above) and real-host captures
  remain.
- Probe and host profile (M2, 03 D49 and D50, K09, #192): the probe's new
  `lxcfs` area lists the `/proc` files that are `fuse.lxcfs` mounts, and
  `HostProfile.showsHostFigures` applies D50: inside a container a
  system-wide `/proc` file shows the host's figures, so its values are
  unknown, unless lxcfs serves the container's own, which it does not
  reliably do for `stat`, `loadavg`, `diskstats` and `pressure/io`. The
  slow program decides `HW_UTF8` once at start from `locale -a` (D49), and
  the probe's `locale` area reports it; no collector uses it yet.
  `HostProfile` gains `fromJson` for the device cache, `serverZone` (the
  probe's offset plus an IANA name, without rules) and `counterWidth` from
  `uname -m`; a `systemd-detect-virt` error no longer reads as a container
  name. Hand-made Debian 12 LXC fixtures with and without lxcfs, marked
  [U], cover it. Nothing reads these yet.
- Jobs model (JOB-01, JOB-02 data): `klabautermann_host`'s `mergeJobs`
  turns a `cron` and a `timers` tick into one list of cron lines,
  periodic scripts and timers, each with an English-free
  `ScheduleDescription` and, for cron, next runs with DST annotations
  in the server zone or the line's `CRON_TZ`. Timer triggers and
  `RandomizedDelaySec` have fields but no source yet, `CRON_TZ` zones
  other than the server's and UTC need a resolver, and nothing in the
  engine or app consumes the list yet.
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
  answering `Hello`/`Subscribe`/`Unsubscribe` and rejecting the rows
  whose milestones have not landed, and `IsolateEngineClient` for the UI
  side. Protocol v2 types `CatalogReplaced` as a list of plain
  `FleetEntry` values and adds `ImportSshConfig`/`SshConfigImported`:
  the engine reads ssh_config text off the UI isolate (CN-19), splitting
  its lines as `readconf.c` does and taking a host for each name a
  `Host` line gives, as `SshConfigImporter.hostAliases` does. Spawning
  takes the app's support directory, where the engine keeps the imports
  (below); `EngineReady` reports a problem with that file and
  `SshConfigImported` says whether the import was saved, both added
  within v2.
- Protocol v3 (M2 links, 03 §10.1): `LinkState` carries a sealed
  `LinkStatus` (D46's eight states plus `blocked`, typed reasons and an
  optional failure kind), `Prompt` a sealed request per kind, and
  `PromptWithdrawn`, `SetAppActivity` and `Reachability` join; `FleetEntry`
  gains the nullable `jumpRoute`, `authKind`, `searchText` and
  `locatorConflict`. The fleet controller keeps link statuses and probe
  answers only for listed servers, and the rail words every status.
  Nothing produces them yet: the engine still rejects `Connect` and
  `SetAppActivity`, sends no prompts or probe answers, and fills the new
  fleet fields only for imports (below).
- Protocol v3 sampling (M2, 03 §10.1, K16a, #193): `Subscribe` and
  `Unsubscribe` name one surface's subscription and its `SampleStream`s
  (D45; the health card's failed units are a `failedUnits` stream of their
  own), `SetCadenceProfile` picks the 03 §6.4 column, and `Sample` carries
  its stream, an engine-owned per-server `seq` (D44), the engine's time
  and a sealed result of derived values (D43) or `CollectorUnavailable`;
  `SamplingState`, `Gap` and `HostProfileChanged` join. Sampling joined v3
  without a bump. The engine keys subscriptions by server and subscription
  id and keeps the cadence profile, but runs no sampler and sends none of
  these events yet.
- Protocol v3 logs (M2, K16b, #198; 03 §10.1, LOG-01 to LOG-03, LOG-22,
  SVC-04): `OpenLogStream` carries an app-chosen `streamId` and a
  `LogStreamSpec` with a sealed source (the journal with unit, identifier,
  priority, current-boot and time filters; the kernel log; one file), a
  `window`, `follow` and `afterCursor`. `LogBatch` carries sealed
  `JournalRecord`, `KernelRecord` and `FileRecord` values with a dropped
  count, and `LogStreamState` a sealed waiting, running or ended status.
  The engine resolves journal entries into plain records and reads a time
  beyond `DateTime`'s range, a priority outside 0 to 7 or a non-positive
  PID as unknown; `JournalEntry.timestampUtc` no longer throws on such a
  time. Logs joined v3 without a bump. Until the log service lands, the
  engine rejects `OpenLogStream` and ignores `CloseStream`.
- Link connector (M2, `klabautermann_core` `links/`, K17, #197): the
  engine's credential source (no vault yet; key files read at connect time
  after `~` expansion, at most 1 MiB, each attempt recorded best effort in
  `identity_reads.jsonl`, waiting at most 2 s and dropping failed writes,
  read failures classified as not found, access denied, unreadable or
  hidden by the Flatpak sandbox), a prompt broker keyed by
  UUID `promptId` with a 2-minute expiry and withdrawal when the attempt
  ends, and `LinkConnector` over `SshLink.connect` with `TofuVerifier`
  over an injected pin store (in memory for now). Only interactive
  connects prompt: background connects decline a first-seen host key and
  offer no keyboard-interactive, and a changed key blocks the link. There
  is no passphrase prompt and no prompt dialog in the app yet, and nothing
  wires the connector or the broker into the engine yet.
- `klabautermann_app`: `flutter create`d for the five platforms with the
  04 §12.3 identities, generated launcher icons, the desktop three-pane
  shell (fleet rail, workspace, inspector) at 960 px and up, the phone
  master-detail stack below 600 dp, the settings route with its seven
  planned tabs (Appearance's theme switch works), light and dark themes
  built through `ghost_theme` from the Klabautermann brand preset (D9;
  the appearance persists in `settings.json`, below), and the English
  ARB catalogue (D35, A11Y-05).
- Visibility and lifecycle (M2, K21, #200): the workspace and the phone's
  server screen hold their server open, so the first open view sends
  `Connect` and the last one `Disconnect` 30 s later; tabs use
  `SelectedTabView`, and only the selected panel subscribes its 03 §6.4
  streams, each surface under its own id (D45). On phones an
  `AppLifecycleListener` sends `SetAppActivity` on foreground and
  background changes; a desktop app stays in the foreground.
  `MonitoringController` keeps the latest sample per server and stream and
  a 300-reading `SeriesRing` per server, stream and series (CPU busy, used
  memory, used swap, one-minute load), with a gap wherever no subscription
  named the stream, and a one-second clock that ages each stream's latest
  `Sample.at` for freshness; a server that leaves the fleet takes its
  readings and seq floor with it (SYN-08). The seq floor lasts one engine
  run: a restarted engine would be a new client with new controllers, and
  the app remounts its tree when handed them (D44), but nothing restarts
  the engine yet: `main.dart` spawns it once per launch. The engine still
  rejects `Connect`, `Disconnect` and `SetAppActivity`, and the app shows
  nothing for it. No surface shows rings or freshness yet, and the
  time-series chart below draws a `TimeSeriesRing`, not these rings.
- Localization contract (D35, A11Y-05):
  `app/klabautermann_app/test/localization_contract_test.dart` runs the
  suite's shared scanner (`tool/l10n_contract`, 03 §3.5 F1b) over `lib/`
  with a per-file allowlist of reviewed technical literals (such as
  channel and file names, command ids and diagnostics), as Poltergeist's
  contract does. It replaces the interim `localization_test.dart` and
  keeps the two checks the scanner does not make: every ARB key is
  referenced from `lib/`, and no `Text`, `text`, `title`, `subtitle`,
  `label`, `tooltip`, `hintText` or `semanticLabel` slot takes a literal
  (other parameters, such as `message`, are not checked).
- Chart foundations (03 §10.7, M2): `lib/ui/charts/` holds `Sparkline`
  over a fixed-capacity `SeriesRing` that repaints on its version
  counter, with min-max downsampling to the pixel width, gaps for unknown
  samples, threshold bands, IEC scale and value text, a screen-reader
  summary per series from the ARB through a string bag (A11Y-02), and no
  motion when the platform asks (A11Y-11). The palette test holds the
  severity and series colours to 3:1 and keeps them apart under simulated
  colour-vision deficiencies (A11Y-04); light and dark goldens draw with
  the Flutter SDK's Roboto and compare on Linux only. `Gauge` follows in
  its own PR. Nothing shows a chart yet: since K21 `MonitoringController`
  fills the rings, and the overview and fleet rows that show them come
  later in M2.
- Bars (03 §10.7, M2): `StackedBar` for the memory breakdown and disks
  (MEM-01, DSK-01) and the fleet rows' three-cell `PressureBar` (FL-07),
  with hatching for unknown values, grey when stale, and threshold
  colours paired with a stripe, an icon and words (A11Y-01), plus
  screen-reader summaries and light and dark goldens. Nothing shows
  them yet.
- Time-series chart (03 §10.7, §9.5 item 5, OV-03, M2, K12, #194):
  `TimeSeriesChart` draws one to four lanes of a `TimeSeriesRing` on a
  shared time axis with round local-time ticks and one IEC or percent
  scale. The caller opens a gap with its reason; no line crosses a gap or
  an unknown sample, each gap is a hatched band (2 px strokes held to 3:1
  as drawn) labelled "app closed", "in background" or "disconnected" where
  it fits, and the legend names each series, each gap reason and the
  caller's source. Screen readers get each series' summary, which reads
  "now unknown" while the right edge is in a gap, and each gap's span.
  Lanes differ by hue alone, which is still open against 03 §10.10. Not
  yet: `CoreHeatmap`, 03 §10.7's crosshair and threshold bands on this
  chart. Nothing shows the chart yet.
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
  temporary folder. Since M2 the import reads each host as ssh does:
  every block that applies gives the values still unset, `Match` blocks
  count where their criteria can be evaluated, and the store keeps the
  effective `HostName`, `Port`, `User`, first `IdentityFile` and
  `ProxyJump`, plus hop records for route names no `Host` line gives
  (schema 3; a schema 1 or 2 file's hosts are listed without route,
  sign-in or connect config until the next import). The engine maps
  imports to the `ServerConfig`s and jump-hop configs links will dial
  (03 §10.1), filling the route, sign-in, search text and `host:port`
  conflict fields. A host it cannot dial as ssh would is skipped and
  counted: a `ProxyCommand`, a `Match` or `Include` that could change
  it (`Include` is not followed), a second reading of the file for the
  host ssh dials that would change it (Fedora's and RHEL's
  `/etc/ssh/ssh_config` ask ssh for one), a token ssh fills in, a value
  holding bytes that are not UTF-8, a line ssh rejects, or a route ssh
  would refuse. Where that second reading would route a host through
  itself or into a jumphost loop, ssh cannot be taking it, so the host
  keeps the first reading's values (as a bastion under `Host * !bastion`
  does). Nothing dials them yet.
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
- Integration CI legs (M2, K47, #195): `detect_klabautermann_integration`
  in the root `ci.yml` runs on every main push and dispatch, and on PRs
  that touch `klabautermann/**`, `seance_core`, `seance_protocol`, the
  Poltergeist fixture files the sshd fixture builds on or `ci.yml`.
  `klabautermann_integration` runs `test/integration/run.sh` once the
  fixture's `docker-compose.yml` is committed, and
  `test/integration/capture.sh` once that is committed.
  `klabautermann_frame_timing` runs `scripts/bench-frame-timing.sh` under
  Xvfb on main pushes and dispatch. Each leg is skipped with a notice
  until its entry point lands, and the detector fails if a committed one
  disappears. `klabautermann_dart` and `scripts/test.sh` also analyze and
  test `klabautermann/test/integration`, which so far holds the jobs'
  contract test. A workspace `dart_test.yaml` declares the `shell` tag and
  the 60 s cap for runs from `klabautermann/`. No entry point is on main
  yet, so none of the three legs has run.
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
- Log buffer model (03 §10.8): `klabautermann_core`'s `LogBuffer` holds up
  to 50,000 entries and 32 MiB of text, counted as the VM stores it (one
  byte a code unit for Latin-1 text, two otherwise), cuts a line at 16 KiB
  and keeps its full length for the truncation marker, and records a
  `LogBatch`'s drops as one "dropped N lines" entry. `parseSgr` turns a
  line's SGR colours and attributes into spans and drops every other
  escape and control but tab. A heap test keeps a full buffer of either
  kind under the 64 MiB budget (03 §11.4). The log viewer below uses
  them; the engine's followers come later in M2.
- Log viewer (03 §10.8, LOG-02): `lib/ui/logs/`'s `LogView` over a
  `LogViewController` draws fixed one-line rows or wrapped rows, measuring
  only the lines a layout shows and finding offsets in O(log n); follows
  the newest line, pauses on any scroll away from it and resumes at the
  end, on End or Follow; colours levels with a spoken gutter icon; holds
  every span to 4.5:1; and scrolls by keyboard with a focus ring. Light
  and dark goldens draw with the test font and compare on Linux only. Not
  yet: sideways scrolling without wrap (a long line ends in an ellipsis,
  which hides a cut line's note) and tab stops. No panel shows it yet: the
  Logs and Services panels and the followers come later in M2.
- Journal rows and search (03 §10.8, LOG-01, LOG-05, K13, #196):
  `LogBuffer.addJournal` keeps a journal entry's MESSAGE as the line's
  text and its other fields as UTF-8 JSON bytes counted against the 32 MiB
  cap; the source and fields get up to one 16 KiB line cap beside the
  text, and fields past it are left out and counted. A buffer full of
  typical entries holds about 42 MiB of retained heap in the heap test,
  within the 64 MiB budget. `addJournal` takes the host's `JournalEntry`,
  not the protocol's `JournalRecord`. `LogView` draws journal rows as
  `unit[PID]: message` with the level from `PRIORITY`, marks a message's
  newlines, and shows an entry's fields beneath its row on a tap or Enter.
  `LogSearch` searches the loaded rows with `planchette_core`'s
  `findSearchMatches` (03 D56), ignoring case unless set, and steps
  between matches with wrap-around; the view highlights matches and
  scrolls the current one's row into sight. Not yet: the search field,
  which must debounce or search in slices; showing a match past a row's
  ellipsis or after a journal row's first line without wrap; a time column
  (needs the server zone); and repeated journal fields, which
  `parseJournalLines` misreads. No panel shows it yet: the Logs and
  Services panels and the engine's log streams come later in M2.

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3),
reachability dots and the `ghost_servers` rail (F4), theme editing and
presets (F4b's editor), the monitor set and per-server device preferences
in `settings.json`, and the release job (M4).

The macOS runner now keeps its window hidden until Dart has placed it,
so the CI launch check's wait for a visible window also proves that
startup reached the window restore. It also passes `--menu File`, as
Planchette's and Poltergeist's do, so the Dart menu bar must be
installed. The Linux and Windows runners show their window on the first
frame, so a startup that never reaches `runApp` fails there.

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
