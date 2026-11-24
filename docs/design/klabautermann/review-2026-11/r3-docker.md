# Klabautermann review r3: Docker slice (DKR)

Scope: `klabautermann/packages/klabautermann_docker/lib` and
`klabautermann/packages/klabautermann_core/lib/src/docker/`, read on the
detached origin/main checkout. Paths below are relative to
`klabautermann/packages/`. Nothing in the repository was changed; two
scratch scripts outside it confirmed DKR-2, DKR-3 and the Dart semantics
behind DKR-1 and DKR-6.

Counts: 1 high, 5 medium, 6 low (12 findings).

## DKR-1 Engine isolate dies on a non-Docker exception in a Docker query

- Kind: bug, security (hostile remote output). Severity: high.
  Size: S. Confidence: high.
- Where: `klabautermann_core/lib/src/docker/docker_router.dart:920-956`
  (`_run`), `:958-1044` (`_read`), trigger in
  `klabautermann_core/lib/src/docker/image_updates.dart:226-237` and
  `klabautermann_docker/lib/src/registry_reference.dart:205-218`.
- What: `_pump` starts each query with `unawaited(_run(session, endpoint,
  query))`. `_run` awaits `_read` with no `try`, and `_read` catches only
  `on DockerException`. Anything else thrown under it is an unhandled
  async error in the engine isolate, which the engine client documents as
  fatal ("errors are fatal in a spawned isolate",
  `engine/engine_client.dart:116-118`; there is no `runZonedGuarded` in
  the engine). Even if it were not fatal, the query would never get its
  `DockerResult` and `endpoint.inFlight--` (line 932, not in a `finally`)
  would never run, so a relay's idle close stops.
