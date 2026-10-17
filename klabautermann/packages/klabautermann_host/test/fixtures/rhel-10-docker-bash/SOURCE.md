Captured on 2026-10-16 by `klabautermann_core/tool/capture_fixtures.dart`
(local mode, `/usr/bin/bash -s`) from
Red Hat Enterprise Linux 10.2 (Coughlan), Linux 6.18.44-fc-v139 x86_64;
collector-set version 6. Goldens come from
`klabautermann_host/tool/regen_goldens.dart`.

Section statuses (each `.txt` file holds the payload only):

| Collector | Status |
|---|---|
| `overview` | ok |
| `core` | ok |
| `fs` | ok |
| `identity` | ok |
| `procs` | ok |
| `units` | error |
| `timers` | error |
| `cron` | ok |

Probe areas: kernel ok, distro ok, init ok, virt ok, lxcfs ok, identity ok, elev ok, tools ok, kfeat ok, locale ok, sockets ok, session ok, clock ok, linger ok.

Redaction (03 §6.5): argv 3. Every `procs` argument after argv[0], and
the part of argv[0] after its first space, reads `[redacted]`. Every
`cron` job keeps a schedule that parses, the first word of a command run
as `root` or from a user crontab, and `run-parts`, the
`/etc/cron.<period>` directories and anacron; the rest of the command,
comments, environment values but `CRON_TZ` and lines that are no job
read `[redacted]`, and user fields but `root` read `user`. A unit
description that is a command line keeps its first word; a device
unit's reads `[redacted]`. The review found nothing left, and every file
parses as the capture did.

Container capture: `klabautermann/test/integration/capture.sh` ran
the tool as root in a fresh container of
`registry.access.redhat.com/ubi10/ubi:10.2@sha256:a75ad754aa048d808dd3260243452f8c9a665831d0493b4c9d92f0c88fe2f8c3`,
whose PID 1 is `sleep infinity`.
