Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), busybox and OpenRC documentation), not captured from a real host.
The capture tooling of spike S2 replaces these fixtures later.

`procs.txt` holds the BusyBox `\037`-separated `cmdline` dump. Alpine has
no systemd, so `units.txt` and `timers.txt` are the empty payload the
`units`/`timers` collectors emit when `systemctl` is missing. `cron.txt`
follows BusyBox crond and crontab(5).
