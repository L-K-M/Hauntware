# Klabautermann review r4: sampling, logs, catalog, settings, history, alerts (prefix SMP)

Scope: `klabautermann/packages/klabautermann_core/lib/src/{sampling,logs,catalog,settings,history,alerts,replay}`.
Paths below are relative to `klabautermann/packages/klabautermann_core/` unless they start with another root.
Read-only review. Nothing in the repository was run except two standalone regex timing scripts in the
scratchpad (no package resolution exists in the checkout, so no test file could be run).

Counts: high 1, medium 4, low 9 (14 findings).

---

## SMP-01 (bug, high): `linePriority` regex backtracks quadratically, freezing the UI on long lines

- File: `lib/src/logs/line_reading.dart:35-39` (`_levelWord`), called from
  `app/klabautermann_app/lib/ui/logs/container_lines.dart:39` (`levelOf`) on the UI isolate.
- Code:
  ```dart
  final _levelWord = RegExp(
    r'^(?:(?:\S*\d\S*|[A-Z]{2,5})\s+){0,4}?\[?'
    r'(FATAL|PANIC|...|TRACE)'
    r'\]?:?(?=\s|$)',
  );
  ```
  `\S*\d\S*` followed by a required `\s+` is O(n^2) on a run of non-space characters that holds
  digits and is not followed by a space, and the lazy `{0,4}?` repeats that for each prefix word.
- Measured with the exact pattern (Dart from `/opt/flutter/bin`, standalone script): a 16,384-char
  line of digits takes 3.8 s; 16 KiB of base64 takes 0.9 s; `2026-10-15T14:30:01Z ` followed by
  16 KiB of base64 takes 13.2 s. 16 KiB is exactly what `LogBuffer` keeps per line
  (`logLineMaxBytes`, `log_buffer.dart:18`), so the cap does not help.
- Scenario: a container logs one long token line (a base64 blob, a hex dump, a JWT, minified JSON
  that does not end in `}`). Opening or scrolling its log view calls `levelOf` per row; each such
  row blocks the UI isolate for seconds. A hostile or merely chatty container makes the log viewer
  unusable. `_exception`, `_logfmtLevel` and `_continuation` were timed on comparable inputs and
  are linear (0 ms).
- Fix: bound the prefix words (`\S{0,40}` style, or match the level word against only the first
  ~200 characters of the line), and add a test that times a 16 KiB no-space line.
- Size S. Confidence high (measured).

## SMP-02 (security, medium): command-line masking misses JSON/colon-form secrets and token-only URL userinfo

- Files: `lib/src/sampling/argument_masking.dart:148-167` (`_keptBeforeValue`),
  `../klabautermann_docker/lib/src/masking.dart:18` (`_urlCredentialPattern`).
- `_keptBeforeValue` returns null unless the token contains `=`:
  ```dart
  if (token.length > 2 && token.startsWith('-p')) return '-p';
  if (!token.contains('=')) return null;
  ```
  and the URL rule needs a colon in the userinfo: `RegExp(r'([^/@\s:]*):[^/\s]+@')`.
- Scenarios that cross to the app in plain text (process list, cron lines via `maskedCronJobs`,
  Docker `top` and image history, which reuse the masker):
  - `curl -d '{"password":"hunter2"}' ...` or `--data-raw '{"token":"abc"}'`: no `=`, `-d` is not
    in the curl table, so nothing is masked.
  - `git clone https://ghp_xxxxxxxx@github.com/org/repo` and
    `https://x-access-token@...`-less forms where the token is the whole userinfo: no colon, so
    `maskUrlCredentials` leaves it.
  - `python client.py -H "Authorization: Bearer abc"`: header rules apply only inside a known
    tool's command (`_Value.header` for curl/wget/httpie).
- The design's SAF-07 lists `-p<secret>`, `--password=` and `scheme://user:pass@`, so the first
  and third are beyond the written rule, but the header comment of this file promises "a secret
  reaches it only behind MaskedValue". The userinfo-token case is a common real credential form.
