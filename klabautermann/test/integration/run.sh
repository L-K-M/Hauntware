#!/usr/bin/env bash
# Runs Klabautermann's SSH integration fixture and the engine suites
# against it (03 §11.3, D53). The klabautermann_integration CI job runs it
# from klabautermann/; it runs the same way locally, given Docker with the
# Compose plugin, OpenSSH's client tools, util-linux flock and the Dart
# SDK with the workspace resolved.
#
# It owns the whole run: client keys and an agent made for this run only
# (never committed, D53), the safety checks of the rendered Compose
# config, readiness, the Docker engine's seed, the tests one at a time,
# and teardown on every exit. With
# KLABAUTERMANN_EVIDENCE_DIR set, logs and test results go there. After
# the fixture suites it runs the host write inventory (03 §8.11, M4
# E31): the Docker host snapshotted as root before and after a scripted
# MVP session, and the diff checked against inventory_allowlist.txt,
# with the snapshots and the report in $KLABAUTERMANN_EVIDENCE_DIR/inventory
# (default build/integration-evidence/inventory). Then the runner-VM leg
# (runner_vm.sh), which skips itself anywhere but a GitHub-hosted runner,
# and then the soak with 03 §11.4's budgets, whose numbers go to
# $KLABAUTERMANN_EVIDENCE_DIR/soak (default build/integration-evidence/soak):
#
#   KLABAUTERMANN_SOAK_SECONDS  the soak's measured window (600 with
#                               GITHUB_ACTIONS=true, otherwise 60)
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly klabautermann_dir="$(cd "$integration_dir/../.." && pwd)"
readonly compose_file="$integration_dir/docker-compose.yml"
readonly compose_project='klabautermann-integration'
# Poltergeist's checker, run by path rather than copied (03 §11.3). It
# reads the rendered Compose JSON on stdin and rejects host networking and
# ports published beyond loopback.
readonly safety_checker="$klabautermann_dir/../poltergeist/test/integration/check_config.dart"
# The Docker exposure rules (M3 decision M6), run after it on the same
# rendered config.
readonly docker_exposure_checker="$integration_dir/check_docker_exposure.dart"
readonly seed_script="$integration_dir/seed_docker.sh"
readonly inventory_script="$integration_dir/inventory.sh"
readonly inventory_checker="$integration_dir/inventory.dart"
readonly inventory_allowlist="$integration_dir/inventory_allowlist.txt"
# The seeded containers' image, pulled by digest through Google's Docker
# Hub mirror on the runner's own daemon and loaded into dind over SSH,
# so dind needs no route to a registry. The tag only documents the pin.
readonly seed_image='mirror.gcr.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'
readonly pull_attempts=3
readonly dart_binary="${DART_BIN:-dart}"
readonly evidence_dir="${KLABAUTERMANN_EVIDENCE_DIR:+$KLABAUTERMANN_EVIDENCE_DIR/fixture}"
readonly fixture_user='klab'
# Every sshd service, the Docker host's negative variants (M3 D11)
# included, each of which run.sh waits for.
readonly services=(sshd jump docker-sshd neg-nostreamlocal
  neg-disableforwarding neg-notcp neg-permitopen neg-maxsessions2 neg-restrict)
readonly ready_attempts=60
# The project name and loopback ports are fixed, and a run starts by
# removing what a killed run left, so two runs on one Docker host would
# tear down each other's fixture. One runs at a time: the lock is on /tmp,
# machine-wide like the Docker daemon, and ends with this shell.
readonly lock_file='/tmp/klabautermann-fixture.lock'
# 03 §11.4's 10-minute soak in CI; a one-minute smoke run elsewhere.
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  readonly soak_seconds="${KLABAUTERMANN_SOAK_SECONDS:-600}"
else
  readonly soak_seconds="${KLABAUTERMANN_SOAK_SECONDS:-60}"
