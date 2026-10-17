#!/usr/bin/env bash
# Runs Klabautermann's SSH integration fixture and the engine suites
# against it (03 §11.3, D53). The klabautermann_integration CI job runs it
# from klabautermann/; it runs the same way locally, given Docker with the
# Compose plugin, OpenSSH's client tools, util-linux flock and the Dart
# SDK with the workspace resolved.
#
# It owns the whole run: client keys and an agent made for this run only
# (never committed, D53), the safety check of the rendered Compose config,
# readiness, the tests one at a time, and teardown on every exit. With
# KLABAUTERMANN_EVIDENCE_DIR set, logs and test results go there. After
# the fixture suites it runs the runner-VM leg (runner_vm.sh), which
# skips itself anywhere but a GitHub-hosted runner.
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly klabautermann_dir="$(cd "$integration_dir/../.." && pwd)"
readonly compose_file="$integration_dir/docker-compose.yml"
readonly compose_project='klabautermann-integration'
# Poltergeist's checker, run by path rather than copied (03 §11.3). It
# reads the rendered Compose JSON on stdin and rejects host networking and
# ports published beyond loopback.
readonly safety_checker="$klabautermann_dir/../poltergeist/test/integration/check_config.dart"
readonly dart_binary="${DART_BIN:-dart}"
readonly evidence_dir="${KLABAUTERMANN_EVIDENCE_DIR:+$KLABAUTERMANN_EVIDENCE_DIR/fixture}"
readonly fixture_user='klab'
readonly services=(sshd jump)
readonly ready_attempts=60
# The project name and loopback ports are fixed, and a run starts by
# removing what a killed run left, so two runs on one Docker host would
# tear down each other's fixture. One runs at a time: the lock is on /tmp,
# machine-wide like the Docker daemon, and ends with this shell.
readonly lock_file='/tmp/klabautermann-fixture.lock'

compose() {
  docker compose --project-name "$compose_project" --file "$compose_file" "$@"
}

# Every profile, so the check covers services that start only on request.
check_rendered_config() {
  local profiles
  profiles="$(compose config --profiles | paste -sd, -)"
  COMPOSE_PROFILES="$profiles" compose config --format json \
    | "$dart_binary" run "$safety_checker"
}

# The service's published SSH port, refused unless it is on loopback.
published_port() {
  local address
  address="$(compose port "$1" 22)"
  if [[ "$address" != 127.0.0.1:* ]]; then
    echo "unsafe published address for $1: $address" >&2
    return 1
  fi
  printf '%s\n' "${address##*:}"
}

