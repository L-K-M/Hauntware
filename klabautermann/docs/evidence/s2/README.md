# Spike S2, part 1: dash and bash on one machine

`local-ubuntu-2404-container.json` is the output of

```bash
cd klabautermann/packages/klabautermann_core
dart run tool/capture_fixtures.dart measure \
  --out ../../docs/evidence/s2/local-ubuntu-2404-container.json
```

with collector-set version 2, run on 2026-10-14 in a 4-CPU Ubuntu 24.04
container without systemd that other jobs shared (dash 0.5.12, bash
5.2.21). It is not the reference VM of 03 §11.4. The program ran as
`sh -s` through a link named `sh` to each shell, so bash ran in POSIX
mode as it does when installed as `/bin/sh`. Login shells ran as sshd
runs a command, `<shell> -c '<start command>'` with the shell's
basename as argv[0], and the start command then exec'd this machine's
`sh`, dash. CPU is the sampler shell's `utime + stime` from
`/proc/<pid>/stat` (plus its waited-for children on the slow sampler),
in 10 ms clock ticks; fast-tick CPU is averaged over 500 ticks.

## What it shows

- **Output before READY.** With `<shell> -c '<start command>'` and the
  variables sshd sets, dash read none of the startup files tried. bash
  read `~/.bashrc` only when `SSH_CLIENT` was set (the 18-byte banner
  `banner from bash` and CRLF arrived before READY), never
  `~/.profile`, `~/.bash_profile` or `~/.bash_login`; Ubuntu's
  `/etc/skel/.bashrc` printed nothing. A `.bashrc` printing 60 KiB
  still reached READY; one printing 70 KiB failed the start
  (`noReady`), as the 64 KiB rule of 03 §6.2 says.
- **Fast tick.** The reply to `overview` is 1,227 bytes (payload 1,084,
  of which `/proc/net/dev` is 710) and to `core` 2,773 bytes (payload
  2,634: `diskstats` 924, `netdev` 711, `stat` 296, `meminfo` 266,
  `pressure` 366). The core reply is over 11.4's 2.5 KB on 4 CPUs, and
  overview is about twice 6.4's 600 B; at the phone cadence (overview
  every 10 s) ten such hosts send 1,227 B/s of replies, above 11.4's
  1 KB/s. Both feed the host-side filters of 03 D48. CPU per tick is
  0.78 ms (overview) and 1.48 ms (core) under dash, 0.94 and 1.86 ms
  under bash, inside the 5 ms budget; no child CPU accrued, as the fork
  budget expects.
- **`procs` beyond 1,000 processes.** With extra `sleep` processes
  (short command lines) the section costs about 445 bytes per process:
  475 KB at 1,079 processes (45 % of the 1 MiB section cap), 934 KB at
  2,083 (89 %) and 1.38 MB at 3,085, where the frame parser rejects the
  section and the reply is lost. Short command lines reach the cap near
  2,350 processes; longer ones sooner. Time grows roughly with the
  square of the process count: 48 ms, 2.3 s, 10.3 s and 23.3 s under
  dash at 78, 1,079, 2,083 and 3,085 processes, and 121 ms, 17.3 s,
  67.5 s and 153 s under bash at 79, 1,079, 2,091 and 3,085, nearly all
  of it CPU time.
- **`procs` against its deadline.** The `stat` and `status` loops over
  `/proc` run in shell builtins, so `timeout 10` does not bound them.
  Under 03 D47 a slow request's deadline is derived from the guarded
  commands its collectors can run, each bounded by `timeout 10`, plus a
  margin that D47 has not fixed yet. `procs` runs one (`head` over the
  command lines; the `ps` fallback up to two), so its derived deadline
  is about 10 s (20 s) plus the margin. The loops alone reach the 10 s
  guarded budget near 2,000 processes under dash (10.3 s at 2,083), so
  whether they pass the deadline there depends on the margin; at the
  square-law growth above, a margin of about 3 s would move the dash
  crossing to the 1 MiB cap. Under bash they pass it by 1,079 processes
  (17.3 s) for any margin under 7 s, so on such hosts a working sampler
  would keep restarting. K15 has to bound the loops or add a
  process-count term to the `procs` deadline; the second amends D47.
- **Slow tick.** Medians of three runs, dash then bash: probe 73 and
  89 ms, `fs` 7 and 9 ms, `identity` 9 and 12 ms, `procs` (78 and 79
  processes) 44 and 89 ms, `cron` 1 ms, and all slow collectors but the
  probe in one tick 78 and 134 ms. `units` (14 and 19 ms) and `timers`
  (9 and 11 ms) only measured their error path: systemd is not running
  here.

## Not covered here

- BusyBox ash, mksh and zsh as `/bin/sh` (`--sh`), and zsh, fish and
  tcsh as login shells (`--login-shell`): in CI where container images
  provide them, otherwise on the manual checklist (06).
- `units`, `timers` and journal paging flags on a running systemd: the
  runner VM leg.
- Captures over SSH. The `capture` command exists, but no fixture comes
  from this machine: its process list and mounts describe the build
  sandbox, not a server.
