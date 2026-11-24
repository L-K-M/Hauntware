# R6: controllers, services, composition root (prefix CTL)

Scope: `klabautermann/app/klabautermann_app/lib/{main,app,settings_window_app}.dart`,
`controllers/`, `services/`. Paths below are relative to
`klabautermann/app/klabautermann_app/lib/` unless they start with
`packages/`. Engine code was read only to confirm what the app side
depends on.

Counts: 1 high, 6 medium, 7 low (14 findings).

---

## CTL-01 (bug, safety) HIGH: controllers built after the first `await` in `main` miss the engine's startup events; synced read-only switches and protected marks are not enforced

- Where: `main.dart:337` (`await LocalSystemNotifications.start(...)`),
  `main.dart:519` (`ServerPrefsController(engine)`), `main.dart:525`
  (`safetyFromSettings(... prefs: serverPrefs)`);
  `controllers/server_prefs_controller.dart:73-83`;
  `controllers/safety_controller.dart:232-237`;
  engine `packages/klabautermann_core/lib/src/engine/engine_isolate.dart:1186-1188, 802-829`;
  client `packages/klabautermann_core/lib/src/engine/engine_client.dart:121-137`.
- What: the engine answers `Hello` with `EngineReady`, then at once
  `CatalogReplaced`, then `await sendServerPrefs()` (`ServerPrefsChanged`,
  `AlertRulesChanged`, `SnippetsChanged`). `events` is a broadcast stream;
  only listeners present when an event is dispatched get it. `main` is
  synchronous from the spawn to line 336, then awaits the notification
  plugin (a platform round trip, up to 3 s on Linux without a bus). The
  port messages already queued are dispatched during that await.
  Everything constructed after line 337 is not subscribed yet:
  `AlertNotificationsController`, `OperationsController`,
  `PinPublicationController`, `SyncController`, `ServerEditorController`,
  `EngineKeystoreResponder`, **`ServerPrefsController`**,
  `RecoveryController`, `AdminRearm`.
- Proof of the ordering: a scratch script against the real engine
  (`IsolateEngineClient.spawn`, one listener at once, a second after a
  single `await Future(() {})`) printed `early: [CatalogReplaced]`,
  `late: []`. One event-loop turn is the least any platform-channel await
  takes.
- Consequence: `ServerPrefsController._syncing` is filled only from
  `CatalogReplaced` (line 73) and `_prefs` only from `ServerPrefsChanged`
  (line 83). With the startup fleet lost, `syncs(id)` is false for every
  server, and `SafetyController._merged()` skips the record:
  ```dart
  for (final id in {...servers.keys, ...prefs.prefs.keys, ..._pending.keys}) {
    if (!prefs.syncs(id)) continue;
  ```
  After the M06 migration a synced server's read-only switch, its SAF-22
  marks and its syslog-line switch live only in the `pref` record
  (`_forgetStored` drops the local copy). So the policy sent to the engine
  at launch is `_local` alone: management on, `readOnly` false, no marks.
  The engine does not resend: `sendServerPrefs` diffs against `prefsSent`,
  and `CatalogReplaced` goes out again only after a sync round, an
  import, an endpoint confirmation or a catalog write. Nothing runs a
  round at startup.
- Scenario: device A marks server S read-only and protects container
  `db`. Device B (already synced, management on for S) is restarted. Until
  the user presses Sync, B's engine takes actions on S and `db` is not a
  protected target. If the startup `ServerPrefsChanged` is lost too (the
  engine reads a local file while the plugin initialises), a later
  `CatalogReplaced` sets `_syncing` but `_prefs` stays empty for the whole
  run, and `setServerSafety` then builds the next record from
  `const ServerPrefs()` (`safety_controller.dart:150-156`), replacing the
  synced record's other fields (cadence, pinned units and containers,
  panel order, scan dirs).
  If only the fleet is lost and the prefs arrive late, `_keepLeaving`
  (line 279) copies each record into `settings.json` as if the server had
  stopped syncing; the next fleet migrates that copy back, which can
  resurrect a mark or a read-only switch another device removed.
