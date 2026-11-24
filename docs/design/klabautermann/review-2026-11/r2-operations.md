# Klabautermann review r2: operations slice (OPS)

Scope: `klabautermann_core/lib/src/{operations,admin,audit,jobs,services}` and
`klabautermann_host/lib/src/{commands,probe/sudo_rules.dart,cron,jobs}` on
origin/main. Paths below are relative to `klabautermann/packages/` unless they
start with `seance/` or `app/`. Read-only; one local experiment with GNU cp
(outside the repository) backs OPS-1.

Counts: 2 high, 4 medium, 5 low (11 findings).

---

## OPS-1 (bug, security) high: an edit of the login user's own file silently changes its group

- File: `klabautermann_host/lib/src/commands/edit.dart:238-253`
  (`_kCopyAttributesScript`), used by `EditCommands.copyAttributes` (:420) and
  `klabautermann_core/lib/src/operations/plans/edit_plan.dart` (the
  `copyAttributes` step of `_planFile`).
- Proof:
  ```sh
  if cp --attributes-only --preserve=mode,ownership,xattr -- "$t" "$tmp" 2>/dev/null; then
    exit 0
  fi
  ```
  GNU cp, run by a non-root user, treats a failed `chown` (EPERM) as success
  and prints nothing. The script trusts exit 0 and never compares the result.
  The BusyBox fallback (`chown -- "$o" "$tmp"`) would fail loudly, so only the
  GNU path, the common one, is silent.
- Verified locally (coreutils 9.4): target `nobody:daemon 0640`, run as
  `nobody` with only group `nogroup`: `cp --attributes-only
  --preserve=mode,ownership,xattr` exits 0 and the temp file is
  `nobody:nogroup 0640`. `replaceIfHash` then renames it over the target.
- Scenario: `/srv/app/.env` is `deploy:www-data 0640`, set up by root; the
  login user `deploy` is not in `www-data`. `edit_reader.dart:103`
  (`privileged: header.uid != c.profile.uid`) makes this an unprivileged
  edit. After Save the file is `deploy:deploy 0640`: the web server can no
  longer read it, and the run reports success. In the other direction a
  `0660` file whose group was a narrow one becomes readable and writable by
  the user's primary group (`users`, gid 100, is shared on SUSE and many
  NAS images). The design's "owner, mode, ACL and xattrs carried over" (D67,
  03 section 8.5) is not met and nothing says so.
