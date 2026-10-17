Captured on 2026-10-16 by `klabautermann_core/tool/capture_fixtures.dart`
(local mode, `/usr/bin/dash -s`) from
Ubuntu 24.04.5 LTS, Linux 6.17.0-1022-azure x86_64;
collector-set version 7. Goldens come from
`klabautermann_host/tool/regen_goldens.dart`.

Section statuses (each `.txt` file holds the payload only):

| Collector | Status |
|---|---|
| `overview` | ok |
| `core` | ok |
| `fs` | ok |
| `identity` | ok |
| `procs` | ok |
| `units` | ok |
| `timers` | ok |
| `cron` | ok |

Probe areas: kernel ok, distro ok, init ok, virt ok, lxcfs ok, identity ok, elev ok, tools ok, kfeat ok, locale ok, sockets ok, session ok, clock ok, linger ok.

Redaction (03 §6.5): argv 41, cron text 46, device id 45, hex id 10, home directory 2, host name 2, unit description 140, user name 12. Every `procs` argument after argv[0], and
the part of argv[0] after its first space, reads `[redacted]`. Every
`cron` job keeps a schedule that parses, the first word of a command run
as `root` or from a user crontab, and `run-parts`, the
`/etc/cron.<period>` directories and anacron; the rest of the command,
comments, environment values but `CRON_TZ` and lines that are no job
read `[redacted]`, and user fields but `root` read `user`. A unit
description that is a command line keeps its first word; a device
unit's reads `[redacted]`. The review found nothing left, and every file
parses as the capture did.

Runner-VM capture: `klabautermann/test/integration/runner_vm.sh`
ran the tool on the GitHub-hosted runner image `ubuntu24 20261012.334.1`, systemd
255, as an account outside `systemd-journal` and `adm` in an SSH
session to a loopback sshd, under `/bin/sh` (dash).

Committed from the `klabautermann-integration-evidence` artifact of CI
run 38959196456 (job 117198081504), unchanged but for this paragraph. A
second review before the commit searched every file for runner and Azure
host names (`runnervm`, `fv-az`, `cloudapp`, `internal.`),
`/home/runner`, IPv4 and MAC addresses, and hex runs of 8 digits or
more, and read each file through. The host name reads `fixture-host`,
the machine and boot ids are the redactor's placeholders, there is no IP
or MAC address, and the only account names are `root`, the runner
account as `user` (uid 1001) and the throwaway account as `user2` (uid
1002). What remains is shared by every VM of the image or lives for one
job only, and identifies neither host nor person: the image version
above, the kernel flavour `6.17.0-1022-azure`, Hyper-V firmware and
udev's `azure-os` disk links, the image's agent units and paths
(`walinuxagent`, `hosted-compute-agent`, the runner's `2.337.0`
directory), the 12-digit Docker network namespace and bridge ids and
`veth` names, and `mktemp` and provisioning suffixes in `/tmp` paths.
