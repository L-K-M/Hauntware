[U] Hand-written, not captured from a real host (and never from a build
container): a Debian 12 container with 2 cores, 2 GiB and a ZFS
subvolume root on a Proxmox VE 8 host (cgroup v2), with lxcfs 5.0
mounted over
`/proc/{cpuinfo,diskstats,loadavg,meminfo,slabinfo,stat,swaps,uptime}`,
following proc_stat(5), procfs(5), os-release(5), df(1),
systemd-detect-virt(1) and systemd 252's manual pages. Replace it with a
capture once one exists.

The probe's `lxcfs` area lists those mounts (D50). `core.txt` and
`overview.txt` carry the container's 2 GiB and uptime as lxcfs would
report them. `/proc/stat` lists the container's two CPUs with the host's
times: on cgroup v2, lxcfs finds no `cpuacct` controller, so it copies
the host's `cpuN` lines for the two CPUs in the container's cpuset and
writes their sum as the `cpu` line. Load and disk counters are the
host's too although lxcfs mounts both files: lxcfs passes
`/proc/loadavg` through unless it runs with `-l`, and on cgroup v2
`/proc/diskstats` too, because it looks up a `blkio` controller that
cgroup v2 calls `io`. The `/proc/pressure` files, which lxcfs 5.0 does
not serve, carry the host's values. `btime` is the host's boot time,
because lxcfs passes the other lines of `/proc/stat` through unchanged.
`/proc/net/dev` and the processes are the container's own. `core.txt`
ends with the host's ZFS ARC, larger than the container's 2 GiB: lxcfs
does not serve `/proc/spl/kstat/zfs/arcstats`, so the container is
assumed to read the host's file [U] (03 D48).

For collector-set version 4 (03 D48) a one-off script rewrote the
`overview` and `core` payloads from their version 3 form into the
filtered shapes, keeping the values: per-core busy and idle sums, the
netdev counters of the interfaces the fragment keeps (lo, docker0 and
unused interfaces go), whole-disk diskstats rows (partitions, dm and
loop devices go), PSI lines without `total`, and `meminfo` lines
without the `kB` unit and padding.

For version 5 the same script turned the `stat` and `status` blocks of
`procs.txt` into the `meta` block and one trimmed row per process,
keeping the `cmdline` block as it was.
