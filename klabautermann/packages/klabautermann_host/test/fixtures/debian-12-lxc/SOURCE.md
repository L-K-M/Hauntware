[U] Hand-written, not captured from a real host (and never from a build
container): a Debian 12 container under plain LXC on a Debian 12 host
with 16 cores and 64 GiB that has no lxcfs, following proc_stat(5),
procfs(5), os-release(5), df(1), systemd-detect-virt(1) and
systemd 252's manual pages. Replace it with a capture once one exists.

Without lxcfs the system-wide `/proc` files show the host's figures
(D50): `core.txt` and `overview.txt` carry the host's 16 CPUs, 64 GiB,
load, uptime and disks, while `/proc/net/dev` and the processes are the
container's own. The probe's `lxcfs` area reports no mounts, and
`systemd-detect-virt` answers `lxc` for both questions. `df` shows the
host filesystem that holds the container's root directory.
