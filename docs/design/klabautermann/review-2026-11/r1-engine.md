# Klabautermann review r1: engine slice (ENG)

Scope: `klabautermann/packages/klabautermann_core/lib/src/engine/`,
`klabautermann_core.dart`, `src/links/`, `src/fleet/`, `src/capabilities/`,
`src/forwards/`, `src/certificates/`. Paths below are relative to
`klabautermann/packages/klabautermann_core/lib/src/` unless they start with
another root. Nothing was executed: every finding is from reading the code
path end to end. No `dart analyze` or test run was needed to decide any of
them, so none is claimed.

Counts: 2 high, 5 medium, 7 low (14 findings).

---

## ENG-1 (bug, high): an unlisted exception from a plan run ends the engine isolate

- Files: `engine/engine_isolate.dart:2439-2443`,
  `operations/operation_runner.dart:104-127` and `:342-357`,
  `docker/docker_router.dart:223-237`, `docker/exec_sessions.dart:109`.
- What is wrong: `RunAction` starts the run with

  ```dart
  unawaited(
    planRunner.run(planId, plan, session: session).then((finished) {
      if (session != null) admin?.touch(serverId);
    }),
  );
  ```

  with no `onError`. `OperationRunner._run` converts only
  `ElevationException`, `RemoteCommandException`, `DockerException`,
  `DockerEndpointUnavailable` and `ChannelOpenException` into an
  `ActionFinished`. Anything else leaves `run()` as a rejected future, which
  is an uncaught error in the isolate's root zone. The isolate is spawned
  with the default `errorsAreFatal: true` (`engine/engine_client.dart:92-104`)
  and `engineMain` has no `runZonedGuarded`, so the isolate dies with every
  link, shell and forward. The app spawns the engine once per launch
  (`app/klabautermann_app/lib/main.dart:252`), so nothing recovers until
  relaunch. No `ActionFinished` is sent either.
- Concrete, reachable case: `DockerChannelUnavailable implements Exception`
  (`docker/docker_router.dart:88`), not `DockerException`. `openExec` throws
  it when the follower share is full on a relay rank
  (`docker_router.dart:231-237`); `runOneOffExec` lets it through
  (`exec_sessions.dart:109`, `await open()` outside any catch); the runner's
  `ExecStep` branch catches only `DockerApiException` (`operation_runner.dart:314`).
- Scenario: a server whose Docker endpoint is reached over a relay (not
  streamlocal). The user follows two container logs (follower limit 2,
  `links/channel_quota.dart:29`), or one follow under a learned session
  limit (`kLowSessionFollowersMax = 1`), then confirms a one-off container
  command (`ContainerExec`, CTX-08). The engine isolate exits; every
  controller sees `events` close.
- Fix: (a) catch `DockerChannelUnavailable` in `_run` and answer
  `ActionFailure.transport` (or a new `noChannel`); (b) give `run()` a final
  `on Object` that answers `ActionFinished(failed, transport)` after
  `_cleanUp`; (c) add `onError` at the call site. Add a runner test with an
  `exec` that throws `DockerChannelUnavailable` and one that throws a
  `StateError`, and an isolate test that the engine still answers afterwards.
- Size S. Confidence high.

## ENG-2 (bug, high): a re-import that moves an import to another endpoint keeps the open link to the old machine

- Files: `engine/engine_isolate.dart:880-932` (line 901 and 909-925),
  `links/link_supervisor.dart:150-156`.
- What is wrong: `refreshFleet` computes `forgotten` as servers that left,
  were `moved`, or whose `fleet.endpointOf(id)` changed, and drops their
  terminals, forwards, Docker session, admin state, plans, reports, profile,
  cache and history. The link is closed only for ids that left the fleet:

  ```dart
  links?.forget(before.difference(fleetIds));
  ```

  An import that keeps its id (`ssh-config:<alias>`) under a new `HostName`,
  `Port`, `User` or route keeps `server.link`, and
  `LinkSupervisor.connect` returns early on `server.link != null`. Synced
  servers do not have this problem (`applySynced` disconnects each changed
  id, lines 988-992); imports have no equivalent.