- Fix: in `_keptBeforeValue`, also treat `"key":` / `key:` followed by a value as an assignment
  when the key matches `secretKeyPattern`; mask a userinfo without a colon when it is followed by
  `@host` in a `scheme://` URL (over-masking `user@host` for ssh-style URLs is the safe
  direction); apply `_keptOfHeader` for `Authorization:` outside known tools. Add tests for each;
  `argument_masking_test.dart` has no JSON-body or colon-less userinfo case.
- Size M. Confidence high (read, not executed).

## SMP-03 (bug, medium): a sign-out that fails partway orphans the account's credentials in the vault

- File: `lib/src/catalog/engine_sync.dart:543-561`.
- Code order inside the exclusive section:
  ```dart
  final secretRefs = { for (final server in await _servers.load()) ... ref };
  for (final name in [_syncRecordsFileName, _serversFileName]) { ... await file.delete(); }
  _openCatalog();
  await _klabautermannRecords.clear();
  await _snippets.clear();
  for (final ref in secretRefs) { await _vault.store.deleteSecret(ref); }
  await enrollment.clear();
  ```
  The only list of vault entries to delete lives in `servers.json`, which is deleted before the
  entries are.
- Scenario: `deleteSecret` (or `_snippets.clear()`, or `_klabautermannRecords.clear()`, which
  throws `SyncStateReadOnlyException` when its file was left as is) throws after the catalog
  files are gone. `signOut` reports failure and stays enrolled. The user retries: `_servers.load()`
  now reads an empty catalog, `secretRefs` is empty, the sign-out succeeds, and every remaining
  credential of the account's servers stays in `vault.json` under the key that stays in the
  keystore. The doc comment promises "its servers with the vault entries they name ... are
  forgotten". The same happens if the process dies between the file deletes and the secret
  deletes and the user signs out again before a round re-pulls the servers.
- Fix: delete the vault entries before the catalog files (still before the enrollment, which keeps
  the stated ordering argument), or sweep vault entries no remaining config names. Add a test with
  a store whose `deleteSecret` fails once.
- Size S. Confidence high for the code path, medium for how often a delete fails.

## SMP-04 (bug, medium): a non-file error in one history write wedges the whole history queue

- File: `lib/src/history/history_store.dart:506-518` (`_queue`), `673-707` (`_decodeBucket`,
  `_fromSeconds`), `379-400` (gap read).
- `_queue` chains on `_tail` and catches only `FileSystemException`:
  ```dart
  _tail = _tail.then((_) async {
    ...
    try { ... await body(rings); } on FileSystemException { }
  });
  ```
  `_decodeBucket` builds `DateTime.fromMillisecondsSinceEpoch(seconds * 1000)` from an int64 read
  from disk; a value past 8.64e12 seconds throws `ArgumentError`. `_openRing` validates only the
  header and the length, never a slot.
- Scenario: a ring slot holds garbage (a torn in-place write after power loss, bit rot, a file
  edited or restored). When `_begin` reads that slot (`history_store.dart:475-486`), the
  `ArgumentError` escapes `_queue`; `_tail` is now a failed future, every later
  `_tail.then(...)` body is skipped, so no bucket or gap of any server is written for the rest of
  the run, `flush()` returns a failed future, and the last link in the chain is an unhandled
  async error in the engine isolate. Independently, `read()` of that server's tier or of a
  garbage gap slot throws on every call, across restarts, since nothing rewrites the slot.
- Fix: catch `Object` in `_queue` (as `_inTurn` already heals its tail), and make
  `_decodeBucket` and the gap decode return null for seconds outside DateTime's range.
- Size S. Confidence medium (path read end to end; the corrupt slot is the assumption).

## SMP-05 (bug + test, medium): 10-minute history bucket double-counts a minute continued after a restart; its test passes only by timing

- File: `lib/src/history/history_store.dart:452-488`; test
  `test/history/history_store_test.dart:212-243`.
