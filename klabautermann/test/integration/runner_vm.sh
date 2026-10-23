#!/usr/bin/env bash
# The runner-VM leg of Klabautermann's integration run (03 §11.3, K28a).
# The GitHub-hosted Ubuntu runner is itself a systemd host, so this
# starts a second sshd on its loopback with its own config and host key,
# creates throwaway accounts whose login shell is /bin/sh (dash on
# Ubuntu), captures the host's collector fixtures as the unprivileged
# one, and runs the engine's runner-VM suites against it
# (klabautermann_core/test/integration/runner_vm_test.dart): units,
# timers and OnCalendar next runs, a journal follow resumed across a
# forced reconnect, unit logs, the kernel log, LOG-04 and journal paging;
# and spike S4's detached runners (runner_vm_s4_test.dart, tag
# runner-vm-s4): systemd-run system, --user and --uid, linger, logout,
# --collect, root-run files, --host and sudo -n -l (03 §7.17, M4 E02);
# and spike S6's privileged-file recipes on ext4 with ACLs and an
# elevated sftp-server (runner_vm_s6_test.dart, tag runner-vm-s6, M5
# M01), in a root-owned directory under /var/tmp each case removes;
# and the engine's admin mode and host actions
# (runner_vm_actions_test.dart, M4 E29): a wrong password and its retry,
# rung 4 under timestamp_timeout=0, admin mode ending with the link, unit
# start, stop, restart and reload, the protected ssh.service, run timer
# now with its journal, other users' crontabs and a kill through
# elevation; and the engine's Docker routes and detached redeploys on
# the runner's own engine (runner_vm_docker_test.dart, M4 E30): rank 3
# through the password prelude, a root redeploy under systemd-run that
# outlives a forced reconnect and whose root files go once admin mode is
# back, and the login user's under systemd-run --uid and --user; and the
# privileged edits (runner_vm_edit_test.dart, M5 M20b): a root file's
# owner, mode, ACL and xattr kept through the prelude with root's backup
# and manifest, a unit file systemd-analyze verify refuses, a conflict,
# and another account's crontab; and the v1 host rows
# (runner_vm_v1_test.dart, M5 M28): unit enable, disable, mask, unmask
# and reset-failed, the linger account's own units, unit files and
# resources, the journal's boots and -g, a rotated .gz, anacron and a
# cron line run now.
#
# run.sh calls it after the fixture suites. It creates accounts and runs
# a root sshd, so it runs only on a GitHub-hosted runner, the ephemeral
# VM the job gets (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted);
# anywhere else it changes nothing and skips with a notice.
#
# What it changes on the runner, all undone on every exit: the accounts
# klab-vm (outside systemd-journal and adm, for LOG-04), klab-vm-journal
# (in systemd-journal), klab-vm-sudo (password sudo), klab-vm-linger
# (linger on, in the docker group, password sudo), klab-vm-docker (a
# NOPASSWD rule scoped to the docker CLI)
# and klab-vm-nocache (password sudo with timestamp_timeout=0, 8.3's
# rung 4) with their homes, sessions, linger and crontabs (one each); the
# sudoers drop-in with those rules; the test units in /etc/systemd/system
# (a service that reloads, and a timer with its oneshot service, which
# never fires on its own); root's Docker CLI directory, whose default context it
# points at a socket nothing listens on, so only a step's own --host
# reaches the engine (M4 plan M17); on the runner's engine, a registry
# container on 127.0.0.1:5243, the images pushed there under
# 127.0.0.1:5243/klabautermann-runner-vm/ and a compose project in the
# homes of klab-vm-sudo and klab-vm-linger; the sshd on 127.0.0.1:2243 with its
# root-owned directory under /tmp; a transient system timer; the
# operation units and the root operation directory the S4 suite leaves;
# the root backups and manifest the edit suite's edits leave, and the
# root file and unit file it seeds; the system unit and rotated log the
# v1 host suite seeds;
# and its key and capture directories. klab-vm-sudo's password is made
# at job start, as are klab-vm-linger's and klab-vm-nocache's, each kept
# in a 0600 file in the
# runner's own key directory and handed to chpasswd on stdin by a builtin
# printf: never in argv, the environment, a log or the repository. Later
# legs reuse the accounts. The system sshd, its config and port 22 stay
# as they are. Should /usr/sbin/sshd or crontab be missing, it installs
# openssh-server or cron with apt first, with a policy-rc.d that refuses
# the package's start of the system sshd or cron daemon; the package
# stays installed, enabled for a boot that never comes, as the runner is
# discarded with the job, as do the registry and busybox images the
# Docker suite pulls. Signing in
# leaves what any SSH login leaves: journal entries and logind sessions.
# Without setfacl or setfattr, it installs acl or attr the same way.
#
# With KLABAUTERMANN_EVIDENCE_DIR set, its logs, test results and the
# capture go to $KLABAUTERMANN_EVIDENCE_DIR/runner-vm/:
#
#   fixtures/<platform>/  the capture tool's redacted, reviewed fixture
#                         directory (ubuntu-2404-runner-dash), in the
#                         layout of klabautermann_host/test/fixtures/,
#                         plus a provenance paragraph in SOURCE.md
#   capture.log           the tool's output
#   host.txt              the image, systemd, sh and journal facts
#   sshd.log              the leg's sshd log
#   engine-tests.json     the suites' results, and an .events log per test
#   s4/                   spike S4's evidence, one JSON file per case
#                         (klabautermann/docs/evidence/s4/README.md)
#   s6/                   spike S6's evidence, one JSON file per case
#                         (klabautermann/docs/evidence/s6/README.md)
set -euo pipefail

integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly integration_dir
klabautermann_dir="$(cd "$integration_dir/../.." && pwd)"
readonly klabautermann_dir
readonly dart_binary="${DART_BIN:-dart}"
readonly evidence_dir="${KLABAUTERMANN_EVIDENCE_DIR:+$KLABAUTERMANN_EVIDENCE_DIR/runner-vm}"
readonly limited_user='klab-vm'
readonly journal_user='klab-vm-journal'
readonly sudo_user='klab-vm-sudo'
readonly linger_user='klab-vm-linger'
readonly docker_user='klab-vm-docker'
readonly nocache_user='klab-vm-nocache'
readonly sshd_host='127.0.0.1'
# Beside the fixture's 2241 and 2242; never the system sshd's 22.
readonly sshd_port=2243
readonly sshd_binary='/usr/sbin/sshd'
# The privilege separation directory Ubuntu's sshd is built with, which
# systemd creates only while the system ssh.service runs
# (RuntimeDirectory=sshd).
readonly privsep_dir='/run/sshd'
readonly timer_unit='klabautermann-runner-vm'
# In systemd's normalized form, which systemctl show and systemd-analyze
# print back.
readonly calendar='Mon..Fri *-*-* 04:05:06'
readonly ready_attempts=30
readonly systemd_marker='/run/systemd/system'
readonly system_sh='/bin/sh'
readonly os_release_file='/etc/os-release'
# Where the accounts and root reach: not $TMPDIR, which may lie under
# the runner's home.
readonly shared_tmp='/tmp'
# The account names, the port and the timer are fixed, so one leg runs
# at a time.
readonly lock_file='/tmp/klabautermann-runner-vm.lock'
# The sudo rules of klab-vm-sudo and klab-vm-docker.
readonly sudoers_file='/etc/sudoers.d/klabautermann-runner-vm'
# What root-run operations create: the wrapper makes
# /var/lib/klabautermann/ops (03 §7.17), and teardown removes it all.
readonly root_ops_parent='/var/lib/klabautermann'
# What the edit suite's root edits leave (M5 M20b): the root footprint
# manifest's directory beside the backups under root_ops_parent, and the
# root file and unit file the suite seeds and removes itself; teardown
# removes all three should a run end part-way.
readonly root_manifest_dir='/etc/klabautermann'
readonly edit_dir='/etc/klabautermann-vm-edit'
readonly edit_unit='klabautermann-vm-edit.service'
# What the v1 host suite seeds and removes itself (M5 M28): a system unit
# and a rotated log under /var/log; teardown removes both should a run
# end part-way.
readonly v1_unit='klabautermann-vm-v1.service'
readonly rotated_log='/var/log/klabautermann-vm.log.1.gz'
# Root's Docker CLI directory, which the leg creates for the dead
# default context and removes; one the image has is moved aside into the
# sshd's root-owned directory meanwhile and put back.
readonly root_docker_dir='/root/.docker'
readonly dead_context='klabautermann-dead'
readonly dead_socket='/run/klabautermann-runner-vm-dead.sock'
# The runner's own engine, which a step reaches with --host.
readonly docker_socket='/var/run/docker.sock'
# The S4 suite's transient units (klabautermann_host's kOpUnitPrefix).
readonly op_units='klabautermann-op-*.service'
# The actions suite's units (M4 E29), files of their own so that a stop
# leaves them loaded, as a transient unit would not be. They run as
# nobody and print what the suite looks for in the journal.
readonly unit_dir='/etc/systemd/system'
readonly test_service='klabautermann-vm-test.service'
readonly job_service='klabautermann-vm-job.service'
readonly job_timer='klabautermann-vm-job.timer'
readonly reload_message='klabautermann-vm-test reloaded'
readonly job_message='klabautermann-vm-job ran'
readonly test_units=("$test_service" "$job_service" "$job_timer")
# The Docker suite's registry on the runner's engine, published on
# loopback only, which the engine treats as insecure without a setting;
# the image its stacks run, pulled once and pushed there for each stack;
# and the accounts with a compose project of their own, named after
# them.
readonly registry_image='mirror.gcr.io/library/registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e'
readonly stack_base_image='mirror.gcr.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'
readonly registry_container='klabautermann-runner-vm-registry'
readonly registry_port=5243
readonly registry="127.0.0.1:$registry_port/klabautermann-runner-vm"
readonly stack_users=("$sudo_user" "$linger_user")