- Scenario: connected to `ssh-config:db`, the user edits `~/.ssh/config`
  (`HostName` from staging to production) and runs Import. The rail shows
  the new address. The samplers keep running on the old link, so metrics,
  alerts and the freshly purged history are recorded from the old machine
  under the new endpoint; host log streams, `HostQuery`, account, timer and
  package reads and new port forwards all go to the old machine. Plans are
  refused `noLink` and Docker waits forever because `profiles` and the
  Docker probe answer were dropped and nothing re-probes until the user
  disconnects and reconnects by hand.
- Fix: in `refreshFleet`, for `forgotten.intersection(fleetIds)` call
  `logs?.disconnect(id)` and `links?.forget({id})` (or `disconnect`), then
  redial what is still wanted (`viewed` interactive, `monitored`
  background). Add an `engine_links_test` case: connect, re-import with a
  changed `HostName`, expect the old link closed and the next dial to the
  new host.
- Size S. Confidence high for the missing close (read every call in
  `refreshFleet` and both `ImportSshConfig` and startup callers); the
  listed consequences follow from the consumers keying on server id only.

## ENG-3 (bug, medium): vault recovery requests stall the whole request queue behind a running sync round

- Files: `engine/engine_isolate.dart:2324-2372` and `:1137-1157`,
  `catalog/engine_recovery.dart:51,65,82,112`,
  `catalog/engine_sync.dart:410,488`.
- What is wrong: `SetRecoveryCode`, `RecoveryStatusRequest`, `ExportVault`
  and `RestoreVault` are handled with `await replyToRecovery(...)` inside
  the serial request queue. Each goes through `EngineVault.exclusive`. A
  sync round holds that same queue for its whole network phase
  (`await _vault.exclusive(() => coordinator.runRound(api))`), and an
  enrollment holds it across key derivation and network. Sync itself was
  deliberately moved off the request queue for this reason (comment at
  `engine_isolate.dart:1013-1016`); recovery was not.
- Scenario: a round is waiting on a slow or dead sync server (30 s per
  request, `seance_core/lib/src/sync/http_sync_client.dart:53`, several
  requests per round). The user opens the recovery settings, which sends
  `RecoveryStatusRequest`. Until the round ends no request is handled:
  `AnswerPrompt` (a host-key prompt expires after 2 minutes,
  `links/prompt_broker.dart:10`), `TerminalInput`, `Disconnect`,
  `CancelAction`, `Shutdown` (the client then kills the isolate after 2 s
  without the history flush).
- Fix: run the four vault-backed recovery requests unawaited, as the reads
  are; `replyToRecovery` already catches everything and answers by
  `requestId`. Size S. Confidence high.

## ENG-4 (bug, medium): no last-resort error boundary in the engine isolate

- Files: `engine/engine_isolate.dart:227` (entry), unawaited sites at
  `:577`, `:743`, `:747`, `:930-931`, `:1376`, `:1550-1573`, `:1749-1775`,
  `:2393`, `:2439`, `:2455-2456`; `forwards/port_forwards.dart:73-78`;
  `admin/admin_mode.dart:237-259`.
- What is wrong: the engine relies on every unawaited future handling all
  of its own errors. The comment at `:2583-2585` states the consequence
  ("being unhandled, end the isolate with every link and shell") and the
  queue is guarded, but work started outside the queue is not uniformly
  guarded. Besides ENG-1: `PortForwards.open` catches only
  `SocketException` around the bind; `AdminModeController.enable` relies on
  `_check`, which catches three exception types; the `.then` continuation
  of the plan attempt (`:1758-1774`) runs `attempt.refusal!`,
  `withHostAuditLine` and `plans.hold` after the `catchError`, so a throw
  there is unhandled too.