- `flush()` (engine shutdown, `engine_isolate.dart:2451`) closes the filling minute M into the
  10-minute bucket and writes both. After a relaunch in the same minute, `_begin(minute M)` merges
  the stored minute (readings r1) into the new accumulator, new readings r2 are added, and when M
  closes `_closeMinute` does `_begin(tenMinutes)`, which merges the stored 10-minute slot (already
  holding r1), then `minute.values.forEach(ten.add)` adds r1+r2. r1 is counted twice: count and
  mean of the 10-minute bucket are wrong (min and max are unaffected).
- The test "a restart inside a bucket keeps the readings from before it" expects count 5 and
  passes because both `observe` calls run synchronously before the queued merge of the stored
  minute has run, so the minute holds only the new reading when it is folded. In the app a minute
  closes seconds after it began, after the merge; the same data then gives count 6 and mean 25.
- Fix: fold only the minute's own (this run's) readings into the 10-minute accumulator, keeping
  the merged-from-disk part separate, or rebuild the 10-minute bucket from its stored minutes.
  Make the test await `store.idle` between the two observes so it exercises the real order.
- Size M. Confidence high (traced by hand; not executed).

## SMP-06 (bug, low): `removeRule` and `_retractPrefs` ignore a refused seal and still answer written

- File: `lib/src/catalog/engine_sync.dart:851-859`, `940-944`.
  ```dart
  await _sealKlabautermann(writes, recordId, removedPayload(recordId));
  return CatalogWritten(requestId: request.requestId);
  ```
  `_sealKlabautermann` returns a `CatalogWriteFailure?`; `putRule` and `setServerPrefs` check it,
  these two do not. Today a removal cannot exceed the blob cap and the policy is `normal`, so the
  refusal is unreachable, but the result is "never report a failed operation as successful" by
  luck. Also `putRule` trims `request.ruleId` (line 829) while `removeRule` uses it untrimmed
  (line 853), so a rule created as `" r1 "` cannot be removed by the same id.
- Fix: return the failure in both; trim in `removeRule`. Size S. Confidence high.

## SMP-07 (bug, low): `AlertEvaluator.gap` restores a resolving alert with the wrong start

- File: `lib/src/alerts/alert_evaluator.dart:188`.
  ```dart
  RulePhase.resolving => ThresholdState(RulePhase.firing, state.since),
  ```
  In `resolving`, `since` is when the clear began and `firedSince` is the alert's start
  (`klabautermann_host/lib/src/rules/threshold.dart:159-167`); `evaluateThreshold` itself returns
  to firing with `previous.firedSince`. After a gap the firing state carries the clear's start.
  Not observable today, since `LocalAlertChanged.since` is sent only on a raise, but any later
  reader of the state gets a wrong start.
- Fix: `state.firedSince ?? state.since`; extend the gap test to assert the start. Size S.
  Confidence high.

## SMP-08 (bug, low): lending the slow sampler reports no gap, and a lend during the probe costs a retry delay

- File: `lib/src/sampling/sampling_scheduler.dart:276-298`, `706-710`, `526-542`.
- While lent, `run.slow.session` is closed, so `_schedule` returns at
  `if (sampler.session.state is SamplerStopped) return;` and never arms `_lose`. The slow streams
  (`fs`, `units`, `timers`, ...) get no reading and no `SamplerSkipped(notReady)` for as long as
  the user's step runs, so the pipeline opens no gap and panels show the last values as current.
  A sampler in backoff, by contrast, reports lost readings (class doc, lines 119-120).
- If the lend starts while the first probe is out, the probe ends as `SamplerGap(closed)`, which
  `_probe` treats as "no reply": `probeAt = now + 15 s` and the retry doubles, although nothing
  failed.
- Fix: when `run.slowLent > 0`, arm `_lose` for the slow streams instead of returning, and in
  `_probe` do not back off on `SamplerGapReason.closed`. Size S. Confidence medium (read; the
  scheduler test file was not checked for a lending-gap case).

## SMP-09 (bug, low): the scheduler's request futures have no error path

