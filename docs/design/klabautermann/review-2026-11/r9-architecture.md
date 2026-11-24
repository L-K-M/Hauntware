# r9 Architecture review: Klabautermann (prefix ARC)

Scope: cross-cutting structure of `/home/user/Hauntware/klabautermann`, by
grep, outlines and normalized diffs. No line-level bug hunt. Paths are
relative to the repository root unless they start with `app/` or
`packages/`, which are under `klabautermann/`.

Counts: high 0, medium 9, low 10 (19 findings).

## Boundary check results (what holds)

- App to `seance_core`: no `package:seance_core`, `dartssh2`,
  `klabautermann_host`, `klabautermann_docker` or `/src/` import anywhere in
  `app/klabautermann_app/lib` (only `seance_terminal` in
  `ui/docker/container_terminal.dart:8`, through its barrel, as the pubspec
  and `test/architecture_contract_test.dart` allow). Every
  `export 'package:...'` in `packages/klabautermann_core/lib/klabautermann_core.dart`
  has a `show` list; the seven exports without one are the package's own
  `src/` libraries.
- UI to engine: no file under `lib/ui` names `EngineClient`, `engine.send`
  or `engine.events`; all go through controllers. `dart:io` in `lib/ui` is
  limited to `server_editing.dart` (`Platform`), `startup_issue_notice.dart`
  (`File(path).uri` for a name) and `logs/log_export.dart` (ARC-19).
- `tool/guards.yaml:120` registers
  `engine_protocol: packages/klabautermann_core/lib/src/engine` with an empty
  callback-owner list, and `no_dart_io` covers `klabautermann_host/lib` and
  `klabautermann_docker/lib`; neither imports `dart:io` (two comment
  mentions only). `dart run tool/protocol_guard/bin/check.dart --product
  klabautermann` printed nothing after the Flutter banner (clean). The
  import guard could not run here: `Missing
  seance/.dart_tool/package_config.json` (not resolved, and `pub get` is
  forbidden by the brief), so the import-guard result is unverified.
- `protocol.dart` has no function-typed fields and no top-level logic apart
  from one private helper (`_sha256OfText`, line 3074).

## Findings

### ARC-01 (drift, medium, confidence high for the drift, medium for the user-visible effect)
**The SHARED.md ledger is stale: Séance's settings-window runners changed after the copy, and Klabautermann's copies lack the change.**

- `klabautermann/docs/SHARED.md` (last commit 2026-11-12) says of the
  settings window runners: "the files are unchanged at `2e61152e`", gives
  `f9bd1e1` as every source's last change, says "`flutter_window.{h,cpp}`
  now equal Séance's", and "A change to Séance's runners should reach both
  copies."
- Séance commit `85b48f21c` (2026-11-04, "Guard desktop quit requests")
  added `yieldForQuitConfirmation` / `restoreAfterQuitConfirmation` to all
  three runners. Normalized diffs (product names folded) of the copies
  against their sources, non-comment lines only:
  - `macos/Runner/SettingsWindow.swift`: Séance has
    `private var quitConfirmationSuppressed`, the two extra channel methods
    and `if !quitConfirmationSuppressed { window.makeKeyAndOrderFront(nil) }`;
    Klabautermann's line 53 is still `guard call.method == "open" else {`.
  - `linux/runner/settings_window.cc`: Séance has `window_hidden`,
    `quit_confirmation_suppressed`, the two methods, and passes `host` to
    `first_frame_cb`; Klabautermann shows unconditionally.
  - `windows/runner/settings_window.{h,cpp}`: Séance has `should_show_`,
    `YieldForQuitConfirmation()`, `RestoreAfterQuitConfirmation()`.
  - `windows/runner/flutter_window.cpp`: differs by Séance's
    `deep_link_scheme.h` and `MarkPrimaryDeepLinkWindow` (commit
    `35c2f20b6`); the ledger's "now equal" is no longer true. Klabautermann
    has no deep links, so this one is a ledger correction only.
- Unchanged and still identical after renames: the view controller `.h/.m`
  (comment-only differences), `Runner-Bridging-Header.h`,
  `AccessibilityLifecycleTest.mm`, `window_title.cc` (byte-identical),
  `window_title.h`, `flutter_window.h`, `MenuChecks.swift` (3 comment lines).