- Fix: after a successful `cp`, compare `stat -c '%u:%g:%a'` of target and
  temp and exit with a new `EditExit` (for example `ownerNotCarried`) on a
  difference, mapped to a typed refusal the app words ("needs admin mode to
  keep the group"). Alternatively make the read mark the edit privileged
  when `header.gid` is not among the login user's groups. Add a host
  integration test with a foreign group.
- Size S. Confidence high.

## OPS-2 (bug) high: an Error in an unawaited engine future ends the engine isolate; a password with CR does it

- Files:
  - `klabautermann_core/lib/src/admin/admin_mode.dart:237-259` (`_check`
    catches `ElevationException`, `RemoteCommandException`,
    `ChannelOpenException` only).
  - `seance/packages/seance_core/lib/src/ssh/elevation.dart:262, 1105-1113`
    (`validatePassword` calls `_checkPassword`, which throws `ArgumentError`
    for `\n`, `\r` or NUL).
  - `klabautermann_core/lib/src/engine/engine_isolate.dart:2393`
    (`unawaited(admin!.enable(serverId))`), `:2440`
    (`unawaited(planRunner.run(...).then(...))`, no `onError`), `:747`
    (`unawaited(operations?.listed(...))`), `:577`
    (`unawaited(operations?.adminOn(...))`).
  - `klabautermann_core/lib/src/engine/engine_client.dart:92-118`: the
    isolate is spawned with default `errorsAreFatal`, and the comment says
    "errors are fatal in a spawned isolate". There is no `runZonedGuarded`.
- Scenario: the admin password dialog returns the raw field text
  (`app/klabautermann_app/lib/ui/prompts/elevation_dialog.dart:51`,
  `pop(_password.text)`, no input formatter). A password pasted from a
  Windows clipboard or a password manager note ends in `\r\n`; Flutter's
  single-line field strips `\n` only. `enable` -> `_check` ->
  `validatePassword` -> `ArgumentError`, which no `on` clause catches, so
  the unawaited `enable` future fails in the root zone: the engine isolate
  dies with every link, stream and running plan. (Engine path confirmed by
  reading; the paste behaviour of the field is the one assumption, medium.)
- Same class, no handler at all: `OperationRunner.run` promises "Always ends
  with one ActionFinished" (`operation_runner.dart:103`), but `_run` only
  catches five exception types; anything else (an `ArgumentError` from
  `ElevatedExecutor._checkArgv`, a `StateError` from a callback, a throwing
  `_finished` hook) skips `ActionFinished`, leaves the app's run pending and
  kills the isolate. The acknowledgement path at `engine_isolate.dart:1833`
  already carries the right comment ("if it does, the engine answers rather
  than dying with every link") and an `onError`; the run, enable, listed and
  adminOn calls do not.
- Also in `operation_tracker.dart:443`: `OperationCommands.opCleanup(path,
  ids)` is built outside `_quietly`, with `path` taken from the host's `dir`
  line. A path `_checkOpsDir` refuses (a `//` from an `XDG_STATE_HOME` with a
  trailing slash, anything under `/tmp`) throws `HostCommandError` out of
  `_listed` and `adminOn`, both unawaited. Hard to reach today because the
  launch refuses the same path, but the listing is remote input.
- Fix: (1) in `_check`, add `on Object` -> `AdminFailure.unavailable` (or
  reject CR, LF and NUL as a wrong password); strip or refuse line breaks
  in the dialog. (2) In `OperationRunner.run`, wrap `_run` in a catch-all
  that returns `ActionFinished(failed, transport)` and still calls
  `_finished`. (3) Give the four unawaited calls an `onError`. (4) Move
  `opCleanup` into the `_quietly` closure.
- Size S to M. Confidence high (engine), medium (trigger through the UI).

## OPS-3 (security) medium: a one-off container command reaches the preview, the audit log and its export unmasked

- Files: `klabautermann_core/lib/src/operations/plan_types.dart:160-180`
  (`ExecStep.display` prints `jsonEncode({'Cmd': argv, ...})`),
  `operations/plans/docker_plans.dart:240-245` (argv straight from the
  intent), `audit/audit_log.dart:77` (`_redactor.redact(step.display)`),
  `operations/danger.dart:24`.
- What is wrong: cron lines and snippets carry a `shownArgv` masked by 8.9's
  argument rules (`host_plans.dart:366`, `:398-403`: "The preview, the
  linter and the audit show the command masked"). `ExecStep` has no shown
  form, so CTX-08 relies on `SecretRedactor` alone, whose patterns are
  provider tokens, JWTs, `bearer` and `password=`/`token:` assignments
  (`seance/.../llm/redaction.dart:19-45`). `-p<secret>`, `--password
  <secret>`, `curl -u user:pass` and URL credentials pass through.
- Scenario: Run command in a database container with
  `mysql -uroot -phunter2 -e 'show databases'`. `audit/<server>.jsonl` keeps
  `POST .../exec {"Cmd":["mysql","-uroot","-phunter2",...]}` for 90 days,
  and Activity's Copy exports it; 03 section 8.10 states "The log stores
  redacted steps only, so E24's export has nothing secret to include".
- Fix: give `ExecStep` a `shownArgv` built with `maskCommandLine` (as
  `_planSnippet` does) and use it in `display` and `lintSteps`; add an audit
  test with `-p<secret>`.
- Size S. Confidence high.

## OPS-4 (bug) medium: any unelevated step that prints "Access denied" is reported as "admin mode required"

- File: `klabautermann_core/lib/src/operations/operation_runner.dart:265-272,
  456-458`.
- Proof:
  ```dart
  !step.elevated && _polkitRefused.hasMatch(result.stderr)
      ? ActionFailure.adminRequired : ActionFailure.stepFailed,
  final _polkitRefused = RegExp(r'Interactive authentication required|Access denied');
  ```
  The check is meant for `systemctl --no-ask-password` (03 section 7.5) but
  runs for every non-elevated `ShellStep`.
- Scenario: JOB-19 "run now" of a backup cron line, or a snippet, whose
  command prints MySQL's `ERROR 1045 (28000): Access denied for user ...`
  and exits 1. The run ends as `adminRequired`, so the app tells the user to
  turn admin mode on; admin mode never applies to a snippet and does not
  change a cron line that runs as the login user. Same for a host
  `docker pull` answered with "denied: access denied" style text containing
  the phrase.
- Fix: apply the polkit mapping only to unit plans (`plan.kind` in the
  systemctl kinds, or `step.argv` containing `systemctl`). Add a runner
  test; none covers this mapping today.
- Size S. Confidence high.

## OPS-5 (bug, test) medium: the power step's outcome is guessed from the transport, both ways, and has no runner test

- File: `klabautermann_core/lib/src/operations/operation_runner.dart:211-237`.
- What is wrong:
  1. `on RemoteCommandException { return succeeded }` covers every transport
     failure, including `SshLink.run`'s 30 s timeout (the step keeps
     `StepTimeout.quick`). A `systemctl reboot` that blocks (an inhibitor, a
     hung `shutdown` on a non-systemd host) or a link that dropped for an
     unrelated reason is audited and shown as a successful reboot. The
     ordinary step branch (`:243-250`) already tells a timeout from a lost
     link with a stopwatch.
  2. `if (result.exitCode != 0) return failed(stepFailed)`: `exitCode` is
     `int?`, and `seance/.../ssh/remote_process.dart:313-318` returns a
     result with `exitCode: null` when the channel closes without an exit
     status, which is what a dying sshd produces (the detached launcher
     handles exactly this at `detached_runner.dart:214-230`). A reboot that
     took the channel that way is reported as a failed step.
- Test gap: `operation_runner_test.dart` has no `endsLink` case at all
  (only `host_plans_test.dart` checks the flag is set), so none of the three
  branches is pinned.
- Fix: for `endsLink`, treat a null exit status as the step taking effect,
  and a `RemoteCommandException` at or past the step's timeout as
  `timedOut`; add tests for exception, timeout, null, zero and non-zero.
- Size S. Confidence medium (the null-status path depends on how the SSH
  library ends the channel on disconnect).

## OPS-6 (bug) medium: a user operation directory with non-ASCII characters is cleaned up at the wrong path and its result returns unacknowledged

- Files: `klabautermann_host/lib/src/parse/ops.dart:291` (`latin1.decode`
  of each header line, including `dir <kind> <state> <count> <path>`),
  consumed by `klabautermann_core/lib/src/operations/operation_tracker.dart`
  `_cleanUp` (:430-470), `_pruneUser` and `logPath` (:286-292).
- What is wrong: the launch resolves the same directory through
  `link.run`, which decodes UTF-8, so the operation starts in the right
  place. The listing's path is decoded as Latin-1, then quoted and sent
  back UTF-8 encoded, so `/home/jörg/.local/state/klabautermann/ops` becomes
  a different byte string. `_checkOpsDir` accepts it (C1 code points are not
  rejected).
- Scenario: after the user acknowledges a result, `rm -f --
  <mojibake>/<id>.json ...` exits 0 without removing anything, so
  `_store.remove` drops the note and the operation leaves the list; the next
  `ops` read lists the record again, unacknowledged and without its launch
  facts, and acknowledging it writes a second audit record. The output view
  (`logPath`) tails a file that does not exist, and the 7-day prune never
  runs on that directory.
- Fix: decode the `dir` line's path as UTF-8 (malformed allowed), or have
  the tracker use the directory the engine resolved for the launch. Add a
  parser test with a non-ASCII path.
- Size S. Confidence medium (traced, not executed).

## OPS-7 (drift) low: an elevated step's preview and audit line are not the command that runs

- Files: `klabautermann_core/lib/src/operations/plan_types.dart:66-75,
  118-123` (`display` = `'sudo: $_shownLine'`, built with
  `HostCommands.commandLine`), `operation_runner.dart:380-395`
  (`session.executor.run(step.argv, ...)`),
  `seance/.../ssh/elevation.dart:929-946`.
- What is wrong: the preview and the audit show
  `sudo: sh -c 'export LC_ALL=C TZ=UTC SYSTEMD_PAGER= NO_COLOR=1; exec "$@"' sh <argv>`,
  and for `discardOutput` a trailing `>/dev/null 2>&1`. What runs is
  `env LC_ALL=C sudo -n -- <argv>` (or the prelude): no `TZ=UTC`, no
  `SYSTEMD_PAGER=`, no `NO_COLOR`, and the output is not discarded on the
  host (it is only dropped by the runner). 03 section 8.5 says the preview
  shows "each step's exact command line" and 8.8 that every remote command
  runs under `LC_ALL=C TZ=UTC`. No elevated step parses zone-dependent
  output today, so the effect is the mismatch itself.
- Fix: run elevated steps as the wrapper argv
  (`['sh','-c', <export script>, 'sh', ...argv]`, plus the redirect inside
  the script for `discardOutput`), or render the elevated form honestly.
- Size S. Confidence high.

## OPS-8 (bug) low: reads of the backup index and manifest ignore `truncated`, so a large index can never be pruned

- Files: `klabautermann_core/lib/src/operations/plans/backup_plans.dart:55-63,
  86-90`, `plans/edit_plan.dart:381-408`.
- What is wrong: `link.run` and the executor cap output at 256 KiB and set
  `RemoteCommandResult.truncated`; neither planner checks it. An index past
  that size (about 2,000 backups at ~120 bytes a line) reads short. Either
  the cut line is skipped and `parseBackupIndex` warns, so the plan is
  refused as `invalidTarget`, or the cut falls on a line end and the write
  step's hash check (`sha256` of the truncated text) fails as
  `contentChanged` every time. Keep-last and Remove backups, the only tools
  that shrink the index, stop working exactly when they are needed.
- Fix: refuse with a specific reason on `truncated`, or read the index with
  a larger `maxOutputBytes`; hash on the host instead of over the decoded
  text.
- Size S. Confidence medium.

## OPS-9 (bug) low: "run now" as another user always uses `runuser`; `RunAsTool.su` is never selected

- Files: `klabautermann_host/lib/src/commands/commands.dart:492, 1269-1283`,
  `klabautermann_core/lib/src/operations/plans/host_plans.dart:435-443`.
- What is wrong: `_cronArgv` calls `HostCommands.runCronCommand(script,
  asUser: runAs)` with the default tool. `RunAsTool.su` has no caller in
  any `lib/`. On a host without util-linux `runuser` (Alpine and other
  BusyBox systems, which the probe otherwise supports) JOB-19 for a system
  table line or another user's crontab fails with exit 127.
- Fix: choose the tool from a probe fact (or try `runuser` then `su` in one
  `sh -c`), or delete the `su` branch and refuse with a reason.
- Size S. Confidence high.

## OPS-10 (refactor) low: dead and duplicated pieces in the slice

- Dead public API: `generateOpId` (`klabautermann_host/.../operations.dart:161`)
  duplicates `newOpId` (`klabautermann_core/.../detached_runner.dart:125`),
  which is the only one the engine calls; `EditCommands.crontabWrite`
  (`edit.dart:539`) was superseded by `crontabWriteIfHash` and has no caller.
- Duplicated constants: `_kTicksGone = 3` (`operation_runner.dart:461`) and
  `_kProcessGone = 3` (`operation_tracker.dart:38`) restate the exported
  `kStartTicksGone` (`proc_stat.dart:8`).
- Duplicated helpers: `_userBackupsDir` in `edit_plan.dart:469` and
  `backup_plans.dart:136`; `_planned`/`_refused` in four planner files and
  `_runner` in two; "sha256 of UTF-8 text" in `edit_reader.dart:189`,
  `edit_plan.dart:406`, `backup_plans.dart:89` and `protocol.dart:3074`;
  the 8-byte hex token in `edit_plan.dart` `_token` and
  `plan_registry.dart` `_newId`.
- Fix: one `plan_support.dart` for the planner helpers, use
  `kStartTicksGone`, drop the dead builders.
- Size M. Confidence high.

## OPS-11 (test) low: risky branches without a test

- `operation_runner_test.dart`: no `endsLink` case (OPS-5), no case for the
  polkit mapping (OPS-4), no case for an unexpected throw inside `_run`
  (OPS-2).
- `edit` pipeline: no test where `cp --attributes-only` succeeds without
  carrying the group (OPS-1); the unit tests assert the argv only.
- `ops` parser: no non-ASCII directory (OPS-6).
- Size M. Confidence high.

---

## Checked and found sound (no finding)

- Shell quoting: every builder returns argv; `HostCommands.commandLine`
  quotes each word once with `quoteShellWord`; scripts are constants with
  values as positional parameters; `detachedArgv` joins already-quoted
  lines; the `systemd-run` `$` -> `$$` escape is applied to every word.
  `ArgValidators` gate unit names, users, paths, cursors and free text.
- Elevation prelude and ladder (seance_core): password only on stdin,
  stderr classified, rung 4 retry bounded by the step timeout.
- Confirmation: `RunAction` re-checks safety policy, tier and typed phrase
  in the engine; a plan is taken once; stale and expired plans are refused.
- Edit pipeline otherwise: path and temp validation, `set -C` temp, hash
  compare-and-swap, symlink refusal, root-only directory check, cleanup on
  failure, manifest and index hash guards.
- Detached wrapper: parameter re-checks, directory ownership and symlink
  refusal, exclusive log creation, atomic record writes; the parser bounds
  pid, exit and times and rejects forged ids and units.
- Audit log: serialised appends, redacted steps, damaged-line recovery,
  newer-version lines preserved.
- Crontab document: byte-preserving edits, pause marker round trip.

## Overall assessment

The command-construction layer is disciplined: I found no injection path, and
the quoting, validators and confirmation checks hold up. The real defects are
at the edges: one host tool whose success is trusted without checking the
result (OPS-1), error handling that assumes only a known set of exceptions in
futures nobody awaits (OPS-2), and masking applied to two of the three ways a
user types a command (OPS-3). The runner's outcome mapping has two heuristics
that misreport (OPS-4, OPS-5). Fixes are small; OPS-1 to OPS-4 deserve tests
with them.

## Coverage

- Read fully: host `commands/edit.dart`, `commands/operations.dart`,
  `probe/sudo_rules.dart`, `cron/document.dart`, `cron/managed.dart`; core
  `operations/operation_runner.dart`, `plan_types.dart`,
  `operation_plan.dart`, `operation_tracker.dart`, `detached_runner.dart`,
  `edit_reader.dart`, `stack_edits.dart`, `confirmation.dart`,
  `plan_registry.dart`, `protected_targets.dart`, `danger.dart`,
  `operations_shown.dart`, `plans/edit_plan.dart`, `plans/host_plans.dart`,
  `plans/backup_plans.dart`; `admin/admin_mode.dart`, `elevated_link.dart`,
  `safety_policy.dart`, `user_crontabs.dart`; `audit/audit_log.dart`,
  `host_audit_line.dart`; `jobs/cron_pause.dart`;
  `services/unit_queries.dart`. Outside the slice, as far as the traces
  needed: `seance_core` `elevation.dart` (run, start rungs, command
  builder, checks), `remote_process.dart` run, `parse/ops.dart`, and the
  engine's PlanAction, RunAction, SetAdminMode and launch wiring.
- Skimmed: host `commands/commands.dart` (commandLine, systemctl family,
  guarded kill, crontab spool, journalctl, auditLine, tail, du, run-cron,
  power, package refresh, onCalendar; the read-only probe scripts only by
  signature), `cron/evaluate.dart`, `jobs/jobs.dart` (first 330 lines);
  core `plans/redeploy_plan.dart` (runner choice, compose plan, host pull,
  `detachedArgv`), `plans/docker_plans.dart` (exec plan and protection
  call sites only).
- Not reached: host `cron/expression.dart`, `jobs/job_history.dart`,
  `jobs/schedule.dart`, `commands/stack_scan.dart`, `proc_stat.dart`;
  core `operations/footprint.dart`, `impact.dart`, `ownership.dart`,
  `command_words.dart`, most of `docker_plans.dart`;
  `admin/{firewall,restarts,smart,sshd_posture}.dart`;
  `jobs/job_history_query.dart`;
  `services/{accounts,disk_usage,packages,timer_detail}.dart`; the test
  suites beyond grep checks for coverage of the reported branches.