- Scenario: any future change (or dartssh2 error type) that throws
  something outside the listed types in one of these paths takes the whole
  engine down instead of one request.
- Fix: wrap the body of `engineMain` in `runZonedGuarded`, reporting the
  error as a `RequestRejected('<engine>', ...)` (or a dedicated
  `EngineFault` event) so the isolate survives and the app can log it; add
  a small `detach(Future, onError)` helper and use it at every `unawaited`
  site so each has an explicit answer. Size M. Confidence high that the
  boundary is missing; medium for each individual site beyond ENG-1.

## ENG-5 (bug, medium): sync chain links without an error boundary

- Files: `engine/engine_isolate.dart:1018-1023` (`pinConfirmed`),
  `:1074-1078` (`runSync` after its `try`), `:1485-1487`
  (`ReadPinConflicts`), `:2323` (`SetSyncSecrets`).
- What is wrong: `syncTail = syncTail.then(...)` runs the next operation
  only if the previous completed normally; `runWrite`'s own comment says so
  (`:1113-1114`). Four links have no `try`: `sync.publishPin`,
  `sync.pinConflicts`, `sync.setSyncSecrets`, and in `runSync` the
  `await sendServerPrefs()` and final `uiPort.send(status.answering(...))`
  that follow a successful round. Each callee is documented "never throws"
  today, so this is latent, but `sendServerPrefs` (`:802-829`) runs
  `encodeSyncedRule`, `alerts.setRules` and `snippet.toJson` over records
  pulled from other devices. One throw there leaves the round's request
  unanswered, silently drops every later sync, write, pin publication and
  conflict read for the run, and, as the last future of the chain is
  unhandled, ends the isolate (ENG-4).
- Fix: one `void chain(Future<void> Function() body, void Function(Object) onError)`
  helper that always completes normally; use it for all eight
  `syncTail = syncTail.then` sites. Move `sendServerPrefs` inside
  `runSync`'s guarded part as `runWrite` does. Size S. Confidence medium
  (the throw itself is not demonstrated).

## ENG-6 (bug, medium): the engine's fatal error is discarded after the handshake

- File: `engine/engine_client.dart:116-119, 167-186`.
- What is wrong: `fatalError` is captured from the isolate's error port for
  the engine's whole life but used only in the "before answering Hello"
  messages. After the handshake an engine that dies only closes `events`
  and makes `send` throw `StateError('the engine isolate is shut down')`.
  The stack trace (`[error, stack]`) is dropped at `:168`.
- Scenario: ENG-1 in the field: the app shows "engine stopped" with no
  cause, and nothing reaches a log or the diagnostic bundle.
- Fix: expose `Future<EngineExit> get exited` (clean or `error` plus stack)
  on `EngineClient`, completed from the exit listener, and have the app log
  and show it. Size S. Confidence high.

## ENG-7 (security, medium): `ConfirmEndpoints` pins jump hosts it never compared with what the user saw

- Files: `engine/engine_isolate.dart:1426-1454`,
  `fleet/synced_fleet.dart:161-188`, `engine/protocol.dart:543-581`,
  `app/klabautermann_app/lib/controllers/fleet_controller.dart:489-493`.
- What is wrong: the `shown` check exists so that "nothing pins what nobody
  saw". It compares `ShownEndpoint.of(entry)` for the selected server only,
  and that carries the route as hop labels (`FleetEntry.jumpRoute`), not
  the hops' host, port or user. `pinsFor` then also pins every hop on the
  route "that this device never confirmed" with the hop's endpoint as it
  stands at that moment.
- Scenario: server S behind synced hop H, neither confirmed. The user
  confirms S only. Whoever can write the account's records (the threat
  SAF-09 names) sets H's host between the list being shown and the
  confirmation, or simply before: H's label is unchanged, S's
  `ShownEndpoint` still matches, and H's rewritten address is pinned as
  confirmed. The next connect to S dials that address as H and offers it
  the user's key or agent identity; only the first-use host-key prompt
  stands in the way.
