# Klabautermann review r10: QA (merges, tests, CI, native, docs)

Reviewed at origin/main `9e2080d44`. Read-only. One test file was run to
confirm QA-02 (`dart test packages/klabautermann_host/test/integration/shell_sampler_test.dart`).

Counts: high 0, medium 5, low 7. No finding from the 16 waived-review merges
is a regression of merged behaviour; the merge diffs read clean (details in
"Recent merges" below). The solid findings are in docs, CI and tests.

## Findings (best first)

### QA-01 docs, medium. INSTALL.md denies the updater the app now ships
- `klabautermann/docs/INSTALL.md:39` "Klabautermann never updates itself."
  and `:109-110` "Klabautermann does not download updates."
- `klabautermann/CHANGELOG.md:153-157` (#693): "Klabautermann checks the
  suite's GitHub releases once per launch and offers a newer version in a
  banner ... on Android the banner downloads and installs the release APK
  once you choose Update." Code: `app/klabautermann_app/lib/main.dart:8,610`
  (`ghost_apk_update`, `ApkUpdater()`), `:711-716` (`checkForUpdate`), and
  ghost_apk_update's manifest adds `REQUEST_INSTALL_PACKAGES`.
- Scenario: INSTALL.md is the trust page (it tells the reader "an installer
  or update offered anywhere else is not ours" and that a matching APK
  signature proves nothing). A user who read it sees an in-app Update banner
  and an install prompt the page says cannot exist; the page also omits that
  the app contacts GitHub at every launch and how to turn that off.
- Fix: rewrite both sentences (launch check, opt-out in Settings > General,
  Android in-app download of the release APK, what is verified before
  install); state the outbound request. Size S. Confidence high.

### QA-02 test, medium. shell_sampler slow-program test fails wherever systemctl exists without a running systemd
- `packages/klabautermann_host/test/integration/shell_sampler_test.dart:151-160`
  `_expectAllStatusesOkOrMissing` accepts only `ok` or `missing`; `:333-342`
  runs `units` and `timers`; the comment at `:372` says "units and timers are
  `missing` where systemd is absent".
- Verified here (systemctl at /usr/bin, no /run/systemd/system):
  `dash slow program: procs, units, timers and cron [E] Expected: (ok or
  missing) Actual: SectionStatus.error`, same for bash; 11 pass, 2 fail.
- Impact: `scripts/test.sh dart` and the `klabautermann_host` suite cannot
  pass in a container, WSL without systemd, or a chroot. This is the "known
  local-only failure" every agent brief now carries as an exception, which
  hides real regressions in the same file. The collector itself reports
  `error`, not `missing`, on such a host; the probe knows
  (`hws/program.dart:656` tests `/run/systemd/system`), so whether a real
  container host shows "failed" instead of "not available" for Services is
  worth one look by the host reviewer.
- Fix: in the test, allow `error` for `units`/`timers` when
  `/run/systemd/system` is absent (or make the collector answer `missing`
  then and keep the assertion). Size S. Confidence high (test), medium
  (product angle, not traced).

### QA-03 docs, medium. klabautermann/AGENTS.md states pull-only (D14) as a live convention
- `klabautermann/AGENTS.md:107-108` "Pull-only from the start (D14): nothing
  the app sends may push or write catalog records; a widget test guards it."
- Code: `packages/klabautermann_core/lib/src/catalog/engine_sync.dart:69`
  `const PushPolicy engineSyncPushPolicy = PushPolicy.normal;`, protocol
  requests `SaveServer`, `DeleteServer`, `SetServerPrefs`, `PutRule`,
  `RemoveRule` (`protocol.dart:1453-1547`); 03 D14 itself says "As built in
  v1 (M5 plan M05), pull-only ends". The remaining D14 tests only cover the
  ssh_config import (`fleet_controller_test.dart:576`,
  `ssh_config_import_test.dart:75`).
- Same file, stale tense that reads as open work: `:105-106` "The protocol
  guard enforces this once the engine directory is registered" (it is, in
  `tool/guards.yaml`), `:116-117` "will fail once the Flutter app exists",
  `:129-130` "commit them once `flutter create` scaffolds the app". This
  review's own brief repeats "pull-only D14" as an architecture rule.
