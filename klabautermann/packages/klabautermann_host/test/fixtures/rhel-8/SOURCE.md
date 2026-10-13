Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), systemd manual pages), not captured from a real host. The capture
tooling of spike S2 replaces these fixtures later.

`procs.txt` holds the `\037`-separated `cmdline` dump. `units.txt` and
`timers.txt` are the `--plain --no-legend` and columnar text fallbacks of
systemd 239 (U). `cron.txt` follows crontab(5) and cron(8).
