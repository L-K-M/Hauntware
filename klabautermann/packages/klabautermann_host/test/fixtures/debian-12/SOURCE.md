Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), systemd manual pages), not captured from a real host. The capture
tooling of spike S2 replaces these fixtures later.

`procs.txt`, `units.txt`, `timers.txt` and `cron.txt` are likewise
hand-written from proc_stat(5), procfs(5), crontab(5), cron(8), ps(1),
journalctl(1), systemctl(1) and systemd.time(7) for systemd 252; the
`cmdline` block holds real `\037` separators.

For collector-set version 4 (03 D48) a one-off script rewrote the
`overview` and `core` payloads from their version 3 form into the
filtered shapes, keeping the values: per-core busy and idle sums, the
netdev counters of the interfaces the fragment keeps (lo, docker0 and
unused interfaces go), whole-disk diskstats rows (partitions, dm and
loop devices go), and PSI lines without `total`.

For version 5 the same script turned the `stat` and `status` blocks of
`procs.txt` into the `meta` block and one trimmed row per process,
keeping the `cmdline` block as it was.
The `arcstats` block of `core.txt`, a ZFS ARC of 2 GiB with a 500 MiB
`c_min`, was added by hand for version 4.
