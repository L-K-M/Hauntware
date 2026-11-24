# Klabautermann review r5: klabautermann_host (HWS program, frames, parsers, probe, access, rates, rules)

Scope: `klabautermann/packages/klabautermann_host/lib/src/{hws,parse,probe,access,rates,rules}`
(not `commands/`, `cron/`, `jobs/`, `probe/sudo_rules.dart`). Paths below are
relative to `klabautermann/packages/klabautermann_host/` unless they start
with `packages/` or `app/`.

How findings were verified. Besides reading, I assembled both sampler
programs with `buildSamplerProgram`, ran them under dash, bash and BusyBox
ash (1.36.1) on this machine, fed the raw output to `HwsTickAssembler` and
the parsers, and ran parsers on crafted payloads. Scratch scripts only
(`scratchpad/hst/`), nothing in the repository was touched and no test
suite was run. "Verified by run" below means I observed the result.

Counts: high 0, medium 5, low 8.

---

## HST-1 (bug, medium) One unreadable mount makes the whole `fs` stream unavailable

- Where: `lib/src/hws/program.dart:495-510` (`c_fs`), consumed at
  `packages/klabautermann_core/lib/src/sampling/sample_pipeline.dart:279-283`
  and `sample_results.dart:50-58`.
- What: `c_fs` derives the section status from `df`'s exit status:
  ```sh
  b=$(hw_run df -PT -B1 </dev/null 2>&1); rb=$?
  ...
  sb=$(hw_st "$rb" "$b"); si=$(hw_st "$ri" "$i")
  case $sb:$si in ok:ok) st=ok ;; ... *) st=error ;;
  ```
  and the pipeline drops the payload of every non-ok section
  (`final unavailable = collectorUnavailable(s); if (unavailable != null) { results[stream] = unavailable; continue; }`).
  `df` exits 1 when a single mount cannot be statted, while printing
  every other row. The fragment's own doc comment says "partial output
  still parses" (program.dart:486-487); it never reaches the parser.
- Scenario: a server with one dead sshfs/FUSE mount ("Transport endpoint
  is not connected"), a stale NFS handle or a CIFS "Host is down". GNU df
  only skips EACCES/ENOENT silently; BusyBox df fails on any `statfs`
  error, so on Alpine a non-root login with one unreadable mount is
  enough. The disk panel then shows "error"/"denied" and no filesystem at
  all, exactly when a mount is broken. Verified by run: a `df` wrapper
  that prints one such stderr line, the real table and exits 1 yields
  `S fs error 1449`.
- Second defect behind it: with `2>&1` the stderr lines sit inside the
  table. `_dfRows` (`lib/src/parse/fs.dart:199-213`) treats a short line
  as a wrapped device and joins it to the next row; the header `continue`
  keeps the carry. Verified by run: a leading
  `df: /mnt/dead: Transport endpoint is not connected` turns the `/` row
  into `device: "df: /mnt/dead: ...", type: "/dev/sda1", usedBytes: <size>,
  capacityPercent: 600000000, mountPoint: "40% /"`. So simply mapping
  exit 1 to ok would publish garbage.
- Fix: send `df` stderr to its own block (`== errors ==`) or drop it, set
  `st=ok` when the table has at least one data row and report the failed
  mounts as a per-row/partial marker; in the parser ignore `df:` lines.
  Add a fixture with a failing mount.
- Size M. Confidence high.

## HST-2 (security, medium) One unprivileged process can blank every later command line in the process list

- Where: `lib/src/parse/procs.dart:450-475` (`_parseCmdline`).
- What: a `==> <pid>/cmdline <==` line is judged forged only when it
  repeats a pid or breaks the byte order. A forged header that keeps the
  order is accepted as real, even for a pid that is not in the rows
  (`flush()` only counts it as `skipped`), and it advances `lastPidText`:
  ```dart
  final forgedHeader = pid == null || seen.contains(pid) ||
      (lastPidText.isNotEmpty && pidText.compareTo(lastPidText) <= 0);
  ...
  flush(); seen.add(pid); lastPidText = pidText; current = pid;
  ```
  Every real header after it then compares `<= lastPidText`, is counted
  as forged and marks its own pid "command line unavailable".
- Scenario: any local user starts a process whose argv contains
  `\n==> 99999999/cmdline <==\n` (fits easily in the 1536-byte cap). All
  processes that sort after it in byte order lose their command line in
  the admin's process view; a pid starting with `1` (cheap to obtain by
  forking) covers almost the whole list. Verified by run with six rows:
  the attacker's row reads `argv=[attacker]`, the five others
  `argv=null`, warnings `5 forged head header(s), 1 header(s) for pids
  outside the rows`. The design text (03 §7.2, line 3615-3620) only
  describes repeated or out-of-order headers, so this path is not an
  accepted trade-off. Rows and comm stay visible, hence medium.