- Fix: replace the bullet with the v1 rule (writes go through the engine's
  catalog requests and `CatalogWriter.sealLocal`; imports are never catalog
  writes) and fix the three tenses. Size S. Confidence high.

### QA-04 ci, medium. Klabautermann CI and release never enforce the committed lockfiles, and the pure-Dart job floats on `sdk: stable`
- `.github/workflows/ci.yml:438-443` (`dart-lang/setup-dart@v1`, `sdk:
  stable`, `dart pub get`), `:1639-1641`, `:2333-2335` and the frame-timing
  and Flatpak legs (`flutter pub get`); `release.yml:266-270, 415-418` the
  same; `scripts/test.sh:160-161, 233`. Only Planchette's app uses
  `--enforce-lockfile` (`ci.yml:1460`). `klabautermann/pubspec.lock` and
  `app/klabautermann_app/pubspec.lock` are committed and today agree with the
  pubspecs (checked by script).
- Scenario 1: a pubspec bump without its lock (a hand edit, or a Dependabot
  PR that touches a sibling package the app reaches by path) resolves
  silently in CI and in the release leg; the shipped APK then carries
  transitive versions that are in no commit, while the notice checks run
  against that same unrecorded resolution.
- Scenario 2: the engine packages are analyzed, formatted and tested on
  whatever Dart is "stable" that day, the app ships Flutter 3.47.2's Dart
  (root AGENTS.md: "Use Flutter 3.47.2 and its bundled Dart"). A new stable
  that changes `dart format` or a lint turns main red with no code change,
  and the engine is never tested on the Dart it ships with.
- Fix: `--enforce-lockfile` on every Klabautermann resolve in ci.yml,
  release.yml and scripts/test.sh; run the pure-Dart job on the pinned
  Flutter's Dart (or pin the SDK version). Size S. Confidence high (facts),
  medium (impact; suite-wide pattern).

### QA-05 ci/test, medium. The real-shell matrix is whatever the runner image has; nothing installs or asserts it
- `ci.yml:425-473` (`klabautermann_dart`) installs no packages. The shell
  suites build their matrix from PATH: `edit_shell_test.dart:28-36` (dash,
  bash, mksh, `busybox ash`), `ops_shell_test.dart:30-31` (dash, bash,
  busybox), and the file headers say "a shell that is not installed gets no
  tests". Tool-dependent cases skip: `edit_shell_test.dart:203` ("BusyBox is
  not installed"), `:306, 367, 389, 434, 520, 549` (`ownTools`),
  `log_sources_shell_test.dart:77-107`, `tls_check_test.dart:67,100`.
  The only guard is `expect(_shells, isNotEmpty)`.