- Also affected: `SyncController`/`OperationsController` miss nothing at
  startup today, but any event the engine adds to its start will be lost
  the same way; the Safety tab and the server header show the wrong
  switches meanwhile.
- Fix: do every engine-independent await before the spawn
  (`LocalSystemNotifications.start`, `readAppVersion`,
  `UrlHandOffLauncher.probe`), so no `await` sits between
  `IsolateEngineClient.spawn` and `runApp`. Add a source contract test
  (as `architecture_contract_test.dart` already reads `main.dart`) that
  fails on an `await` between the spawn and the last controller, and a
  test with the real engine that a `ServerPrefsController` built as
  `main` builds it reports `syncs()` for a synced server. A sturdier
  variant: have the client replay the startup batch to every listener
  that subscribes before the first frame, or have `ServerPrefsController`
  ask for the prefs (`ReadServerPrefs`) instead of depending on arrival
  order.
- Size S (reorder + tests). Confidence: high for the lost fleet (measured),
  high for the policy consequence (read from code), medium for which of
  the two sub-cases a given machine hits.
- Docs: 03 §6711 and D59 say "only the first listener gets it", which
  describes held events; the real constraint is "no await between spawn
  and the last controller", and nothing states it.

## CTL-02 (bug, drift) MEDIUM: the app never sends `Shutdown`; the engine's clean stop is dead code in production

- Where: no call of `EngineClient.shutdown()` anywhere in `lib/`
  (`grep -rn "shutdown\b\|Shutdown" lib` is empty);
  `ui/actions/quit_guard.dart` answers the exit question and nothing else;
  engine `engine_isolate.dart:2444-2459`.
- What: the engine's `Shutdown` handler flushes the history buckets still
  filling, waits for capability-cache writes, and ends open container
  shells so their `TerminalClosed` and audit records are written
  ("so their TerminalClosed and audit records are not cut off by
  Isolate.exit"). On quit the process just exits and the isolate dies
  with it.
- Scenario: quit with a container shell open (the quit guard asks, the
  user confirms): no terminal-closed audit record, and the last partial
  history bucket of every sampled server is lost on every quit.
- Fix: in `AppQuitGuard._requestExit` (and the window lifecycle's close
  path, and Android/iOS `detached` where reachable) `await
  engine.shutdown()` after the confirmation and before answering
  `AppExitResponse.exit`; the client already bounds it at 2 s. Test: a
  fake engine records `Shutdown` when the guard answers exit.
- Size S. Confidence high (absence verified by grep; engine comment
  states the intent).

## CTL-03 (bug) MEDIUM: Docker state survives an endpoint change; the engine drops the watches, the app keeps their ids and the old machine's lists

- Where: `controllers/docker_controller.dart:1043-1191` (no
  `EndpointChanged` case; `CatalogReplaced` only removes servers that left);
  compare `controllers/monitoring_controller.dart:781-788`
  (`_readings[serverId]?.clear()`); engine
  `engine_isolate.dart:909-921` (`docker..forget(forgotten)`, where
  `forgotten` includes `moved` ids and imports whose endpoint differs) and
  `docker/docker_router.dart:532-539` (`forget` ends the session and its
  watches).
- What: when a synced server's endpoint changes (`EndpointChanged`) or an
  import is re-pointed, the engine ends the server's Docker session and
  every `DockerWatch`. `DockerController` keeps `watchId`,
  `summaryWatchId`, `imagesWatchId`..., the view counts, and the lists,
  images, volumes, stacks, usage histories and `diskUse` read from the old
  machine. `_syncSummary` then never re-sends
  (`if (server.summaryWatchId != null || _stopped) return;`, line 315),
  and `_watch` is only called by the first view, `showStatsFor` on a
  changed row set, or a retry.
- Scenario: a workspace is open on S; a sync moves S to another host; the
  user confirms the endpoint; the link comes up. The Overview's Docker
  summary and unhealthy list still show the old host's containers and do
  not update until the panel is remounted; `diskUse` stays too when both
  hosts use `/var/run/docker.sock` (it resets only on a different socket
  path, line 1081-1086), so OV-05 shows the old host's disk use as the
  new host's.
- Fix: handle `EndpointChanged` (and, for imports, a `CatalogReplaced`
  whose entry has a different `user@host:port + jumpRoute` key, the same
  key `FleetServer._endpoint` builds) by resetting the `_DockerServer` in
  place: keep the notifiers and view counts, clear every list, `usage`,
  `diskUse`, `engine`, `compose`, null the watch ids and query ids, end
  `fileReads` with `notInFleet`, mark inspected containers; then re-send
  the watches for the views still counted once the link rises. Add a
  controller test beside the monitoring one
  (`monitoring_controller_test.dart:561`).
- Size M. Confidence: high that the state and watch ids are kept and the
  engine's are dropped; medium on how long a user sees it (tab switches
  remount most panels).

