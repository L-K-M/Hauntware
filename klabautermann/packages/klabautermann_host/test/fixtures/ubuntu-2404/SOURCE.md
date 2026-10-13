Hand-written from documentation (proc_stat(5), procfs(5), os-release(5),
df(1), systemd manual pages), not captured from a real host. The capture
tooling of spike S2 replaces these fixtures later.

`procs.txt`, `units.txt`, `timers.txt` and `cron.txt` are likewise
hand-written from proc_stat(5), procfs(5), crontab(5), cron(8), ps(1),
journalctl(1), systemctl(1) and systemd.time(7) for systemd 255; the
`cmdline` block holds real `\037` separators.
