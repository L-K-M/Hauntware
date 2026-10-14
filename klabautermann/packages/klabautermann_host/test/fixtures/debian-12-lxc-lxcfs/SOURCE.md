[U] Hand-written, not captured from a real host (and never from a build
container): a Debian 12 container with 2 cores, 2 GiB and a ZFS
subvolume root on a Proxmox VE 8 host (cgroup v2), with lxcfs 5.0
mounted over
`/proc/{cpuinfo,diskstats,loadavg,meminfo,slabinfo,stat,swaps,uptime}`,
following proc_stat(5), procfs(5), os-release(5), df(1),
systemd-detect-virt(1) and systemd 252's manual pages. Replace it with a
capture once one exists.

The probe's `lxcfs` area lists those mounts (D50). `core.txt` and
`overview.txt` carry the container's two CPUs, 2 GiB and uptime as lxcfs
would report them. Load and disk counters are the host's although lxcfs
mounts both files: lxcfs passes `/proc/loadavg` through unless it runs
with `-l`, and on cgroup v2 `/proc/diskstats` too, because it looks up a
`blkio` controller that cgroup v2 calls `io`. The `/proc/pressure` files,
which lxcfs 5.0 does not serve, carry the host's values, and `btime` is
the host's boot time, assuming lxcfs passes the non-CPU lines of
`/proc/stat` through unchanged [U]. `/proc/net/dev` and the processes
are the container's own.
