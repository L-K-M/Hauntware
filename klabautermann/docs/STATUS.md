# Status & next steps

Living snapshot of where Klabautermann is, what's proven, and what to pick
up next. Read [AGENTS.md](../AGENTS.md) for build/test commands and
[../docs/design/klabautermann/](../../docs/design/klabautermann/) for the
normative plan (`03-ARCHITECTURE.md` §2 is the decision log).

## Where things stand

M2, the host read MVP, is the current milestone. What is on main:

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
  and local dash and bash (a SIGSTOP stall included). Only the sampling
  scheduler (K22) starts it, over the links the app turns on (K44b,
  below), and K24's fixture tests (below) run it over SSH.
- Spike S2 part 1: `klabautermann_core/tool/capture_fixtures.dart
  measure` runs the real program locally under dash and bash (as
  `sh -s`, and as `<login shell> -c '<start command>'` the way sshd
  runs a command) and records [the evidence](evidence/s2/README.md):
  output before READY, fast-tick bytes and CPU, `procs` beyond 1,000
  processes and slow-tick times. The unguarded `procs` loops reach the
  10 s guarded budget near 2,000 processes under dash, where passing
  the D47 deadline depends on its margin (5 s, an estimate), and pass it by
  1,079 under bash; K15b's `procs` bound (below) resolves that.
  `capture` (K08b, #227) runs the program once per collector, redacts
  the payloads and writes a fixture directory with a `SOURCE.md`, and
  writes nothing while its review finds residue, a line that parses
  differently after redaction included (03 §6.5). The redaction keeps a
  system crontab line's user slot after an `@` macro, an unknown one
  included, so the line parses as before (K23c, below). The container
  captures (K28c) and the runner-VM capture (K28a), both below, are the
  first committed captures; the other platform fixtures are still
  hand-written. The tool has no SSH mode, so a BusyBox or musl userland,
  which cannot run its glibc build, stays on the manual list.
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
  from 22 CPUs. Real-host captures remain.
- Procs bound (M2, 03 D48, K15b, #205): collector-set version 5 sends
  one trimmed `procs` row per process (pid, state, ppid, utime, stime,
  starttime, uid, RSS and comm), joined in chunks of 64, so a tick grows
  linearly with the process count. Above 500 processes it keeps the
  union of the 250 with the highest CPU share since start and the 250
  with the most RSS (`selection=cpu_rss`); without `sort` or `head`, or
  when that selection fails, the first 500 in glob order
  (`selection=pid`). A `meta` block reports the total, and only the kept
  rows' command lines are read. A container with 2,080 sleeping
  processes took 0.7 s per tick under dash and sent 30 KB, where version
  4 took 9.6 s and sent 900 KB [U]. Command lines have no byte cap yet,
  so 500 rows with long ones can still pass the 1 MiB section cap. The
  per-file byte cap that 03 D48 names as a follow-up, marking the
  argument vector truncated, has no plan item yet.
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
  [U], cover it. The sample pipeline reads `showsHostFigures` and
  `counterWidth`, the System tab `showsHostFigures` (below), the cron
  next runs `serverZone` (K23b, below) and the capability cache
  `fromJson` (K27, below).
- Jobs model (JOB-01, JOB-02 data): `klabautermann_host`'s `mergeJobs`
  turns a `cron` and a `timers` tick into one list of cron lines,
  periodic scripts and timers, each with an English-free
  `ScheduleDescription` and, for cron, next runs with DST annotations
  in the server zone or the line's `CRON_TZ`. Timer triggers and
  `RandomizedDelaySec` have a source (`timer_detail`, below) that
  nothing wires yet. The sample pipeline's `cron` results carry the cron
  lines' rows (K23b, below), and the Jobs tab (K36, below) shows them.
- Cron next runs (M2, 03 §7.7, D58, K23b, #213): each `cron` sample's
  `CronResult` carries jobs rows for its cron lines and `cron.<period>`
  scripts, with next runs evaluated at the sample's time. The server
  zone follows `package:timezone`'s rules for the probe's zone name when
  they give the offset the server reported; otherwise the runs use the
  probe's fixed offset and `zoneFallback` says why. `CRON_TZ` names
  resolve through the same database. On the server's clock a fixed-time
  job runs a gap's minutes at the jump and a fall-back's repeated
  minutes once, as cronie and Debian's cron do, and a job whose minute
  or hour field starts with `*` runs by the clock; a `CRON_TZ` line
  follows cronie's rule for it. Runs within an hour of a transition are
  marked `nearTransition`, because the client's zone data can differ
  from the server's. A reading evaluates its first 200 lines
  (`notEvaluated` beyond). Timer rows still come only from
  `TimersResult`, the zone tables end early in 2038, and the runs do not
  model Debian's cron ignoring `CRON_TZ` or BusyBox crond running every
  job by the clock. The app's engine samples them since K44b turned links
  on.
- Cron parser (M2, 03 §7.7, JOB-01, K23c, #228): in system crontabs
  (`/etc/crontab`, `/etc/cron.d`) `parseCron` reads the user field after
  an `@` macro too, as cronie's `load_entry` does, and skips with a
  warning a system line that ends before its command. A command keeps
  its inner blanks as written. User crontabs still have no user field.
- Log and job commands (M2, `klabautermann_host`, K18, #211): the
  `journalctl` builder adds the kernel log (`-k -b`), an identifier
  (`-t`), the current boot, `--until`, times sent as `@<epoch>` so the
  session's zone plays no part, and newest-first (`-r`) or follow (`-f`)
  order. It refuses `--since` with a cursor, a range that ends before it
  starts and a follow with `--until`. `dmesgJson` builds `dmesg --json
  --decode`, and `parseDmesgJson` reads it record by record, mapping
  util-linux's facility and level names, so a cut document keeps its
  complete records. util-linux before 2.38 (RHEL 8 and 9, Ubuntu 22.04)
  has no `dmesg --json`, so there the kernel log comes from `journalctl -k`
  alone.
  `tail -n N [-F] -- <path>` takes only an absolute, normalized path.
  `HostCommands.commandLine` is the 03 §8.8 `sh -c` wrapper: it exports
  the sampler's environment with `LC_ALL=C`, or `C.UTF-8` on request, and
  `exec`s the argv; tests run it through dash and bash with hostile words.
  The slow sampler gains the on-demand `timer_detail` collector
  (collector-set version 6, D57): one timer's triggers and randomized
  delay from `systemctl show`, requested through `hw_o` only.
  `timerCalendarCommands` builds the `systemd-analyze calendar -- <expr>`
  reads for its calendar triggers (one run below systemd 242), and
  `TimerJobEntry.withDetail` merges them, leaving the triggers unknown
  when a read lists none. `parseOnCalendar` now reads systemd 242 to 252's
  `Iter. #N:` rows, and elapses in zero-offset zones, where no `(in UTC)`
  line follows. With links on, the log service (K25a, below) runs the
  `journalctl`, `dmesg --json` and `tail -n` window reads, and the
  follower (K26, below) the `journalctl -f` and `tail -F` follows. The
  Jobs tab (K36, below) renders `timer_detail`'s results, but the engine
  does not run that read or the calendar reads yet; only the runner-VM
  leg (K28a, below) runs them, over a side channel. The app's engine
  runs the log reads since K44b turned links on.
  The fixtures are hand-written.
- Access rules (M2, `klabautermann_host` `access/`): the CN-24 rows from
  a `HostProfile` (passwordless sudo, journal group with the LOG-04
  notice, Docker socket rights with the SAF-08 flag, systemd version,
  runtimes per host for CN-09), each `ok`, `missing` or `unknown` with
  an enum reason. Only the journal and Docker socket rows can carry a
  copyable fix argv, which is never run; sudo has none until SAF-17.
  Streamlocal, the compose plugin and a chosen runtime come from the
  Docker endpoint's facts since D20 (below). Panel
  capability declarations for the M2 host panels (the probe now also
  checks `dmesg` and `tail` for LOG-03 and LOG-22) and an
  external-monitor rule over the units list. The Access tab, panel
  gating and LOG-04's notice (below) read the rows and the panel
  declarations, and the coverage card and the inspector (K39b, below)
  the external-monitor rule.
- `klabautermann_docker`: pure-Dart HTTP/1.1 client, NDJSON/JSON-seq
  scanning, stdcopy, versioned API models and negotiation, compose labels
  and grouping, and `/system/df` across its shapes with the OV-05 summary
  maths.
- Docker transport (M3, D04, 03 §5.3, §5.9): `klabautermann_core`'s
  `DockerLadder.resolve` picks rank 1 (streamlocal), 2 (`dial-stdio`
  with `--host`, Podman's `--url`) or 4 (socat, then `nc -U`), with one
  exec probe per refused socket telling missing, denied and disabled
  apart; rank 3 says "needs admin mode" until M4. The streamlocal and
  relay-process duplexes are tested over fakes only.
- Docker session (M3, D05, 03 §5.8, §10.1): with links on, a
  `DockerQuery` (engine, containers, one container, images) opens its
  server's session, which runs the ladder once the probe has answered,
  passes over a route whose engine does not answer `_ping`/`/version`,
  negotiates (floor 1.41, max 1.55), names Podman from
  `Libpod-API-Version` and reports `DockerEndpointState`. Results are
  typed; inspect `Path`/`Args`, `Entrypoint`/`Cmd` and health output
  cross masked, and the list drops its command line. Tested over fakes
  only; no `/system/df` (D03).
- Docker watches (M3, D06, 03 §7.12, §10.1): `DockerWatch` keeps the
  container, image and stack lists current from one `/events` stream
  per server (250 ms batches, targeted re-reads by container id,
  resume with `since`, a full re-list after a gap over 60 s) and reads
  one-shot list stats for the ids on screen every 5 s (4 at once on
  streamlocal, one at a time on a relay), all as `DockerListChanged`.
  Tested over fakes only; the app watches the containers and their
  stats since D13 (below), and no other list yet (D16, D17).
- Container logs (M3, D07, 03 §5.6, §10.1): `ContainerLogSource`
  streams a container's logs through `OpenLogStream` as
  `ContainerRecord`s over the server's Docker endpoint: framing by
  `Config.Tty` when no `Content-Type` comes (Docker 20.10, Podman),
  Podman's lines split over two frames joined, the journal follow's
  ring and pace, a resume after the newest line with `since` and the
  boundary line dropped, a stopped container read again with backoff,
  and `logDriverUnreadable` naming a driver whose logs the API cannot
  read. Tested over fakes only; the app opens them since D15 (below),
  and the background does not pause them.
- Docker in the app (M3, D12, 03 §5.9, §8.4, §10.2): a Docker controller
  per engine run asks for each server's endpoint as its link comes up
  and keeps its `DockerEndpointState`; the server header names the
  transport in every mode (E4) with SAF-08's engine badge, the
  low-session indicator and the runtime the API names (M13). The Docker
  tab waits, looks or says why no route works (with the Access link and
  a retry), then shows SAF-08's notice until it is dismissed on the
  device (`settings.json`), the engine strip (DKE-01) and the
  Containers, Images and Stacks sub-tabs, the last two still empty (D16,
  D17). Tested against the fake engine only.
- Stack sources (M3, D08, 03 §7.16, §10.1): the stacks list carries a
  verdict per compose project (verified, unverified with a reason, or
  source not on host naming the marked manager) and the compose CLIs
  found, the standalone v1 read-only. Verification runs `test -f` on
  the config files, then `compose config --hash '*'` with `--host`
  against each service's `config-hash`, both in short-action slots,
  and falls back to "CLI could not hash" when the flag form fails.
  `DockerStackFileQuery` reads a verified stack's compose or `.env`
  file over SFTP, at most 1 MiB, masked in the engine. Tested over
  fakes only, plus the `test -f` quoting in a real `sh`; the `--hash`
  output shape comes from Compose's source and awaits D21's run, and
  the app shows no stacks yet (D17, D18).
- Low-session mode (M3, D09, 03 §5.2, M9): one `ChannelQuota` per server
  serves the host log reads and the Docker session, so on relay ranks
  the pooled connection (one, in a short-action slot until its 30 s idle
  close), the events stream and container log follows (follower slots),
  and the stack checks count against the same shares as journal reads.
  Without a follower slot the events stream gives way to a full re-list
  every 15 s. A learned session limit holds followers to one (none below
  4) and the shares together to what the two samplers leave (at 4, one
  follower and one short action), keeps a relay's events stream closed
  in favour of the re-lists (streamlocal keeps its stream), reads stats
  one at a time and sets `DockerEndpointState.lowSession`, on
  streamlocal too; a new link ends it. A failed endpoint (unreachable,
  link error) is looked for again while a watch holds, after 5 s
  doubling to 2 min, from 5 s again after a new link or watch. Tested
  over fakes only at learned limits of 2 to 4; D22 checks
  `MaxSessions 2` on a real sshd, and the server header shows the mode
  (D12).
- Containers in the app (M3, D13, 03 §7.12, §10.4): the Containers
  sub-tab holds one `DockerWatch` of the containers and their stats per
  server while it shows and sends `DockerUnwatch` once hidden; the
  running rows on screen go to `statsFor` under the same watch id after
  a 250 ms settle. The sortable table lists name, state, health, the
  engine's status text (the uptime, which sorts by the duration it
  names), image, ports, compose project or Swarm service, CPU and
  memory (IEC), grouped by compose project under headings that fold,
  with a running-only toggle and a search by name, image or ID; phones
  and 200 % text get two-line rows with a sort menu. Stats older than
  20 s turn grey beside a history icon and read "stale"; a failed read
  keeps the last list with why and a retry, and low-session mode is
  named. No sizes (the watch never asks for `size=1`). Tested against
  the fake engine only.
- Container details in the app (M3, D14, 03 §7.12, §8.9, §10.2): a
  container row (click, Enter or a screen reader's tap) opens its
  details in the desktop inspector, which replaces the server's
  coverage until closed (Escape or the close button, which takes focus
  as it opens) or another server is selected, or on a phone's pushed
  page. The Docker controller sends one `DockerContainerQuery` per
  container a view shows, again when its row's state, status, health or
  image changes in a delivered list (one at a time), and after a read
  that failed once the endpoint is ready on a new route; a list without
  it or a `notFound` answer says "container removed" over the last
  read, and other failures say why with a retry. The details show the
  managed-by badge (`detectOwnership` over the labels, now exported by
  the core barrel), state with the exit code and an OOM kill, health
  with the last checks' output, restart policy and count, image, times,
  entrypoint and arguments, environment, labels, mounts, the row's
  ports (the inspect model carries none), networks and a raw JSON view
  drawn from the masked model. Masked values reveal for 30 s on
  selection in the view's state only, mask again when the app turns
  inactive or the view closes or changes container, and read as
  "(masked)" to a screen reader. Logging driver options stay out of the
  JSON: the model carries them unmasked. Tested against the fake engine
  only.
- Container logs in the app (M3, D15, 03 §7.12, §10.2, §10.8): the
  details (an inspector button, a phone page's app bar) and a table
  row's menu open a container's logs, on the desktop in a pane under
  the Docker tab's sub-tabs, which follows only while the tab shows and
  closes with Escape, its button or another server's selection, and on
  a phone in a bottom sheet (60 % of the screen, dragging from a quarter
  to full), whose close by button, drag or Back closes the stream. The
  Logs panel's controller reads `ContainerLogSource` with the same
  buffer, Live chip, gap notice, dropped-lines rows, status line and
  search; like a file, the follow has no cursor and starts over when
  shown again. Each row starts with its local time and its stream,
  `stderr` in the error colour and spoken as "standard error"; search
  reads both. `logDriverUnreadable` names the driver and why (`none`,
  Podman's readable drivers, or "driver X, cache disabled") without a
  Retry; other ends keep the Logs panel's wording, so a removed
  container reads "no such file or log tool". The engine delivers a
  container window oldest first, against `LogStreamSpec`'s newest
  first, so the controller keeps that order. Tested against the fake
  engine only.
- Runtime override and the Docker Access rows (M3, D20, 03 §4.10,
  §5.4, §10.1, CN-09, CN-24, D54): `SetDockerEndpoint` carries a
  server's socket choice (automatic, a detected socket or a custom
  path); the engine keeps it across links, resolves a session again
  with it as the ladder's first candidate, fails a path that is not an
  absolute socket path as `invalidChoice`, and forgets it with the
  server (SYN-08). `DockerEndpointState` carries the choice. The app
  keeps each choice in `settings.json`
  (`klabautermann.docker.endpointOverrides`) with the endpoint it was
  made for, drops it when the fleet drops the server or moves it to
  another endpoint, and sends it as the link comes up and on each
  change. The Docker tab's engine strip, and the failed tab under its
  reason, hold the picker (automatic, each socket the probe found, a
  custom path checked before it is sent) and say when the chosen socket
  did not answer. `evaluateAccess(profile, docker:)` answers the
  streamlocal row from the route (allowed, disabled, denied, untested),
  the compose row from a `DockerComposeQuery` the Access tab asks for
  once the endpoint is ready (version, standalone only, v1 only, none),
  and the runtime row "chosen manually". Tested over fakes and the fake
  engine only; D21 and D22 meet the rows on real sshd variants.
- `klabautermann_core`: the D18 engine isolate skeleton: the plain-data
  request/event protocol of 03 §10.1 as sealed classes, `engineMain`
  answering the requests whose milestones have landed (below) and
  rejecting the rest, and `IsolateEngineClient` for the UI
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
  Only an engine with links on sends link states and prompts, as the
  app's does since K44b (below). The engine sends probe answers since
  K20 (below) and fills the new fleet fields only for imports (below).
- Protocol v3 sampling (M2, 03 §10.1, K16a, #193): `Subscribe` and
  `Unsubscribe` name one surface's subscription and its `SampleStream`s
  (D45; the health card's failed units are a `failedUnits` stream of their
  own), `SetCadenceProfile` picks the 03 §6.4 column, and `Sample` carries
  its stream, an engine-owned per-server `seq` (D44), the engine's time
  and a sealed result of derived values (D43) or `CollectorUnavailable`;
  `SamplingState`, `Gap` and `HostProfileChanged` join. Sampling joined v3
  without a bump. The engine keys subscriptions by server and subscription
  id and keeps the cadence profile. Only an engine with links on samples
  and sends these events (K22), as the app's does since K44b (below).
- Sample pipeline (M2, 03 §6.4, §10.1, K23, #207): `klabautermann_core`'s
  `ServerSamplePipeline` turns one server's sampler outcomes into
  `Sample`, `Gap`, `SamplingState` and `HostProfileChanged` events; the
  phase follows from the subscribed streams, the app's activity and the
  link. The pipeline derives rates over the host's uptime (D43), also
  across a lost reading or a sampler restart. A reboot, leaving the
  sampling phase or unsubscribing starts a new series; a slow sampler's
  reply never does. `SampleSequence` keeps one `seq` per server for the
  engine's lifetime (D44). Once the probe has answered, inside a
  container the values whose `/proc` file shows the host's figures are
  null and named in `withheld` with a typed reason (D50). A gap opens
  from a stream's last reading for the background, a lost link or a lost
  reading, and the next reading closes it. Per-process CPU shares need
  `procs` to lead its request, and the host's process count and row
  selection pass through for "showing N of M" (D48). A collector error
  crosses as at most its last 4,096 characters. `HostProfileChanged` goes
  out for the first profile and when a later one differs beyond its clock
  and session fields. Fixture tests run every platform through the
  pipeline. The sampling scheduler (K22) runs it, only with links on,
  which the app leaves off (below).
- Sampling scheduler (M2, 03 §6.4, K22, #219): `SamplingScheduler` runs
  a fast and a slow sampler session on each subscribed server's ready
  link. They tick the union of the server's subscribed streams at the
  cadence profile's aligned periods, `procs` first, with `overview` and
  `failedUnits` riding on `core` and `units`, and every outcome goes
  through the server's pipeline. The probe goes first on each link and
  holds the fast sampler while no profile is known (D50); a probe
  without a reply goes out again after 15 s, the wait doubling up to
  15 min. `identity` is read once per link and, under the cellular
  saver, `timers` and `cron` once per `Subscribe`. An overlapping tick
  is skipped and counted, never queued; a first reading waits for the
  outstanding request, and a reading due while a sampler restarts or
  the probe holds it shows as a gap. The background, a lost link, the
  last unsubscribe and leaving the fleet close the samplers. After a
  missed fast deadline the restarted fast sampler's start is a dead-peer
  hint, and the supervisor closes a link silent for 20 s as
  `pingTimeout` and redials. The scheduler exists only with links on,
  which the app's engine has since K44b. K24's fixture tests (below) run
  a stopped fast sampler, whose link stays up, and a paused host, closed
  as `pingTimeout` and redialed.
- Capability cache and argument masking (M2, 03 §4.10, §6.1, §8.9, D59,
  CN-02, SAF-07, SYN-08, K27, #230): the engine keeps each fleet
  server's last probed profile in `capabilities/<name>.json` under the
  support directory for 24 h, named by its UUID or by the SHA-256 of
  its import alias. It rewrites the file on every probe answer, deletes
  it when the server leaves the fleet or a re-import gives its id
  another endpoint, and at start deletes the files of servers outside
  the fleet. It writes and deletes only when the app holds the instance
  lock or runs on a phone (`SupportDirectoryAccess`), deletes nothing
  while the import store is left as it is, and after an import that was
  not saved writes nothing until one is. A fresh cached profile reaches
  the app once, as `HostProfileChanged` with `cachedAt`, when a
  `Connect` or `Subscribe` first names the server before this run's
  probe answers; the app does not keep `cachedAt` yet, and sampling
  still waits for the probe. Process arguments cross as `MaskedValue`s,
  masked in the engine by 03 §8.9's rules: an attached `-p`, a secret
  `name=value`, the value after a secret-named option and URL
  credentials, with shell-word extents inside `-c` lines and at most
  65,536 tokens read per procs reading. A short option's separate value
  (`sshpass -p`), `curl -u user:pass` and header values are not masked
  yet (03 §8.9). Since K44b turned links on in the app, its engine caches
  the profiles its probes answer and masks the procs rows it reads.
- Spike S5 part 1 (M2, 03 §11.4, K29a, #220):
  `klabautermann_core/tool/engine_budget.dart` replays the host fixtures
  for ten hosts at the Phone cadence (or every host reading `core` every
  2 s) plus a 1,000 lines/s journal follow through the frame reader, the
  sample pipeline, the journal parser and an isolate send. It reports
  engine time per tick and per second, reply bytes, lines/s, the
  resident set and, under JIT, the live heap. A stand-in
  (`FollowReplay`), not K26's follower (below), holds 03 §10.1's cap of
  20 batches a second. Provisional local numbers are in
  [the evidence](evidence/s5/README.md) and set no budget; they predate
  two review fixes to the harness's output. A one-second smoke run is
  among the core tests. K29b (below) measures the UI frames; device
  numbers remain for the manual gate.
- Spike S5 part 2 (M2, 03 §11.4, §11.6, K29b, #235):
  `app/klabautermann_app/integration_test/frame_timing_test.dart` runs
  the real app in profile mode over a replay engine
  (`package:klabautermann_core/replay.dart`, outside the barrel; a
  contract test keeps `lib/` from importing it). The replay serves the
  host fixtures through the frame reader and the sample pipeline across
  the production client's isolate hop: ten servers reading `core` every
  2 s and a 1,000 lines/s journal follow. For the fleet list, a server's
  Overview and its Logs panel, 20 s each, the test reports `FrameTiming`
  build and raster times (average, p90, p99, worst, frames over 16 ms)
  and collections, and fails only when the load does not reach the app.
  The replay answers log streams as K25b's router does but serves
  follows itself, not through K26's follower (below), and keeps no
  capability cache. `scripts/bench-frame-timing.sh` runs it under Xvfb
  in CI's `klabautermann_frame_timing` job (main pushes and dispatch);
  a provisional software-rendered local run is in
  [the evidence](evidence/s5/README.md). It runs on desktops only until
  the fixtures are bundled; device numbers stay the manual gate (06).
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
  time. Logs joined v3 without a bump. With links on, the engine routes
  windows to the log service and follows to the follower (K25a, K25b
  and K26, below); with links off (the engine's default, which the app
  overrides since K44b), it rejects every `OpenLogStream` and ignores
  `CloseStream`.
- Log service (M2, 03 §7.6, LOG-01, LOG-03, LOG-22, SVC-04, K25a, #221):
  `klabautermann_core`'s `LogService` reads one window (`follow: false`)
  over a server's link: up to 500 journal records newest first from
  `journalctl -o json -r -n`, paged by cursor, with `since` applied by
  the engine after a cursor; the kernel log from `journalctl -k -b`,
  falling back to `dmesg --json --decode` when journalctl exits without
  a kernel record, with `LogStreamRunning.reader` naming the source; or
  a file through `tail -n`. Each command keeps the newest 4 MiB of
  stdout and runs at most 30 s once its channel is open. A cut window
  ends as filled, and one that keeps no whole entry, record or line
  counts it as dropped; a full journal window left with no record ends
  as failed. Exit codes and stderr map to missing, denied or failed, and
  a signal, timeout or lost link always ends as failed. Stderr crosses
  through `stripControlChars`. The app does not word the `dmesg`
  fallback yet, and a malformed `dmesg` record is skipped without
  counting as dropped. The engine reaches it only with links on (K25b,
  below).
- Log-read wiring (M2, 03 §5.2, §7.6, K25b, #229): with
  `EngineStart.linksEnabled`, a `LogStreamRouter` hands `OpenLogStream`
  windows and `CloseStream` to a `LogService` on each server's ready
  link, and follows to K26's follower (below). It rejects a reused
  stream id, a server outside the fleet and a server's 17th stream. A
  per-server `ChannelQuota` lets 2 short actions and 2 followers run at
  once, and a read that finds its share full waits as
  `LogStreamWaiting(channel)`.
  Every stream ends with exactly one `LogStreamEnded`: on `CloseStream`,
  `Disconnect`, fleet removal and `Shutdown`, and for a running read
  when its link is lost or replaced; a waiting read waits for the next
  link. The background pauses reads as `LogStreamWaiting(background)`,
  and the foreground runs them again from the start. The app's engine
  has links on since K44b, so it serves the app's reads.
- Log followers (M2, 03 §5.2, §7.6, §10.1, §10.8, LOG-02, LOG-22, CN-05,
  K26, #237): `klabautermann_core`'s `LogFollower` runs each
  `OpenLogStream(follow: true)` on its own process in one of the
  server's two follower slots (one at a learned session limit of 4, none
  below): `journalctl -o json -f` with the spec's filters (`-k -b` for
  the kernel log, with no `dmesg` fallback) or `tail -n <window> -F`,
  stopped with TERM, then the channel close. journalctl gets no
  `--since`; the engine skips older records itself. Lines are cut at 256
  KiB and wait in a ring of 5,000 lines and 4 MiB [E], oldest dropped
  and counted, and go out as `LogBatch`es at most every 50 ms (20 a
  second) with the dropped count. After a lost or replaced link or the
  background, a journal follow resumes after the newest cursor received
  (`--after-cursor` with `--no-tail`), so nothing repeats or goes
  missing; a file follow, or a journal follow with no valid cursor,
  restarts with new lines only, and `LogStreamRunning` carries
  `LogContinuity.gap`, which the Logs panel words. Any exit ends a
  follow once its held lines are sent, and so does a file follow whose
  `tail` reports a failed open before its first line; a rotation does
  not. Tested with a fake clock, a scripted link, dash and bash, and a
  1,000 lines/s run with a 10 s stall; the runner-VM leg (K28a, below)
  resumes a follow across a forced reconnect against systemd 255. A long
  gap re-reads the whole backlog after the cursor, of which the ring
  keeps the newest 5,000 lines.
- Link connector (M2, `klabautermann_core` `links/`, K17, #197): the
  engine's credential source (no vault yet; key files read at connect time
  after `~` expansion, at most 1 MiB, each attempt recorded best effort in
  `identity_reads.jsonl`, waiting at most 2 s and dropping failed writes,
  read failures classified as not found, access denied, unreadable or
  hidden by the Flatpak sandbox), a prompt broker keyed by
  UUID `promptId` with a 2-minute expiry and withdrawal when the attempt
  ends, and `LinkConnector` over `SshLink.connect` with `TofuVerifier`
  over the engine's pin store (since K44a, below, `seance_core`'s
  `FileHostKeyStore` over `host_keys.json`, or pins held in memory when
  the process lacks exclusive access to the support directory, D61).
  Only interactive connects prompt: background connects decline a
  first-seen host key and offer no keyboard-interactive, and a changed
  key blocks the link until the user's connect reviews it (K44a). There
  is no passphrase prompt yet; the app shows the host-key and
  keyboard-interactive prompts (K43). The engine
  wires the connector and the broker in behind links, which the app
  turns on since K44b (below).
- Link supervisor (M2, 03 §5.1, §5.12, K19a, #206): `LinkSupervisor`
  holds at most one link and one dial per server over the link
  connector, with at most 4 attempts in flight across the fleet (D19).
  The user's attempts dial first; unattended ones wait a random 0 to 1 s
  in their slot. A given-up dial already on the network keeps its slot
  until it returns, and a link it brings late is closed. Only a failure
  to reach the server (unreachable or timed out) and a lost link redial,
  after a backoff of 1 s doubling to 30 s, less up to 30 % jitter. Every
  other failure, an unclassified one included, waits for the user's next
  connect, as does any server that asked keyboard-interactive questions.
  A changed host key blocks the server until the user's connect reviews
  it (K44a, below). Each
  attempt has a 60 s deadline, which counts a wait for the server's
  given-up dial and stops while a prompt is open; a given-up attempt
  withdraws its prompts. The connector now reports the connecting,
  authenticating and needs-user phases itself. No attempt starts in the
  background; phones close their links after 30 s there and redial on
  return. An interactive attempt that the phone's background close ends
  comes back unattended on return, so a host-key prompt it needed fails
  instead of asking again. Identity files must be regular files, so a
  FIFO or a device such as a tty fails as unreadable. Tested with a fake
  clock and fake links.
- Links in the engine (M2, 03 §5.1, K19b, #212): the engine hands
  `Connect`, `Disconnect` and `SetAppActivity` to the link supervisor and
  `AnswerPrompt` to the prompt broker, and dials through the link
  connector with the one pin store it opens at start (K44a, below).
  `Connect` is the user's
  connect, so it may prompt; one for an id outside the fleet gets
  `RequestRejected`, and one for a fleet server without a config gets
  `ConnectRejected` (K44a). Phones close links in the background (D34);
  desktops keep them. `EngineStart.linksEnabled` gates the whole stack.
  It is off unless given, and `main.dart` turns it on since K44b (a
  contract test holds it on), after pins in `host_keys.json` (K44a) and the
  app's prompts (K43) landed. With links off,
  `Connect` is rejected, `Disconnect` and `SetAppActivity` change nothing,
  and nothing dials. A server that leaves the fleet is forgotten: its link
  and attempts end without a `LinkState`, its subscriptions go, and a
  `Subscribe` for it is ignored. `MonitoringController` sends it nothing
  while it is gone and, when it returns, sends `Connect` and `Subscribe`
  again for the views still holding it. An entry that keeps its id under
  a new endpoint keeps its old link until that closes, as 03 §5.1
  records. Engine unit tests use a fake dialer; K24's fixture tests
  (below) dial a containerized sshd, and no manual run against a real
  server has happened yet.
- Reachability probes (M2, 03 §4.7, §5.12, FL-04, K20): the engine's
  `ReachabilityService` runs `seance_core`'s `ProbeService` (a TCP
  connect to the SSH port, 45 s jittered sweeps, at most 6 at once) over
  the fleet entries with a connect config and a confirmed endpoint:
  imports (O6's default) and confirmed synced servers, never an
  unconfirmed or changed one. Each sweep sends a `Reachability` per
  target; a server behind a jump host is reported unknown without a
  probe, and one holding a link is answered online. Probing starts after
  `Hello`'s fleet, sweeps at once for a new or moved target, stops for
  a server before the fleet or `EndpointChanged` that removes it goes
  out, and pauses with `SetAppActivity` in the background (phones only
  send it). `EngineStart.probesEnabled`, off unless given, gates it
  apart from links, and `main.dart` turns it on (the contract test holds
  it). The fleet controller drops the answer of a server whose endpoint
  waits for confirmation. Tested with a fake prober, under a fake clock
  for the service; no real host has been probed from the app.
- Shared host-key file store (M2, `seance_core`, 03 D3, F3b-1, #242):
  Poltergeist's `FileHostKeyStore` and its corrupt-file quarantine moved
  into `seance_core` (`package:seance_core/catalog.dart`, re-exported by
  `poltergeist_core`) with the catalog's `AtomicFileWriter` as the
  default writer, so K44a (below) persists pins through the shared
  store rather than a copy. Séance still uses its own store.
- Prompts in the app (M2, 03 §10.1, D8, K43, #252): `PromptController`
  keeps the engine's open prompts oldest first and sends an answer only
  for one still open. `PromptHost` shows one dialog at a time through
  `ghost_servers`' `GhostHostKeyPrompt` and `GhostKeyboardPrompt`, which
  #244 and #248 moved there from the siblings, with the fingerprint in
  the app's monospace stack, and closes a withdrawn prompt's dialog
  without an answer. Cancel on a keyboard-interactive prompt sends the
  new `PromptCancelAnswer`, which ends the attempt at once as
  `keyboardInteractiveCancelled` instead of waiting out the 2-minute
  expiry, and `KeyboardInteractivePromptRequest` gains the asking
  machine's `user`. Credential and elevation prompts have no producer
  and no dialog; the app dismisses them with `PromptSecretAnswer(null)`.
  These joined v3 without a bump. The app's engine sends prompts since
  K44b; no manual or real-device run has shown one.
- Host-key pins and re-pin (M2, 03 §4.6, §4.10, §5.1, §10.1, D61, K44a,
  #255): the engine opens one pin store at start (`openHostKeyPins`):
  `seance_core`'s `FileHostKeyStore` over `host_keys.json` in the
  support directory when the process holds it alone, so a pin outlives
  the engine; otherwise it reads the file's pins once and keeps them and
  its own in memory, writing, renaming and creating nothing there, a
  damaged file included. A changed key still blocks the server, and an
  unattended connect never asks about it. The user's `Connect` to a
  server a changed key blocked reviews it: `HostKeyPromptRequest`
  carries the pinned key's type and fingerprint, the app shows
  `ghost_servers`' changed-key review, and trusting it re-pins through
  `TofuVerifier.pin` and connects; declining, expiry or a `Disconnect`
  before deciding blocks the server again. The app sends `Connect` only
  when a server's first view opens, so a server whose key changes while
  its view is open is reviewed only after the user leaves it, waits out
  the 30 s link grace and opens it again. A `Connect` to a fleet server
  without a config gets `ConnectRejected` (`noLoginName` or
  `addressOnlyImport`), which `MonitoringController` keeps while a view
  holds the server and `ConnectRejectedBanner` shows above its panels,
  as a live region, until the next connect, which a new import sends.
  `host_key_repin_test.dart` re-pins against the sshd fixture (K24,
  below) after regenerating its host keys.
- Typed connect failures (M2, `seance_core`, 03 §5.3, X5a, #240):
  `SshConnectException` gains an optional `kind`
  (`SshConnectFailureKind`), set at every throw site in
  `ssh_session.dart`: unreachable, timed out (the platforms' ETIMEDOUT
  codes included), an invalid jump route, a key that needs a passphrase
  or got a wrong one, an unreadable key, an empty agent, rejected
  authentication, a refused host key, or `other`, the default, so
  Poltergeist's positional throws are unchanged. An agent that cannot be
  reached is `other`. `privateKeyNeedsPassphrase` tells an encrypted
  PEM apart, and the two rejected-key summaries no longer name Séance.
- Client-limitation failures (M2, `seance_core`, 03 §5.3, CN-23, D23,
  X5b, #249): a passive tap on the socket reads the server's cleartext
  KEXINIT (`server_kex_init.dart`, outside the barrel), and a failed
  handshake is classified against `suiteSshAlgorithms`:
  `unsupportedAlgorithm` when a part shares no algorithm with the suite,
  `insecureAlgorithmsOnly` when only `suiteRefusedSshAlgorithms`
  (`diffie-hellman-group1-sha1`, `hmac-md5` and the truncated
  `hmac-sha2-*-96`) would agree, and `keyExchangeTimedOut` when an
  agreed finite-field DH exchange broke off before the host-key check,
  on every platform, not only Android. Each gets a product-neutral
  summary, and the link connector maps the three to the
  `LinkFailureKind`s of the same names. Tested with scripted transcripts
  only: no live OpenSSH server for the mismatch kinds and no Android
  device for the timeout.
- Link failure messages (M2, 03 §5.3, §10.1, §10.3, §10.4, CN-23, K45a,
  #245): the link connector maps the typed kinds (X5a, X5b, above) to
  `LinkFailureKind`, and falls back to the error's cause for `other`
  and for failures before the dial: a missing or wrong passphrase is
  the new `keyPassphraseRequired`, an unreadable key and an empty agent
  credentials unavailable, a refused sign-in credentials rejected, and
  an invalid route or a host-key refusal without a declined prompt
  stays unclassified. Inside Flatpak a key file the sandbox hides is the
  new `keyFileHiddenBySandbox`. The supervisor's prompt decision is
  exhaustive over the kinds, and it neither redials a
  `keyPassphraseRequired` failure nor hands an unattended one to the
  user's request, since no prompt can fix it yet. Every kind has ARB
  copy: the server header shows it under its facts, and the fleet row
  adds it to its tooltip and screen-reader label, not its visible line.
  Until a passphrase prompt (K45b, owner question O5) and the Flatpak
  grant (O1) exist, both new kinds' copy says to load the key into
  ssh-agent and drop the `IdentityFile` line that names it. The message
  goes once a backoff replaces the closed state, since `LinkBackoff`
  carries no failure, and an unreachable agent stays unclassified.
- `SshLink` liveness and channel-budget tests (M2, `seance_core`, X7,
  #239): tests only, added before K44b made `SshLink` production code.
  On fake time, a silent peer closes the link as `pingTimeout` 30 s
  after the ping; bytes on stdout, stderr or a forwarded stream skip a
  ping, and a quiet follower channel does not. On the real event loop,
  a ninth open queues on the link, a freed slot goes to user actions in
  arrival order before a queued SFTP open, and a session refusal below
  the budget learns the limit and degrades the link for both of
  OpenSSH's refusal shapes.
- Endpoint pin store (M2, `seance_core`, 03 §4.7, §4.9, §4.10, D16, X11,
  #247): `package:seance_core/catalog.dart` gains the `EndpointPin`
  value (server id, host, port, user, jump route ids in hop order,
  confirmation time), the `EndpointPinStore` interface (`pinFor`,
  `confirm`, `drop`) and `FileEndpointPinStore` over
  `endpoint_pins.json`: calls in order, whole-file atomic writes, a
  damaged file quarantined, a newer one left as it is with changes
  refused. Nothing in Klabautermann uses it yet: endpoint confirmation
  (SAF-09) and gating background connects on a pin are not built.
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
  the engine yet: `main.dart` spawns it once per launch. The app's engine
  runs with links on since K44b, so `Connect` dials, `Disconnect` closes
  the link and `SetAppActivity` reaches the supervisor; the app shows
  nothing for a `RequestRejected` of `Connect` (an id outside the
  fleet), and shows a `ConnectRejected` on the server's views (K44a). The
  Overview's sparklines show the rings (K32a, below); the coverage
  card's chart draws a separate `core` history (K39b, below), and the
  fleet rows use the clock for a reading's age (below).
- Phone server screen (M2, 03 §10.5, PLT-02, PLT-04, SYN-08, K40,
  #246): the phone's More destination lists Processes, Services, Jobs,
  System and Access, each opening full-screen in its narrow layout under
  its panel gate and return banner; while More shows, only the pushed
  panel samples. A unit's recent log lines open in a bottom sheet (60 %
  of the screen, draggable from 25 % to full height) that closes a
  running read when it closes; the desktop keeps them inline. The
  Overview and every pushed panel that samples pull to refresh through
  the new `RefreshSubscription` (joined v3 without a bump), which reads
  the subscription's streams at once, `identity` included; the
  indicator waits for a newer sample of each stream, for the server to
  stop sampling, or 10 s [E]. On iOS and Android the server header says
  that reading stops in the background (PLT-04). When the fleet stops
  listing the open server, its screen and every route above it close
  and the fleet list names it in a live-region notice. Pull to refresh
  has no keyboard or screen-reader action, and the gesture and the sheet
  drag are checked in widget tests only.
- Fleet rows (M2, 03 §10.3, FL-04, FL-05, FL-07, K31, #208): the rail
  and the phone list share one row, resolved through `ghost_servers`'
  indicator from the link status and the probe's answer. Each known state
  shows a word and an icon, a connected mark is framed, and each row is
  one screen-reader node. The shared filter field matches the engine's
  `searchText` (else the name and address), every term required; Enter
  opens the first match and Esc clears it. A server with an `overview`
  or `core` reading this engine run shows a CPU, memory and root-disk
  `PressureBar` (80 and 90 % until OV-11) and the reading's age. Both
  turn stale, with a history icon and, unless the state word already
  says the link is down, "Stale", once the link is connecting, failed,
  blocked or closed, or the reading reaches twice its stream's slowest
  cadence; they give way where the name and state word would not fit.
  K14's locator flag shows as a warning whose words a tap shows. Link
  changes are announced, through a live region where the platform takes no
  announcements; samples and probe answers are not. Rows subscribe
  nothing; the engine samples `overview` for the monitor set (K30, below),
  and the app's engine sends probe answers since K20 (below). It sends
  link states and samples since K44b turned links on, so in a real run a
  row shows its link state once its server is opened or monitored, and
  its readings while a view or the monitor set holds them.
- Monitor set (M2, FL-21, 03 §4.3 step 4, §10.1, K30): every fleet row's
  menu offers Monitor or Stop monitoring, and Settings > Servers (the
  route, and the desktop window through the `setMonitored` link method)
  lists the fleet with a switch per server, why a server cannot join,
  and the count out of 10. Eligible: a confirmed endpoint (imports count
  as confirmed) and agent or key-file sign-in, by
  `monitorEligibilityOf`, which the engine enforces too. Until the user
  chooses, desktops monitor the first 10 eligible servers and phones
  none; a choice is kept as `klabautermann.monitorSet` in
  `settings.json`, without the ids that left the fleet or stopped being
  eligible. The engine samples each member's `overview` under its own
  subscription over an unattended link, keeps that link when a view
  disconnects, and drops a member that leaves the fleet or whose
  endpoint a sync changes; `SetMonitorSet` with more than 10 ids is
  rejected whole, and ineligible ids are skipped by name. The coverage
  chip and sheet count the set. Tested in the engine (unattended dial,
  samples without a view, the limit, skipped ids, a moved server, a
  view's disconnect), the store (round trip, damaged values, read-only),
  the controller (defaults per platform, eligibility, limit, purge on
  save, not-saved), the row menu and both settings surfaces. Not
  checked: a jump host's credentials, and an encrypted key file, which
  fails the unattended connect until K45; on a real device, unverified.
- Server header and Overview part 1 (M2, 03 §10.2, §10.4, OV-01, OV-03,
  OV-04, MEM-01, MEM-02, K32a, #223): the desktop workspace and the
  phone's server screen open with a header showing the link state as a
  dot, an icon and a word through `ghost_servers`' indicator, as the
  fleet rows resolve it; a per-server coverage chip ("T0: sampled only
  while open") that opens the coverage sheet (below); the detected
  runtime from the access check, with the caveat that Podman can also
  answer on Docker's socket path; and, under those facts, why the link
  failed (K45a, below) and, on iOS and Android, the background line
  (K40, above). Past 40 % of its surface's height the header scrolls.
  The Overview tab shows the last `core` reading:
  CPU busy, user, system and idle and a bar per core in numeric order;
  the load averages and the load per core; used memory out of the total
  with total, available, buffers, cache, shared and the ZFS ARC note;
  and swap with its total. CPU busy, used memory and used swap each have
  a session sparkline over `MonitoringController`'s rings and a one-part
  bar; MEM-01's stacked breakdown is not drawn, since its parts overlap.
  One freshness line in K39a's words heads the cards, which grey past
  the `core` stream's 20 s limit; a failed reading says why above the
  last values, unknown values never read 0, and a figure a container
  withholds says why once per card (SYS-04, D50). CPU and memory warn at
  80 and 90 %, as the fleet rows do. Every figure uses IEC units, and a
  test keeps `ghostFormatFileSize` and `ghostFormatByteRate` out of
  `lib/`. Not yet: `CoreHeatmap`, a load sparkline and a radial `Gauge`.
  Since K44b turned links on, the app's engine connects an opened server,
  samples it and sends its profile, so the header shows the live link
  state and the detected runtime and the Overview shows the readings.
- Overview part 2 (M2, 03 §9.5, §10.3 to §10.5, §10.10, OV-01, OV-02,
  A11Y-15, D50, D60, K32b, #236): the `core` freshness line now heads
  the whole Overview, and a health card follows it: the failed units
  through the Services tab's `FailedUnitsSummary` (grey when stale),
  every listed mount, pseudo filesystems aside, whose space or inode use
  reaches the fleet rows' 80 or 90 %, critical and fullest first with
  the level in words, and a link to the announcement switch. After the
  CPU, load, memory and swap cards come Disks (the first eight mounts in
  the System tab's order, with bars that warn at 80 and 90 %, use, size
  and inodes; after a `df` timeout the last mounts with their use
  unknown, after any other failure only the reason), Network (NET-01's
  total rates from `core`) and Host (OS and kernel from `identity`,
  uptime and boot time with D50's reason in a container). The health and
  Disks cards give their own age and grey past the `fs` stream's 240 s
  limit. While the Overview shows uncovered and the switch is on, screen
  readers hear CPU busy, used memory and each listed mount's space and
  inode use cross into or out of a band, each change held 10 s through
  `threshold.dart`'s rules and spoken only with a whole percent inside
  the new band; where the platform takes no announcements (Android), a
  live region carries it. The switch is a device setting (D60; its key
  is in `settings.json`, below), on Settings' General tab and in the
  desktop settings window. Not yet: unhealthy containers (M3) and user
  thresholds (OV-11).
- Coverage part 1 (M2, 03 §9.5 items 1, 2 and 4, K39a, #210): a
  first-run card heads the desktop workspace and the phone's fleet list
  until "Got it", which `settings.json` keeps (below). A coverage chip at
  the top of the rail and above the phone's list counts the servers in
  FL-21's monitor set (none until K30) and opens the coverage sheet: the
  T0 badge, what is and is not covered, and no tier control. One
  formatter (`ui/freshness.dart`) words the background pause, a server
  not watched, a link lost while sampling, a reading's age and
  staleness, and no data yet. `MonitoringController` keeps each server's
  latest `SamplingState` and the phase before it. The Overview's
  freshness line (K32a, above) and the inspector's coverage (K39b,
  below) use the formatter's words; the fleet rows word their age
  with their own strings. The app's engine sends `SamplingState` since
  K44b turned links on.
- Coverage part 2 (M2, 03 §9.5 items 3, 5 and 6, K39b, #226): each
  server's Overview ends with a coverage card: the T0 badge with what
  live reading is doing (or the tier's rule before the engine says), a
  10-minute CPU busy `TimeSeriesChart` whose hatched bands say "in
  background", "disconnected" or "reading failed", the external-monitor
  finding, and what is not covered, with no control for T1 or T2. K04's
  rule now also recognises collectd, Prometheus, the Grafana Agent
  (static and Flow) and Alloy, and the card reads the units list once
  per engine run. The desktop inspector shows the selected server's
  coverage: its newest five gaps in words, "No data yet" before any
  reading, and each uncovered case with its reason.
  `MonitoringController` keeps a session history per `core` series and
  labels gaps from `SamplingState`, `Gap` and failed readings, and a
  `Gap` breaks the sparklines' rings, so they no longer join across a
  pause. Phones, and iOS or Android tablets in the desktop layout, show
  a dismissible return banner after a background pause of a server the
  engine was sampling, at most a fifth of the screen high. Since K44b
  turned links on, the app's engine sends samples, `SamplingState` and
  `Gap`, so the card, the chart, the inspector and the banner follow a
  connected server's readings.
- System tab (M2, 03 §10.4, K37, #209): the desktop workspace's System
  tab shows identity with virtualization (SYS-01), uptime and boot time
  (BOOT-01), total receive and transmit rates (NET-01), and usage and
  inodes per mount (DSK-01, DSK-02) in the sortable table, in IEC units,
  with pseudo filesystems behind a checkbox. Inside a container, uptime
  and boot time read as unknown with the reason wherever the probe's
  profile says their `/proc` file shows the host's figures (SYS-04,
  D50). After a `df` timeout the last complete reading's mounts stay
  listed with its date and time and their usage unknown. Any row opens
  its full mount point, device and figures in a sheet, and a narrow
  three-column table takes over below a width that grows with the text
  scale. `MonitoringController` keeps each server's latest host profile
  and latest reading per stream, and drops them with the server (SYN-08).
  Since K44b turned links on, the app's engine samples a connected server
  and sends its profile, so the tab shows its readings; phones reach it
  through More (K40, above).
- Processes tab (M2, 03 §7.2, §8.9, §10.4, PRC-01, SAF-07, D48, D50,
  K33, #238): the Processes tab lists the `procs` stream while it shows,
  in the sortable table by CPU (busiest first), IEC memory, user, start
  time and command, with the PID, under a filter over the PID, name,
  user as shown and command line as shown; below a 600 px width that
  grows with the text scale it lists two-line entries with a sort menu.
  A user reads as a name only where the host gives one, never a name
  GNU `ps` cut or a bare uid, otherwise "UID n". The engine dates each
  start (`ProcessRow.startedAt`) from the reply's uptime and the start
  ticks at USER_HZ 100; it is unknown until the probe reports its lxcfs
  mounts, and where lxcfs serves `/proc/uptime` (D50). The `ps`
  fallback's `[comm]`, or a zombie's `[comm] <defunct>`, reads as no
  command line, as on `/proc`. Command lines are drawn and searched up
  to 4,096 characters, a cut list says "Showing N of M" (D48), and
  through a failed reading the last list stays under K39a's freshness
  line and greys past 20 s. A row opens its details in a sheet, where
  selecting a masked argument shows it for 30 s, masked again sooner
  when the sheet closes or the app turns inactive, with a 48 dp target
  on touch; screen readers hear "(masked)". The row-action slot stays
  empty until PRC-02 (M4). Phones reach the tab through More (K40,
  above).
- Services tab (M2, 03 §7.5, SVC-01, SVC-02, SVC-04, K34, #216): the
  desktop workspace's Services tab lists the `units` stream's units in
  the sortable table with their load, active and sub states, filtered by
  unit type (services by default) and active state, under a summary that
  counts the failed units and names up to five (`FailedUnitsSummary`,
  which the health card is to share). A state systemd does not use in
  its column reads "unknown", and so do every state and the description
  of a row whose name ends in no unit type, which opens nothing (CN-10);
  a notice names the text fallback below systemd 246. A unit opens a
  page, under the table or in its place on a narrow panel, where Back
  returns and focus follows. The page reads SVC-04's 50-record journal
  window through `MonitoringController.openLogRead`, which opens it
  through `MonitoringController.logs` (`LogStreams`, shared with the Logs
  panel, below), and says what the read is doing. Since K44b turned links
  on, the app's engine samples a connected server and serves its log
  reads, so the list and the page show what the server returns; phones
  reach the tab through More (K40, above), where the unit's log lines
  open in a sheet.
- Jobs tab (M2, 03 §7.7, JOB-01, JOB-02, D57, D58, K36, #234): the Jobs
  tab lists the `cron` stream's rows (the user's crontab,
  `/etc/crontab`, `/etc/cron.d` and the `cron.<period>` scripts) and one
  row per `list-timers` entry in the sortable table, by job, source with
  the user its line names, schedule and next run (sorted first), and
  samples `cron` and `timers` only while it shows; below a 600 px width
  that grows with the text scale it keeps the job and next run. Cron
  schedules are worded field by field from ARB templates (crontab(5)'s
  day rule, uneven `*/n` steps with their bounds, macros, `CRON_TZ`);
  `OnCalendar` expressions show verbatim and monotonic triggers as
  spans. Cron runs show on their zone's clock with its offset, the
  engine's DST gap, overlap and near-transition marks, and a notice of
  the zone basis (D58). A timer's next run shows at the probe's offset,
  which its cell names, with a notice that a DST change before it does
  not show; a timer with no next instant reads "unknown". A row without
  runs gives the engine's reason, and any row opens its details in a
  sheet. Stale and failed readings keep the last rows under K39a's
  freshness line, greyed past 120 s. The engine does not run D57's
  timer reads, so timer rows say their triggers are not read; the
  details render triggers, randomized delay and calendar elapses once a
  row carries them. Cron commands show unmasked (SAF-07's masking covers
  process arguments only), and other users' crontabs (JOB-03) are not
  read. Phones reach the tab through More (K40, above).
- Access tab and panel gating (M2, 03 §10.4, CN-24, CN-09, SAF-08, D51,
  K38, #218): the desktop workspace's Access tab runs K04's access check
  over the probe's latest `HostProfile`
  (`MonitoringController.profileFor`) and lists its seven rows (CN-24's
  six and CN-09's runtime) under SAF-08's notice. Each row shows its
  state as an icon and a word, its reason, and SAF-08's badge on a
  root-equivalent right. Each fix is one line, quoted only where a shell
  would split or expand a word, behind a Copy button that only writes the
  clipboard; the row says whether the copy worked, and a copy from another
  row clears that line. The tab says the app never runs a fix, and shows
  the detected runtime (CN-09), chosen in the Docker tab since D20. A
  tab whose host panels all lack a capability the probe answered does
  not build its panel: a notice in its place names what is missing and
  links to Access, which the desktop selects with focus moved in and a
  phone pushes. The Docker tab follows
  its Docker endpoint since M3 (D12, above). Since K44b turned links
  on, the app's engine sends `HostProfileChanged` for a connected server,
  so the rows and the panel gating follow its probe.
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
  its own PR. The Overview (K32a, above) shows `MonitoringController`'s
  rings as session sparklines (OV-03).
- Bars (03 §10.7, M2): `StackedBar` for the memory breakdown and disks
  (MEM-01, DSK-01) and the fleet rows' three-cell `PressureBar` (FL-07),
  with hatching for unknown values, grey when stale, and threshold
  colours paired with a stripe, an icon and words (A11Y-01), plus
  screen-reader summaries and light and dark goldens. The fleet rows show
  `PressureBar`, the System tab's wide mounts table a `StackedBar` per
  mount, and the Overview one-part `StackedBar`s for CPU busy, each
  core, used memory and used swap; it draws no memory breakdown, whose
  parts overlap (above).
- Time-series chart (03 §10.7, §9.5 item 5, OV-03, M2, K12, #194):
  `TimeSeriesChart` draws one to four lanes of a `TimeSeriesRing` on a
  shared time axis with round local-time ticks and one IEC or percent
  scale. The caller opens a gap with its reason; no line crosses a gap or
  an unknown sample, each gap is a hatched band (2 px strokes held to 3:1
  as drawn) labelled "app closed", "in background", "disconnected" or,
  since K39b, "reading failed" where it fits, and the legend names each
  series, each gap reason and the caller's source. Screen readers get
  each series' summary, which reads "now unknown" while the right edge
  is in a gap, and each gap's span.
  Lanes differ by hue alone, which is still open against 03 §10.10. Not
  yet: `CoreHeatmap`, 03 §10.7's crosshair and threshold bands on this
  chart. The coverage card shows it (K39b, above).
- Sortable table (M2): the app's `SortableTable`, which the M2 lists
  build on. The caller owns the sort (a header click flips it; ties keep
  the caller's order and unknown values sort last). A screen reader hears
  each cell with its column name and gets the row's verbs as actions
  (A11Y-03, 03 §10.10). The body is one keyboard stop with an active row
  (arrows, paging, Home, End, Enter, Shift+F10), and rows keep the
  listing's fixed extent at the text scale. The System, Processes,
  Services and Jobs tabs use it (above); since K33 a row without verbs
  keeps an empty row-action slot, and since K37 a table sized to show
  every row scrolls the page around it to the active row.
- Device settings (03 §4.10): `settings.json` under the app's
  `getApplicationSupportDirectory()`, through `klabautermann_core`'s
  `DeviceSettingsStore`, which the composition root opens before the
  engine isolate starts (and never in the settings window's engine). It
  holds `klabautermann.settings.version` (1),
  `klabautermann.sync.deviceId`, `klabautermann.appearance` and, since
  K39a, `klabautermann.coverage.firstRunCardDismissed`, where anything
  but `true` shows the card again, and, since K32b,
  `klabautermann.accessibility.announceThresholdBands` (D60), on unless
  `false` and never synced; keys it does not know are kept on
  every write. The device id is a UUID v4 (`seance_core`'s `uuidV4`, as
  the catalog library's enrollment expects), minted and saved on the
  first launch and never regenerated while the file can be read; a
  damaged file whose text shows no id gets a new one (the old bytes stay
  in the corrupt copy). Nothing reads the device id yet. A second
  desktop instance stops at the instance lock (below) before the store
  opens, so two launches no longer race to mint it unless the lock
  cannot be taken.
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
- Sync state files and keystore port (M2, 03 §4.5, §4.10, D62, K49a,
  #258): `klabautermann_core/lib/src/catalog/` gives the catalog
  library's seams engine-side files under the support directory:
  `FilePinVerdictStore` over `pin_verdicts.json`,
  `FileSyncTripwireStore` over `sync_tripwires.json` and
  `FileSyncEnrollmentState` over `sync_enrollment.json`, which holds no
  device id and is handed the one `settings.json` holds. They share one
  rule set: a damaged file is renamed aside and the store starts empty;
  an unreadable file, a damaged one that cannot be renamed, or one from
  a newer schema is left as it is, and changes stay in memory and throw;
  writes are whole-file, atomic and queued in call order, and a failed
  one stays in memory for the next save; without exclusive access
  nothing is written or renamed. `KeystoreSyncCredentialStore` keeps the
  sync token and the vault key behind `SyncKeystore`, a pure-Dart port
  for the app to answer over `ghost_keystore`
  (`klabautermann.vault.masterKey.v1`,
  `klabautermann.apikey.sync.token`), and stages a vault re-key in the
  shared `FileVaultStore` journal. K49b (below) opens them in the
  engine and binds the port in the app.
- Pull-only sync (M2, 03 §4.3 steps 1 and 2, §4.4, §4.5, §10.1, D63,
  K49b, #261): the engine runs `EnrollSync` and `RunSyncRound` through
  the catalog library under `PushPolicy.none` (`engineSyncPushPolicy`),
  one operation at a time in request order beside the request queue,
  and its coordinator installs pulled pins through the engine's one
  host-key store (K44a). Sync needs exclusive access to the support
  directory: an unguarded engine refuses with `directoryShared`, and
  enrollment uses the device id the app read after taking the instance
  lock. The app's `EngineKeystoreResponder` answers the engine's
  keystore requests (`KeystoreRequest`, `AnswerKeystore`) through
  `ghost_keystore`, and a read never mints a key. You sign in from the
  sync chip at the foot of the fleet rail, or the sync button on
  phones, with the server address, account name, password and
  encryption passphrase, and confirm that every device on the account
  runs Séance 0.9.0 or later before anything is sent. An existing vault
  is re-keyed through the journal; a first enrollment without one
  installs the account key directly. The account's servers then lead
  the fleet, ahead of imports, and stay after a restart; each round is
  started by the user, none runs at startup or on a timer. Synced
  servers have no connect config, so a `Connect` to one is rejected
  until endpoint confirmation (K41) exists. Sign-out, switching
  accounts, secrets, quarantine and pin-conflict surfaces are not
  built. Tested against an in-memory sync server that refuses any push
  and a fake OS keystore; no real Séance server or OS keystore has been
  exercised, and the keychain sign-off stays a manual gate (06).
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
  does). Only an engine with links on dials them, as the app's does
  since K44b (above).
- Final-pass hops (M2, 03 §10.1, K14b, #222): the import no longer
  checks a hop that keeps its first pass against that hop's final pass
  where ssh's final pass already fails before the hop: for the hops of a
  host that keeps its first pass, and behind a first hop that holds only
  by looping. So hosts plain ssh reaches, such as web behind
  `bastion,bastion2` in 03 §10.1's example, import with their jump
  chain. This assumes a system config asks for the final pass for every
  name or for none, as `Match final all` does. Still left out,
  conservatively: hosts behind a first hop whose own route fails the
  check, and hosts behind a hop left out for what its final pass sets.
- Packaging: `scripts/build.sh`, `scripts/package-linux.sh` (.deb and
  AppImage through the shared `scripts/package-linux-common.sh`) and
  `scripts/build-flatpak.sh` with `flatpak/ch.lkmc.klabautermann.yml`.
  The flatpak grants read-only `~/.ssh/config` for the FL-02 import and
  nothing else under `~/.ssh` (04 §12.1). Links are on in the app since
  K44b, and their identity-file reads (K17, above) need the wider grant,
  which waits for the owner's sign-off (O1): until then the Flatpak
  build cannot read a host's `IdentityFile`, and signs in through an
  ssh-agent only for hosts that name none. Locally the scripts have only
  run on stub bundles;
  CI's Linux client leg runs them on the real release bundle, with
  appimagetool and flatpak-builder.
- Client CI legs: `klabautermann_client` in the root `ci.yml` builds
  Android, Linux, macOS, iOS and Windows on every PR, launches the three
  desktop release builds, checks the APK's version code and the macOS
  bundle's signature, packages the .deb, AppImage and Flatpak, and runs
  the macOS fixtures. The root `release.yml`'s `client_klabautermann`
  job (M4 E32) builds the same five targets on a release tag and
  attaches eight preview assets, all but the .deb with the preview
  label in their names, which
  `scripts/release-manifest.txt` and `scripts/check-workflows.sh` hold
  to the release floor (decision 16).
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
  test `klabautermann/test/integration`, which holds the contract tests
  of the jobs and their entry points. A workspace `dart_test.yaml`
  declares the `shell` tag and the 60 s cap for runs from
  `klabautermann/`. All three entry points are on main (K24, K28c and
  K29b, below), and all three legs passed on main at #259's merge (run
  39020297754).
- sshd integration fixture (M2, 03 §11.3, D53, K24, #233):
  `test/integration/docker-compose.yml` builds two services on
  Poltergeist's digest-pinned sshd base, the sampled host `sshd` and the
  ProxyJump host `jump`, on fixed loopback ports, with Poltergeist's
  common sshd config mounted by path. `run.sh` checks its prerequisites,
  holds a machine-wide lock, generates the client keys and an agent
  outside the repository for each run, checks the rendered config with
  Poltergeist's `check_config.dart`, runs the `integration`-tagged
  engine suites one at a time and tears down on every exit, stopping
  the suites first on a signal; with `KLABAUTERMANN_EVIDENCE_DIR` set it
  keeps the logs. `engine_fixture_test.dart` spawns the real engine with
  links on over an imported ssh_config and checks each host-key prompt
  against the container's fingerprints. It covers an `IdentityFile`
  host's probe and ticks, agent sign-in, ProxyJump, a SIGSTOPped fast
  sampler (`Gap(readingLost)`, the link stays up), a `df` hung until its
  timeout guard stops it, `compose restart` (a redial without a prompt,
  the `seq` continuing) and `compose pause` (closed as `pingTimeout`,
  redialed after unpause). The suites skip without `run.sh` and fail on
  a partial fixture environment. The fixture showed that BusyBox's
  `timeout` exits 143 when it stops a command, so a guarded 143 now
  reads as a timeout (collector-set version 7). Not covered:
  keyboard-interactive sign-in, agent forwarding and a redial while the
  host is still paused.
- Runner-VM leg (M2, 03 §7.6, §11.3, D57, K28a, #243): after the fixture
  suites, `run.sh` runs `test/integration/runner_vm.sh`, which runs only
  on a GitHub-hosted runner (elsewhere it skips with a notice) and there
  fails rather than skips on a missing prerequisite. It starts a sshd of
  its own on 127.0.0.1:2243, signs in as two throwaway accounts whose
  login shell is dash, `klab-vm` outside `systemd-journal` and
  `klab-vm-journal` in it, captures the runner's fixture
  (`ubuntu-2404-runner-dash`: Ubuntu 24.04, systemd 255, now committed
  with its goldens) and runs `runner_vm_test.dart` against real systemd:
  the probe and units on the JSON path; a transient timer, with its
  `timer_detail` and `systemd-analyze calendar` reads run over a side
  channel and parsed by the host's parsers; a journal follow without a
  pager resumed after its cursor across a forced reconnect, with nothing
  repeated, dropped or marked as a gap; a system unit's logs, which the
  limited account does not see (LOG-04); the kernel log from the
  journal, or for the limited account the `dmesg` fallback; and journal
  pages continuing after the last cursor. Teardown removes the accounts,
  the timer and the sshd. The S5 replay and budget harness skip the
  `-runner-` and `-docker-` captures, so they keep the six platform
  fixtures.
- Fixture soak (M2, 03 §11.4, K28b, #250): after the runner-VM leg,
  `run.sh` runs `soak_test.dart` (tag `soak`) against the sshd fixture
  for 600 s under `GITHUB_ACTIONS=true` and 60 s elsewhere
  (`KLABAUTERMANN_SOAK_SECONDS`), and a soak that writes no `soak.json`
  fails the run. Ten `Host alias-N` entries share the sampled host, so
  ten links sample at S5's Phone cadence, one of them also reading
  `core` every 3 s; a test-only meter wraps each real `SshLink` through
  the engine's dial seam. The soak asserts fast-tick replies within
  2,500 B plus 30 B per CPU beyond 32, the ten hosts' channel output
  under 1,000 B/s, no growth in channels per link, descriptors (2 of
  slack), live heap after a full collection (1 MiB) or resident set
  (32 MiB), and steady sampling. It records without asserting the
  server CPU per fast tick against 03's 5 ms reference-VM estimate, the
  engine's CPU and the SSH payload. The tolerances are provisional; the
  24 h soak before M4 and M7 stays manual.
- Container captures (M2, 03 §6.5, §6.6, §11.3, K28c, #241):
  `test/integration/capture.sh` compiles the capture tool, runs it as
  root in a fresh container per capture (nothing mounted or published,
  each container labelled and removed on exit) and copies the redacted
  fixture out with its provenance. The images are pinned by digest
  (Debian 12 and 13 and Ubuntu 22.04 and 26.04 under dash and bash; UBI
  9 and 10, Fedora 44 and Arch under bash), and Debian 13 also runs
  BusyBox ash, mksh and zsh as `sh -s` and bash, zsh, fish and tcsh as
  login shells, from Debian packages pinned by SHA-256 on
  snapshot.debian.org. The 19 captures are committed as
  `<platform>-docker-<shell>` fixtures with goldens, and the pipeline
  fixture test covers each. CI's `klabautermann_integration` job runs
  the script in check mode, which fails a capture whose files, section
  statuses or probe statuses differ from the committed fixture;
  `--update` replaces them. No capture runs systemd (its collectors are
  the runner-VM leg's), as a non-root account, on a BusyBox or musl
  userland or on arm64, and the Debian, Ubuntu and Fedora captures name
  no container, so D50 withholds nothing there.
- Fedora 44 repin (M2, #259): `quay.io` no longer serves the Fedora 44
  digest `capture.sh` pinned, so `fedora-44` now pins the tag's current
  index digest, and the `fedora-44-docker-bash` fixture is recaptured
  from it with its goldens (collector-set version 7).
- Docker fixture and rank-1 smoke (M3, 03 §5.4, §11.3, D10): the
  fixture adds `dind` (Docker 29.9.1, privileged, unpublished, dockerd
  on one Unix socket with gid 990, on a named volume) and `docker-sshd`
  on 127.0.0.1:2244, the sshd base plus the static docker CLI and
  Compose plugin copied from the digest-pinned CLI image, with
  `AllowTcpForwarding local` ahead of the common config, the socket at
  `/var/run/docker.sock` and `/run/user/<uid>/docker.sock`, `klab` in
  `docker` and `klab-nosock` outside it. `run.sh` checks the rendered
  config with `check_docker_exposure.dart` after Poltergeist's checker
  (no published 2375 or 2376, no host `docker.sock` bind, `privileged`
  only on dind or Podman, dind's dockerd on an explicit Unix `--host`),
  loads busybox pulled by digest into dind over SSH and runs
  `seed_docker.sh` as `klab` (stack `demo` with healthy, unhealthy and
  TTY services, stack `gone` without its files, a Coolify-managed
  container). `docker_link_test.dart` (tags `integration`, `docker`)
  pings, negotiates and lists over `SshLink.openUnixStream`, reaches the
  second path, and sees `klab-nosock` refused. Locally it adds about
  16 s to `run.sh` with the images cached.
- Recorded Docker API corpus (M3, 03 §11.1, D21, D01): `capture.sh`
  also runs `capture_docker_api.sh`, which starts digest-pinned rootful
  daemons in privileged containers (unix socket only, nothing published,
  labelled and removed with their volumes on exit): Docker 20.10.24,
  25.0.5, 29.0.4 and 29.7.2 at their native maxima 1.41, 1.44, 1.52 and
  1.55, and Podman 5.8.7's compat service (1.44). In each,
  `klabautermann_docker/tool/capture_api.dart` drives the package's own
  HTTP client over the socket, seeds containers (health passing and
  failing, a 2,000-line job, TTY, paused, a compose project, a Coolify
  container, fake low-entropy secrets), an image, a network and a
  volume, and records 30 exchanges as raw response bytes into
  `klabautermann_docker/test/fixtures/api-*/`. Check mode compares a
  fresh capture by structure, never by value; `--docker-api-only`
  [`--update`] runs only these. The committed corpus comes from a local
  cgroup v1 run; rootless daemons stay unrecorded.
- Negative sshd variants and refusal evidence (M3, 03 §5.3, §11.3,
  D11): six Docker hosts on 127.0.0.1:2245 to 2250 refuse with
  `AllowStreamLocalForwarding no`, `DisableForwarding yes`,
  `AllowTcpForwarding no`, `PermitOpen 127.0.0.1:1`, `MaxSessions 2`
  and a `restrict` key. `docker_refusal_test.dart` records, on the
  base's OpenSSH 10.6, that every forwarding variant refuses
  streamlocal (reason 2, "open failed", `forwardDisabled`), that only
  `AllowStreamLocalForwarding no` still opens `direct-tcpip`, that
  `MaxSessions 2` teaches the link a limit of 2, and that `klab-nosock`
  sees the socket, fails `test -w` and gets `EACCES` from the docker
  CLI. Each result, with sshd's log lines, goes to
  `$KLABAUTERMANN_EVIDENCE_DIR/fixture/refusals/`. Locally it adds
  about 8 s to `run.sh` with the images cached.
- Recorded API replay (M3, 03 §11.1, D02): `RecordedDaemon` in
  `klabautermann_docker/testing.dart` serves a corpus to the real HTTP
  client, matching method, path (a lower negotiated version gets the
  native recording) and normalized query, whole or one byte at a time.
  `recorded_api_test.dart` replays every `api-*` directory: negotiation
  from `_ping` and `/version`, the client's floor and server-minimum
  refusals and the daemons' own 400s (Podman accepts every version),
  every typed endpoint with no parser warning, the event, image-count,
  logs `Content-Type` and `/system/df` gates against the lists, the
  2,000-line follow demultiplexed, a `since` resume with no lost or
  repeated line, and one-shot stats then a stream delta. An idle
  container's CPU now reads 0 % rather than unknown, and Go's zero time
  (a created container's `StartedAt`) reads as absent.
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
    and Windows, none on phones. Registered: About Klabautermann (first
    in the application menu on macOS, Help elsewhere; below), Settings…
    (⌘, on macOS, Ctrl+, elsewhere; in the application menu on macOS,
    File elsewhere), Import from ~/.ssh/config (File, desktops, disabled
    while an import runs) and Quit (File, Linux and Windows, the close
    button's path). On macOS AppKit adds Services, the hide trio, Quit
    (⌘Q), Enter Full Screen (View) and Minimize, Zoom and Bring All to
    Front (Window).
    The same registry binds the shortcuts. No command is a toggle, so
    `klabautermann/menu_checks` stays reserved.

  The macOS runner lines are copied from Séance and ledgered in
  [SHARED.md](SHARED.md); Linux and Windows need no runner code. The
  client CI legs compile the macOS runner;
  `app/klabautermann_app/test/desktop_chrome_runner_test.dart` also
  guards its wiring on Linux.
- Preview label (E26, M16; 04 §12.3): until v1 the app title is
  "Klabautermann (preview)" (`appTitle`), tied by tests to
  `kPreviewLabel` in `lib/app_identity.dart`, as is the `.deb`
  description of `scripts/package-linux.sh`. About Klabautermann, on
  every desktop, opens the app's About dialog (Material's, with the
  title, the version and the Unlicense line, and View licenses);
  Settings > General has an about row with the title and version that
  opens it everywhere, phones included. On macOS the command replaces
  AppKit's About panel, which shows `CFBundleName`, an identity that
  stays unchanged (owner question Q3). The version comes from
  `package_info_plus`, read once in `main`; the settings window's
  engine has no plugins, so the snapshot of the settings link carries
  it. The release asset names keep their label from the packaging
  scripts, and the release job and notes carry it (E32). M7 drops the
  label in one change.
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
  them; the engine's followers run since K26 (above).
- Log viewer (03 §10.8, LOG-02): `lib/ui/logs/`'s `LogView` over a
  `LogViewController` draws fixed one-line rows or wrapped rows, measuring
  only the lines a layout shows and finding offsets in O(log n); follows
  the newest line, pauses on any scroll away from it and resumes at the
  end, on End or Follow; colours levels with a spoken gutter icon; holds
  every span to 4.5:1; and scrolls by keyboard with a focus ring. Light
  and dark goldens draw with the test font and compare on Linux only. Not
  yet: sideways scrolling without wrap (a long line ends in an ellipsis,
  which hides a cut line's note) and tab stops. The Logs panel and the
  Services tab's unit page show it; the engine's followers run since K26
  (above).
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
  scrolls the current one's row into sight. The Logs panel (below) adds
  the search field. Not yet: showing a match past a row's ellipsis or
  after a journal row's first line without wrap; a time column (needs
  the server zone); and repeated journal fields, which
  `parseJournalLines` misreads. The Logs panel and the unit page draw
  journal rows; the engine reads windows and runs follows only with
  links on (K25b and K26, above).
- Logs panel (M2, 03 §10.4, §10.8, LOG-01 to LOG-05, LOG-22, K35, #217):
  the desktop Logs tab and the phone's Logs destination read one source
  into the log viewer with journal rows and search: the journal, filtered
  by unit, identifier, priority, current boot and a time range counted
  back from when the stream opens; the kernel log; or one file, whose
  path the app checks with the engine's rule (absolute, no NUL, no `.`
  or `..` part), with common syslog, auth, nginx and Apache paths
  offered. The Live chip (LOG-02) follows, resuming after the panel's
  newest journal record, or reads a 500-record window, and names the
  stream's state by word and icon. A status line in a live region gives
  the reason, the host's error output and Retry where reading again may
  help. The search field waits 200 ms after typing. LOG-04's notice shows
  above the journal and the kernel log when the access check says the
  account sees only its own entries. Narrow panels, phones included, open
  the source and filters in bottom sheets. A stream is open only while
  the panel shows.
  `MonitoringController.logs` (`LogStreams`) owns the engine run's log
  streams, the unit page's reads included: it mints `log-N` ids, sends
  `OpenLogStream` and `CloseStream`, routes events by id, gives a
  rejection to the oldest unanswered open, and keeps each server's
  journal access, dropped with the server (SYN-08). That rule holds
  because the engine answers each open it accepts before the next
  request (03 §10.1). With links on the engine runs the Live chip's
  follows (K26, above), and the status line says when a follow that
  restarted may have missed lines. Since K44b turned links on, the app's
  engine serves the panel's reads over the server's link and sends the
  host profile that LOG-04's notice follows.
- M4 spike S3 (E01): `capture.sh --elevation-only` drives the real
  elevation executor in containers. It covers sudo 1.9.16p2 under four
  timestamp and tty rules, sudo-rs 0.2.13 and Alpine's doas, as a
  non-root account with no tty. The evidence is in `docs/evidence/s3/`,
  with D65 in 03. Rungs 2 to 4 hold; `requiretty` and password doas
  need rung 5. Under `timestamp_type=global` a cached record accepts a
  wrong password, so admin-mode validation (E11) will use
  `sudo -k -S -p '' -v`. The matrix ran locally; CI runs only its
  contract tests, since the Alpine package pin can disappear. run0 stays
  manual.
- M4 protected targets, ownership and danger (E10): the plan facts
  for 03 §8.6 and §8.7, with no planner using them yet.
  - Protected targets: built-in units, PID 1, the core daemons, the
    session's own sshd and sampler PIDs (from E07's `SELF`), containers
    on the SSH or a VPN port, and the user's device-local marks.
  - Managed containers and stacks raise the tier to typed.
  - API steps are linted as their Docker CLI equivalents.
  - Typed impact facts.

  E14 and E15 build plans from these facts.
- M4 audit log (E12b): every finished run appends a redacted record to
  the server's `audit/` file. Records are pruned after 90 days, and a
  damaged file is quarantined. Without exclusive access the log lives in
  memory, and the engine says so at start. `AuditQuery` reads it; the
  viewer and export arrive with E24.
- M4 operation runner (E12a): a confirmed plan is re-validated (unit
  loaded, process start time, Docker target unchanged), then its own
  steps run in order. Shell steps go over the link or through admin
  mode's executor; API steps go through the Docker runner E15 adds. A
  failure stops the run and is reported with typed facts. Plans run
  once, and only on the link generation they were previewed on.
- M4 admin mode and safety policy (E11): the engine runs admin mode
  per server (03 §8.2). It detects how to elevate, asks for the password
  only when the prelude needs it, and validates it through the elevation
  executor. Admin mode ends after inactivity, in the background, on link
  loss or when the server leaves. The engine enforces the app's safety
  policy: observe-only by default, read-only above it. No app surface
  sends these messages yet: E19 adds the Safety settings and the chip.
- M4 operation model (E09): `klabautermann_core` builds immutable
  operation plans, whose preview shares the steps the runner will take
  (03 §8.5). It also computes 8.6's confirmation tiers and holds
  previewed plans for 5 minutes, refusing stale ones. `ActionIntent` is
  sealed, one variant per MVP action, and `ActionPreview` carries typed
  steps and risk facts. Until the planners land (E14, E15), the engine
  refuses every plan with `ActionRefused`.
- M4 command builders (E08): `klabautermann_host` builds the guarded
  kill (PRC-02), which signals only when the PID's start ticks still
  match and exits 4 for a reused PID. It also builds `timerStart`
  (JOB-08), the crontab spool listing (JOB-03) and the detached
  operation commands (SAF-23): the inline wrapper, which writes
  `<id>.json` records atomically with `mv`, the launch argv of the five
  runner rows, cleanup and the 7-day prune. Real-shell tests run under
  dash and bash. Nothing runs these builders yet: E14 and E17 will.
  The root-run wrapper's `chown` was checked by hand only, and whether
  the backgrounded `setsid` launch survives logout waits for spike S4.
- M4 theme editing (E25): Settings > Appearance edits the theme with
  ghost_theme's shared editor (presets, mode, colours, font, corners,
  copy, paste and reset), in the app and in the desktop settings window,
  in Klabautermann's words.
- M4 Docker fixture for mutations (E27): the Docker fixture gains a
  registry on its Compose network, which dind alone trusts, and seeds a
  stack to redeploy, one with an orphan, a managed one and a container
  on port 22.
- Probe and sampler additions (M4, E07, 03 §6.2, §7.17): collector-set
  version 8 prints a `SELF <pid> <ppid>` marker before READY, which
  `HwsSessionReady` carries for 8.6's protected targets, and the
  assembler ends a session whose READY of this version comes without it.
  The probe runs `run0 --no-ask-password true` when run0 exists
  (`HostProfile.run0NonInteractive`; the probe's deadline grows to 175 s
  for its 17 guarded commands). The slow `ops` collector lists both
  operation directories, at most 50 records each cut at 4 KiB, framed by
  byte counts; `parseOps` reads E08's record schema into `OpRecord` and
  rejects truncated, malformed, other-version and forged records (an id
  that differs from the file name, or a unit not its own). Tested with
  record fixtures and through dash and bash (BusyBox sh where
  installed). Nothing in the engine uses the SELF PIDs or `ops` yet:
  E10 takes the PIDs into the protected targets, E17 runs `ops` on
  connect, and `ops` has no platform fixture.

Pull-only from the start (D14): no surface sends a request that could
push or write catalog records, and a widget test guards it.

Not in yet (later PRs): pull-only enrollment and the catalog (F3), the
engine's reachability probes behind the rows' dots (K20), theme editing
and presets (F4b's editor), the monitor set and per-server device
preferences in `settings.json`, and the release job (M4).

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
  does what it says. About Klabautermann opens the app's About dialog
  ("Klabautermann (preview)", the build's version, the Unlicense line),
  never AppKit's panel. ⌘, opens Settings from the main window, from a
  focused text field, and with Settings in front (it comes forward).
  There is no Edit menu yet: ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z still work in a text
  field in both windows. Linux and Windows: a menu strip above the
  content with File (Import from ~/.ssh/config, Settings… with Ctrl+,
  shown and working, and Quit, which closes the app the way the close
  button does) and Help (About Klabautermann, the same dialog). The
  import item is dimmed while an import runs. Phones and tablets show
  no menu. On every OS, Settings > General's about row shows the
  build's version, in the settings window too, and opens the dialog. Open: needs a person on each OS; the widget tests check the
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
