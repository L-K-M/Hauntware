#!/usr/bin/env bash
# The runner-VM leg of Klabautermann's integration run (03 §11.3, K28a).
# The GitHub-hosted Ubuntu runner is itself a systemd host, so this
# starts a second sshd on its loopback with its own config and host key,
# creates two throwaway accounts whose login shell is /bin/sh (dash on
# Ubuntu), captures the host's collector fixtures as the unprivileged
# one, and runs the engine's runner-VM suite against it
# (klabautermann_core/test/integration/runner_vm_test.dart): units,
# timers and OnCalendar next runs, a journal follow resumed across a
# forced reconnect, unit logs, the kernel log, LOG-04 and journal paging.
#
# run.sh calls it after the fixture suites. It creates accounts and runs
# a root sshd, so it runs only on a GitHub-hosted runner, the ephemeral
# VM the job gets (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted);
# anywhere else it changes nothing and skips with a notice.
#
# What it changes on the runner, all undone on every exit: the accounts
# klab-vm (outside systemd-journal and adm, for LOG-04) and
# klab-vm-journal (in systemd-journal) with their homes and sessions;
# the sshd on 127.0.0.1:2243 with its root-owned directory under /tmp; a
# transient system timer; and its key and capture directories. The
# system sshd, its config and port 22 stay as they are. Should
# /usr/sbin/sshd be missing, it installs openssh-server with apt first,
# with a policy-rc.d that refuses the package's start of the system
# sshd; the package stays installed, its socket enabled for a boot that
# never comes, as the runner is discarded with the job. Signing in
# leaves what any SSH login leaves: journal entries and logind sessions.
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
#   engine-tests.json     the suite's results, and an .events log per test
set -euo pipefail

integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly integration_dir
klabautermann_dir="$(cd "$integration_dir/../.." && pwd)"
readonly klabautermann_dir
readonly dart_binary="${DART_BIN:-dart}"
readonly evidence_dir="${KLABAUTERMANN_EVIDENCE_DIR:+$KLABAUTERMANN_EVIDENCE_DIR/runner-vm}"
readonly limited_user='klab-vm'
readonly journal_user='klab-vm-journal'
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
for tool in flock ssh ssh-keygen ssh-keyscan systemctl "$dart_binary"; do
  command -v "$tool" >/dev/null || die "needs $tool"
done

exec 8>"$lock_file"
flock --nonblock 8 || die "another runner-VM leg holds $lock_file"

for user in "$limited_user" "$journal_user"; do
  if id "$user" >/dev/null 2>&1; then
    die "$user exists; this leg removes only accounts it created"
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
created_users=()

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
  local status="$?" cleanup=0 user dir
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
  if ((sshd_started)); then
    stop_sshd || cleanup=1
  fi
  if [[ -n "$evidence_dir" && -n "$sshd_dir" ]]; then
    # Root reads the log; the copy is the runner's, as the artifact is.
    # shellcheck disable=SC2024
    sudo -n cat -- "$sshd_dir/sshd.log" >"$evidence_dir/sshd.log" 2>/dev/null || true
  fi
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

# The package's maintainer scripts would start the system sshd; a
# policy-rc.d that refuses every start, which invoke-rc.d(8) and
# deb-systemd-invoke honour, holds it back for the install. They still
# enable ssh.socket (systemctl preset), which takes effect at a boot.
install_openssh_server() {
  local policy=/usr/sbin/policy-rc.d
  if sudo -n test -e "$policy"; then
    die "$policy exists; not replacing it to install openssh-server"
  fi
  policy_installed=1
  printf '#!/bin/sh\nexit 101\n' | sudo -n tee "$policy" >/dev/null
  sudo -n chmod 0755 "$policy"
  sudo -n apt-get update -qq
  sudo -n env DEBIAN_FRONTEND=noninteractive \
    apt-get install -qq -y --no-install-recommends openssh-server
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
  install_openssh_server
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
AllowUsers $limited_user $journal_user
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

timer_started=1
sudo -n systemd-run --quiet --unit="$timer_unit" --on-calendar="$calendar" \
  --timer-property=AccuracySec=1us /bin/true

export KLABAUTERMANN_RUNNER_VM_HOST="$sshd_host"
export KLABAUTERMANN_RUNNER_VM_PORT="$sshd_port"
export KLABAUTERMANN_RUNNER_VM_USER="$limited_user"
export KLABAUTERMANN_RUNNER_VM_JOURNAL_USER="$journal_user"
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
run_child "$dart_binary" test --concurrency=1 --tags runner-vm \
  "${reporter[@]}" packages/klabautermann_core/test/integration ||
  suite_status="$?"

if ((suite_status != 0)); then
  exit "$suite_status"
fi
if ((capture_status != 0)); then
  die "the capture failed; see $evidence_dir/capture.log"
fi
