# Spike S4: the detached runners

The case files here are the evidence CI's `klabautermann_integration` job
wrote for main at a1350177 on 2026-10-19 (workflow run 39301519267,
artifact `klabautermann-integration-evidence`), copied unchanged:

- `runner-vm/`: `klabautermann_core/test/integration/runner_vm_s4_test.dart`
  (tag `runner-vm-s4`), which `test/integration/runner_vm.sh` runs on the
  GitHub-hosted Ubuntu runner, a systemd 255 host, over real SSH as its
  throwaway accounts;
- `fixture/`: `klabautermann_core/test/integration/s4_setsid_test.dart`,
  which `test/integration/run.sh` runs as the fixture user `klab` on the
  Docker host (Alpine, BusyBox 1.38.0) and in a digest-pinned Debian 13
  container (util-linux 2.41.5) as a non-root account.

Every case runs E08's wrapper and launch argv
(`klabautermann_host/lib/src/commands/operations.dart`) and writes what it
saw before its expectations, so a failing case still leaves its file. No
password is in any file: `klab-vm-sudo`'s is made at job start and goes
to sudo on stdin only.

## What it shows

| Case | Runner | Survived the session's end | Notes |
| --- | --- | --- | --- |
| `vm-systemd-run-system` | `systemd-run` system through the prelude | n/a (ends at once) | records 0600 owned by the login user in root's 0755 `/var/lib/klabautermann/ops`; unit unloaded |
| `vm-collect-failure` | the same, the command exiting 3 | n/a | done record with exit 3; `--collect` unloaded the failed unit too |
| `vm-systemd-run-uid` | `systemd-run --uid` through the prelude, no linger | yes | the user manager is inactive after the logout; the unit runs under the system manager |
| `vm-systemd-run-user-linger` | `systemd-run --user`, linger on | yes | the user manager stays active |
| `vm-systemd-run-user-no-linger` | `systemd-run --user`, linger off | **no** | killed with the user manager; its record stays "running" |
| `fixture-setsid-background` | E08's launcher: backgrounded BusyBox `setsid`, printing `$!` | yes | a new session, led by the printed PID |
| `fixture-nohup-background`, `fixture-plain-background` | `nohup ... &`, plain `&` | yes | no new session; the fixture has no logind |
| `fixture-busybox-setsid-f` | BusyBox `setsid -f` | n/a | refused: "unrecognized option: f" |
| `debian-setsid-fork` | util-linux `setsid -f` | yes | the launcher printed no usable PID (0) |
| `debian-setsid-background` | E08's launcher under util-linux | yes | a new session, led by the printed PID |
| `vm-docker-host` | root-run `docker version`, with and without `--host` | n/a | see below |
| `vm-sudo-docker-scoped` | the listing and probes under a docker-scoped rule | n/a | see below |

- **Cleanup through the prelude.** The login user owns its records in
  the root directory but cannot remove them ("Permission denied"); the
  prelude's `rm` removes them and leaves nothing (`cleanupUnelevated`,
  `cleanupElevated`, `filesLeft` in each root case).
- **`--host` decides the engine.** In `vm-docker-host`, root's default
  context points at a dead socket. A root-run `docker version` with
  `--host` naming the runner's socket reaches its Docker 28.0.4; the same
  step without it fails with "Cannot connect to the Docker daemon
  at unix:///run/klabautermann-runner-vm-dead.sock". The unit's
  environment is systemd's clean one (`USER=root`, no `DOCKER_*`).
- **`KillUserProcesses` is readable unprivileged.** As `klab-vm`,
  `busctl` reads logind's property (`b false`); `/etc/systemd/logind.conf`
  leaves it commented. The runner has it off, so what it does when on is
  not recorded.
- **A sudo rule scoped to the docker CLI** (`vm-sudo-docker-scoped`):
  `sudo -n -l` lists `(root) NOPASSWD: /usr/bin/docker` without asking
  for a password, `sudo -n docker version` runs, and `sudo -n true` and
  `sudo -n systemd-run` both answer "a password is required". The
  engine's probe reads no passwordless sudo there (`sudoNopasswd:
  false`).

03 §2 D66 states what this settles in 7.17.