# Ready once sshd completes a key exchange on the port. One key type
# keeps each probe to one connection: sshd counts every connection that
# leaves before authenticating toward its per-source penalty.
wait_for_sshd() {
  local port="$1" attempt
  for ((attempt = 0; attempt < ready_attempts; attempt++)); do
    if [[ -n "$(ssh-keyscan -T 2 -t ed25519 -p "$port" 127.0.0.1 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "sshd on port $port did not become ready" >&2
  return 1
}

fingerprint() {
  ssh-keygen -lf "$1" | cut -d ' ' -f 2
}

runtime_dir=''
agent_started=0
suites_pid=''
runner_vm_pid=''

on_exit() {
  local status="$?" cleanup=0
  trap - EXIT
  # A further signal, such as a second Ctrl-C or a supervisor's repeated
  # SIGTERM, would otherwise end this shell part-way through teardown and
  # leave the fixture, the agent or the key directory behind.
  trap '' INT TERM HUP

  # Before the fixture goes: the suites would fail against it, and they
  # hold the lock. package:test lets the running test finish after a
  # first signal, which can take up to its timeout, and exits at once on
  # a second; a supervisor may send SIGKILL before then, which would skip
  # compose down. The pause keeps the two signals from merging into one.
  if [[ -n "$suites_pid" ]]; then
    kill "$suites_pid" 2>/dev/null || true
    sleep 0.5
    kill "$suites_pid" 2>/dev/null || true
    wait "$suites_pid" || true
  fi
  # The runner-VM leg undoes its own changes on TERM, ignoring further
  # signals while it does; the wait lets it finish.
  if [[ -n "$runner_vm_pid" ]]; then
    kill "$runner_vm_pid" 2>/dev/null || true
    wait "$runner_vm_pid" || true
  fi
  if [[ -n "$runtime_dir" ]]; then
    if [[ -n "$evidence_dir" ]]; then
      compose logs --no-color --timestamps >"$evidence_dir/compose.log" 2>&1 || true
    fi
    compose down --volumes --remove-orphans || cleanup="$?"
  fi
  if ((agent_started)); then
    ssh-agent -k >/dev/null || cleanup="$?"
  fi
  if [[ -n "$runtime_dir" ]]; then
    rm -rf -- "$runtime_dir"
  fi

  if ((status == 0)); then
    status="$cleanup"
  fi
  exit "$status"
}

if [[ "$#" -ne 0 ]]; then
  echo 'usage: test/integration/run.sh' >&2
  exit 2
fi

for tool in docker flock ssh-keygen ssh-keyscan ssh-agent ssh-add "$dart_binary"; do
  if ! command -v "$tool" >/dev/null; then
    echo "run.sh needs $tool" >&2
    exit 1
  fi
done
docker compose version >/dev/null

exec 9>"$lock_file"
if ! flock --nonblock 9; then
  echo "another fixture run holds $lock_file" >&2
  exit 1
fi

# Keys live outside the repository, so none can be committed.
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/klabautermann-fixture.XXXXXX")"
export KLABAUTERMANN_FIXTURE_RUNTIME="$runtime_dir"
trap on_exit EXIT
if [[ -n "$evidence_dir" ]]; then
  mkdir -p "$evidence_dir"
fi

# A run that was killed may have left its containers behind.
compose down --volumes --remove-orphans
check_rendered_config

# One key the engine reads from its file, and one only the agent holds:
# its file is gone once the agent has it.
ssh-keygen -q -t ed25519 -N '' -C 'klabautermann fixture identity' \
  -f "$runtime_dir/identity"
ssh-keygen -q -t ed25519 -N '' -C 'klabautermann fixture agent' \
  -f "$runtime_dir/agent"
cat "$runtime_dir/identity.pub" "$runtime_dir/agent.pub" \
  >"$runtime_dir/authorized_keys"
# The agent outlives a killed run, so it must not inherit the lock.
eval "$(ssh-agent -s 9>&-)" >/dev/null
agent_started=1
ssh-add -q "$runtime_dir/agent"
rm -f -- "$runtime_dir/agent"

compose up --detach --build
for service in "${services[@]}"; do
  port="$(published_port "$service")"
  wait_for_sshd "$port"
done

export KLABAUTERMANN_FIXTURE_COMPOSE_FILE="$compose_file"
export KLABAUTERMANN_FIXTURE_COMPOSE_PROJECT="$compose_project"
export KLABAUTERMANN_FIXTURE_HOST='127.0.0.1'
KLABAUTERMANN_FIXTURE_PORT="$(published_port sshd)"
KLABAUTERMANN_FIXTURE_JUMP_PORT="$(published_port jump)"
KLABAUTERMANN_FIXTURE_IDENTITY_FINGERPRINT="$(fingerprint "$runtime_dir/identity.pub")"
KLABAUTERMANN_FIXTURE_AGENT_FINGERPRINT="$(fingerprint "$runtime_dir/agent.pub")"
export KLABAUTERMANN_FIXTURE_PORT KLABAUTERMANN_FIXTURE_JUMP_PORT \
  KLABAUTERMANN_FIXTURE_IDENTITY_FINGERPRINT \
  KLABAUTERMANN_FIXTURE_AGENT_FINGERPRINT
export KLABAUTERMANN_FIXTURE_USER="$fixture_user"
export KLABAUTERMANN_FIXTURE_IDENTITY_FILE="$runtime_dir/identity"

reporter=(--reporter expanded)
if [[ -n "$evidence_dir" ]]; then
  reporter+=(--file-reporter "json:$evidence_dir/engine-tests.json")
fi

# One test at a time: they share the fixture, and some restart or pause it.
# On a signal, bash runs the EXIT trap without waiting for a foreground
# child, so the suites run in the background, where on_exit can stop
# them.
cd "$klabautermann_dir"
"$dart_binary" test --concurrency=1 --tags integration "${reporter[@]}" \
  packages/klabautermann_core/test/integration &
suites_pid="$!"
suites_status=0
wait "$suites_pid" || suites_status="$?"
suites_pid=''

# ---- Runner-VM leg (03 §11.3, K28a) -------------------------------------
# systemd on the runner itself, over a loopback sshd of its own; it runs
# whatever the suites gave, and in the background for on_exit, as they do.
"$integration_dir/runner_vm.sh" &
runner_vm_pid="$!"
runner_vm_status=0
wait "$runner_vm_pid" || runner_vm_status="$?"
runner_vm_pid=''
# ---- End of the runner-VM leg -------------------------------------------

if ((suites_status != 0)); then
  exit "$suites_status"
fi
exit "$runner_vm_status"