- Fix: either refuse to confirm a server whose route has an unconfirmed hop
  unless that hop is in `seen` with a matching `ShownEndpoint` (the app
  already lists hops as entries), or extend `ShownEndpoint` with each hop's
  `host:port:user` and compare them. Size M. Confidence medium: the code
  path is as described; whether the confirmation sheet shows hop addresses
  elsewhere was not checked (app slice).

## ENG-8 (bug, low): exponential `Host` pattern matching can hang the engine on import

- File: `fleet/ssh_config_settings.dart:1206-1234` (`_matchPattern`),
  `:1242` and `:1270` (any pattern holding `?` takes that path).
- What is wrong: `_matchPattern` is OpenSSH's recursive backtracking
  matcher. With k `*` groups followed by a byte the text lacks, it tries
  every placement: `Host *a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a?b` against an alias
  of sixty `a` is on the order of C(60,16) steps. `ImportSshConfig` parses
  in the request queue (`engine_isolate.dart:1402`), synchronously, so the
  engine isolate stops serving every request and timer (samplers, link
  deadlines) with no way to cancel. `_HostList` caps `Match` subpatterns at
  1023 bytes; `Host` patterns have no cap.
- Scenario: a damaged or hostile `~/.ssh/config`. ssh itself degrades the
  same way, and the file is the user's own, hence low.
- Fix: memoise on `(t, p)` or use the standard two-pointer wildcard
  matcher with single backtrack point (linear in practice, O(n*m) worst
  case); the `*`-only fast path already avoids it. Size S. Confidence high
  on the complexity (traced by hand, not timed).

## ENG-9 (refactor, medium): ten near-identical read handlers in `handle`

- File: `engine/engine_isolate.dart:1860-2290`.
- What is wrong: `ReadUserCrontabs`, `ReadSmart`, `ReadRestarts`,
  `ReadFirewall`, `ReadSshdPosture` share one 30-line shape (no link, admin
  required, `admin.touch`, `lendSession`, `then(send, onError: fail(transport))`),
  and `ReadAccounts`, `ReadTimerDetail`, `ReadPackages`, `UnitQuery`,
  `JobHistoryQuery`, `ReadDiskUsage` a second one. About 430 lines differ
  only in the report type and failure enum, and the fleet check is
  inconsistent between the two groups (the admin group does not test
  `fleetIds`, the others do).
- Fix: two helpers, `linkRead<T>(serverId, {read, onNoLink, onTransport})`
  and `adminRead<T>(...)`, in the `engine_reads.dart` proposed in ENG-11.
  Size M. Confidence high.

## ENG-10 (refactor, medium): split `protocol.dart` (7959 lines)

It should be split. Constraint: `EngineRequest` and `EngineEvent` are
`sealed`, so their direct subclasses must stay in one library, and the
protocol guard scans `packages/klabautermann_core/lib/src/engine`
(`tool/guards.yaml:121`), so the files stay in that directory. Roughly
4,400 of the lines are not requests or events but the payload families
they carry, each its own sealed family, which can move to separate
libraries that `protocol.dart` re-exports (the barrel keeps
`export 'src/engine/protocol.dart'` unchanged):