fi
# Absolute, since the soak runs from klabautermann/.
soak_dir="${KLABAUTERMANN_EVIDENCE_DIR:-$klabautermann_dir/build/integration-evidence}/soak"
if [[ "$soak_dir" != /* ]]; then
  soak_dir="$PWD/$soak_dir"
fi
readonly soak_dir
inventory_dir="${KLABAUTERMANN_EVIDENCE_DIR:-$klabautermann_dir/build/integration-evidence}/inventory"
if [[ "$inventory_dir" != /* ]]; then
  inventory_dir="$PWD/$inventory_dir"
fi
readonly inventory_dir

compose() {
  docker compose --project-name "$compose_project" --file "$compose_file" "$@"
}

# Every profile, so the check covers services that start only on request.
check_rendered_config() {
  local profiles
  profiles="$(compose config --profiles | paste -sd, -)"
  COMPOSE_PROFILES="$profiles" compose config --format json \
    | "$dart_binary" run "$safety_checker"
  COMPOSE_PROFILES="$profiles" compose config --format json \
    | "$dart_binary" run "$docker_exposure_checker"
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

# The sync service's published address, which must be loopback.
sync_address() {
  local address
  address="$(compose port sync 8787)"
  if [[ "$address" != 127.0.0.1:* ]]; then
    echo "unsafe published address for sync: $address" >&2
    return 1
  fi
  echo "$address"
}

# Ready once the sync server answers HTTP: an unknown user's prelogin is
# refused, which proves the server is up without making an account.
wait_for_sync() {
  local address attempt
  address="$(sync_address)"
  for ((attempt = 0; attempt < ready_attempts; attempt++)); do
    if curl --silent --max-time 2 --output /dev/null \
      --write-out '%{http_code}' -X POST \
      -H 'content-type: application/json' \
      --data '{"username":"klabautermann-readiness"}' \
      "http://$address/v1/prelogin" | grep -q '^[1-4]'; then
      return 0
    fi
    sleep 1
  done
  echo "sync on $address did not become ready" >&2
  return 1
}

fingerprint() {
  ssh-keygen -lf "$1" | cut -d ' ' -f 2
}

# Runs a command on the Docker host as the fixture user, with the key
# file, against the host key read from the container (seed_docker_host).
docker_host_ssh() {
  ssh -F /dev/null -i "$runtime_dir/identity" -o IdentitiesOnly=yes \
    -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
    -o UserKnownHostsFile="$runtime_dir/known_hosts" \
    -p "$docker_port" "$fixture_user@127.0.0.1" "$@"
}

# Loads the seed image into dind through the Docker host and runs
# seed_docker.sh there as the fixture user (03 §11.3).
seed_docker_host() {
  local attempt host_key image_id
  host_key="$(compose exec -T docker-sshd cat /etc/ssh/ssh_host_ed25519_key.pub)"
  if [[ -z "$host_key" ]]; then
    echo 'the Docker host has no ed25519 host key' >&2
    return 1
  fi
  printf '[127.0.0.1]:%s %s\n' "$docker_port" "$(cut -d ' ' -f 1,2 <<<"$host_key")" \
    >"$runtime_dir/known_hosts"

  for ((attempt = 1; ; attempt++)); do
    docker pull --quiet "$seed_image" >/dev/null && break
    if ((attempt == pull_attempts)); then
      echo "cannot pull $seed_image" >&2
      return 1
    fi
    sleep $((attempt * 10))
  done
  # Saved by digest, the archive names no image, so the load reports
  # only its ID, which the seed tags.
  image_id="$(docker save "$seed_image" | docker_host_ssh docker load --quiet \
    | sed -n 's/^Loaded image ID: //p')"
  if [[ -z "$image_id" ]]; then
    echo "dind did not report loading $seed_image" >&2
    return 1
  fi
  docker_host_ssh sh -s -- "$image_id" <"$seed_script"
}

# The Docker host's paths as inventory.sh lists them, run there as root,
# into $1.
docker_host_snapshot() {
  compose exec -T --user root docker-sshd sh -s -- / <"$inventory_script" >"$1"
}

# Stops a backgrounded `dart test` run. package:test lets the running
# test finish after a first signal, which can take up to its timeout, and
# exits at once on a second; a supervisor may send SIGKILL before then,
# which would skip compose down. The pause keeps the two signals from
# merging into one.
stop_tests() {
  kill "$1" 2>/dev/null || true
  sleep 0.5
  kill "$1" 2>/dev/null || true
  wait "$1" || true
}

runtime_dir=''
agent_started=0
suites_pid=''
inventory_pid=''
runner_vm_pid=''
soak_pid=''

on_exit() {
  local status="$?" cleanup=0
  trap - EXIT
  # A further signal, such as a second Ctrl-C or a supervisor's repeated
  # SIGTERM, would otherwise end this shell part-way through teardown and
  # leave the fixture, the agent or the key directory behind.
  trap '' INT TERM HUP

  # Before the fixture goes: the suites and the soak would fail against
  # it, and they hold the lock.
  if [[ -n "$suites_pid" ]]; then
    stop_tests "$suites_pid"
  fi
  if [[ -n "$inventory_pid" ]]; then
    stop_tests "$inventory_pid"
  fi
  if [[ -n "$soak_pid" ]]; then
    stop_tests "$soak_pid"
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
if [[ ! "$soak_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo 'KLABAUTERMANN_SOAK_SECONDS takes a whole number of seconds' >&2
  exit 64
fi

for tool in docker flock ssh ssh-keygen ssh-keyscan ssh-agent ssh-add "$dart_binary"; do
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
# The same keys behind the `restrict` option for neg-restrict, whose sshd
# allows forwarding: the key option alone refuses it.
sed 's/^/restrict /' "$runtime_dir/authorized_keys" \
  >"$runtime_dir/authorized_keys.restrict"
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
docker_port="$(published_port docker-sshd)"
seed_docker_host
wait_for_sync

export KLABAUTERMANN_FIXTURE_COMPOSE_FILE="$compose_file"
export KLABAUTERMANN_FIXTURE_COMPOSE_PROJECT="$compose_project"
export KLABAUTERMANN_FIXTURE_HOST='127.0.0.1'
KLABAUTERMANN_FIXTURE_PORT="$(published_port sshd)"
KLABAUTERMANN_FIXTURE_JUMP_PORT="$(published_port jump)"
KLABAUTERMANN_FIXTURE_DOCKER_PORT="$docker_port"
KLABAUTERMANN_FIXTURE_IDENTITY_FINGERPRINT="$(fingerprint "$runtime_dir/identity.pub")"
KLABAUTERMANN_FIXTURE_AGENT_FINGERPRINT="$(fingerprint "$runtime_dir/agent.pub")"
export KLABAUTERMANN_FIXTURE_PORT KLABAUTERMANN_FIXTURE_JUMP_PORT \
  KLABAUTERMANN_FIXTURE_DOCKER_PORT \
  KLABAUTERMANN_FIXTURE_IDENTITY_FINGERPRINT \
  KLABAUTERMANN_FIXTURE_AGENT_FINGERPRINT
export KLABAUTERMANN_FIXTURE_USER="$fixture_user"
export KLABAUTERMANN_FIXTURE_IDENTITY_FILE="$runtime_dir/identity"
export KLABAUTERMANN_SYNC_SERVER="http://$(sync_address)"

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

# ---- Host write inventory (03 §8.11, M4 E31) -----------------------------
# The Docker host snapshotted before and after the scripted session alone,
# in the background for on_exit as the suites are; a change outside the
# allowlist fails the run. It runs whatever the suites gave.
mkdir -p "$inventory_dir"
inventory_status=0
docker_host_snapshot "$inventory_dir/docker-host.before"
"$dart_binary" test --concurrency=1 --tags inventory --reporter expanded \
  packages/klabautermann_core/test/integration/inventory_session_test.dart &
inventory_pid="$!"
wait "$inventory_pid" || inventory_status="$?"
inventory_pid=''
docker_host_snapshot "$inventory_dir/docker-host.after"
if ((inventory_status == 0)); then
  "$dart_binary" run "$inventory_checker" "$inventory_allowlist" \
    "$inventory_dir/docker-host.before" "$inventory_dir/docker-host.after" \
    >"$inventory_dir/docker-host.report" || inventory_status="$?"
  cat "$inventory_dir/docker-host.report"
fi
# ---- End of the host write inventory ------------------------------------

# ---- Runner-VM leg (03 §11.3, K28a) -------------------------------------
# systemd on the runner itself, over a loopback sshd of its own; it runs
# whatever the suites gave, and in the background for on_exit, as they do.
"$integration_dir/runner_vm.sh" &
runner_vm_pid="$!"
runner_vm_status=0
wait "$runner_vm_pid" || runner_vm_status="$?"
runner_vm_pid=''
# ---- End of the runner-VM leg -------------------------------------------

# ---- Soak and budgets (03 §11.4, K28b) ----------------------------------
# Ten aliases of the fixture's sshd at the Phone cadence for
# $soak_seconds s after a warm-up: no growth in channels, descriptors or
# memory, and the fast-tick and ten-host budgets. It runs whatever the
# legs before it gave, in the background for on_exit, as they do. A run
# that passes without soak.json skipped, which must not pass the job.
mkdir -p "$soak_dir"
rm -f -- "$soak_dir/soak.json"
KLABAUTERMANN_SOAK_SECONDS="$soak_seconds" KLABAUTERMANN_SOAK_DIR="$soak_dir" \
  "$dart_binary" test --concurrency=1 --tags soak --reporter expanded \
  --file-reporter "json:$soak_dir/soak-test.json" \
  packages/klabautermann_core/test/integration/soak_test.dart &
soak_pid="$!"
soak_status=0
wait "$soak_pid" || soak_status="$?"
soak_pid=''
if ((soak_status == 0)) && [[ ! -f "$soak_dir/soak.json" ]]; then
  echo "the soak wrote no $soak_dir/soak.json: it skipped" >&2
  soak_status=1
fi
# ---- End of the soak ----------------------------------------------------

if ((suites_status != 0)); then
  exit "$suites_status"
fi
if ((inventory_status != 0)); then
  exit "$inventory_status"
fi
if ((runner_vm_status != 0)); then
  exit "$runner_vm_status"
fi
exit "$soak_status"
