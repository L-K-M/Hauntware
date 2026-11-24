# Wave 7 SECRETS (plan rows 2.4, 1.6, 2.10)

- PR #811 `klab/secret-masking`, head `db5b4b340` (3 commits, rebased on
  main after #805).
- PR #813 `klab/history-fixes`, head `672210b08` (1 commit, rebased on
  main after #805).
- Not subscribed, not merged. Worktrees removed.

All findings were confirmed on main first (red tests below are that
confirmation).

## PR #811, masking

### UIA-01 FIXED (`db5b4b340`)
- `klabautermann_core/lib/src/logs/host_queries.dart`:
  `maskDiagnosticBundle`, called where the `DiagnosticBundleQuery` is
  answered. `procs`: each `==> pid/cmdline <==` record masked as its
  arguments (split at `\x1f`, newlines inside an argument kept), `ps`
  fallback rows and payloads without the block masked per line. `cron`:
  every line. An empty program stands in front, one budget per section.
- Tests: `test/logs/host_queries_test.dart` group "a diagnostic bundle
  crosses with its command lines masked ... (UIA-01)" (4 tests, asserts
  the section text and the text after the real `SecretRedactor` for
  the report's samples: mysql -p, curl -u, redis-cli -a, --password
  value, --password=, postgres URL, sshpass -p, docker login -p,
  PGPASSWORD=, mysqldump cron line). App:
  `test/diagnostic_bundle_test.dart` "the exported text carries no
  command-line secret, with secrets included or not".
- Red: 3 of the 4 core tests failed with the mask call stashed (the
  fourth is the never-throws guard). Green: file +21.
- Limitation: "Include secrets" no longer shows these arguments. Both
  forms would need a field on `DiagnosticSection` (`lib/src/engine/
  protocol.dart`) and a second line list in `log_export.dart`, neither
  mine. `diagnosticsHint` (ARB, l10n regenerated) now says so. DEFERRED
  as a follow-up if the raw form is wanted.
- Report's side notes not done: URL-credential and env-prefix coverage in
  seance_core's generic `SecretRedactor`, and its per-line PEM rule.

### OPS-3 FIXED (`3cb5ea562`)
- `operations/plan_types.dart`: `ExecStep.shownArgv`, masked in the
  constructor; `display` shows it. No change under `plans/` was needed.
  `plan_types.dart` is not on my owned list nor on the forbidden one; it
  is the only place the display string can be masked.
- Tests: `docker_plans_test.dart` "the preview shows the command masked
  ... (OPS-3)", `audit_log_test.dart` "a one-off container command's
  secrets never reach the log or a read of it".
- Red: both failed (display and the stored jsonl held `-phunter2`).
  Green: `test/audit test/operations` +302.
- `danger.dart` (not mine) still lints the real argv, which is what
  runs; left as is.

### SMP-02 FIXED (`531f098ec`)
- `argument_masking.dart`: `_secretColon` (name:value with a key word,
  up to 8 key words per token, path and host guards), `_keptOfAnyTool`
  (colon forms and secret headers for every tool), pending value handed
  on from a one-token argument. `klabautermann_docker/lib/src/
  masking.dart`: token-only userinfo for http and https.
- Kept from impl-mask.md/declined.md: known tools table, secret headers,
  budget, linear scans, separate masks for scheme and credential.
- Tests: group "colon forms, token-only URL userinfo and secret headers
  outside the known tools (SMP-02)" (9 tests), 3 new linear-time cases,
  `masking_test.dart` "a token that is all of an http URL's userinfo".
- Red: 6 failures in the core file, 1 in the docker file. Green: +57
  and +18.
- One existing expectation changed: `app -H Authorization:x` after a
  separator was pinned as visible; it is masked now (the finding asks
  for that). The test keeps its point with `app -b sid`.
- Partly declined: the report proposes masking a colon-less userinfo for
  every scheme. Limited to http(s): `ssh://git@host`, `postgres://app@db`
  are login names, and the existing test "URLs without a password" pins
  `ssh://me@host/repo` visible.

### DKR-9 FIXED for log driver options, DEFERRED for volumes (`531f098ec`)
- `masking.dart`: `maskedDriverOptions` (exported from the docker barrel,
  one line there). `inspect_masking.dart`: `maskContainerInspect` masks
  `HostConfig.LogConfig.Config`.