| New file (in `engine/protocol/`) | Lines today | Content |
| --- | --- | --- |
| `fleet.dart` | 4357-4576 | `FleetEntry`, `EndpointConfirmation`, `FleetAuthKind`, `ImportStoreIssue`, `ShownEndpoint` |
| `logs.dart` | 4577-5010 | `LogStreamSpec`, `LogSource`, `LogRecord`, `LogStreamStatus` families |
| `docker.dart` | 5011-6168 | `DockerQuerySpec`, `DockerPayload`, endpoint route and choice, container details, review |
| `actions.dart` | 6169-6811 plus 3222-3412 | `ActionIntent` family, `EditTarget`, `SafetyPolicy`, confirmation, preview, `ActionFailure`, `ActionRefusalReason`, `ExecOutput` |
| `prompts.dart` | 6812-7000 | `PromptRequest`, `PromptAnswer`, withdrawal reason |
| `links.dart` | 7026-7235 | `AppActivity`, `LinkStatus` family and reasons, `ReachabilityStatus` |
| `sync.dart` | 1962-2120, 7236-7446 | sync phases, failures, account, store issues, keystore operations and results, `ServerPrefs`, budget |
| `sampling.dart` | 7447-7959 | `SampleStream`, cadence, `SampleResult` family, `ProcessRow` |
| `host_reports.dart` | 2717-2865, 3413-3780 | `HostPayload` family and the report failure enums |

What remains in `protocol.dart` is the version constant with its history,
`EngineRequest` and `EngineEvent` with their direct subclasses (about
3,500 lines). If that is still too large, make the request and event
classes `part` files (`protocol_requests.dart`, `protocol_events.dart`),
which keeps the sealed exhaustiveness. Do the family moves first: they are
mechanical, need no `part`, and each is one PR that the guard and
`protocol_test.dart` (2472 lines, to be split along the same lines) cover.
Size L. Confidence high.

Related layering point: the "plain data" library imports implementation
libraries (`history_store.dart`, `docker_ladder.dart`, `tls_check.dart`,
`klabautermann_records.dart`, `operations/plan_types.dart`). Moving
`HistoryRange`/`HistoryTier`, `TlsEndpoint`/`TlsEndpointCheck` and the
`DockerRank`-style enums into the protocol files inverts that dependency.

## ENG-11 (refactor, medium): split `engine_isolate.dart` (2611 lines, one function)

`engineMain` is a single 2,380-line closure over about 40 mutable locals;
`handle` is a 1,300-line switch. It should be split, keeping one isolate
and one serial queue:

1. `engine_state.dart`: an `_Engine` class holding what are now locals
   (`links`, `scheduler`, `logs`, `docker`, `admin`, `operations`,
   `profiles`, `readyLinks`, `linkGenerations`, `viewed`, `monitored`,
   `safetyPolicy`, stores). `engineMain` becomes construction, the startup
   chain (`:2486-2574`) and the `commands.listen` loop (`:2575-2610`).
2. `engine_fleet.dart`: `refreshFleet`, `listSynced`, `applySynced`,
   `relistSynced`, `applyMonitorSet`, `monitorEligibleIds`, `probeFleet`
   (`:831-1011`). This is where ENG-2 lives and it is testable without an
   isolate once it is a class.
3. `engine_sync_chain.dart`: `syncTail`, `runSync`, `runWrite`,
   `sendServerPrefs`, pin publication (`:795-829`, `:1013-1135`), with the
   `chain` helper of ENG-5.
4. `engine_actions.dart`: `PlanAction`, `RunAction`, `CancelAction`,
   `lendSession`, `stackEditLookup`, the `OperationRunner` wiring
   (`:463-510`, `:584-717`, `:1580-1775`, `:2394-2443`).
5. `engine_reads.dart`: the read handlers with ENG-9's helpers
   (`:1785-2290`).
6. `handle` stays in `engine_isolate.dart` as a dispatch switch of one line
   per request, so the sealed exhaustiveness and the request order stay in
   one place.

Order: 5 (pure extraction), 3, 2, 4, then 1. Size L. Confidence high.

## ENG-12 (docs, low): stale statements in the engine's own documentation

- `engine/engine_isolate.dart:143-144`: "The app's composition root leaves
  them off; tests turn them on." `main.dart:200-201` passes
  `linksEnabled: true, probesEnabled: true`.
- `engine/engine_isolate.dart:209-212`: "a [PlanAction] gets
  [ActionRefused] until its planner lands and a [RunAction] because no plan
  is held yet ... every other 03 §10.1 row gets [RequestRejected] until its
  milestone lands." Planners and the runner exist; the only request left
  for the fallback is `HandleAlert` (v1.x), which is answered
  "not implemented yet (M1a scaffold)" (`:2460-2466`).