## CTL-04 (bug) MEDIUM: a sign-out leaves the removed servers' safety entries in `settings.json` and the Safety tab, and a later sign-in pushes them back

- Where: `controllers/safety_controller.dart:279-311` (`_keepLeaving`),
  `316-340` (`_migrate`); engine `engine_isolate.dart:1075-1076`
  (`CatalogReplaced` goes out before `sendServerPrefs`).
- What: on sign-out the fleet without the account's servers arrives
  first. `ServerPrefsController` notifies (its syncing set changed) while
  `_prefs` still holds every record, so `_keepLeaving` sees "a record the
  engine still reports but which no longer syncs" for every removed server
  and copies its read-only switch and marks into `_local`, then saves
  `settings.json`. The `ServerPrefsChanged(null)` events arrive after.
- Scenario: sign out with three synced servers that have marks. The
  Safety tab (and the settings window's `labels` snapshot,
  `settings_window_host.dart:272-274`) now lists three entries labelled by
  raw UUID (`labelOf` falls back to the id), `settings.json` keeps the
  mark names of an account the device left (decision Q2 removes sync-only
  servers and their cached data), and signing in again makes `_migrate`
  merge the stale copies into the records and push them, undoing changes
  made on other devices meanwhile.
- Fix: keep a leaving server's record locally only while the fleet still
  lists the server (excluded from sync); when the id left the fleet, drop
  it from `_local` instead. `SafetyController` needs the fleet ids for
  that (pass a `listed(id)` callback next to `labelOf`). Tests: sign-out
  leaves no entry; exclusion keeps it.
- Size S/M. Confidence medium-high (event order read from the engine,
  not run).

## CTL-05 (bug) MEDIUM: id-carrying reads stay pending when the engine answers with a `RequestRejected`

- Where: `controllers/monitoring_controller.dart:462-469, 573-580, 747-823`
  (no `RequestRejected` case); `controllers/admin_controller.dart`,
  `controllers/operations_controller.dart:238-258` (`readAudit`,
  `readEditable`), `controllers/engine_reads.dart:62-66`; engine
  `engine_isolate.dart:1316-1322` and the catch-all at `2600-2612`.
- What: the engine rejects `HostQuery` for a server outside its fleet with
  `reject(message, 'no fleet server $serverId')`, and every handler that
  throws answers `RequestRejected(name, 'engine error: ...')`. Neither
  carries the request id. `MonitoringController.queryHost` does not check
  `_listed(serverId)` and keeps the completer in `_hostQueries` until the
  engine stops, so the caller's `await` never returns. The same holds for
  every per-id completer map (`_unitQueries`, `_redactions`, `_tlsChecks`,
  admin's five read maps, `EngineReads._pending`, `_editReads`,
  `_auditReads`) whenever a handler throws.
- Scenario: a sync round removes server S while its Logs panel asks for
  `/var/log` files (`ui/logs/logs_panel.dart:493`) or Processes reads a
  detail: the spinner never ends. `redactLines` pending means a log
  export never finishes.