- Fix: `head` is only given the kept rows' paths, so a header naming a
  pid outside `rowPids` is always argument text: treat it as forged
  content and do not advance the order. For a forward forgery that names
  a real later row, resolve the conflict the other way: when a header for
  a not-yet-seen row arrives that is below `lastPidText`, condemn the
  earlier jump (the entry it interrupted and the pid it named) instead of
  the new header. Add both cases to `procs_test.dart`.
- Size M. Confidence high.

## HST-3 (bug/drift, medium) `ArgValidators.unitName` rejects systemd's own `\x2d` escaping

- Where: `lib/src/hws/collector.dart:243-246`.
  ```dart
  final _unitNamePattern = RegExp(
    '^[A-Za-z0-9:_.\\-]+(@[A-Za-z0-9:_.\\-]*)?\\.(service|socket|...|scope)\$');
  ```
- What: systemd unit names may contain `\` (systemd.unit(5): letters,
  digits, `:`, `-`, `_`, `.`, `\`), and every unit derived from a path or
  device with a hyphen has one. 03 §7.5 says names are "validated against
  the systemd unit-name grammar"; this grammar is narrower. The validator
  runs before quoting, so the backslash carries no injection risk.
- Scenario: the captured fixture already holds such units
  (`test/fixtures/ubuntu-2404-runner-dash/units.txt`:
  `run-credentials-systemd\x2dresolved.service.mount`,
  `dev-disk-azure-os\x2dpart1.device`); common service cases are
  `systemd-fsck@dev-disk-by\x2duuid-....service` and
  `systemd-cryptsetup@luks\x2d....service`. The list shows them, but
  every `HostCommands` builder that calls `_check(ArgValidators.unitName, ...)`
  (commands.dart:545, 578, 590, 624, 755, 773, 826, 1236: actions, unit
  file, resources, sockets, load state, timer detail) throws
  `HostCommandError`, so status, logs and actions are refused for them.
  `test/hws/request_test.dart:96-101` has no backslash case.
- Fix: add `\\\\` to both character classes; add tests with the fixture's
  names.
- Size S. Confidence high.

## HST-4 (bug, medium) `cron`: an unreadable `/etc/crontab` discards the user's own crontab, and unreadable cron directories read as empty

- Where: `lib/src/hws/program.dart:1109-1128` (`c_cron`).
  ```sh
  if [ -r /etc/crontab ]; then ... elif [ -e /etc/crontab ]; then st=denied; fi
  for _f in /etc/cron.d/*; do [ -f "$_f" ] && [ -r "$_f" ] || continue ...
  for _f in "/etc/cron.$_d"/*; do [ -e "$_f" ] || continue ...
  ```
- What, part a: `st=denied` applies to the whole section, and the
  pipeline drops non-ok payloads (see HST-1), so the successfully read
  `crontab -l` and `/etc/cron.d` are thrown away.
  Part b: an unreadable `/etc/cron.d` (glob does not expand), an
  unreadable file in it, and unreadable `cron.{hourly,...}` directories
  are skipped silently, so the section says ok with no jobs. That is a
  skipped read reported as "none" (AGENTS.md "Never report a skipped or
  failed operation as successful"; 03 "unknown stays unknown").
- Scenario: CIS-hardened hosts set `/etc/crontab` to 0600 and
  `/etc/cron.d`, `/etc/cron.daily` and so on to 0700 root. A non-root
  login there gets "denied" for the whole Jobs cron stream although its
  own crontab was read; where only the directories are closed, the panel
  can state that the server has no cron jobs
  (`app/klabautermann_app/lib/ui/jobs_panel.dart:481-489`).
- Fix: keep `st=ok` and report per-source state in the payload (for
  example `== sources ==` lines `etc_crontab denied`, `cron_d denied`,
  using `[ -d ] && [ ! -r ]` and `[ -e ] && [ ! -r ]`), and let the
  parser and panel show those sources as unreadable.
- Size M. Confidence high (code path); the hardened-permission values are
  from the CIS benchmarks, not re-checked here.

## HST-5 (bug, medium) `parseFs` turns a device name with a space into a wrong row

- Where: `lib/src/parse/fs.dart:191-215` (`_dfRows`) and `149-166`.
- What: rows are split on whitespace and indexed from the left; the only
  sanity check is `int.tryParse(joined[width - 4])`. A source with a
  space shifts every column by one and still passes, because the size
  lands at that index.
- Scenario: `df -P` prints sources verbatim; rclone remotes
  (`gdrive:My Drive`), CIFS shares (`//nas/Shared Docs`) and some FUSE
  sources contain spaces. Verified by run:
  `gdrive:My Drive fuse.rclone 5000 2000 3000 40% /mnt/g` parses with
  status ok as `device: "gdrive:My", type: "Drive", sizeBytes: null,
  usedBytes: 5000, availBytes: 2000, capacityPercent: 3000,
  mountPoint: "40% /mnt/g"`, and its inode row no longer joins
  ("inode row for unmounted"). The disk panel shows a mount named
  `40% /mnt/g` at 3000 %.
- Fix: parse from the right, anchored on the fixed columns, for example
  `^(.*\S)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%|-)\s+(/.*)$` for
  blocks and the same idea for inodes; keep the wrapped-line join only
  for lines without the numeric tail.
- Size S. Confidence high.

## HST-6 (bug, low) CPU gauge drops out when `iowait` goes backwards

- Where: `lib/src/rates/rates.dart:91-97` (`cpuDeltaPercent`), and
  `112-124` (`perCpuBusyPercent`, where idle is idle plus iowait).
  ```dart
  if (n < p) { if (i < primary) return null; continue; }
  ```
- What: any decrease of a primary field is read as a counter reset. The
  kernel documents that `iowait` in `/proc/stat` is not monotonic
  (Documentation/filesystems/proc.rst: "The value of iowait field in
  /proc/stat will decrease in certain conditions"); monitoring agents log
  this regularly on tickless kernels. Resets are already detected through
  uptime and `btime` in `sample_results.dart:156-164`.
- Scenario: a host doing I/O on an otherwise idle CPU: single ticks
  return `null` for the aggregate (and the affected cores), which shows
  as holes in the CPU series and suspends `cpu.busy` rule evaluation for
  that tick.
- Fix: clamp a negative `iowait` (and the summed per-core idle) delta to
  zero instead of returning null; keep null for the other fields. Add a
  test.
- Size S. Confidence medium (kernel behaviour from documentation, not
  reproduced here).

## HST-7 (drift/test, low) systemd JSON timers: `left` and `passed` are absolute, `last: 0` means never

- Where: `lib/src/parse/timers.dart:41-46, 300-306`; fixtures
  `test/fixtures/{debian-12,ubuntu-2404}/timers.txt` (hand-written) against
  `test/fixtures/ubuntu-2404-runner-dash/timers.txt` (captured).
- What: the model documents `leftUs`/`passedUs` as "Relative
  microseconds for the LEFT and PASSED columns". The only real capture
  shows `"next":1792189800000000,"left":1792189800000000` (left equals
  next, an absolute stamp), `"passed":10101367` (a monotonic stamp) and
  `"last":0,"passed":0` for a timer that never ran. The hand-written
  fixtures encode the assumed relative values (`"left":3600000000`). So
  on JSON hosts the two fields hold a different quantity than on text
  hosts, and `lastUs == 0` yields `lastUtc == 1970-01-01` instead of
  null. Nothing reads `leftUs`, `passedUs` or `lastUtc` today (grep over
  core and app), so there is no visible defect yet; the first consumer
  would show "56 years ago" or a 1970 last run.
- Fix: map `last`/`next` of 0 to null, and either delete `leftUs` and
  `passedUs` (unused public API) or normalise them; replace the two
  hand-written JSON fixtures with the captured shape.
- Size S. Confidence high for the capture, medium for systemd versions
  other than 255.

## HST-8 (bug, low) BusyBox `crontab -l` without a crontab reads as "unknown"

- Where: `lib/src/parse/cron.dart:262-267` (`_crontabMeta`).
  ```dart
  if (crontabLines.any((l) => l.toLowerCase().contains('no crontab'))) return false;
  warnings.add('cron: crontab -l exited rc=$rc'); return null;
  ```
- What: BusyBox prints `crontab: can't open 'root': No such file or
  directory` and exits 1 (verified by run with BusyBox 1.36.1). That does
  not match, so `ownCrontabPresent` is null and the Jobs panel treats the
  user's crontab as unread instead of absent
  (`jobs_panel.dart:457-461`), which also suppresses the "no jobs"
  statement. Alpine is tier B, so low.
- Fix: also accept `can't open` with `No such file or directory` at rc 1;
  add it to the hand-written alpine fixture or a unit test.
- Size S. Confidence high.

## HST-9 (bug, low) Unbounded `int.parse` on host text breaks the "never throws" contract

- Where: `lib/src/parse/models.dart:215-220` (`parseMemInfoBlock`:
  `(\d+)` then `int.parse(m[2]!)`), `lib/src/parse/oom.dart:135, 144-145,
  152` (`Killed process (\d+)`, journal and dmesg stamps),
  `lib/src/parse/ports.dart:229` (`^(\d+)/` of netstat).
- What: a digit run of 20 or more characters throws `FormatException`.
  Verified by run for meminfo: a mutation fuzz over every fixture and
  test literal (2.5 million parser calls, digit inflation, truncation,
  line shuffles) found exactly this one thrower among the section
  parsers; `parseOverview`/`parseCore` document "never throws"
  (models.dart:1-3). The values come from the kernel or root-written
  logs, so this is not attacker-reachable in practice, and the pipeline
  catches it (`sample_pipeline.dart:266`), costing the tick's metrics.
  The existing `test/parse/robustness_test.dart` fuzz does not inflate
  digit runs and covers eight collectors only, not the command-read
  parsers (`parseOomKills`, `parseListeningPorts`, `parseMounts`, ...).
- Fix: `int.tryParse` with a skip-and-warn in the three places; add a
  digit-inflation case and the command-read parsers to the robustness
  test.
- Size S. Confidence high.

## HST-10 (security hardening, low) `ThresholdRule.fromJson` accepts an inverted hysteresis band

- Where: `lib/src/rules/threshold.dart:100-114`; evaluator `204-237`;
  decode path `packages/klabautermann_core/lib/src/catalog/klabautermann_records.dart:204`.
- What: the editor refuses `clear` on the wrong side of `raise`
  (l10n "The clear value must not be above the raise value"), but the
  strict decoder of synced `rule` records does not. With `greaterThan`,
  `raise 80`, `clear 90` and both durations zero, a steady value of 85
  goes ok -> firing (breach) -> ok (`!thresholdHolds(op, 85, 90)`) ->
  firing on every observation.
- Scenario: a rule record written by another client version or by a
  compromised device on the account (in the threat model, 03 line 6081)
  produces one raise and one clear per tick for every host in scope.
- Fix: in `fromJson`, throw `FormatException` when `clear` lies on the
  breach side of `raise` for the rule's operator; test it.
- Size S. Confidence high.

## HST-11 (bug, low) Kernel check reports "newer installed" for another kernel flavour

- Where: `lib/src/parse/boots.dart:76-90` (`parseKernels`).
- What: the state is `newerInstalled` whenever the highest name in
  `/lib/modules` sorts above `uname -r`, across flavours.
  `compareVersions('5.14.0-503.el9.x86_64+debug', '5.14.0-503.el9.x86_64')`
  is positive (longer, extra part does not start with `~`), and
  `6.8.0-1012-aws` sorts above `6.8.0-45-generic`.
- Scenario: a host with `kernel-debug`, an `-rt`/`-cloud` flavour or a
  second Ubuntu flavour installed shows a pending-reboot hint that a
  reboot never clears.
- Fix: compare only releases of the running kernel's flavour (same
  suffix after the ABI number), or report other flavours separately.
- Size S. Confidence medium (traced by reading `compareVersions`, not
  run).

## HST-12 (refactor, low) Frame parser buffers bytes as growable `List<int>`

- Where: `lib/src/hws/frames.dart:162-165, 258-267, 466-470`.
- What: `_buf` and `_payload` are `List<int>` (8 bytes per element), and
  `_take` copies with `sublist` and then shifts with `removeRange(0, n)`.
  A 1 MiB section costs roughly 8 MiB in `_buf` plus 8 MiB in `_payload`
  before `Uint8List.fromList`, and each marker shifts the remaining
  buffer. Correctness is fine (limits and resynchronisation held in all
  my runs, including forged markers carrying the real nonce inside a
  payload).
- Fix: `BytesBuilder`/`Uint8List` with a read offset; payload chunks
  appended without boxing.
- Size M. Confidence high (cost), low priority.

## HST-13 (refactor, low) Duplicated fragments and header pattern

- Where: `lib/src/hws/program.dart:998-1023` and `1049-1075` (`c_units`
  and `c_user_units` differ only in `--user` and `hw_userbus`; likewise
  `c_timers`/`c_user_timers` at 1028-1041 and 1079-1093); the status
  merge `case $a:$b in ok:ok) ... *:timeout | timeout:*) ...` is written
  four times (fs, units, user_units, ops); `blockHeaderPattern`
  (program.dart:77) duplicates the literal in
  `lib/src/parse/models.dart:30` and is used only by
  `packages/klabautermann_core/tool/src/s2_measure.dart`.
- Fix: one `hw_units <flag>` / `hw_timers <flag>` helper and one
  `hw_worst <st> <st>` helper in `_kHelpers`; make `splitBlocks` use
  `blockHeaderPattern`. Bump the collector-set version.
- Size M. Confidence high.

---

## Checked and found sound (no finding)

- Framing: byte counts held under dash, bash and BusyBox ash with UTF-8,
  invalid bytes, embedded `\036<real nonce> E 2` / `B 3` marker lines,
  `== ps ==`, `== meta ==`, `== rows ==` and `hw_timeout=absent` lines in
  a process's argv; no lost tick, no block reopened (`verbatimBlocks`).
- No `timeout` on PATH: every section still parses, the marker is
  stripped in sections and probe areas.
- `fs` under BusyBox `df -PT -B1` and `df -Pi`: columns match the parser.
- Tick assembler: out-of-order, resync and section-cap paths read
  consistent with the parser's states; no path leaves it stuck.
- Rates: zero and negative intervals, 32-bit wrap against 64-bit reset,
  disk timing wrap, PID reuse guard. Units: meminfo and RSS kB are
  multiplied by 1024 in core; nvidia MiB, amdgpu bytes, millidegrees and
  microwatts are converted correctly.
- Time zones: all command reads run under `TZ=UTC` (`who` stamps,
  list-timers text, unit timestamps); the probe reads the offset in an
  `unset TZ` subshell.
- Probe: the 17 guarded commands match the fragment; `systemd-detect-virt`
  "none" with exit 1 is read as an answer; unknown stays null.
- Threshold pending state across a disconnect is reset by the core
  evaluator's `gap()` (not a finding).
- The 1 MiB section cap losing a whole reply is a recorded design
  decision (03 line 725), not re-raised.

## Overall assessment

The slice is in good shape: framing cannot be forged by remote data, the
program behaves the same under the three shells I could run, and the
parsers survive hostile and truncated input (one thrower in 2.5 million
mutated calls). The real weaknesses are at the seams: section status is
all-or-nothing, so one failing mount or one unreadable file blanks a
whole panel (HST-1, HST-4), and two parsers trust column or header order
more than the data allows (HST-2, HST-5). The validator grammar for unit
names is narrower than systemd's (HST-3). Fixtures for systemd output are
mostly hand-written and one of them contradicts the single real capture
(HST-7).

## Coverage

- Read fully: `hws/program.dart`, `hws/frames.dart`,
  `hws/tick_assembler.dart`, `hws/request.dart`, `hws/collector.dart`,
  `rates/rates.dart`, `rules/threshold.dart`, `probe/probe_parse.dart`,
  `probe/host_profile.dart`, `parse/models.dart`, `parse/metrics.dart`,
  `parse/parse_result.dart`, `parse/fs.dart`, `parse/procs.dart`,
  `parse/dmesg.dart`.
- Read in large part: `parse/timers.dart`, `parse/cron.dart` (to line
  460), `parse/units.dart`, `parse/identity.dart`, `parse/temps.dart`,
  `parse/gpu.dart`, `parse/boots.dart`, `parse/oom.dart`,
  `parse/smart.dart`, `access/access_check.dart` (lines 1-140, 250-665).
- Only skimmed (grep for throwing calls, regex bounds, plus the mutation
  fuzz): `parse/accounts.dart`, `ports.dart`, `interfaces.dart`,
  `mounts.dart`, `log_sources.dart`, `registry_heads.dart`,
  `footprint.dart`, `unit_details.dart`, `ops.dart`, `packages.dart`,
  `sshd.dart`, `firewall.dart`, `journal.dart`, `oncalendar.dart`,
  `restarts.dart`, `process_detail.dart`, `cpu.dart`.
- Not reached: `parse/disk_usage.dart`, `parse/disk_usage_export.dart`,
  `access/panels.dart`, `access/external_monitors.dart`,
  `access/access_check.dart` lines 140-250, and the tests beyond the
  files named above.
- Not possible here: zsh, mksh, fish and tcsh runs (not installed), any
  systemd, `ss`, `ip` or `nvidia-smi` output (the machine has none), so
  the semantic checks of those parsers rest on fixtures and reading.