- Scenario: Klabautermann has the same guard
  (`app/klabautermann_app/lib/ui/actions/quit_guard.dart:12`, "Window close,
  application Quit and the Settings engine share one decision"), and its
  question is a dialog in the main window. With the Settings window in front
  and an operation running, Quit asks in the main window behind the Settings
  window; Séance fixed exactly that by hiding the Settings window while the
  question is open. Not verified on a desktop (manual check).
- Fix: port the three runner changes and the Dart side (Séance's
  `lib/services/app_quit_guard.dart` `QuitSettingsWindow` interface) into
  Klabautermann's `AppQuitGuard` and `settings_window_host.dart`; update the
  ledger rows (source commit `85b48f21c`, the `flutter_window.cpp`
  divergence). Poltergeist's copy lacks it too (`grep` finds the method only
  under `seance/`), which is a suite follow-up.
- Size M (three native files plus about 60 Dart lines and tests). Risk
  medium: only each OS's toolchain compiles the runners.

### ARC-02 (drift, medium, confidence high)
**Engine features the app never reaches; the CHANGELOG claims one of them.**

Word-level scan of every type declared in `protocol.dart` against
`packages/klabautermann_core/lib` and `app/klabautermann_app/lib`:

- `AnacronQuery` / `AnacronPayload` (`protocol.dart:808`, `:2640`), the
  engine handler (`jobs/job_history_query.dart:55`), the host script and
  command (`klabautermann_host/lib/src/commands/commands.dart:473`, `:1224`)
  and the barrel exports `AnacronJob`, `AnacronPeriod` exist, but no file in
  the app's `lib/` names any of them. `ui/jobs_panel.dart:313-320` sends only
  `TimerLastRunQuery` and `CronRunsQuery`. The UI text says so itself:
  `app_en.arb` "anacron runs this directory; its timing is not shown in this
  version." Yet `klabautermann/CHANGELOG.md:443` (Unreleased) says "Jobs:
  anacron jobs, timers' last runs and cron's run log", and 03 §7.x lists
  "anacron's table with each job's stamp (JOB-04)" as v1. STATUS.md has no
  anacron entry.
- `SocketsQuery` / `UnitSocketsPayload` (`protocol.dart:780`, SVC-10
  `list-sockets`), handled in `services/unit_queries.dart:76,93`, barrel
  export `UnitSocket`: never sent by the app.
- `TerminalEndInput` (`engine_isolate.dart:1367`), `DockerContainersQuery`
  and `DockerImagesQuery` (`docker_router.dart:971,986`): handled, never
  sent (the app uses watches for both lists).
- `HandleAlert`, `AlertsArrived`, `AlertStatusChanged`, `AlertDescriptor`,
  `AlertStatus`, `AlertAction`: declared v1.x, named by no library code;
  `HandleAlert` falls into the catch-all (ARC-05).
- Barrel names shown but used by neither the app's `lib/` nor its tests (15
  of 272): `AnacronJob`, `AnacronPeriod`, `DeviceSettingsWriter`,
  `EngineComponent`, `ExternalMonitorReport`, `ExternalMonitorUnit`,
  `LabelLinkSource`, `OnCalendarResult`, `PushPolicy`, `ReleaseAsset`,
  `SshdForwardingBlock`, `TimerDetail`, `UnitSocket`, `kImageUpdateFresh`,
  `kTlsDefaultPort`. 03 §3.2 says a `show` list "changes as a milestone
  wires types in or retires them".
- Fix: decide per item. For JOB-04 and SVC-10 either wire the UI or correct
  the CHANGELOG line and record them as open in STATUS. Delete
  `DockerContainersQuery` / `DockerImagesQuery` if the watches replaced
  them. Drop the 15 unused barrel names and add a contract test that every
  shown name has a user under `app/`.
- Size S for docs and barrel, M to L per wired feature. Risk low.

### ARC-03 (refactor, medium, confidence high)
**`docker_controller.dart` carries five copies of one ref-counted watch.**