- Fix: (1) app: answer no-link at once for an unlisted server in
  `queryHost`/`queryUnit`; (2) protocol: give `RequestRejected` an
  optional `requestId` filled from the request where it has one (one
  `requestIdOf(EngineRequest)` switch in the engine), and settle the
  matching completer in one shared helper; (3) fold the hand-written
  completer maps into `EngineReads` (see CTL-12), so the handling exists
  once.
- Size M. Confidence high for the `HostQuery` reject path, medium for how
  often handlers throw.

## CTL-06 (bug) MEDIUM: raised-alert notifications are never withdrawn when the run ends

- Where: `controllers/alert_notifications.dart:40` (no `onDone`),
  `114-115` (`Object.hash(ruleId, serverId)`), `services/system_notifications.dart`
  (no `cancelAll`), `controllers/app_badge.dart:16-20` (the badge alone is
  reset at start).
- What: alerts last one engine run. `AlertCenter._onEngineDone` clears
  them, and the badge controller sends 0 at start "which clears a badge a
  previous run left". The notifications themselves are only cancelled by a
  clear event in the same run; ids come from `Object.hash`, which is not
  stable across runs, so a later run cannot withdraw them either.
- Scenario: CPU alert raised, notification posted, user quits (or the
  engine dies). The notification centre on macOS, iOS and Android keeps
  "CPU high on S" with no app state behind it, indefinitely.
- Fix: `SystemNotifications.cancelAll()` called once at start (beside the
  badge reset) and from an `onDone` handler; or derive the id from a
  stable hash (FNV-1a over `ruleId\0serverId`) so clears survive a
  restart. Extend `alert_notifications_test.dart`.
- Size S. Confidence high.

## CTL-07 (refactor) MEDIUM: split `docker_controller.dart` (1787 lines)

The file holds four things: the wire-facing controller, six near-identical
view-counted watches, seven immutable list models, and the inspect
machinery. Concrete split, no behaviour change:

1. `controllers/docker/docker_lists.dart` (about 300 lines): the value
   types `DockerContainerList`, `DockerImageList`, `DockerVolumeList`,
   `DockerNetworkList`, `DockerEventList`, `DockerStackList`,
   `DockerDiskUse`, `DockerContainerDetails`, plus `_takeList`,
   `_waitedOnEndpoint`, `_sameEndpoint`, `_rowChanged` as library-private
   or `@visibleForTesting` functions. Image, volume and network lists are
   the same class three times (lines 1361-1449); one generic
   `DockerWatchedList<T>` with a payload extractor replaces them.
2. `controllers/docker/view_watch.dart` (about 80 lines): one
   `_ViewWatch` (view count, watch id, id prefix, the `lists` set) with
   `add()`, `remove()`, `retry()`, `reset()`. It replaces
   `watchImages/unwatchImages/retryImages/_watchImages/_unwatchImages`
   and the same five methods for volumes, networks, events and stacks
   (lines 344-391 and 477-677: about 250 lines that differ only in a field
   name, a prefix and a set), and the ten fields in `_DockerServer`
   (1721-1749). The containers watch (stats) and the summary watch
   (endpoint-gated) become two small subclasses or flags. This is also
   where CTL-03's "reset and re-send on endpoint change" lands once
   instead of seven times.
3. `controllers/docker/container_inspects.dart` (about 250 lines):
   `_InspectedContainer`, `openContainer`, `closeContainer`,
   `retryContainer`, `_inspect`, `_takeInspect`, `_followInspected`,
   `_inspectAfterFailure`, `_keepShownDetails`, `_leftFleet`.
4. `controllers/docker/docker_one_shots.dart`: `_ask` and its eight
   callers over `EngineReads<DockerPayload>` (the query id prefix
   `stack-file-` is used for every one-shot today, line 463).
