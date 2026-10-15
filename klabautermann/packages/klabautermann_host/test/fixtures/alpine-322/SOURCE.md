Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), busybox and OpenRC documentation), not captured from a real host.
The capture tooling of spike S2 replaces these fixtures later.

`procs.txt` holds the BusyBox `\037`-separated `cmdline` dump. Alpine has
no systemd, so `units.txt` and `timers.txt` are the empty payload the
`units`/`timers` collectors emit when `systemctl` is missing. `cron.txt`
follows BusyBox crond and crontab(5).

For collector-set version 4 (03 D48) a one-off script rewrote the
`overview` and `core` payloads from their version 3 form into the
filtered shapes, keeping the values: per-core busy and idle sums, the
netdev counters of the interfaces the fragment keeps (lo, docker0 and
unused interfaces go), whole-disk diskstats rows (partitions, dm and
loop devices go), and PSI lines without `total` and without cpu's
`full` line.