- Scenario: mksh is not on GitHub's Ubuntu image, so every mksh case has
  never run in CI; BusyBox cases run only while the image happens to ship
  `/usr/bin/busybox`. A runner image update (or `vars.CI_LINUX_RUNNER`
  pointing at a self-hosted box, which the Flutter job already honours)
  silently drops BusyBox/ash coverage that STATUS and INSTALL claim ("Alpine
  and BusyBox hosts"); the job stays green because skips are not counted.
- Fix: `apt-get install -y mksh busybox-static acl attr cron openssl` in
  `klabautermann_dart`, plus one test that, under `GITHUB_ACTIONS`, asserts
  the expected shells and tools are present. Size S. Confidence medium (the
  image's contents were not inspected).

### QA-06 docs, low. STATUS M5 exit still lists pin publication as waiting
- `klabautermann/docs/STATUS.md:2859` "Left open: the pin publication
  switch, which waits on the release above".
- #760 set `const String kPinPublicationRelease = '1.9.3'`
  (`protocol.dart:1324`), `EngineStart.pinPublicationRelease` defaults to it
  (`engine_isolate.dart:126`), the X4 row above the sentence was updated,
  and `CHANGELOG.md:148-150` says Settings > Sync offers it. The switch that
  publishes host-key pins to the account went live in a waived-review PR and
  the status page says it has not.
- Fix: drop the clause; add the manual check (publish against a real Séance
  1.9.3+ account) to the open gates. Size S. Confidence high.

### QA-07 docs, low. SHARED.md ledger is behind Séance's runners, and says the app has no terminal
- `klabautermann/docs/SHARED.md:102` "the files are unchanged at
  `2e61152e`" and every row cites source `f9bd1e1`. Séance's
  `settings_window.cc`, `SettingsWindow.swift` and `settings_window.{h,cpp}`
  changed in `85b48f21c` (2026-11-04, quit-confirmation
  `yieldForQuitConfirmation`/`restoreAfterQuitConfirmation`) and
  `1c5afda76` (2026-11-09). Normalized diff of the Linux runner now differs
  by 48 lines, macOS 76, Windows 72; the ledger's Divergences column lists
  only names and titles. `:131-132` "A change to Séance's runners should
  reach both copies".
- `:48-49` "Séance's terminal Edit-menu routing ...; the app has no
  terminal." The app has one: `lib/ui/docker/container_terminal.dart`
  (seance_terminal, CTX-07).
- Fix: record the two source commits and the deliberate non-port of the quit
  yield (Klabautermann has no quit review), reword the terminal line with
  the reason the routing is still not needed (Dart menus). Size S.
  Confidence high.

### QA-08 bug, low. A finished power wait never leaves: "back after N" and "shutting down" persist for the app run
- `app/klabautermann_app/lib/controllers/power_waits.dart` (new in #774):
  `_waits[serverId]` is removed only by `stop()` (offered in `waiting` and
  `notBack` only, `ui/power.dart:88-103`), by a failed run, or by a later
  boot after `off`. A wait in `back` stays until the next power action.
- `ui/power.dart:149-150` shows `PowerWaitProgress` for any non-running
  wait and `ui/quick_actions.dart:93-94` for any wait, so after one reboot
  the System tab and the Overview's quick actions card read "back after 2
  min" for hours or days, on every visit. Before #774 the line lived in the
  section's State and went when the user left the tab.
- `ui/power.dart:158-161`: `busy` includes `off`, with no Stop button in
  that phase, so after a shutdown the host did not carry out (or a host
  powered on again while its `core` stream is not subscribed) Reboot and
  Shut down stay hidden until a later boot is read or the app restarts.
- Fix: drop a `back` wait when its surface is left or after a short hold,
  and offer Stop waiting in `off`. Size S. Confidence medium (read, not
  run; `power_test.dart` and `quick_actions_test.dart` do not cover it).

### QA-09 test, low. Wall-clock assertions in unit suites
- `packages/klabautermann_core/test/replay/replay_engine_test.dart:201-213`
  sleeps one real second and asserts the follow rate within 0.5x to 1.5x of
  the plan; `:225, :356` assert "no batch within 150 ms". A loaded shared
  runner (the suites run three packages in one `dart test`) can miss both.
- Other real sleeps: `sampler_session_test.dart:201, 225, 373`,
  `tls_check_test.dart:111` (600 ms), `sampling_scheduler_test.dart:655`,
  `fleet_controller_test.dart:701`, `engine_isolate_test.dart:81` (200 ms),
  `log_service_test.dart:764, 811`. The sampler ones are ordered by timer
  creation and are robust; the replay rate window is the one to fix.
- Also: `packages/klabautermann_core/dart_test.yaml` has no `timeout: 60s`
  while `klabautermann/dart_test.yaml` and the host package have it, so a
  run from the core package (as AGENTS.md's examples do) uses 30 s and CI
  uses 60 s.
- Fix: drive the replay engine's rate with an injected clock or widen to a
  count-over-elapsed lower bound only; add the timeout to the core file.
  Size S. Confidence medium (no flake observed here).

### QA-10 refactor, low. The app is analyzed without the engine packages' async and cast lints
- `klabautermann/analysis_options.yaml` enables `strict-casts`,
  `unawaited_futures`, `prefer_final_locals`;
  `app/klabautermann_app/analysis_options.yaml` has an empty `rules:` over
  flutter_lints. The app holds the controllers that drop futures on purpose
  and by accident, and casts link payloads (`remote_settings.dart`
  `await _call(...) as int`). Séance's app at least adds
  `prefer_final_locals`.
- Fix: add the three rules to the app and clear the findings in one PR.
  Size M (unknown count; the options could not be changed to measure).
  Confidence high (fact), low (count).

### QA-11 docs, low. Stale comments that misstate the dependency reasons
- `app/klabautermann_app/pubspec.yaml:24-27` "Not the siblings' file_picker
  11.0.3 and share_plus 12.0.2" and `:108-110` "Not Poltergeist's 8.3.1":
  Poltergeist pins `file_picker: 13.3.3`, `package_info_plus: 10.2.2`,
  Séance `^13.3.3` / `^13.3.1` / `^10.2.2`.
- `ci.yml:2288, 2377` "the M4 release leg will zip/ship" and `:2357`
  "Nothing reads the keychain yet" describe a state two milestones old.
- Root `AGENTS.md:76` names "file_picker's iOS Swift packages" as needing an
  app LICENSE chunk; no LICENSE has one and file_picker_darwin 2.5.1 depends
  on Flutter only, so there is no gap, only a stale rule.
- Fix: delete or correct. Size S. Confidence high.

### QA-12 docs, low. One 520-line "Unreleased" section; subtree AGENTS rules differ from root
- `klabautermann/CHANGELOG.md` has a single `## Unreleased` heading although
  v1.9.2 to v1.9.4 shipped preview assets, so no reader can tell what a
  release contains (Séance's has the same shape; a release-script matter).
- The `shared-rules` block of `klabautermann/AGENTS.md` (and of the three
  siblings, identical to each other) lacks root's "Decide procedural
  questions yourself" bullet and keeps the old "After two consecutive
  reviewer-integration failures, stop" rule that root replaced with "Do not
  let GLM block a PR". An agent started in `klabautermann/` reads the old
  rule. No script checks the block against root.
- Fix: roll the changelog at release in `release_version`; sync the block
  and add a guard. Size S. Confidence high.

## Recent merges (2026-11-12 to 2026-11-17)

Read the Klabautermann diff of #734, #736, #741, #754, #760, #763, #766,
#767 (stat and test deletions), #774, #776, #780, #783, #792, #794, #796,
#800, plus #735.

- No test was weakened or deleted to get green. Every removed `test(` or
  `expect(` is a move: #767's recovery tests to ghost_keystore, #796's gate
  model test to ghost_keystore, #800's authenticator test likewise, #763's
  "seven planned tabs" replaced with the Docker tab's removal. #734 changed
  `@ANNUALLY` from accepted to rejected on purpose (cronie compares with
  strcmp).
- #734: `SeriesRing.clear`/`TimeSeriesRing.clear` keep running indices and
  eviction consistent; parser failures now cost one stream; the error port
  names a startup failure. Fine.
- #736, #763: behaviour-preserving extractions (`PersistedSetting`,
  `TimedReveals`, `HostReadSectionState`, `EngineReads`, `writeSetting`).
  `EngineReads` keeps PackageReads' different send-failure rule behind an
  enum. Removing `SettingsTab.docker` is safe: tabs cross the link by
  `values`, not by stored name.
- #741: read `argument_masking.dart` whole; traced curl `-H`, `-u`,
  `--user=`, sshpass `-p`, docker login and the `-c` newline rule by hand
  and found no leak. Not run against new inputs (no scratch scripts).
- #754: the PID acknowledgement requires a full `^[1-9][0-9]*\n$`, not
  truncated, setsid only. The inventory session now always simulates a
  missing status; the normal exit-0 path is still covered by
  `docker_actions_test.dart`.
- #760: startup failure is held and answered to Hello; `refusalDetail`
  strips controls and caps at 300; `_stepFailure` carries stderr only.
  `actionKeyOf` is exhaustive and the ARB select has every key.
- #766: every master-key read goes through `settledMasterKey`.
- #774: see QA-08. #776: header dots; fine. #780: sign-out is confirmed,
  blocked while busy, link-safe. #783: badge logic is tested; the plugin
  call (`setBadge` posting and cancelling notification id -1) is untested
  and disclosed as a manual gate. #792/#794: held-record state; fine.
- CHANGELOG and STATUS match the merged behaviour except QA-01 and QA-06.

## Checked and found in order

- `tool/guards.yaml`: Klabautermann registered with pure packages,
  forbidden dependencies, `no_dart_io` and `engine_protocol`; no
  `package:seance_core/src` or `klabautermann_*/src` import in the app's
  lib (grep), one in app tests.
- Integration fixture: `Fixture.fromEnvironment` fails on partial
  environments, the soak fails when it wrote no `soak.json`, the detector
  fails closed on shallow clones, and `integration_workflow_test.dart`
  pins ci.yml's legs. Remaining vacuous path: `sync_convergence_test.dart`
  skips on an empty `KLABAUTERMANN_SYNC_SERVER`/harness variable (run.sh
  sets them under `set -e`, so only an empty-but-successful script output
  would skip).
- Native: identities match AGENTS.md on all five platforms and Flatpak
  (`ch.lkmc.klabautermann`, `ch.lkmc.klabautermannApp`, `CompanyName`
  `ch.lkmc`, copyright `Unlicense`); no `com.example` left; Android backup
  off with extraction rules, AppCompat launch theme and
  `FlutterFragmentActivity` for local_auth; macOS Release entitlements
  empty by design; iOS has the Face ID string; Flatpak grants only
  `~/.ssh/config:ro`, ssh-auth, secrets and notifications.
- Licensing: Android `config/` carries Apache-2.0, protobuf BSD and the
  desugar GPL+CE texts; the app LICENSE has the WIL and C++/WinRT chunks
  `check-flutter-notices.sh` requires.
- STATUS: all 40 test files and 81 other files it names exist, except the
  explicitly retired `localization_test.dart`.

## Overall assessment

The Klabautermann periphery is in better shape than the waived reviews
suggest: the 16 merges are disciplined, tests were moved rather than cut,
and the fixture and its CI contract tests fail closed in most places.
The weak spots are documentation that lags the code on trust-relevant
points (updater, pin publication, pull-only), CI reproducibility
(lockfiles, floating Dart), and shell coverage that depends on the runner
image. One environment-dependent test is tolerated as a standing exception.
No high-severity defect found in this slice.

## Coverage

Read fully: the brief, declined.md, DECISIONS.md; non-test Klabautermann
diffs of #734, #736 (controllers, read_section, timed_reveal, processes
panel, mounts), #754, #760, #763, #766, #774, #776, #780, #783, #792, #794,
#796, #800; `argument_masking.dart`; `inspect_masking.dart`;
`power_waits.dart`; `klabautermann/AGENTS.md`, `README.md`,
`docs/INSTALL.md`, `docs/COVERAGE.md`, `docs/SHARED.md`; STATUS lines 1-125
and 2783-2920; ci.yml's `klabautermann_dart`, detector, integration,
frame-timing, flutter, client and Flatpak jobs; `scripts/test.sh`;
`tool/guards.yaml`; all `dart_test.yaml` and `analysis_options.yaml`;
Android manifest and Gradle config, iOS Info.plist, macOS entitlements,
Flatpak manifest; `app_badge_test.dart`.

Skimmed: #736's remaining UI files and #767 by stat and deleted tests only;
`run.sh` (test legs and exports), `previous_release.sh` head,
`bench-frame-timing.sh`, `build.sh`; release.yml by grep; test suites by
pattern scans (skips, sleeps, body-less tests, untested lib files) and
about ten files by hand; CHANGELOG by grep.

Not reached: `runner_vm.sh`, `capture*.sh`, `inventory.sh`,
`package-linux.sh`, `seed_docker.sh` and their contract tests line by line;
Windows and Linux runner sources beyond identities; the l10n contract
test's allowlist; goldens; STATUS lines 126-2782 and the manual gates
table; the test bodies of #774, #780 and #792 beyond their names.