5. `docker_controller.dart` keeps the endpoint/engine/compose state, the
   choice and program sending, `_onEvent` dispatch and `_DockerServer`
   (about 500 lines).

Size L (mechanical), covered by the 54 tests in
`docker_controller_test.dart`. Confidence high.

## CTL-08 (refactor) MEDIUM: split `monitoring_controller.dart` (1206 lines)

`MonitoringController` is at once the façade that owns ten sub-concerns,
the link/view/subscription bookkeeping, four one-shot read maps, the
background-pause banner and the per-server readings. Concrete split:

1. `controllers/monitoring/server_readings.dart` (about 250 lines):
   `_ServerReadings`, `_HistoryGapSource`, `MetricSeries`,
   `chartGapReasonOf`, `sampleAge`, `SamplingStatus`. It is already a
   closed class with one caller; make it library-visible with a narrow
   API. This also lets `PowerWaits` and tests use it without the engine.
2. `controllers/monitoring/freshness_clock.dart`: `_FreshnessClock`.
3. `controllers/monitoring/pending_refresh.dart`: `_PendingRefresh` and
   `kRefreshWait`.
4. `controllers/host_reads.dart`: `queryHost`, `queryUnit`, `redactLines`,
   `checkTlsEndpoints` over four `EngineReads` (they need nothing of the
   controller but the engine; today they add four maps, four counters and
   four loops in `_onEngineDone`, lines 255-267 and 869-886). Callers go
   through `monitoring.hostReads`, as they already do for
   `monitoring.packages`, `.accounts`, `.diskUsage`.
5. `controllers/monitoring/background_pause.dart`: `BackgroundPause`,
   `_notePause`, `_forgetPause`, `_pausedServers` as a small notifier fed
   the activity and the sampling phases.
6. `monitoring_controller.dart` keeps views, links, subscriptions,
   cadence, activity, fleet following and event dispatch (about 450
   lines).

Further, `MonitoringController` is used as a service locator
(`monitoring.docker`, `.logs`, `.terminals`, `.forwards`, `.jobHistory`,
...): ten controllers with their own engine subscriptions are created in
its constructor and reached through it by the UI and by `main`
(`monitoring.terminals.shells`, `main.dart:408`). Moving their
construction to `main` and passing them through scopes (as `operations`,
`admin`, `alerts` already are) removes the coupling; that part is L and
optional.

Size M for 1-5. Confidence high.

## CTL-09 (bug) LOW: a wait in `PowerWaits` listens to a notifier the monitoring controller may dispose

- Where: `controllers/power_waits.dart:140-150`
  (`core.addListener(onCore)` on `monitoring.sampleFor(serverId, core)`),
  `controllers/monitoring_controller.dart:838-842` (`readings.dispose()`
  when the server leaves the fleet).
- Scenario: reboot S, then S leaves and re-enters the fleet during the
  wait (sign out and in, or a re-import). The wait holds the disposed box;
  the new readings are in a new `_ServerReadings`, so the wait never sees
  the later boot and ends as `notBack` after 15 minutes although the
  server is up. Related: `sampleFor` on an unlisted id creates a fresh
  `_ServerReadings` that stays until the next fleet (`_server` is
  `putIfAbsent`).
- Fix: `PowerWaits` resolves the listenable on each fleet change (listen
  to the fleet, re-attach), or drops waits of servers that left.
- Size S. Confidence medium.

## CTL-10 (bug) LOW: one rejected `OpenTerminal` or `TestServerConnection` fails every pending one

- Where: `controllers/container_terminals.dart:234-245`,
  `controllers/server_editor_controller.dart:137-142`; engine
  `engine_isolate.dart:1355-1358` (`reject(message, problem)` for one
  open), `1536` (`'invalid draft'` for one test).
- What: both comments say the only rejection is "links are off", which
  rejects all alike. The engine also rejects a single request for its own
  reason; the app then ends every shell still opening, or every test in
  flight. Rare (two opens in flight at once), but the comments are wrong.