- Concrete scenario: `DockerImageUpdatesQuery`. A registry (any registry a
  tag on the host names, or the host's own curl output) answers `429`
  with `ratelimit-remaining: 0;w=9000000000000`.
  `RegistryRateLimit._parse` takes the seconds unbounded:
  ```dart
  final seconds = int.tryParse(kv.substring(2));
  if (seconds != null && seconds > 0) window = Duration(seconds: seconds);
  ```
  and `_keep` adds it to the clock:
  ```dart
  cache._backoffUntil[entry.reference.registry] = now.add(
    row.rateLimit?.window ?? kImageUpdateBackoff,
  );
  ```
  `DateTime.now().add(Duration(seconds: 9000000000000))` throws
  `RangeError (millisecondsSinceEpoch)` (run and confirmed). It leaves
  `checkImageUpdates`, passes `_read`'s `on DockerException`, and ends the
  engine: every server's link, sampler and stream goes with it.
- Second path of the same class: `stack_sources.dart:713`
  `ascii.decode(bytes.sublist(0, newline))` in `_readElevated` throws
  `FormatException` on a non-ASCII byte in the first stdout line of the
  elevated read (a host that prints anything before `wc -c`'s number),
  and `await for (final chunk in process.stdout)` rethrows any stream
  error; both reach `_run` through `DockerStackFileQuery`.
- A smaller valid window (`w=315360000`) is not a crash but silently
  disables update checks for that registry for ten years of process
  life: `refresh: true` does not bypass `_backingOff`.
- Fix: in `_run`, wrap the read in `try { ... } on Object` that answers
  `DockerQueryFailed(connectionFailed, detail: ...)` and put the
  `inFlight--` in a `finally` (the same bookkeeping exists three times:
  `_run`, `_use`, `_WatchTarget.use`; only `_run` lacks the `finally`).
  Clamp the window (for example to 24 h) in `RegistryRateLimit._parse`,
  and use `ascii.decode(..., allowInvalid: true)` in `_readElevated`.
  Add a router test with a query whose read throws a `StateError`.

## DKR-2 `DockerHttpClient.close()` misses a connection still opening; the events watcher then leaks it

- Kind: bug (leak). Severity: medium. Size: S. Confidence: high
  (reproduced with a scratch script against the package).
- Where: `klabautermann_docker/lib/src/http_client.dart:154-168` (`close`),
  `:270-303` (`_acquire`), `:358-379` (`_serveWaiters`);
  `klabautermann_core/lib/src/docker/docker_watch.dart:373-379`.
- What: `close()` aborts what is in `_all` and fails `_waiters`, but an
  open in flight (`_opening > 0`) is in neither. `_acquire` checks
  `_closed` only before `await _open(scope)`; afterwards it does
  `_all.add(c); c.markBusy(); return c;` and the request is written and
  answered on a client that was closed. Reproduction: `requestLines('GET',
  '/events')`, `close()` while the opener is pending, opener completes,
  head arrives: the request returned status 200, the duplex was never
  closed and `connectionCount` stayed 1.
- Scenario: `DockerWatcher._open` awaits `client.requestLines('/events')`
  (an SSH channel open plus the head, two round trips). A `detach()` in
  that window (endpoint drop, new endpoint choice, last unwatch when the
  user leaves the Docker view) closes the lease first. Then:
  ```dart
  final response = await client.requestLines(...);
  if (epoch != _epoch) return;
  ```
  returns without touching `response.body`. The `direct-streamlocal`
  channel (or the relay process, whose follower slot was already given
  back, so the quota undercounts sessions) and the daemon's `/events`
  stream stay open until the link closes, and with DKR-3 every later
  event is buffered in memory. `ContainerLogReader._open` handles the
  same case (`response.body.listen(null).cancel()`), and `ExecSessions`
  closes the hijacked body; the watcher is the one that does not.
  `yieldStream()` has the mirror problem: the epoch does not change, so a
  stream whose lease was closed in that window keeps running while its
  slot is free.
- Fix: in `_acquire` and `_serveWaiters`, after the open returns, dispose
  the connection and throw `DockerTransportException('client is closed')`
  when `_closed`; in `DockerWatcher._open` cancel the body on an epoch
  mismatch as the log reader does. Add an `http_pool_test` for "close
  while a duplex opens".

## DKR-3 A response body nobody listens to yet is read without backpressure

- Kind: bug (unbounded buffering). Severity: medium. Size: S.
  Confidence: high (reproduced).
- Where: `klabautermann_docker/lib/src/http_client.dart:1067-1135`
  (`_BodyCtl`), `:941-957`.
- What: `_BodyCtl.emit` holds the pump only `while (_paused && ...)`, and
  `_paused` is set in the controller's `onPause`. A single-subscription
  controller without a listener never calls `onPause`; `controller.add`
  just queues. So from the moment `sendBytes`/`sendLines`/`sendJsonValues`
  return until the caller listens, and forever if it never does, the pump
  reads the duplex as fast as it delivers. Reproduction: 2 MB of chunked
  events fed to an unlistened body were all consumed; the source was not
  paused. The same holds for `hijack()` (`http_client.dart:999-1011`):
  `_onData` adds to `_hijackCtl` before any listener.
- Scenario: DKR-2's abandoned `/events` response grows by every event of
  the host until the link closes; any future caller that inspects the head
  and returns early has the same leak. The class comment promises "Pausing
  it pauses the duplex subscription (03 §5.5 backpressure)".
- Fix: start `_BodyCtl` (and the hijack controller) in the paused state:
  pause `_conn._sub` until `onListen`, or have `emit` wait while
  `!controller.hasListener`.

## DKR-4 Update check rows are kept by tag and survive the image changing

- Kind: bug (wrong result). Severity: medium. Size: S. Confidence: high.
- Where: `klabautermann_core/lib/src/docker/image_updates.dart:79-83,
  175-176, 152-154`; consumer
  `app/klabautermann_app/lib/ui/docker/images_panel.dart:355-358`.
- What: the cache is `Map<String, ImageUpdateRow>` keyed by the tag, and a
  row is reused when it is younger than six hours:
  ```dart
  bool _stale(ImageUpdateRow? row, DateTime now) =>
      row == null || now.difference(row.checkedAt) >= kImageUpdateFresh;
  ```
  `ImageUpdateRow.imageId` is recorded but never compared with
  `entry.image.id`. The app maps rows to images by `row.reference`.
- Scenario: the check says `nginx:latest` has an update; the user pulls
  it (the panel's own action, or a stack redeploy). The tag now names a
  new image id, but the next `DockerImageUpdatesQuery` without `refresh`
  returns the old row, so the freshly pulled image still shows "update
  available" for up to six hours. The reverse also holds: a tag moved to
  an older local image keeps "up to date". The cache lives in the router
  across reconnects (`_imageUpdates`), so reconnecting does not clear it.
- Fix: treat a row as stale when `row.imageId != entry.image.id` (and
  drop rows whose tag no longer exists). Add a test: check, change the
  image id behind the tag, check again without `refresh`.

## DKR-5 A container shell never gets its initial size on API 1.41

- Kind: bug. Severity: medium. Size: S. Confidence: high.
- Where: `klabautermann_core/lib/src/docker/exec_sessions.dart:326-362`,
  `klabautermann_docker/lib/src/endpoints.dart:276-306, 322-339`.
- What: `createExec` and `startExec` send `ConsoleSize` only
  `if (consoleSize != null && apiVersion >= _execConsoleSizeSince)`
  (1.42), and `createExec`'s comment says "below, the caller resizes
  after the start". The caller does not:
  ```dart
  // A resize while the exec started; the create took the size before.
  if (terminal.size != size) _sendSize(terminal);
  ```
  `_sendSize` runs only when the app resized during the start.
- Scenario: Docker 20.10 (API 1.41, the supported floor, in the recorded
  corpus) or a Podman whose compat API reports 1.41. The exec's PTY keeps
  the daemon's default size until the user resizes the window, so `top`,
  `vi`, `less` and line wrapping are wrong in every new shell. The Docker
  CLI resizes after the start for exactly this reason.
- Fix: after the start, call `_sendSize(terminal)` when the client's
  version is below 1.42 (`sentSize` is still null there, so it sends
  once). Test gap: `exec_sessions_test.dart` builds every client at
  `ApiVersion(1, 44)`; add one at 1.41 that expects one `/resize`.

## DKR-6 Typed stream endpoints are `async*`, unused in production, and cannot be cancelled while quiet

- Kind: refactor, dead code with a latent hang. Severity: medium
  (maintenance; a hang for whoever uses them). Size: M. Confidence: high.
- Where: `klabautermann_docker/lib/src/endpoints.dart:124-139`
  (`containerStatsStream`), `:475-494` (`pullImage`), `:613-637`
  (`events`).
- What: each is `async* { final res = await requestLines(...); await for
  (final line in res.body) { yield ... } }`. Cancelling an `async*`
  subscription takes effect only at the next `yield`: a scratch run
  confirmed `sub.cancel()` does not complete, and the inner stream keeps
  its listener, until the inner stream emits again. On a quiet daemon
  `events().listen(...).cancel()` therefore neither completes nor closes
  the connection. Production does not use them: `DockerWatcher` calls
  `requestLines('/events')` and decodes lines itself
  (`docker_watch.dart:373-403, 455-462`), the pull plan calls
  `requestJsonValues` (`operations/plans/docker_plans.dart:609`), and no
  code calls `containerStatsStream`. `demuxStdcopy`,
  `joinTimestampedLogLines` and `dropInclusiveSince` are `async*` too;
  their one caller is safe only because `_closeConnection` closes the
  client together with the cancel (`container_logs.dart:323-334`), which
  nothing documents.
- Other exported API with no caller outside the package's tests:
  `RegistryChallenge`/`anonymousTokenUri` and `parseRegistryHead` (the
  token flow and the head parse live in `klabautermann_host`),
  `BoundedLogRing`, `lastDeliveredTimestamp`, `parseTimestampedLogLines`,
  `negotiateDockerClient` (the router negotiates by hand,
  `docker_router.dart:816-849`), `composePs`, `composeRestart`,
  `parseComposeConfig`, `parseComposeVersion`, `planEventRefresh`'s
  `previousEventAt`/`fullRelist` branch (the watcher never passes it and
  does its own gap handling with `_lostAt`).
- Fix: delete the three stream helpers or rebuild them on `_pipe`
  (`json_streams.dart:21-63`), which propagates cancel; have the watcher
  and the pull plan use the one implementation; remove or un-export the
  rest. State the "close the client to stop the read" rule on
  `demuxStdcopy` and `joinTimestampedLogLines`, or convert them as well.

## DKR-7 A pooled connection is reused with unread bytes in its buffer

- Kind: bug, hardening. Severity: low. Size: S. Confidence: high (by
  reading), impact medium-low.
- Where: `klabautermann_docker/lib/src/http_client.dart:626-643, 273-283`.
- What: `usable => alive && !_busy`. `_onData` on an idle connection
  appends to `_buf`, and nothing checks `_available` when the connection
  is taken from `_idle`. Bytes that arrive after a completed body (a peer
  that sends more than its `Content-Length`, a relay that prints to
  stdout) become the start of the next request's response: at best
  `malformed status line` and a dropped endpoint, at worst a complete
  stale response attributed to the wrong request.
- Fix: in `_release` and in `_acquire`'s idle loop, dispose a connection
  whose `_available > 0`.

## DKR-8 A follow that fails on the wire format retries forever and says nothing

- Kind: bug (silent failure). Severity: low. Size: S. Confidence: medium.
- Where: `klabautermann_core/lib/src/docker/container_logs.dart:233-256,
  289-313`.
- What: `resolveLogFraming(...).framing` discards the choice's `warning`
  ("Content-Type contradicts Config.Tty", "unknown Content-Type ... fell
  back"), and for a follow `_lost(epoch, error)` ignores `error`: it
  reconnects after 1 s to 30 s for good. A `DockerProtocolException`
  (`invalid stdcopy stream type`, a frame over 8 MiB, `truncated stdcopy
  frame`) is deterministic, so the stream stays "running" with no lines
  and no reason, re-inspecting and re-requesting every 30 s.
- Scenario: an engine whose framing differs from what `Config.Tty` and a
  missing `Content-Type` imply (the case the warning exists for).
- Fix: end the stream as `failed` with the detail after N consecutive
  protocol errors without a line, or flip the framing once when the
  warning was set; surface the warning in the first `LogStreamState`.

## DKR-9 Volume driver options and log driver options cross unmasked

- Kind: security, drift from 03 §8.9. Severity: low (not rendered today).
  Size: S. Confidence: medium.
- Where: `klabautermann_docker/lib/src/models/volume.dart:27,36`
  (`options: r.stringMap('Options')`), `models/network.dart:86,133`,
  `models/container.dart:371-379` (`LogConfig.config`), passed through by
  `inspect_masking.dart:46` (`hostConfig: inspect.hostConfig`) and
  `DockerVolumesPayload`.
- What: labels and env are masked in the models, but a CIFS/NFS volume's
  `Options` (`"o": "username=u,password=p"`) and a log driver's options
  (`splunk-token`, `loki-url` with credentials) are plain
  `Map<String, String>` in events the engine emits. The app does not
  show them today (`container_details_view.dart:134` prints only the
  driver type; no view reads a volume's options), so nothing leaks to
  the screen yet, but they are in memory on the UI side and one view
  away from being shown unmasked.
- Fix: parse both through `maskedLabels`-style masking (key pattern plus
  an `o=` sub-key split), or drop the fields until a view needs them.

## DKR-10 Byte buffers are growable `List<int>`

- Kind: refactor (memory, duplication). Severity: low. Size: M.
  Confidence: high.
- Where: `klabautermann_docker/lib/src/http_client.dart:611, 641,
  702-715`; `stdcopy.dart:60-91`; `json_streams.dart:73-106`.
- What: three hand-written parsers each keep `final buf = <int>[]`,
  `addAll(chunk)`, a manual `pos`, a `removeRange` compaction rule and
  `sublist` copies. A growable `List<int>` holds a machine word per byte,
  so one stdcopy frame at the 8 MiB cap (`defaultMaxStdcopyFrameBytes`,
  taken from the frame header, so a hostile daemon chooses it) costs
  32 to 64 MiB plus the copy, per stream, and a 1 MiB JSON line 4 to
  8 MiB. `_indexOfCrlf` also rescans from `_pos` on every chunk.
- Fix: one small `Uint8List`-backed read buffer (append, peek, take,
  indexOf with a scan offset) in the package, used by all three.

## DKR-11 `docker_router.dart` is 1674 lines with three copies of the in-flight bookkeeping and three backoffs

- Kind: refactor. Severity: low. Size: M. Confidence: high.
- Where: `klabautermann_core/lib/src/docker/docker_router.dart`;
  backoffs at `:748-750`, `docker_watch.dart:426-429`,
  `container_logs.dart:304-307`.
- What: `_run` (925-932), `_use` (275-290) and `_WatchTarget.use`
  (1577-1589) each cancel the idle timer, count `inFlight` and call
  `_idleCheck`; the copies have already diverged (DKR-1). The doubling
  backoff `base * pow(2, min(retries, 5))` capped is written three times
  with two different bases.
- Split: `docker_queries.dart` (`_read`, `_review`, `_containerTop`,
  `_valid`: about 200 lines of query dispatch), `docker_log_streams.dart`
  (`openLogs`, `_serveLogs`, `_pauseLogs`, `_endLogs`, `_release`,
  `_LogStream`), `docker_endpoint.dart` (`_Endpoint`, `_WatchTarget`,
  `_SlotDuplex`, `_pool`, `_relayConnection`), leaving session state and
  resolution in the router. One `Future<T> _counted<T>(session, endpoint,
  body)` and one `Backoff` value type replace the copies.

## DKR-12 Test gaps for the risky paths above

- Kind: test. Severity: low. Size: M. Confidence: high.
- No test closes a `DockerHttpClient` while its opener is pending, or
  leaves a streamed body unlistened (DKR-2, DKR-3).
- No router test makes a query's read throw anything but a
  `DockerException` (DKR-1); `image_updates_test.dart` only uses
  `w=3600`.
- `exec_sessions_test.dart` never runs below API 1.42 (DKR-5).
- `image_updates_test.dart` never changes the image behind a cached tag
  (DKR-4).
- `http_client_test.dart` has no case for bytes arriving on an idle
  pooled connection (DKR-7).

## Checked and found sound (no finding)

- HTTP head parsing: status line, header line, header block and header
  count caps; conflicting `Content-Length`; `Transfer-Encoding` over
  `Content-Length`; chunk-size line cap; EOF mid-line, mid-chunk and
  mid-body are protocol errors; error bodies capped at 64 KiB.
- Timeout and cancel scope handoff through queued wait, open and bound
  connection (`_RequestScope`); waiter service after a failed open.
- Hijack: buffered remainder first, pause and resume to the duplex,
  cancel aborts, exec leases are their own client so the pool is not
  exhausted; `ExecSessions._start` catches `on Object`.
- Ladder: probe script takes the path as a positional parameter, socat
  path whitelist, `--host` always named, sudo relay only in admin mode,
  excluded routes end the loop; `_resolve` cannot stay `resolving`.
- Events watch: lists are re-read after the stream opens, resume within
  60 s with `since`, replayed events skipped in the timeline, full
  re-list past the gap, stats baseline cleared.
- Log demux and resume: partial frames joined per stream, inclusive
  `since` de-duplicated, ring bounded by lines and characters,
  `LogBatch` copies the ring before it is cleared.
- Model parsers are tolerant (`JsonReader`), label links validate scheme,
  host and userinfo, compose argv values are validated before quoting.
- `/system/df` under the 30 s default timeout is already recorded as
  unmeasured in STATUS.md, so not raised.

## Overall assessment

The slice is careful and well commented: the parser limits, scope
handling and the ladder are solid, and most remote input is treated as
hostile. The real exposure is at the seams: the router trusts that only
`DockerException` escapes a query (one crafted header ends the engine),
and client `close()` versus an in-flight open leaks a stream that then
buffers without bound. Two user-visible wrong results (stale update rows,
shell size on 1.41) are small fixes. The package also carries a second,
unused copy of the stream endpoints and several exported helpers nothing
calls. Tests are broad on the happy and split-input paths but thin on
lifecycle races and the oldest supported API.

## Coverage

- Read fully: `http_client.dart`, `duplex.dart`, `json_streams.dart`,
  `stdcopy.dart`, `log_resume.dart`, `log_time.dart`, `docker_client.dart`,
  `endpoints.dart`, `http_types.dart`, `api_version.dart` (code, not doc
  comments), `masking.dart`, `compose/file_masking.dart`,
  `compose/commands.dart`, `compose/label_links.dart`,
  `image_digest.dart`, `registry_reference.dart`, `json_reader.dart`;
  core `docker_router.dart`, `docker_watch.dart`, `docker_ladder.dart`,
  `exec_sessions.dart`, `container_logs.dart`, `image_updates.dart`,
  `inspect_masking.dart`, `duplex_adapters.dart`, `dropbear.dart`,
  `stack_sources.dart` (from line 60).
- Skimmed: `compose/parsers.dart` (second half), `models/stats.dart`
  (delta only), `models/container.dart`, `volume.dart`, `network.dart`,
  `image.dart`, `engine_info.dart` (masking and field types only),
  `errors.dart`, `events_refresh.dart`; outside the slice only what a
  finding needed (`seance_core` `byte_duplex.dart`, `engine_client.dart`
  spawn, `images_panel.dart`, `registry_heads.dart`).
- Not reached: `compose/grouping.dart`, `compose/ownership.dart`,
  `compose/labels.dart`, `docker_summary.dart`, `models/events.dart`,
  `system_df.dart`, `pull.dart`, `exec.dart`, `container_top.dart`,
  `image_history.dart`, `time.dart`, `testing/recorded_daemon.dart`,
  `docker_access.dart`, `container_review.dart`, and the test files
  beyond targeted greps. No test suite was run.