- File: `lib/src/sampling/sampling_scheduler.dart:916-924`, `573-596`, `619-657`, `528-563`.
- `SamplerSession.tick` and `onDemand` complete with an error (`HwsRequestError`) when the encoder
  refuses a request (`sampler_session.dart:462-468`). The scheduler chains `.then` without
  `onError` on all four call sites and sets `sampler.busy = true` or `run.probing = true` first.
  If one ever fails, the flag is never cleared, that sampler never ticks again for the run, and
  the error is unhandled in the engine isolate. The same holds for an exception thrown inside the
  callbacks (`_emit`, `_probed`, `_opsRead`). No current input reaches it: every scheduled
  collector is argument-less. It is a latent hang for the next collector added.
- Fix: clear the flags in `whenComplete` and route errors to a gap outcome. Size S.
  Confidence high that the path is unreachable today.

## SMP-10 (bug, low): settings setters accept non-finite doubles that poison every later save

- File: `lib/src/settings/device_settings_store.dart:509-524` (pane widths), `783-788`
  (thresholds), `1038-1054` (`_save`).
- The setters store the double unvalidated, and `_save` encodes the whole document lazily in the
  queue. `jsonEncode` throws on NaN or infinity; the value stays in `_values`, so every later
  save of any setting fails for the session. Getters already treat non-finite as absent
  (`_paneWidth`), the setters do not. Current callers pass layout widths and parsed percentages,
  so this needs a caller bug to trigger.
- Fix: reject or drop non-finite values in the setters. Size S. Confidence medium.

## SMP-11 (docs, low): pull-only (D14) is still stated as a current rule

- `klabautermann/AGENTS.md:107-108`: "Pull-only from the start (D14): nothing the app sends may
  push or write catalog records; a widget test guards it." The code runs
  `engineSyncPushPolicy = PushPolicy.normal` (`engine_sync.dart:69`) with `SaveServer`,
  `DeleteServer`, `SetServerPrefs`, `PutRule`, `RemoveRule` and pin publication, and 03 D14 says
  "As built in v1 (M5 plan M05), pull-only ends". `klabautermann_records.dart:637-638` still says
  local writes are "refused under `PushPolicy.none`", and 03 D63 (line 1052-1056) still describes
  the coordinator under `PushPolicy.none`.
- Fix: update AGENTS.md and the two comments to name the write requests the app test allows.
  Size S. Confidence high.

## SMP-12 (refactor, low): `retractServerPrefs` is test-only and diverges from the production path

- File: `lib/src/catalog/klabautermann_records.dart:639-654`. The extension is called only from
  `test/catalog/klabautermann_records_test.dart:546,561`. Production retracts through
  `EngineSync._retractPrefs` (`engine_sync.dart:940-944`), which stamps with `nextUpdatedAt` and
  updates `KlabautermannRecordStore`; the extension does neither, so the tests of retraction
  exercise a path the engine never runs. Remove it and point the tests at the engine path.
- Size S. Confidence high.

## SMP-13 (refactor, low): three copies of the shell-quote scanner, four of the serialized write tail

- `lib/src/sampling/argument_masking.dart:173-187` (`_shellWordEnd`), `198-211` (`_closesQuote`)
  and `228-243` (`_ShellLine.separatesBefore`) each re-implement the same backslash, single and
  double quote state machine. One scanner with a callback or a small state object would remove
  two copies in the file where a divergence is a masking hole.
- The "run after the tail, heal the tail" queue is written out in
  `catalog/engine_vault.dart:103-107`, `catalog/sync_state_file.dart:250-257`,
  `settings/device_settings_store.dart:1043-1053` and `history/history_store.dart:506-526`, with
  different error handling in each (SMP-04 is the one that got it wrong). A shared serial queue
  helper in core would fix the class.
- `_monotonicClock` is duplicated in `sampling_scheduler.dart:106-109` and
  `log_stream_router.dart:58-61`.
- Size M. Confidence high.

## SMP-14 (refactor, low): `sampling_scheduler.dart` (1,118 lines) mixes four jobs