- `klabautermann/AGENTS.md:105-106`: "The protocol guard enforces this once
  the engine directory is registered in `tool/guards.yaml`." It is
  registered (`tool/guards.yaml:121`).
- Size S. Confidence high.

## ENG-13 (refactor, low): constants and parsers kept in step by hand

- The 16-hop limit exists three times: `fleet/jump_routes.dart:14`
  (`_maxJumpHops`), `fleet/synced_fleet.dart:9` (`_maxRouteHops`) and
  seance_core's private `_maxJumpHosts`. Export one from seance_core.
- `fleet/jump_routes.dart:17,698-703` (`_decimal`, `_port`) duplicates the
  port parsing `ssh_config_settings.dart` exports as `parseSshPort` /
  `isTcpPort`; `_replacement` is declared in both files.
- `engine/engine_isolate.dart:2533-2538` and `:2544-2549`: the same
  `CachePurge` switch twice.
- Size S. Confidence high.

## ENG-14 (test, low): gaps around the risky paths above

- No test drives an `OperationRunner` whose `exec`/`api`/`launch` throws an
  unlisted exception, and no isolate test asserts the engine survives a
  failed run (ENG-1).
- The SYN-08 re-import test (`test/engine_isolate_test.dart:1010`) runs
  with links off, so it cannot see ENG-2.
- No test sends a recovery request while a sync round is in flight (ENG-3).
- `ConfirmEndpoints` tests cover a changed server, not a changed
  never-confirmed hop behind a selected server (ENG-7).
- Size M. Confidence high.

---

## Overall assessment

The slice is careful code: link supervision, slot accounting, prompt
scoping, pin stores, the capability cache and the ssh_config resolver held
up under tracing, and most error paths answer by request id. The real
risk is structural: one 2,400-line closure where every unawaited future
must be individually perfect, with no isolate-level safety net and no
restart, so a single missed exception type (ENG-1) costs the whole
session. ENG-2 is the one wrong-target bug found. The two large files
should be split as described; the protocol split is mechanical, the
isolate split is what makes ENG-2, ENG-4 and ENG-5 testable.

## Coverage

Read fully: `engine/engine_isolate.dart`, `engine/engine_client.dart`,
`links/` (all seven files), `forwards/port_forwards.dart`,
`certificates/tls_check.dart`, `fleet/jump_routes.dart`,
`fleet/ssh_config_entries.dart`, `fleet/imported_fleet.dart`,
`fleet/synced_fleet.dart`, `fleet/reachability_service.dart`,
`fleet/ssh_config_import_store.dart` (from `open` down),
`capabilities/capability_cache.dart` (from line 60).

Skimmed: `engine/protocol.dart` (declaration index, version history,
`ShownEndpoint`, port-forward validation, `LinkStatus`, alert stubs; not
each class), `fleet/ssh_config_settings.dart` (lines 1-760 and the glob
and host-list code; not `_Reading`, `_ConfigLine`, `sshCanonicalHost`),
`klabautermann_core.dart` (export list only, `show` lists not audited).
Outside the slice, only as far as a trace needed: `operation_runner.dart`,
`exec_sessions.dart` (`runOneOffExec`), `docker_router.dart` (`_use`,
`openExec`), `engine_sync.dart`, `engine_vault.dart`, `engine_recovery.dart`,
`keystore_channel.dart`, `admin_mode.dart` (`enable`, `_check`).

Not reached: `fleet/endpoint_pins.dart`, `fleet/monitor_set.dart` (only its
eligibility function), `fleet/server_file_stem.dart`; the tests beyond
targeted greps; sendability of every event payload across the port; the
intermittent `noLink` after redial recorded in the declined list (#721),
which I could not explain from the supervisor or `PlanAction` code.