`app/klabautermann_app/lib/controllers/docker_controller.dart:474-678`:
`watchImages/unwatchImages/retryImages/_watchImages/_unwatchImages` and the
same five methods for Volumes, Networks and Events. A diff with the nouns
folded shows only doc-comment wrapping and the `lists:` set differ
(`{DockerWatchList.X, DockerWatchList.containers}` versus `{events}`).
Stacks (`:344-392`) is the same shape. Each also has a
`<noun>Views` counter and `<noun>sWatchId` on `_DockerServer` (`:1722-1725`).

- Cost: about 250 lines, and every change to the watch rules (the
  `_stopped` check, the retry id) has to be made five times; Summary
  (`:283-334`) already differs in whether it waits for the endpoint.
- Fix: one private `_ListWatch` value on `_DockerServer` (views, watchId,
  id prefix, lists) with `watch`, `unwatch`, `retry`; the public methods stay
  as one-line forwards so the panels and tests are untouched.
- Size M. Risk low (controller tests cover each list).

### ARC-04 (refactor, medium, confidence high)
**The Docker list panels repeat one scaffold.**

`ui/docker/networks_panel.dart` (603 lines) and `volumes_panel.dart` (573)
differ in about 100 lines each after folding the noun (202 differing diff
lines in total): the state (`_sort`, `_search`, `_searchFocus`, `_filter`,
`_held`), `initState/didUpdateWidget/dispose`, `_sync/_release`, the
three-listenable `build`, the notices, the filter row, the wide table and
the narrow list are the same. `images_panel.dart:74-123,411-448` and
`containers_panel.dart:104-197,591-610` repeat the state and filter row;
`networks_view.dart` and `volumes_view.dart` repeat
`containersBy<Noun>`, `<Noun>Entry`, `<noun>Entries`, `<noun>Matches`.
`const double _wideWidth = 600;` is declared in nine panel files.

- Fix: a `DockerListPanel<E>` scaffold in `ui/docker/` taking the watch
  pair, the list listenable, columns, the narrow row builder, the filter
  chips and the header actions; move `_wideWidth` to `panel_kit.dart`.
  Networks and Volumes first (nearly identical), then Images; Containers
  keeps its own body (grouping, selection, stats) and takes only the
  search/filter/watch state mixin.
- Size L. Risk medium (widget tests per panel exist; semantics order must
  not change). Land after ARC-03 and ARC-12.

### ARC-05 (refactor, medium, confidence high)
**`engine_isolate.dart`: `engineMain` is one function from line 227 to 2611.**

All engine state is closure-local, `handle` is one `switch` from 1159 to
2475, and nothing in it can be unit-tested without spawning the engine.
Visible consequences:

- Five admin reads are the same 30 lines: `ReadUserCrontabs` (1860),
  `ReadSmart` (2047), `ReadRestarts` (2082), `ReadFirewall` (2112),
  `ReadSshdPosture` (2140): a local `fail`, `links?.link(serverId) == null`
  to `noLink`, `admin?.session` null to `adminRequired`, `admin?.touch`,
  `unawaited(lendSession(...).then(uiPort.send, onError: transport))`. The
  login-level reads repeat a second shape (`ReadAccounts` 1896,
  `ReadDiskUsage` 1925, `ReadTimerDetail` 2009, `ReadPackages` 2172,
  `UnitQuery` 2214, `JobHistoryQuery` 2253). The copies have already
  drifted: the login reads test `!fleetIds.contains(serverId)`, the five
  admin reads do not.
- `case EngineRequest():` at 2460 answers "not implemented yet (M1a
  scaffold)". `EngineRequest` is sealed, so this catch-all removes the
  compiler's exhaustiveness check: a new request compiles and is rejected at
  run time. Only `HandleAlert` reaches it today (`AnswerKeystore` is taken
  before the queue at 2579).
- Seven `@visibleForTesting` parameters on `engineMain` (227-237) are the
  only seam.

Ordered split, public API (`engineMain`, `EngineStart`) unchanged:
1. Replace the catch-all with `case HandleAlert():` (S, no behaviour
   change; the existing `engine_isolate_test.dart:93` still passes).
2. Two local helpers, `adminRead` and `linkRead`, taking the report
   constructor for a failure and the read body; fold the eleven handlers
   (M; decide deliberately whether admin reads gain the fleet check).