- Fix: with CTL-05's `requestId` on `RequestRejected` (the terminal id,
  the test's request id), settle only that one.
- Size S. Confidence medium.

## CTL-11 (bug) LOW: `RecoveryController`'s 20 s wait reports failure while the engine goes on

- Where: `controllers/recovery_controller.dart:40, 171-195`.
- What: `_request` times out after 20 s, removes the pending id and throws
  `failed`; the engine request is not cancelled. A `SetRecoveryCode` or
  `RestoreVault` that takes longer (a keystore read waiting on the app
  lock, a large vault on a phone) still completes: the vault is restored
  or the code saved while the UI says it failed, and `_configured` keeps
  its old value because the late `RecoveryStatus` finds no pending entry.
- Fix: on a late answer for a timed-out id still apply the status
  (`_applyConfigured`) and, for restore, surface "finished after all"; or
  drop the timeout for the two mutating requests and rely on
  `_onEngineDone`.
- Size S. Confidence medium (timing not measured).

## CTL-12 (refactor) LOW: three hand-written copies of the request-id completer pattern beside `EngineReads`

- Where: `controllers/engine_reads.dart` (the shared helper, used by six
  read concerns); hand-written again in `monitoring_controller.dart`
  (four maps), `admin_controller.dart:22-36, 75-170, 212-244` (five maps,
  five `_no...Link` factories, five loops), `operations_controller.dart`
  (`_editReads`), `server_editor_controller.dart` (three maps),
  `alert_rules_controller.dart` and `server_prefs_controller.dart` (the
  same `_writes`/`CatalogWritten`/`CatalogWriteRefused` code twice).
- Fix: `AdminController`'s five reads become five `EngineReads`
  (about 150 lines less); one `CatalogWrites` helper serves the rules,
  prefs and server editor. This is where CTL-05's rejection handling
  should live.
- Size M. Confidence high.

## CTL-13 (bug) LOW: stored Docker socket choices are purged for good when the startup fleet is incomplete

- Where: `controllers/docker_endpoint_choices.dart:118-134`
  (`_purgeAgainst` removes and calls `purge(endpoints)` on the first
  engine fleet); engine `catalog/engine_sync.dart:293-296` (`servers()`
  returns none when the directory is not held exclusively) and the
  import store's "none when the stores were empty or unusable".
- Scenario: one launch where the instance lock cannot be taken
  (`InstanceLockUnavailable`, the app "runs unguarded") or where
  `ssh_config_imports.json` is unreadable: the fleet lacks those servers,
  and every CN-09 socket and CN-16 program chosen for them is deleted from
  `settings.json`, although the servers are back at the next launch.
- Fix: skip the purge while `instanceLockIssue != null` or the engine
  reported a store issue; purge only ids whose endpoint changed, and ids
  that left after a fleet that listed them in this run.
- Size S. Confidence medium.

## CTL-14 (docs, drift) LOW: comments and scaffolding describe an engine restart that nothing performs