- Cadence ticks, the probe and `ops` owed reads, the diagnostic bundle (`readDiagnostics`,
  `_readDiagnostics`, `_finishDiagnostics`, `_Diagnostics`, about 150 lines) and slow-sampler
  lending share one class and one `_schedule` with five early exits. The diagnostic bundle and
  the owed reads (probe, ops) are each a self-contained "one request on a free sampler" and could
  move behind a small interface (`nextRequest(sampler)`), leaving `_schedule` with ticks only.
  `settings/device_settings_store.dart` (1,183 lines) is about 40 near-identical getter and
  setter pairs that a typed key table would shrink.
- Size L. Confidence medium (maintenance cost, not a defect).

---

## Checked and found sound (no finding)

- Scheduler: overlap (busy skip and `missed` carry-over), cadence change (`profileChanged`
  realignment), server removed mid-tick (`identical(server.run, run)` guards on every callback,
  diagnostics completers answered in `_stop`), dead-peer hint ordering, probe backoff cap.
- Sampler session: one outstanding request, deadline timers cancelled on every completion path,
  late channel closed after stop, restart backoff reset only on a reply.
- Log follower and router: ring bounded by lines and bytes, in-progress line bounded at 256 KiB,
  resume cursor validated before reuse, double loss on a live link ends the stream, no double
  end event on `disconnect` (the service's synchronous ends empty `running` first), quota given
  back on every exit.
- SGR parser: total over hostile input, unterminated strings confined to their line, parameters
  clamped, C1 and C0 dropped.
- Sync state files: corrupt file set aside, newer schema read-only, unguarded never writes.
- Vault and recovery: every write under `exclusive`, no key minted while a vault or account
  exists, re-key staged through the journal with release in `finally` (already refuted in
  declined.md, not re-raised).
- Instance lock: single acquire per path per isolate, error codes per platform.

## Note for another slice (not verified here)

`SamplingScheduler._finishDiagnostics` (`sampling_scheduler.dart:677-684`) puts the raw `procs`
and `cron` payloads into `DiagnosticBundle` text, which crosses to the app unmasked; the export
sheet redacts through `RedactLines` (`engine_isolate.dart:1326`, a per-line redactor, not the
argv masker). Whether that redactor covers `-p<secret>` and option-value forms that
`maskCommandLine` covers was not checked.

## Overall assessment

The slice is carefully built: lifetimes, timers and channel closes are handled consistently, and
hostile host output is bounded almost everywhere. The one user-visible defect is the log level
regex (SMP-01), which a single long log line triggers. The rest are edge-path defects: sign-out
ordering, history queue error handling and rollup accounting, and masking coverage that follows
the written rule but misses common credential shapes. Tests are extensive but two rely on
synchronous timing or a test-only path (SMP-05, SMP-12). Refactoring pressure is concentrated in
the scheduler and the settings store.

## Coverage

- Read fully: `sampling/sampling_scheduler.dart`, `sampler_session.dart`, `sampler_timing.dart`,
  `sample_pipeline.dart`, `argument_masking.dart`, `subscriptions.dart`, `cron_zone.dart`;
  `logs/log_follower.dart`, `log_buffer.dart`, `line_reading.dart`, `log_stream_router.dart`,
  `sgr.dart` (parser part); `catalog/engine_sync.dart`, `klabautermann_records.dart`,
  `engine_vault.dart`, `engine_recovery.dart`, `sync_credentials.dart`, `sync_state_file.dart`;
  `settings/instance_lock.dart`; `history/history_store.dart`; `alerts/alert_evaluator.dart`.
- Skimmed: `sampling/sample_results.dart` (metric derivation not traced),
  `logs/log_service.dart` (lines 150-470), `logs/host_queries.dart` (first 140 lines),
  `catalog/sync_enrollment_file.dart`, `settings/device_settings_store.dart` (open, recovery,
  save, a few setters), the history, alert and masking tests.
- Not reached: `replay/` (bench stand-in engine), `catalog/snippet_mirror.dart`,
  `sync_verdict_files.dart`, `server_drafts.dart`, `keystore_channel.dart`,
  `logs/journal_record.dart`, `alerts/alert_rules.dart`, most test files, and the seance_core
  catalog library the sync code delegates to (`RecordCoordinator`, `FileVaultStore`).