3. Move the composition (lines 240-800: stores, links, routers, trackers)
   into an `EngineServices` class in `engine/engine_services.dart`, fields
   instead of closure locals (L, mechanical but wide).
4. Split `handle` into per-area handler files that take `EngineServices`:
   `handlers/catalog.dart` (ImportSshConfig to RemoveRule, 1394-1578),
   `handlers/actions.dart` (PlanAction, RunAction, CancelAction,
   ReadEditable, AuditQuery, 1580-1840 and 2394-2443),
   `handlers/reads.dart` (1841-2290), `handlers/sync_recovery.dart`
   (1470-1506, 2302-2372), leaving sampling, logs, Docker and terminals
   routing in `engine_isolate.dart` (L).

Risk medium to high for steps 3 and 4 (ordering of side effects inside one
isolate turn); steps 1 and 2 are low. Nothing else should touch this file
while 3 and 4 are open.

### ARC-06 (refactor, medium, confidence high)
**`protocol.dart` (7,959 lines, 456 declarations) with a split that keeps the API.**

`EngineRequest` has 75 direct subtypes and `EngineEvent` 68; Dart requires
a sealed class's direct subtypes in the same library, so those two families
can only be split with `part` files. The protocol guard resolves each file
(`tool/protocol_guard/lib/protocol_guard.dart:77`, `getResolvedUnit`) and
requires subtypes under `src/engine/`, so parts in `src/engine/protocol/`
satisfy it; run its tests when doing step 2, since no Klabautermann library
uses `part` today.

Order:
1. Independent sealed families and their value types move to their own
   libraries under `src/engine/protocol/`, re-exported from `protocol.dart`
   (no `part` needed, importers unchanged):
   `logs.dart` (4628-5010: `LogSource`, `LogRecord`, `LogStreamStatus`),
   `docker.dart` (5011-6168: `DockerQuerySpec`, `DockerPayload`,
   `DockerTimelineEntry`, `StackVerdict`, `DockerEndpointChoice`, details),
   `actions.dart` (6169-6820: `ActionIntent`, `EditTarget`, safety),
   `prompts.dart` (6822-7040), `links.dart` (7042-7250), `sync_keystore.dart`
   (7251-7490), `sampling.dart` (7492-7959), `host_queries.dart`
   (`UnitQuerySpec`, `JobHistorySpec`, `HostQuerySpec` and their payloads,
   756-975 and 2563-2850). About 4,500 lines leave the file. Size L,
   risk low (moves only; the round-trip tests in `protocol_test.dart` and
   the guard prove it).
2. `part 'protocol/requests.dart'` (378-1776 minus what step 1 took) and
   `part 'protocol/events.dart'` (1780-4600), leaving the version constant
   and the two sealed roots in `protocol.dart`. Size L, risk low to medium
   (guard and analyzer behaviour with parts to be confirmed first).

Land step 1 before ARC-05 steps 3 and 4 and before any feature PR that adds
protocol types, or rebase pain is certain.

### ARC-07 (refactor, medium, confidence high)
**Request/answer correlation is still hand-rolled in six controllers beside `EngineReads`.**

