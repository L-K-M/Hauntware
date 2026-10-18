# Spike S3: the elevation matrix

The case files here are the output of

```bash
cd klabautermann
test/integration/capture.sh --elevation-only --update
```

run on 2026-10-18 in a Linux x86_64 container with Docker 29.8.2. This was a
local run: capture.sh's default run, which CI makes, leaves the matrix out
(see `test/integration/capture_elevation.sh`). A later run without
`--update` compared its capture with these files and found no difference.

## How each case ran

Each case is a fresh container, with no network and nothing published, of
one of these pinned images:

- capture.sh's `debian-13` or `ubuntu-2604`;
- `capture_elevation.sh`'s Alpine 3.22.

The case's package was unpacked into it:

| Tool | Version | Source |
| --- | --- | --- |
| sudo | 1.9.16p2 | Debian 13, plus `libapparmor1` |
| sudo-rs | 0.2.13 | Ubuntu 26.04, plus `sudo-common`, linked as `/usr/bin/sudo` |
| doas | OpenDoas 6.8.2 | Alpine 3.22's `doas-6.8.2-r8` |

A non-root account `klab` got a password made for the case and one rule:

- sudo: `klab ALL=(ALL) ALL`, with the `Defaults` line the case names;
- doas: `permit klab as root` or `permit nopass klab as root`.

klabautermann_core's `tool/capture_elevation.dart` ran on the host. It
probed the account as the engine's probe does (03 §6.1). It then drove
seance_core's `ElevatedExecutor`: the D24 prelude, the rung-4 retry and
the refusal classifier. Each command ran as `klab` through
`docker exec -i` under `sh -c`, as sshd runs a command, in a new session
with no controlling terminal. Each executor run was one of:

- `id -u` with the right password;
- `id -u` with a wrong password;
- `id -u` with no password;
- `cat` with a line of stdin after the password line.

The tool also recorded raw `sudo -n -l` and, for doas, `doas -n true` and
a password on a pipe. Every command line, its exit status, its stdout and
its full stderr are in the case file. No password is: the tool refuses to
write a file that contains one.

`printf-builtin.txt` is `command -V printf` under each shell in Debian 13,
with BusyBox, mksh and zsh from capture.sh's pinned packages.

## What it shows

| Case | Rule | Right password | Wrong password | Commands | stdin passes |
| --- | --- | --- | --- | --- | --- |
| `debian-13-sudo-tty` | `timestamp_type=tty` | runs as root | `wrongPassword` | 1 | yes |
| `debian-13-sudo-ppid` | `timestamp_type=ppid` | runs as root | `wrongPassword` | 1 | yes |
| `debian-13-sudo-global` | `timestamp_type=global` | runs as root | **runs as root** | 1 | yes |
| `debian-13-sudo-timeout-0` | `timestamp_timeout=0` | runs as root | `wrongPassword` | 2 (rung 4) | yes |
| `debian-13-sudo-requiretty` | `requiretty` | `ttyRequired` | `ttyRequired` | 1 | no |
| `ubuntu-2604-sudo-rs` | default | runs as root | `wrongPassword` | 1 | yes |
| `ubuntu-2604-sudo-rs-timeout-0` | `timestamp_timeout=0` | runs as root | `wrongPassword` | 2 (rung 4) | yes |
| `alpine-322-doas-nopass` | `permit nopass` | runs as root (rung 2) | runs (no password used) | 1 | yes |
| `alpine-322-doas-password` | `permit` | `ttyRequired`, nothing run | `ttyRequired` | 0 | no |

Without a password every sudo case refuses with `passwordRequired` before
any command, as the prelude rung needs one.

- **Rungs 2 to 4 hold as 03 §8.3 states them.**
  - With no tty, sudo keys its record to the parent process under `tty`
    and `ppid`, so the prelude's `sudo -v` and `sudo -n` share it.
  - Under `timestamp_timeout=0` the prelude's `sudo -n` finds no record.
    The executor's single `sudo -S -p ''` retry then runs the command, and
    the stdin after the password line reaches it. This holds for sudo and
    sudo-rs alike.
- **`timestamp_type=global` accepts a wrong password while a record is
  valid.** The right-password run left a record that every session of the
  account shares. The wrong-password run's `sudo -S -v` then succeeded
  without reading its password, and the command ran.
  - This grants nothing the account could not do anyway: `sudo -n` works
    for it while the record lasts.
  - But a validation by `sudo -v` cannot tell a wrong password from a
    right one. The same holds when the user ran sudo in their own terminal
    minutes before.
  - Locally, against the same Debian 13 sudo, `sudo -k -S -p '' -v`
    ignored the cached record: it refused the wrong password and recorded
    the right one, so a following `sudo -n` ran.
  - sudo-rs 0.2.13 also checks the password under `-k`, but records
    nothing, so its next `sudo -n` asks again (rung 4).
  - 03 D65 takes this into admin mode's validation (E11).
- **Rung 5 is needed for two setups.**
  - `requiretty` refuses before reading a password: "sudo: sorry, you must
    have a tty to run sudo". It is classified `ttyRequired`.
  - doas with a password refuses `-n` with "doas: Authentication required"
    and a password on a pipe with "doas: a tty is required". The executor
    reports `ttyRequired` without running anything, which matches.
- **sudo-rs 0.2.13's texts.**
  - A wrong password prints "sudo: Authentication failed, try again." and
    "sudo: Authentication required but not attempted".
  - `sudo -n` without a record prints "sudo: interactive authentication is
    required".
  - The classifier's sudo-rs table maps both. sudo-rs also writes one empty
    stderr line after reading a password, which the classifier skips.
- **sudo 1.9.16p2's texts** match 04 Appendix A E8's 1.9.15p5 lines: "Sorry,
  try again.", "sudo: no password was provided", "sudo: 1 incorrect
  password attempt" and "sudo: a password is required".
- **printf.** dash, bash, BusyBox ash and zsh report a builtin. mksh
  reports "printf is a tracked alias for /usr/bin/printf". Under mksh as
  `sh`, the probe therefore withholds the prelude rung, as 8.3 requires.
- **Fixture texts for E04.** sudo 1.9's rejection texts are in
  `debian-13-sudo-ppid.json`, and `requiretty`'s in
  `debian-13-sudo-requiretty.json`. sudo-rs 0.2's are in
  `ubuntu-2604-sudo-rs.json`, and doas's in `alpine-322-doas-password.json`
  (`rawCalls`).

Rung 6 (run0) is not covered: run0 needs systemd 256 or later, and the
runner VM has 255, so it stays on the manual checklist (06).
