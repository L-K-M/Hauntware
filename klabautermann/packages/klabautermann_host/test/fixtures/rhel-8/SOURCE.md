Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), systemd manual pages), not captured from a real host. The capture
tooling of spike S2 replaces these fixtures later.

`procs.txt` holds the `\037`-separated `cmdline` dump. `units.txt` and
`timers.txt` are the `--plain --no-legend` and columnar text fallbacks of
systemd 239 (U). `cron.txt` follows crontab(5) and cron(8); its
`/etc/crontab` `run-parts` lines are RHEL 5-era. RHEL 8's `crontabs`
package ships only the environment lines there, and cronie-anacron runs
`cron.daily`, `cron.weekly` and `cron.monthly` through
`/etc/cron.hourly/0anacron` (`test/jobs/jobs_test.dart` covers that
layout).

For collector-set version 4 (03 D48) a one-off script rewrote the
`overview` and `core` payloads from their version 3 form into the
filtered shapes, keeping the values: per-core busy and idle sums, the
netdev counters of the interfaces the fragment keeps (lo, docker0 and
unused interfaces go), whole-disk diskstats rows (partitions, dm and
loop devices go), and PSI lines without `total` and without cpu's
`full` line.