`controllers/engine_reads.dart` (from #763) owns the pattern for seven
reads. The same bookkeeping (pending map, counter, `_engineStopped`,
`StateError` on send, complete all on done, cancel in `dispose`) is written
out again in:

- `alert_rules_controller.dart:32-97` and `server_prefs_controller.dart:36-108`:
  the `CatalogWritten` / `CatalogWriteRefused` pair, identical except for
  the exception type; `server_editor_controller.dart:37-39,56-78,127-129`
  has three more maps of the same kind.
- `monitoring_controller.dart:264-265,473-494,751-754,879-886`
  (`_redactions`, `_tlsChecks`, plus `_hostQueries`),
  `operations_controller.dart:79,92`, `recovery_controller.dart:54`,
  `sync_controller.dart:228`, `docker_controller.dart:1756` (`fileReads`).
- `_engineStopped` is tracked in eleven controllers; twenty files listen to
  `engine.events`.

The copies differ in the edge that matters: `EngineReads` and the two write
controllers catch `StateError` per request, `MonitoringController._send`
(738-745) treats it as engine-stopped for everything.

- Fix: let `EngineReads<A>` complete with an error as well as a value (or
  add a sibling `EngineWrites` over `CatalogWritten`/`CatalogWriteRefused`
  taking the exception factory), then replace the maps in the two write
  controllers and the server editor, then monitoring's two, each in its own
  commit. Public controller API unchanged.
- Size M. Risk low to medium (each controller has tests; the stop
  semantics must be chosen per controller, not unified silently).

### ARC-08 (refactor, medium, confidence high; suite-level, earlier deferred, not declined)
**`ui/editor_strings.dart` is a 927-line file that exists three times.**

`klabautermann/app/klabautermann_app/lib/ui/editor_strings.dart`,
`poltergeist/app/poltergeist_app/lib/ui/editor_strings.dart` and
`planchette/app/planchette_app/lib/ui/editor_strings.dart` are identical
after folding the class name (0 differing lines), and each app's ARB carries
the same `editor*` keys (about 2,800 ARB lines per the earlier s09 audit).
The earlier wave deferred it as "no ARB-backed shared adapter"
(STATE.md:136). Every editor string change now needs three ARB edits, three
regenerations and three adapters, and nothing checks that they agree.

- Fix: give `planchette_editor` its own gen-l10n catalog and
  `LocalizationsDelegate` (the package already owns the English defaults in
  `EditorStrings`), have `EditorStrings.of(context)` read it, and delete the
  three adapters and the `editor*` ARB keys. Each app adds one delegate.
- Size L (three apps, the l10n contract tool, generated files). Risk
  medium. Independent of every other item; do it as its own suite PR.

### ARC-09 (refactor, medium, confidence high)
**Docker mutations have two definitions; the package's one is unused.**

`packages/klabautermann_docker/lib/src/endpoints.dart` defines
`startContainer` (174), `stopContainer` (186), `restartContainer` (200),
`pauseContainer` (214), `unpauseContainer` (226), `killContainer` (239),
`removeContainer` (255) and `removeImage` (442). No file under any `lib/`
calls them (`stop/restart/pause/unpause/removeImage` have no caller at all;
`start/kill` only `endpoints_test.dart`). The engine builds the same
requests as plan steps by hand, for example
`packages/klabautermann_core/lib/src/operations/plans/docker_plans.dart:112`
`path: _path(c, '/containers/${container.id}/${intent.verb.name}')`, also
`:185,190,282,333,702,707,912`.

- Cost: the tested path and query rules (the `t=` timeout, `force`,
  `noprune`) are not the ones that run, so `endpoints_test.dart` gives no
  assurance about what a confirmed action sends.
- Fix: either delete the eight methods and their tests, or better, have the
  package expose the request as data (`DockerRequestSpec stopContainer(id,
  {timeout})` returning method, path, query) that both the plan preview and
  the client use.
- Size M. Risk low for deletion, medium for the shared spec (plan
  fingerprints must not change).

### ARC-10 (docs, low, confidence high)
**The stated protocol and barrel rules no longer match the code.**

- `klabautermann/AGENTS.md:103-106`: "Engine protocol types carry no
  function-typed fields and no `seance_core` or dartssh2 types."
  `protocol.dart:85` imports `seance_core` `show DangerFinding, Snippet`;
  `SnippetsChanged.snippets` is `List<Snippet>` (4320) and the action
  preview carries `List<DangerFinding>` (6786). The protocol guard checks
  function-typed fields and subtype location only, so nothing enforces the
  second half.
- `docs/design/klabautermann/03-ARCHITECTURE.md:1857-1872`: the barrel
  "re-exports exactly one `seance_core` name" and "no `seance_core` type
  crosses the isolate boundary (D18)". The barrel now has 13 `seance_core`
  export statements showing 28 names.
- Fix: correct both texts to the rule that is actually kept (plain,
  sendable data; `seance_core` value types allowed when the barrel shows
  them), or map `Snippet` and `DangerFinding` to protocol-owned types if
  the stricter rule is wanted. Size S (docs) or M (mapping). Risk low.

### ARC-11 (docs, low, confidence high)
**Stale scaffold-era comments in `engine_isolate.dart`.**

- `:143-144` on `EngineStart.linksEnabled`: "The app's composition root
  leaves them off; tests turn them on." `app/klabautermann_app/lib/main.dart:200-201`
  passes `linksEnabled: true, probesEnabled: true`.
- `:209-212` in `engineMain`'s doc: "a [PlanAction] gets [ActionRefused]
  until its planner lands and a [RunAction] because no plan is held yet ...
  every other 03 §10.1 row gets [RequestRejected] until its milestone
  lands." Both are implemented (1580-1775, 2396-2443).
- `:2463` the rejection text `'not implemented yet (M1a scaffold)'`.
- The 60-line doc comment (173-226) restates the whole protocol in one
  sentence and will keep going stale; replace it with a pointer to 03 §10.1.
- Size S. Risk none. Fold into ARC-05 step 1.

### ARC-12 (refactor, low, confidence high)
**Shared widgets live inside the largest feature files.**

- `PanelSection` and `PanelNotice` are declared at
  `ui/system_panel.dart:838,923`; 22 files import `system_panel.dart`.
- `DockerNotice` (`ui/docker/containers_panel.dart:1755`),
  `ContainerHealthBadge` (1351), `ContainerStateBadge` (1523) and
  `containerStateText` (1233) are imported by 14 files, including
  `ui/edit/remote_editor.dart:26` and `ui/palette.dart:14`, which pull in
  the whole containers panel for one widget or one function.
- Fix: move the first pair to `ui/panel_kit.dart` (which already holds
  `TitledGroup`), the Docker ones to `ui/docker/docker_cells.dart`, and
  keep `export ... show` lines in the old files for one release so tests
  need no change. This is also step 1 of the two panel splits below.
- Size S to M (moves). Risk low. Land first among the UI items.

### ARC-13 (structure, low, confidence high)
**Ordered splits for the remaining oversized files.**

- `ui/docker/containers_panel.dart` (1,777): after ARC-12, move
  `_columns`/`_shownColumns` and the cell widgets (`_StatusCell`,
  `_Figure`, 952-1180 and 1607-1690) to `container_table_columns.dart`;
  `_ColumnsDialog` (1397-1478) to `container_columns_dialog.dart`;
  selection (`_selectionBar`, `_toggleProject`, `_GroupHeading`,
  `_Selectable`, `_GroupSelection`) to `container_selection.dart`. The
  panel keeps state, build and the list. Size M, risk low.
- `ui/overview_panel.dart` (1,734): `_Cards` (1168-1588: cpu, slowness,
  pressure, load, memory, network, swap) to `overview_metric_cards.dart`;
  `_PartTwo` (764-1137: health, disks, host) to `overview_state_cards.dart`;
  `_Docker`, `_DockerSummaryWatch`, `_DockerCard`, `_UnhealthyContainers`
  (433-758) to `overview_docker_card.dart`; `_Facts`, `_IconLine`,
  `_valueStyle`, `_CoreBars` to `overview_parts.dart` (three files also
  declare a private `_Facts`). Size M, risk low.
- `packages/klabautermann_core/lib/src/docker/docker_router.dart` (1,674):
  endpoint resolution (`_resolve`, `_retryLater`, `_pool`,
  `_relayConnection`, 632-918) to `docker_endpoint_resolver.dart`; the
  query dispatch `switch` (920 onward, one case per `DockerQuerySpec`) to
  `docker_queries.dart` as functions over `DockerClient`. `DockerRouter`
  keeps sessions, watches and logs. Size L, risk medium.
- `packages/klabautermann_host/lib/src/commands/commands.dart` (1,646): the
  first 510 lines are markers, exit codes and embedded scripts for a dozen
  unrelated reads. Move them beside their parsers by area
  (`commands/process_commands.dart`, `journal_commands.dart`,
  `cron_commands.dart`, `network_commands.dart`, `firewall_commands.dart`),
  keep `HostCommands` as the facade whose static methods forward, and
  re-export the constants from `commands.dart`. Size L, risk low
  (golden command tests exist).
- `controllers/docker_controller.dart` (1,787): ARC-03 removes about 250
  lines; then move the container inspection and stats pinning (734-900) to
  a `ContainerInspections` part object owned by the controller. Size M.

### ARC-14 (refactor, low, confidence high; suite-level)
**Small pieces that exist once per product and belong in a shared package.**

- `app/klabautermann_app/lib/controllers/persisted_setting.dart`
  (`PersistedSetting<T>`, five subclasses) and
  `poltergeist/app/poltergeist_app/lib/services/persisted_value_controller.dart`
  (`PersistedValueController<T>`) are the same apply-then-save
  `ChangeNotifier`; Klabautermann's also retries a failed save. One base in
  `ghost_ui` (Klabautermann's, as the superset). Size M, risk low.
- `HttpSyncTransport` / `httpSyncTransport` / `SyncTransportFactory`:
  `packages/klabautermann_core/lib/src/catalog/engine_sync.dart:81-105` and
  `poltergeist/app/poltergeist_app/lib/services/sync_transport.dart:15-60`
  are the same marker subclass of `HttpSyncClient`. Belongs beside
  `HttpSyncClient` in `seance_core`. Size S.
- Six serial write tails inside `klabautermann_core`
  (`engine_vault.dart:92-103`, `audit_log.dart:65,196-200`,
  `sync_state_file.dart:101,253-260`, `device_settings_store.dart:214,1043-1053`,
  `capability_cache.dart:172,351-363`, `history_store.dart:272`), each the
  same three lines (`_tail.then(body)`, swallow the error for the next,
  return the caller's future). A `SerialQueue` with `run<T>` and `idle` in
  core removes the repetition and the chance of one copy forgetting the
  `onError`. Size S to M, risk low.
- Local repeats: `_retryBase`/`_retryCap` in `docker/container_logs.dart:49`
  and `docker/docker_watch.dart:79` (same values), `_commandNotFound = 127`
  in `admin/smart.dart:17` and `services/timer_detail.dart:19`,
  `_detailLimit = 500` in `jobs/job_history_query.dart:25` and
  `services/unit_queries.dart:27`, `_maxInstantUs` in
  `klabautermann_host/lib/src/parse/timers.dart:330` and `journal.dart:73`.
  Size S.

### ARC-15 (refactor, low, confidence medium; suite-level)
**Klabautermann has the suite's second, fuller ssh_config reader.**

`packages/klabautermann_core/lib/src/fleet/ssh_config_settings.dart` (1,346
lines) implements `ssh -G` resolution (`Host`/`Match` blocks, pattern
lists, quoting, canonicalization, two passes) and repeats constants from
Séance's importer (`_servicePorts`, `_decimal`, `_minimumPort`,
`_maximumPort`; compare `seance/packages/seance_core/lib/src/ssh_config/ssh_config_import.dart:107-119`,
382 lines). 03 §4.x records it as deliberate for Klabautermann. Séance and
Poltergeist import the same file through the simpler reader, so the three
products can resolve one `~/.ssh/config` differently.

- Fix: move the resolver into `seance_core/src/ssh_config/` and let
  `SshConfigImporter` use it. Owner decision, since it changes what the
  siblings import. Size L, risk medium.

### ARC-16 (refactor, low, confidence high)
**Three notice widgets remain.** `StateNotice` (`ui/state_notice.dart`),
`DockerNotice` (composes it) and `PanelNotice` (`system_panel.dart:923`).
The earlier dedup declined folding `PanelNotice` because it shows an empty
detail where the others hide it, and called it "worth a follow-up decision".
Not re-raised as a fold; the open point is only that the decision is still
unmade, and ARC-12's move is the moment to make it. Size S.

### ARC-17 (test, low, confidence high)
**Nothing checks the SHARED.md ledger or the barrel against the code.**
ARC-01 and ARC-02 both went stale silently.
`test/settings_window_runner_test.dart` and `test/macos_runner_test.dart`
check Klabautermann's wiring, not equality with the source. A small root
script (rename-folding diff of each ledgered pair, allowed-divergence list
in the ledger) run by `scripts/build.sh --check`, and a contract test for
unused barrel names, would keep both honest. Size M, risk low.

### ARC-18 (structure, low, confidence medium)
**`remote_settings.dart` (998 lines) is nineteen `Remote*` mirror classes**
(`services/settings_window/remote_settings.dart`: `RemoteAppearance`,
`RemoteSafety`, `RemoteCadence`, ... `RemoteRecovery`), each a
`ChangeNotifier` that applies a snapshot and forwards a write over the link.
Poltergeist's file has the same shape (694 lines, 254 differing lines for
the two classes both products have). The link engine is already shared in
`ghost_desktop`; a generic `RemoteValue<T>` there (key, decode, encode)
would shrink both files. Not read in full; size L, risk medium. Lowest
priority.

### ARC-19 (refactor, low, confidence high)
**A plugin-backed service sits in `lib/ui`.**
`ui/logs/log_export.dart:36-125` (`markSavedExport`, `stageMarkedExport`,
`PluginLogExportHost`) uses `dart:io`, `file_picker`, `share_plus` and
`path_provider` directly. The interface is right; the implementation
belongs in `lib/services/` (the repository rule: UI uses application
services for files). Size S (move), risk low.

## Landing order

Independent, any time: ARC-01, ARC-02 (docs and barrel part), ARC-10,
ARC-17, ARC-19, ARC-08 (own suite PR), ARC-15 (owner decision first).

Chain A, engine and protocol (each waits for the one before):
1. ARC-05 step 1 with ARC-11 (S).
2. ARC-06 step 1, protocol family libraries (L, low risk). Freeze other
   protocol edits while it is open.
3. ARC-05 step 2, read helpers (M).
4. ARC-06 step 2, request and event parts (L).
5. ARC-05 steps 3 and 4, services class then handler files (L, the
   riskiest; alone in its PR).
6. ARC-09 and the `docker_router` and `commands` splits of ARC-13 (touch
   other files; after 5 only to avoid review overlap).

Chain B, app:
1. ARC-12, move shared widgets (S).
2. ARC-03, watch object (M).
3. ARC-07, correlation helper (M); does not touch the files of 4.
4. ARC-04, Docker list scaffold (L).
5. ARC-13 panel splits for containers and overview (M each), after 4 so
   the scaffold is not split twice.
6. ARC-14, ARC-16, ARC-18 as capacity allows.

Chains A and B do not share files except `docker_controller.dart`, which
only B touches.

## Overall assessment

The declared boundaries hold: the app reaches the engine only through
controllers and the core barrel, the pure packages stay off `dart:io`, and
the protocol guard is registered and clean. The weak points are size and
repetition, not layering: one 2,400-line engine function, one 8,000-line
protocol library, and Docker UI and controller code written once per list.
Two written records have drifted from the code (the native copy ledger and
the CHANGELOG's anacron claim), and the engine carries several request
kinds no UI sends. The largest suite-level duplicate is the three identical
editor string adapters. None of this is a correctness defect by itself;
ARC-01 is the only item with a likely user-visible effect.

## Coverage

Read fully: `klabautermann/docs/SHARED.md`, `tool/guards.yaml`, the core
barrel, `engine_reads.dart`, `persisted_setting.dart`, the account and
package reads, `networks_view.dart`, `volumes_view.dart`,
`quit_guard.dart` (first 72 lines), the admin read handlers in
`engine_isolate.dart` (1860-1924, 2047-2172), `EngineStart` and
`engineMain`'s header.

Outlined and grepped, not read line by line: `protocol.dart`,
`engine_isolate.dart`, `docker_controller.dart`, `containers_panel.dart`,
`overview_panel.dart`, `docker_router.dart`, `commands.dart`,
`ssh_config_settings.dart`, `networks_panel.dart` and `volumes_panel.dart`
(by normalized diff), the six write queues, the alert-rule and server-prefs
controllers, `log_export.dart`, every ledgered native file (by normalized
diff against its source).

Not reached: `images_panel.dart`, `stacks_panel.dart`, `logs/*`, `charts/*`
and `settings_page.dart` internals; `klabautermann_host` and
`klabautermann_docker` barrels for unused exports; `ghost_editors` and
`ghost_servers` against Klabautermann's server editor glue; the scripts
under `klabautermann/scripts`; whether `seance/packages` offers a backoff
or serial-queue helper already (grep for class names found none). The
"public name with no outside user" scan was too noisy (it matches methods
and local closures) and is not used as evidence beyond the items verified
individually above. The import guard was not run (unresolved sibling
workspace).