- Volumes: `maskVolumeOptions` exists and is tested, but the call site is
  `docker_watch.dart:765` (`DockerVolumesPayload(_volumes!)`), not mine.
  One line: `DockerVolumesPayload(maskVolumeOptions(_volumes!))`.
  Network driver and IPAM options (`models/network.dart`) untouched.
- Tests: `test/docker/inspect_masking_test.dart` (new, 2 tests),
  `masking_test.dart` "driver options mask ...". Red: the log config
  test failed before the fix. Green: +2 and +18.

## PR #813, history (`672210b08`)

### SMP-04 FIXED
- `_queue` and `forget` catch every error; `_fromSeconds` returns null
  outside DateTime's range, so bucket and gap slots with garbage read as
  empty. Test "a ring slot that holds garbage costs that slot ...".
- Red: `RangeError (millisecondsSinceEpoch)`. Green.

### SMP-05 FIXED
- `_Accumulator.added` beside `values`; `_closeMinute` folds `added`.
- The timing test now awaits `idle` between the observes. Red: count 7,
  mean 28.57 instead of 5 and 30 (the report predicted 6). New test for
  flush-then-continue and a clock step back. Red: count 7. Green.

### SMP-07 FIXED
- `state.firedSince ?? state.since`; `@visibleForTesting stateOf`.
- Red (with `stateOf` added, fix reverted): since 12:20:30 instead of
  12:20:00. Green.

### SMP-10 FIXED
- The three setters throw `ArgumentError` for a non-finite value and
  store nothing. Red: `JsonUnsupportedObjectError`. Green.

## Checks (real results)

PR #811, after the rebase:
- `dart analyze --fatal-infos packages/klabautermann_core
  packages/klabautermann_docker`: No issues found.
- `dart test packages/klabautermann_core`: +2057 ~30 all passed.
- `dart test packages/klabautermann_docker`: +427 all passed.
- App `flutter analyze`: No issues found. Whole `flutter test`: +2334
  all passed, before the rebase and before the last `_maskedLine`
  change in core; after both, `diagnostic_bundle_test` and
  `container_details_test` +30 passed.
- `dart run tool/protocol_guard/bin/check.dart`: exit 0.
- `dart format --set-exit-if-changed` on the changed files: clean.

PR #813:
- `dart analyze --fatal-infos packages/klabautermann_core`: No issues.
- `dart test packages/klabautermann_core`: +2037 ~30 all passed before
  the rebase; history, alerts and settings tests +111 after it.
- App not run (unchanged).

Not run: `tool/import_guard` (needs every product resolved; it failed
on a missing poltergeist_bench resolution), klabautermann_host suite
(unchanged), `scripts/check-workflows.sh` (no workflow or script
touched).

## STATUS sentences (docs/STATUS.md not edited)

- Masking: "the masker also reads `name:value` pairs with a secret
  name (`{"password":"…"}`), an http URL's userinfo that is one token,
  and secret headers of any tool; a one-off container command's step and
  the diagnostic bundle's `procs` and `cron` sections cross masked by the
  same rules, and a log driver's options by key."
- Open: "volume and network driver options still cross unmasked (not
  rendered); the diagnostic bundle has no raw form for command lines."
- History: "a damaged ring slot reads as empty and never stops the
  write queue; a minute continued after a restart is counted once in its
  10-minute bucket."

03-ARCHITECTURE §8.9 was not edited either; it should gain the colon
form, the http userinfo token and "secret headers of any tool".

## Noticed

- The colon rule over-masks a bare `name:tag` or `host:port` whose name
  holds a key word and has no `/` before it: `keycloak:24`,
  `keydb:6379`, `authelia:latest`. Namespaced image references and URLs
  are not affected. Safe direction; reveal undoes it in Processes.
- `"password" : "x"` (a blank before the colon) is not caught.
- Only the first 8 key words of one token are tried for the colon form.
- `_maskHostConfig` rebuilds `ContainerHostConfig` field by field
  (no copyWith); a field added to the model must be added there.
- A procs record's program is masked as an operand, so a login shell
  named `-pwsh` shows as `-p********` in the bundle.
- CHANGELOG: both PRs append at the end, so the second to merge will
  conflict there (as #805 did with both).
