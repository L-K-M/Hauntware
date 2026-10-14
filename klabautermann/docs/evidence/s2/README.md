# Spike S2, part 1: dash and bash on one machine

`local-ubuntu-2404-container.json` is the output of

```bash
cd klabautermann/packages/klabautermann_core
dart run tool/capture_fixtures.dart measure \
  --out ../../docs/evidence/s2/local-ubuntu-2404-container.json
```

with collector-set version 2, run on 2026-10-14 in a 4-CPU Ubuntu 24.04
container without systemd that other jobs shared (dash 0.5.12, bash
5.2.21). It is not the reference VM of 03 §11.4. CPU is the sampler
shell's `utime + stime` from `/proc/<pid>/stat` (plus its waited-for
children on the slow sampler), in 10 ms clock ticks; fast-tick CPU is
averaged over 500 ticks.

## What it shows

- **Output before READY.** With `<shell> -c '<start command>'` and the
  variables sshd sets, dash read none of the startup files tried. bash
  read `~/.bashrc` only when `SSH_CLIENT` was set (a 27-byte banner
  arrived before READY), never `~/.profile`, `~/.bash_profile` or
  `~/.bash_login`; Ubuntu's `/etc/skel/.bashrc` printed nothing. A
  `.bashrc` printing 60 KiB still reached READY; one printing 70 KiB
  failed the start (`noReady`), as the 64 KiB rule of 03 §6.2 says.
- **Fast tick.** The reply to `overview` is 1,226 bytes (payload 1,083,
  of which `/proc/net/dev` is 710) and to `core` 2,766 bytes (payload
  2,627: `diskstats` 918, `netdev` 711, `stat` 295, `meminfo` 266,
  `pressure` 366). The core reply is over 11.4's 2.5 KB on 4 CPUs, and
  overview is about twice 6.4's 600 B; at the phone cadence (overview
  every 10 s) ten such hosts send 1,226 B/s of replies, above 11.4's
  1 KB/s. Both feed the host-side filters of 03 D48. CPU per tick is
  0.78 ms (overview) and 1.50 ms (core) under dash, 0.90 and 1.78 ms
  under bash, inside the 5 ms budget; no child CPU accrued, as the fork
  budget expects.
- **`procs` beyond 1,000 processes.** With extra `sleep 600` processes
  (short command lines) the section costs about 440 bytes per process:
  470 KB at 1,077 processes (45 % of the 1 MiB section cap), 919 KB at
  2,081 (88 %) and 1.37 MB at 3,084, where the frame parser rejects the
  section and the reply is lost. Short command lines
  reach the cap near 2,400 processes; longer ones sooner. Time grows
  roughly with the square of the process count: 38 ms, 2.2 s, 10.4 s
  and 23.3 s under dash at 77, 1,077, 2,081 and 3,084 processes, and
  72 ms, 16.8 s, 67.3 s and 157 s under bash, nearly all of it CPU
  time. The loop over `/proc` runs in shell builtins, outside
  `timeout 10`: under bash the tick passed 03 §6.2's 30 s slow deadline
  between 1,077 and 2,084 processes, under dash it stayed below 30 s up
  to 3,084.
- **Slow tick.** Medians of three runs, dash then bash: probe 83 and
  91 ms, `fs` 8 and 9 ms, `identity` 11 and 10 ms, `procs` (77
  processes) 59 and 87 ms, `cron` 1 ms, and all slow collectors but the
  probe in one tick 95 and 134 ms. `units` (14 and 17 ms) and `timers`
  (9 and 13 ms) only measured their error path: systemd is not running
  here.

## Not covered here

- BusyBox ash, mksh and zsh as `/bin/sh`, and zsh, fish and tcsh as
  login shells: in CI where container images provide them, otherwise on
  the manual checklist (06).
- `units`, `timers` and journal paging flags on a running systemd: the
  runner VM leg.
- Fixture capture and captures over SSH. No fixture should come from
  this machine: its process list and mounts describe the build sandbox,
  not a server.