skip() {
  echo "::notice::Runner-VM leg skipped: $*"
  exit 0
}

die() {
  echo "runner_vm.sh: $*" >&2
  exit 1
}

if [[ "$#" -ne 0 ]]; then
  echo 'usage: test/integration/runner_vm.sh' >&2
  exit 2
fi

if [[ "${GITHUB_ACTIONS:-}" != true ||
  "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  skip 'it creates accounts and runs sshd as root, so it runs only on a GitHub-hosted runner'
fi

# A GitHub-hosted runner that lacks any of these fails the leg rather
# than skipping it, so a changed image cannot pass unnoticed.
[[ "$(uname -s)" == Linux ]] || die 'needs Linux'
[[ -d "$systemd_marker" ]] || die 'PID 1 is not systemd'
sudo -n true 2>/dev/null || die 'needs passwordless sudo'
for tool in flock ssh ssh-keygen ssh-keyscan systemctl od docker "$dart_binary"; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
# The docker rule names the CLI by the path sudo will find.
docker_cli="$(command -v docker)"
[[ "$docker_cli" == /* ]] || die "docker is $docker_cli, not a path"
readonly docker_cli

exec 8>"$lock_file"
flock --nonblock 8 || die "another runner-VM leg holds $lock_file"

readonly users=("$limited_user" "$journal_user" "$sudo_user" "$linger_user"
  "$docker_user" "$nocache_user")
for user in "${users[@]}"; do
  if id "$user" >/dev/null 2>&1; then
    die "$user exists; this leg removes only accounts it created"
  fi
done
for path in "$sudoers_file" "$root_ops_parent" "$root_manifest_dir" \
  "$edit_dir" "$unit_dir/$edit_unit" "$unit_dir/$v1_unit" \
  "$rotated_log" "${test_units[@]/#/$unit_dir/}"; do
  if sudo -n test -e "$path"; then
    die "$path exists; this leg removes only what it created"
  fi
done

runtime_dir=''
sshd_dir=''
capture_dir=''
sshd_started=0
sshd_pid=''
child_pid=''
timer_started=0
policy_installed=0
privsep_created=0
sudoers_installed=0
root_docker_created=0
root_docker_saved=''
suite_started=0
units_installed=0
registry_started=0
stacks_started=0
created_users=()
crontab_users=()

# Runs "$@" in the background and waits for it: on a signal bash runs the
# EXIT trap without waiting for a foreground child, and on_exit stops a
# background one before tearing down what it uses.
run_child() {
  local status=0
  "$@" &
  child_pid="$!"
  wait "$child_pid" || status="$?"
  child_pid=''
  return "$status"
}

# Ends every process of a throwaway account, then removes it, its home
# and its group. Only accounts this run created get here.
remove_user() {
  local user="$1" uid attempt pids
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  # With linger on, logind would start the user manager again.
  sudo -n loginctl disable-linger "$user" 2>/dev/null || true
  sudo -n loginctl terminate-user "$user" 2>/dev/null || true
  sudo -n systemctl stop "user@$uid.service" "user-runtime-dir@$uid.service" \
    2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    pids="$(pgrep -u "$uid" || true)"
    [[ -n "$pids" ]] || break
    # shellcheck disable=SC2086 # one PID per word
    sudo -n kill -KILL $pids 2>/dev/null || true
    sleep 0.5
  done
  sudo -n userdel --remove "$user"
}

# Whether process $1 runs: a zombie has ended.
running() {
  ps -o stat= -p "$1" 2>/dev/null | grep -qv Z
}

# The daemon's PID from its PID file, once it has written it.
read_sshd_pid() {
  if [[ -z "$sshd_pid" ]]; then
    sshd_pid="$(sudo -n cat -- "$sshd_dir/sshd.pid" 2>/dev/null)" || sshd_pid=''
  fi
  [[ "$sshd_pid" =~ ^[0-9]+$ ]]
}

# Stops the sshd: each connection's monitor first, as the listener
# leaves them running, then the listener, which a test may have left
# stopped (a stopped process holds TERM until it continues).
stop_sshd() {
  local pids attempt
  read_sshd_pid || return 0
  pids="$(pgrep -P "$sshd_pid" || true)"
  # shellcheck disable=SC2086 # one PID per word
  [[ -z "$pids" ]] || sudo -n kill -TERM $pids 2>/dev/null || true
  sudo -n kill -CONT "$sshd_pid" 2>/dev/null || true
  sudo -n kill -TERM "$sshd_pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    running "$sshd_pid" || return 0
    sleep 0.5
  done
  sudo -n kill -KILL "$sshd_pid" 2>/dev/null || true
  return 1
}

on_exit() {
  local status="$?" cleanup=0 user dir tags
  trap - EXIT
  # A further signal would otherwise end this shell part-way through
  # teardown and leave an account or the sshd behind.
  trap '' INT TERM HUP

  # Before what it uses goes. package:test lets the running test finish
  # after a first signal and exits at once on a second; the pause keeps
  # the two from merging into one.
  if [[ -n "$child_pid" ]]; then
    kill "$child_pid" 2>/dev/null || true
    sleep 0.5
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" || true
  fi
  if ((timer_started)); then
    sudo -n systemctl stop "$timer_unit.timer" || cleanup=1
    sudo -n systemctl reset-failed "$timer_unit.timer" "$timer_unit.service" \
      2>/dev/null || true
  fi
  # Before the accounts: an operation unit may run as one of them.
  if ((suite_started)); then
    sudo -n systemctl stop "$op_units" 2>/dev/null || true
    sudo -n systemctl reset-failed "$op_units" 2>/dev/null || true
    sudo -n rm -rf -- "$root_ops_parent" "$root_manifest_dir" "$edit_dir" \
      "$unit_dir/$edit_unit" || cleanup=1
    sudo -n systemctl unmask -- "$v1_unit" 2>/dev/null || true
    sudo -n systemctl disable -- "$v1_unit" 2>/dev/null || true
    sudo -n rm -f -- "$unit_dir/$v1_unit" "$rotated_log" || cleanup=1
  fi
  if ((units_installed)); then
    sudo -n systemctl stop "${test_units[@]}" 2>/dev/null || true
    sudo -n rm -f -- "${test_units[@]/#/$unit_dir/}" || cleanup=1
    sudo -n systemctl daemon-reload || cleanup=1
    sudo -n systemctl reset-failed "${test_units[@]}" 2>/dev/null || true
  fi
  # Before the accounts, whose homes hold the compose files.
  if ((stacks_started)); then
    for user in "${stack_users[@]}"; do
      runner_docker compose --project-name "$user" down --remove-orphans \
        --volumes --timeout 1 || cleanup=1
    done
  fi
  if ((registry_started)); then
    runner_docker rm --force --volumes "$registry_container" >/dev/null ||
      cleanup=1
    # The tags the leg and the suite made. The pulled images stay, as do
    # the digests a redeploy left untagged, which list as <none>.
    tags="$(runner_docker image ls --format '{{.Repository}}:{{.Tag}}' \
      --filter "reference=$registry/*")" || cleanup=1
    tags="$(grep -v ':<none>$' <<<"$tags" || true)"
    # shellcheck disable=SC2086 # one tag per word
    [[ -z "$tags" ]] || runner_docker image rm $tags >/dev/null || cleanup=1
  fi
  if ((root_docker_created)); then
    sudo -n rm -rf -- "$root_docker_dir" || cleanup=1
    if [[ -n "$root_docker_saved" ]]; then
      sudo -n mv -- "$root_docker_saved" "$root_docker_dir" || cleanup=1
    fi
  fi
  if ((sshd_started)); then
    stop_sshd || cleanup=1
  fi
  if [[ -n "$evidence_dir" && -n "$sshd_dir" ]]; then
    # Root reads the log; the copy is the runner's, as the artifact is.
    # shellcheck disable=SC2024
    sudo -n cat -- "$sshd_dir/sshd.log" >"$evidence_dir/sshd.log" 2>/dev/null || true
  fi
  if ((sudoers_installed)); then
    sudo -n rm -f -- "$sudoers_file" || cleanup=1
  fi
  # userdel leaves the spool's crontab behind.
  for user in "${crontab_users[@]}"; do
    sudo -n crontab -u "$user" -r || cleanup=1
  done
  for user in "${created_users[@]}"; do
    remove_user "$user" || cleanup=1
  done
  if ((policy_installed)); then
    sudo -n rm -f -- /usr/sbin/policy-rc.d || cleanup=1
  fi
  # Empty once the sshd is gone, unless the system ssh.service took it
  # over meanwhile.
  if ((privsep_created)); then
    sudo -n rmdir -- "$privsep_dir" 2>/dev/null || true
  fi
  for dir in "$sshd_dir" "$capture_dir"; do
    if [[ -n "$dir" ]]; then
      sudo -n rm -rf -- "$dir" || cleanup=1
    fi
  done
  if [[ -n "$runtime_dir" ]]; then
    rm -rf -- "$runtime_dir"
  fi

  if ((status == 0)); then
    status="$cleanup"
  fi
  exit "$status"
}

# Ready once the daemon has written its PID, after it bound its port,
# and completes a key exchange; fails at once if it exited.
wait_for_sshd() {
  local attempt
  for ((attempt = 0; attempt < ready_attempts; attempt++)); do
    if read_sshd_pid; then
      if ! running "$sshd_pid"; then
        sudo -n cat -- "$sshd_dir/sshd.log" >&2 || true
        die 'sshd exited'
      fi
      if [[ -n "$(ssh-keyscan -T 2 -t ed25519 -p "$sshd_port" "$sshd_host" 2>/dev/null)" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  sudo -n cat -- "$sshd_dir/sshd.log" >&2 || true
  die "sshd on $sshd_host:$sshd_port did not become ready"
}

# Installs package $1. Its maintainer scripts would start its daemon,
# the system sshd or cron; a policy-rc.d that refuses every start, which
# invoke-rc.d(8) and deb-systemd-invoke honour, holds it back for the
# install. They still enable it (systemctl preset), which takes effect
# at a boot.
install_package() {
  local policy=/usr/sbin/policy-rc.d
  if sudo -n test -e "$policy"; then
    die "$policy exists; not replacing it to install $1"
  fi
  policy_installed=1
  printf '#!/bin/sh\nexit 101\n' | sudo -n tee "$policy" >/dev/null
  sudo -n chmod 0755 "$policy"
  sudo -n apt-get update -qq
  sudo -n env DEBIAN_FRONTEND=noninteractive \
    apt-get install -qq -y --no-install-recommends "$1"
  sudo -n rm -f -- "$policy"
  policy_installed=0
}

# Creates throwaway account $1, with any further useradd options, that
# signs in with the run's key only: its password field is `*`, no
# password, not a locked account.
create_user() {
  local user="$1" home
  shift
  created_users+=("$user")
  sudo -n useradd --create-home --shell /bin/sh --user-group --password '*' \
    --comment 'Klabautermann runner-VM leg' "$@" "$user"
  home="$(getent passwd "$user" | cut -d : -f 6)"
  sudo -n install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
  sudo -n install -m 0600 -o "$user" -g "$user" "$runtime_dir/identity.pub" \
    "$home/.ssh/authorized_keys"
}

# A password made now, in $password.
new_password() {
  password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$password" =~ ^[0-9a-f]{48}$ ]] || die 'no password from /dev/urandom'
}

# Gives klab-vm-sudo, klab-vm-linger and klab-vm-nocache a password
# each, made now. They
# stay in this shell and in 0600 files under the runner's own key
# directory, which the suites read; printf is a bash builtin, so the lines
# chpasswd reads are in no process's argv. Nothing prints them.
set_passwords() {
  local password sudo_password linger_password
  new_password
  sudo_password="$password"
  new_password
  linger_password="$password"
  new_password
  (umask 077 &&
    printf '%s\n' "$sudo_password" >"$runtime_dir/sudo-password" &&
    printf '%s\n' "$linger_password" >"$runtime_dir/linger-password" &&
    printf '%s\n' "$password" >"$runtime_dir/nocache-password")
  printf '%s:%s\n%s:%s\n%s:%s\n' "$sudo_user" "$sudo_password" \
    "$linger_user" "$linger_password" "$nocache_user" "$password" |
    sudo -n chpasswd
}

# Password sudo for klab-vm-sudo and klab-vm-linger, the same for
# klab-vm-nocache without a
# cached credential (rung 4 of 03 §8.3), and for klab-vm-docker a NOPASSWD
# rule scoped to the docker CLI, which the S4 suite reads with sudo -n -l
# and which cannot start systemd-run (03 §7.17, Docker-scoped sudo rules).
# Checked before it is installed: a broken drop-in disables sudo for the
# rest of the job.
install_sudoers() {
  printf '%s\n' \
    "$sudo_user ALL=(ALL) ALL" \
    "$linger_user ALL=(ALL) ALL" \
    "$nocache_user ALL=(ALL) ALL" \
    "Defaults:$nocache_user timestamp_timeout=0" \
    "$docker_user ALL=(root) NOPASSWD: $docker_cli" >"$runtime_dir/sudoers"
  sudo -n visudo -cf "$runtime_dir/sudoers" >/dev/null
  sudoers_installed=1
  sudo -n install -m 0440 -o root -g root "$runtime_dir/sudoers" \
    "$sudoers_file"
  sudo -n visudo -cf "$sudoers_file" >/dev/null
  sudo -n true
}

# Root's default Docker context on a socket nothing listens on, so a
# docker step that runs as root reaches the runner's engine only through
# the --host in its own argv (03 §7.17, M4 plan M17).
use_dead_docker_context() {
  # Only once it has moved does teardown remove the path.
  if sudo -n test -e "$root_docker_dir"; then
    sudo -n mv -- "$root_docker_dir" "$sshd_dir/root-docker"
    root_docker_saved="$sshd_dir/root-docker"
  fi
  root_docker_created=1
  sudo -n docker --config "$root_docker_dir" context create "$dead_context" \
    --docker "host=unix://$dead_socket" >/dev/null
  sudo -n docker --config "$root_docker_dir" context use "$dead_context" \
    >/dev/null
}

# The actions suite's units: the service it starts, stops, restarts and
# reloads, which runs until stopped, and the timer whose service it runs
# now, which fires on its own only on 1 January. The service starts here
# and the timer waits.
install_test_units() {
  printf '%s\n' '[Unit]' 'Description=Klabautermann runner-VM leg test service' \
    '[Service]' 'User=nobody' 'ExecStart=/bin/sleep infinity' \
    "ExecReload=/bin/echo $reload_message" >"$runtime_dir/$test_service"
  printf '%s\n' '[Unit]' 'Description=Klabautermann runner-VM leg test job' \
    '[Service]' 'Type=oneshot' 'User=nobody' \
    "ExecStart=/bin/echo $job_message" >"$runtime_dir/$job_service"
  printf '%s\n' '[Unit]' 'Description=Klabautermann runner-VM leg test timer' \
    '[Timer]' 'OnCalendar=*-01-01 04:05:06' "Unit=$job_service" \
    >"$runtime_dir/$job_timer"
  units_installed=1
  local unit
  for unit in "${test_units[@]}"; do
    sudo -n install -m 0644 -o root -g root "$runtime_dir/$unit" \
      "$unit_dir/$unit"
  done
  sudo -n systemctl daemon-reload
  sudo -n systemctl start "$test_service" "$job_timer"
}

# docker as root on the runner's own engine: root's default context is
# the dead one.
runner_docker() {
  sudo -n docker --host "unix://$docker_socket" "$@"
}

# The Docker suite's registry, and each stack's image pushed to it: the
# suite pushes a new digest of a stack's image to have its redeploy pull
# it, as the fixture's registry serves the Docker host's (E28).
start_registry() {
  local user attempt
  registry_started=1
  runner_docker run --detach --quiet --name "$registry_container" \
    --publish "127.0.0.1:$registry_port:5000" "$registry_image" >/dev/null
  runner_docker pull --quiet "$stack_base_image" >/dev/null
  for user in "${stack_users[@]}"; do
    runner_docker image tag "$stack_base_image" "$registry/$user:1"
    # The registry listens a moment after its container starts.
    for ((attempt = 1; ; attempt++)); do
      runner_docker push --quiet "$registry/$user:1" >/dev/null && break
      ((attempt < ready_attempts)) || die "the registry took no push of $user's image"
      sleep 1
    done
  done
}

# A compose project in each stack account's home, named after it, whose
# files the account owns, as a stack the account deployed itself would
# be; root starts it, so the account needs no Docker access of its own.
# Its one container sleeps under an init, so a stop takes no grace
# period.
start_stacks() {
  local user home dir
  stacks_started=1
  for user in "${stack_users[@]}"; do
    home="$(getent passwd "$user" | cut -d : -f 6)"
    dir="$home/stack"
    printf '%s\n' 'services:' '  app:' "    image: $registry/$user:1" \
      '    command: [sleep, "86400"]' '    init: true' \
      >"$runtime_dir/compose-$user.yaml"
    sudo -n install -d -m 0755 -o "$user" -g "$user" "$dir"
    sudo -n install -m 0644 -o "$user" -g "$user" \
      "$runtime_dir/compose-$user.yaml" "$dir/compose.yaml"
    runner_docker compose --project-name "$user" --project-directory "$dir" \
      --file "$dir/compose.yaml" up --detach --quiet-pull
  done
}

# One crontab for each account, which the actions suite reads through
# elevation, masked. The lines name a credential the reading must not
# show, and run only on 1 January, which cron (held back from starting
# when installed here) would never reach meanwhile.
install_crontabs() {
  local user
  for user in "${users[@]}"; do
    crontab_users+=("$user")
    printf '5 4 1 1 * curl -s https://ops:secret-%s@example.invalid/ping\n' \
      "$user" | sudo -n crontab -u "$user" -
  done
}

os_release() {
  sed -n "s/^$1=//p" "$os_release_file" | tr -d '"'
}

# Compiles the capture tool to $1. run_child runs it in a subshell of its
# own, which becomes the compiler.
compile_capture_tool() {
  cd "$klabautermann_dir/packages/klabautermann_core"
  exec "$dart_binary" compile exe --verbosity=warning \
    tool/capture_fixtures.dart -o "$1"
}

# Captures the host as the unprivileged account, in an SSH session, under
# dash as `sh -s`, into $evidence_dir/fixtures/$platform/. Called in a
# condition, where errexit is off, so every step checks its own status.
capture() {
  local out
  capture_dir="$(mktemp -d "$shared_tmp/klabautermann-runner-vm-capture.XXXXXX")" ||
    return 1
  chmod 0755 "$capture_dir" || return 1
  out="$capture_dir/out"
  run_child compile_capture_tool "$capture_dir/capture_fixtures" || return 1
  sudo -n install -d -m 0755 -o "$limited_user" -g "$limited_user" "$out" ||
    return 1
  if ! run_child ssh "${ssh_args[@]}" -l "$limited_user" "$sshd_host" -- \
    "$capture_dir/capture_fixtures" capture --sh dash \
    --platform "$platform" --out "$out" >"$evidence_dir/capture.log" 2>&1; then
    sed 's/^/    /' "$evidence_dir/capture.log" >&2
    return 1
  fi
  mkdir -p "$evidence_dir/fixtures" || return 1
  cp -R -- "$out/$platform" "$evidence_dir/fixtures/$platform" || return 1
  provenance >>"$evidence_dir/fixtures/$platform/SOURCE.md"
}

# shellcheck disable=SC2016 # Markdown code spans, not expansions
provenance() {
  printf '\nRunner-VM capture: `klabautermann/test/integration/runner_vm.sh`\n'
  printf 'ran the tool on the GitHub-hosted runner image `%s %s`, systemd\n' \
    "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
  printf '%s, as an account outside `systemd-journal` and `adm` in an SSH\n' \
    "$systemd_version"
  printf 'session to a loopback sshd, under `/bin/sh` (dash).\n'
}

trap on_exit EXIT
# Keys and the client config live outside the repository, so none can be
# committed.
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/klabautermann-runner-vm.XXXXXX")"
if [[ -n "$evidence_dir" ]]; then
  mkdir -p "$evidence_dir"
fi

sshd_preinstalled=yes
if [[ ! -x "$sshd_binary" ]]; then
  sshd_preinstalled=no
  install_package openssh-server
fi
cron_preinstalled=yes
if ! command -v crontab >/dev/null; then
  cron_preinstalled=no
  install_package cron
fi
# The edit suite's root file carries an ACL entry and an extended
# attribute (D67).
if ! command -v setfacl >/dev/null; then
  install_package acl
fi
if ! command -v setfattr >/dev/null; then
  install_package attr
fi
systemd_version="$(systemctl --version | sed -n '1s/^systemd \([0-9]*\).*/\1/p')"
[[ -n "$systemd_version" ]] || die 'no systemd version from systemctl --version'
readonly systemd_version
sh_target="$(readlink -f "$system_sh")"
[[ "$sh_target" == */dash ]] || die "$system_sh is $sh_target, not dash"
platform="$(os_release ID)-$(os_release VERSION_ID | cut -d . -f 1,2 | tr -d .)-runner-dash"
[[ "$platform" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "no platform id from /etc/os-release: $platform"
readonly platform

ssh-keygen -q -t ed25519 -N '' -C 'klabautermann runner-VM identity' \
  -f "$runtime_dir/identity"
ssh-keygen -q -t ed25519 -N '' -C 'klabautermann runner-VM host' \
  -f "$runtime_dir/host_key"
printf '[%s]:%s %s\n' "$sshd_host" "$sshd_port" \
  "$(cut -d ' ' -f 1,2 "$runtime_dir/host_key.pub")" >"$runtime_dir/known_hosts"
host_key_fingerprint="$(ssh-keygen -lf "$runtime_dir/host_key.pub" | cut -d ' ' -f 2)"
# The leg's own client: the run's key and the sshd's host key only, and
# no agent.
ssh_args=(-F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes
  -o IdentityAgent=none -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$runtime_dir/known_hosts"
  -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10
  -i "$runtime_dir/identity" -p "$sshd_port")

create_user "$limited_user"
create_user "$journal_user" --groups systemd-journal
create_user "$sudo_user"
# In the docker group, so the engine reaches Docker as this account
# itself, over the CLI relay (the Docker suite's login-user redeploys).
create_user "$linger_user" --groups docker
create_user "$docker_user"
create_user "$nocache_user"
set_passwords
install_sudoers

# Root's own directory: sshd refuses a host key or config that others
# could change.
sshd_dir="$(sudo -n mktemp -d "$shared_tmp/klabautermann-runner-vm-sshd.XXXXXX")"
sudo -n install -m 0600 -o root -g root "$runtime_dir/host_key" \
  "$sshd_dir/ssh_host_ed25519_key"
rm -f -- "$runtime_dir/host_key"
cat >"$runtime_dir/sshd_config" <<EOF
# The runner-VM leg's own sshd (runner_vm.sh): loopback only, keys only,
# its throwaway accounts only, no forwarding and no terminal. PAM as the
# system sshd uses it, so each sign-in opens a logind session.
ListenAddress $sshd_host:$sshd_port
HostKey $sshd_dir/ssh_host_ed25519_key
PidFile $sshd_dir/sshd.pid
AllowUsers ${users[*]}
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitUserEnvironment no
UsePAM yes
StrictModes yes
AuthorizedKeysFile .ssh/authorized_keys
DisableForwarding yes
PermitTTY no
PrintMotd no
PrintLastLog no
UseDNS no
LogLevel VERBOSE
EOF
sudo -n install -m 0600 -o root -g root "$runtime_dir/sshd_config" \
  "$sshd_dir/sshd_config"
if ! sudo -n test -d "$privsep_dir"; then
  privsep_created=1
  sudo -n install -d -m 0755 -o root -g root "$privsep_dir"
fi
sudo -n "$sshd_binary" -t -f "$sshd_dir/sshd_config"
# It detaches, with no sudo left above it: sudo stops itself when its
# command stops, and a test stops the listener. Neither lock goes to the
# daemon: a killed run's sshd must not hold them.
sshd_started=1
sudo -n "$sshd_binary" -E "$sshd_dir/sshd.log" -f "$sshd_dir/sshd_config" \
  8>&- 9>&-
wait_for_sshd

if [[ -n "$evidence_dir" ]]; then
  journal_storage=volatile
  if [[ -d "/var/log/journal/$(cat /etc/machine-id)" ]]; then
    journal_storage=persistent
  fi
  # shellcheck disable=SC2016 # a dpkg-query format, not an expansion
  {
    echo "image ${ImageOS:-unknown} ${ImageVersion:-unknown}"
    grep -E '^(PRETTY_NAME|VERSION_ID)=' "$os_release_file" || true
    systemctl --version | sed -n 1p
    echo "sh $sh_target"
    echo "openssh-server $(dpkg-query -W -f '${Version}' openssh-server 2>/dev/null || echo unknown), preinstalled: $sshd_preinstalled"
    echo "cron $(dpkg-query -W -f '${Version}' cron 2>/dev/null || echo unknown), preinstalled: $cron_preinstalled"
    echo "journal storage $journal_storage"
    echo "kernel.dmesg_restrict $(cat /proc/sys/kernel/dmesg_restrict)"
  } >"$evidence_dir/host.txt"
fi

# Before the timer starts, so the captured timers list is the image's.
capture_status=0
if [[ -n "$evidence_dir" ]]; then
  echo "== Capturing $platform"
  capture || capture_status=1
else
  echo '::notice::No KLABAUTERMANN_EVIDENCE_DIR: the runner-VM capture is skipped'
fi

# After the capture, so the captured units, timers and crontab are the
# image's: linger starts a user manager.
sudo -n loginctl enable-linger "$linger_user"
use_dead_docker_context
install_test_units
install_crontabs
start_registry
start_stacks

timer_started=1
sudo -n systemd-run --quiet --unit="$timer_unit" --on-calendar="$calendar" \
  --timer-property=AccuracySec=1us /bin/true

export KLABAUTERMANN_RUNNER_VM_HOST="$sshd_host"
export KLABAUTERMANN_RUNNER_VM_PORT="$sshd_port"
export KLABAUTERMANN_RUNNER_VM_USER="$limited_user"
export KLABAUTERMANN_RUNNER_VM_JOURNAL_USER="$journal_user"
export KLABAUTERMANN_RUNNER_VM_SUDO_USER="$sudo_user"
export KLABAUTERMANN_RUNNER_VM_SUDO_PASSWORD_FILE="$runtime_dir/sudo-password"
export KLABAUTERMANN_RUNNER_VM_LINGER_USER="$linger_user"
export KLABAUTERMANN_RUNNER_VM_LINGER_PASSWORD_FILE="$runtime_dir/linger-password"
export KLABAUTERMANN_RUNNER_VM_DOCKER_USER="$docker_user"
export KLABAUTERMANN_RUNNER_VM_NOCACHE_USER="$nocache_user"
export KLABAUTERMANN_RUNNER_VM_NOCACHE_PASSWORD_FILE="$runtime_dir/nocache-password"
export KLABAUTERMANN_RUNNER_VM_CRONTAB_USERS="${users[*]}"
export KLABAUTERMANN_RUNNER_VM_TEST_SERVICE="$test_service"
export KLABAUTERMANN_RUNNER_VM_RELOAD_MESSAGE="$reload_message"
export KLABAUTERMANN_RUNNER_VM_JOB_TIMER="$job_timer"
export KLABAUTERMANN_RUNNER_VM_JOB_SERVICE="$job_service"
export KLABAUTERMANN_RUNNER_VM_JOB_MESSAGE="$job_message"
export KLABAUTERMANN_RUNNER_VM_DOCKER_CLI="$docker_cli"
export KLABAUTERMANN_RUNNER_VM_DOCKER_SOCKET="$docker_socket"
export KLABAUTERMANN_RUNNER_VM_DEAD_DOCKER_CONTEXT="$dead_context"
export KLABAUTERMANN_RUNNER_VM_REGISTRY="$registry"
export KLABAUTERMANN_RUNNER_VM_IDENTITY_FILE="$runtime_dir/identity"
export KLABAUTERMANN_RUNNER_VM_KNOWN_HOSTS="$runtime_dir/known_hosts"
export KLABAUTERMANN_RUNNER_VM_HOST_KEY_FINGERPRINT="$host_key_fingerprint"
export KLABAUTERMANN_RUNNER_VM_SSHD_PID="$sshd_pid"
export KLABAUTERMANN_RUNNER_VM_TIMER="$timer_unit.timer"
export KLABAUTERMANN_RUNNER_VM_CALENDAR="$calendar"
export KLABAUTERMANN_RUNNER_VM_RUNTIME="$runtime_dir"

reporter=(--reporter expanded)
if [[ -n "$evidence_dir" ]]; then
  reporter+=(--file-reporter "json:$evidence_dir/engine-tests.json")
fi

# One test at a time: they share the sshd, and one pauses it.
cd "$klabautermann_dir"
suite_status=0
suite_started=1
run_child "$dart_binary" test --concurrency=1 \
  --tags 'runner-vm || runner-vm-s4 || runner-vm-s6' "${reporter[@]}" \
  packages/klabautermann_core/test/integration || suite_status="$?"

if ((suite_status != 0)); then
  exit "$suite_status"
fi
if ((capture_status != 0)); then
  die "the capture failed; see $evidence_dir/capture.log"
fi