- Where: `app.dart:440-443, 742-787` (`_RemountOnChange`, "new
  controllers, an engine restart"), `main.dart:252-254`,
  `monitoring_controller.dart:145-150`, and the "the next one gets the
  name/switch/policy at its spawn" comments in `main.dart:563-566,
  578-581` and `services/stored_safety.dart:33-36`.
- What: the engine is spawned once (`main.dart:198`); no code builds a
  second client or new controllers, and when the isolate dies after
  startup no surface says so: every controller flips `_engineStopped`,
  reads answer no-link, and the window shows "disconnected" states with no
  explanation or restart offer (`EngineFailedApp` covers only a failed
  spawn). Either wire the restart the comments describe (a
  `ValueNotifier` of the controller set in `main`, rebuilt on
  `events.done`) or add an "engine stopped, restart Klabautermann" notice
  and delete `_RemountOnChange` and the restart wording.
- Size S (notice) or L (restart). Confidence high.

---

## Checked and found sound (no finding)

- Startup before `restoreMainWindow`: `lockInstanceFor`,
  `installMacosTitlebar`, `DeviceSettingsStore.open` and
  `restoreMainWindow` do not throw. Only
  `getApplicationSupportDirectory()` (`main.dart:109`) can, which would
  leave the macOS window hidden; very unlikely, not listed.
- Settings window branch: runs before the lock, `settings.json` and the
  spawn; `RemoteSettings` opens no store. Every `SettingsLinkMethod` has a
  `_handleCall` case and every snapshot key a decoder; the lock is checked
  before any call. `RemoteSettings.dispose` skips five of its notifiers
  (`_cadence`, `_cadenceCaps`, `_adminMemory`, `_logDisplay`,
  `_timeDisplay`), harmless since the window lives as long as the app.
- Instance guard: lock taken before any file; held, unavailable and phone
  cases map to the right `SupportDirectoryAccess`.
- Unattended dials cannot hit the keystore before
  `EngineKeystoreResponder` listens: vault credentials make a server
  ineligible for the monitor set.
- `PlanAction` always answers (engine catches planner throws), so
  `OperationsController._pending` cannot stick short of a hung link read.
- Sync pin-conflict FIFO matches the engine (only requests emit
  `PinConflictsChanged`; `pinConflicts()` never throws).
- Badge logic matches decision Q3; `FleetController` settles import and
  confirm on engine stop and dispose; `PersistedSetting` overlap was
  declined before and is not re-raised.

## Overall assessment

The controllers are careful about engine stop, dispose and fleet removal,
and the settings link is consistent. The one serious defect is in the
composition root, not in a controller: an `await` added after the spawn
silently removed the startup events from every controller built after it,
which disables synced safety switches until the first sync round
(CTL-01). The second theme is an endpoint change or a removal handled in
one controller and not in its neighbours (CTL-03, CTL-04, CTL-09). The
third is the missing clean shutdown (CTL-02). The two large files should
be split along the seams above; the watch duplication in the Docker
controller is the part that already costs correctness.

## Coverage

- Read fully: `main.dart`, `settings_window_app.dart`,
  `controllers/`: `monitoring_controller`, `docker_controller`,
  `fleet_controller`, `operations_controller`, `safety_controller`,
  `sync_controller`, `sync_sign_out`, `recovery_controller`,
  `power_waits`, `alert_center`, `alert_notifications`, `app_badge`,
  `admin_controller`, `admin_memory`, `server_prefs_controller`,
  `alert_rules_controller`, `snippets_controller`, `engine_reads`,
  `persisted_setting`, `docker_endpoint_choices`, `prompt_controller`;
  `services/`: `instance_guard`, `window_state`, `system_notifications`,
  `engine_keystore`, `stored_safety`, `app_version`,
  `settings_window/settings_window_host`.
- Skimmed: `app.dart` (lines 330-787 read, the constructor fields not),
  `container_terminals`, `log_streams`, `port_forwards`,
  `server_editor_controller`, `pin_publication_controller`,
  `settings_window/settings_window_link` (first 200 lines),
  `settings_window/remote_settings` (structure only), `recovery_files`
  (second half), `hand_off`, `ui/actions/quit_guard.dart`.
- Not reached: `attention`, `cadence_controller`, `threshold_controller`,
  `overview_layout`, `pinned_services`, `window_panes`, `workspace_dock`,
  `stack_folders`, `tls_endpoints`, `container_usage`, `container_columns`,
  `device_name`, `editor_display`, `log_display`, `time_display`,
  `fleet_density`, `monitor_set`, `appearance_controller`,
  `coverage_controller`, `announcement_controller`,
  `docker_notice_controller`, `sync_secrets_controller`, `account_size`,
  `log_reads` and the six small `*_reads` files, `ssh_config_source`,
  `stored_appearance`, and the tests beyond checking which files exist.
- Run: one scratch Dart script against the real engine for CTL-01 (kept
  outside the repository, since deleted). No test suite, no `pub get`, no
  repository change.
