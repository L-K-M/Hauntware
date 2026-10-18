# shellcheck shell=bash
# Recorded Docker API captures (03 §11.1, D21; spike S1), sourced by
# capture.sh, which owns the modes, the evidence directory, the labels
# and the teardown. Defining things here runs nothing.
#
# Each target is a real daemon at its native API maximum, rootful in a
# privileged container of a digest-pinned image:
#
#   1. Two volumes carrying the run label: one for the daemon's socket
#      directory, one for its storage.
#   2. The daemon container, with an explicit unix-only listener
#      (`dockerd --host=unix://...`; without it, the dind entrypoint
#      adds tcp://0.0.0.0:2375 when TLS is off) and nothing published.
#      It keeps Docker's default network for the pull of the seed image.
#   3. klabautermann_docker's tool/capture_api.dart, compiled ahead of
#      time, in a fresh Debian container with no network and only the
#      socket volume mounted. It seeds the daemon through the API,
#      records each exchange's raw response bytes and fails when the
#      daemon's API maximum is not the expected one.
#   4. The corpus is copied out to $evidence/docker-api/<corpus>/, the
#      daemon's log to $evidence/logs/, and both containers and volumes
#      are removed.
#
# Check mode compares each capture with the committed corpus in
# klabautermann_docker/test/fixtures/<corpus>/ by structure (exchange
# list, statuses, content types, header names, body kinds and JSON key
# paths, never values); --update replaces the committed corpora.
#
# KLABAUTERMANN_CAPTURE_CA_BUNDLE, when set, names a PEM bundle the
# daemons trust for that pull, for a sandbox whose egress re-terminates
# TLS. CI leaves it unset.

# capture.sh defines klab_dir, evidence, work, images, run_label, mode,
# pull_attempts and die before it calls anything here.
# shellcheck disable=SC2154
readonly api_fixtures_root="$klab_dir/packages/klabautermann_docker/test/fixtures"

# Bounds one capture: the tool waits up to its --wait for the socket and
# for each seeded state, and the follow and stats streams take seconds.
readonly api_capture_timeout_seconds=600
readonly api_wait_seconds=120
readonly api_hostname='capture-daemon'

# The daemons, through Google's Docker Hub mirror and quay.io. The tag
# only documents the pin; Docker pulls by digest. 29.7.2 is the newest
# release whose maximum is 1.55 (29.8 serves 1.56).
declare -rA api_images=(
  [docker-20.10]='mirror.gcr.io/library/docker:20.10.24-dind@sha256:af96c680a7e1f853ebdd50c1e0577e5df4089b033102546dd6417419564df3b5'
  [docker-25.0]='mirror.gcr.io/library/docker:25.0.5-dind@sha256:b41d0183012e2334aacd4e0b8e339b89246c4fdb7eada6cc86b0355f41328549'
  [docker-29.0]='mirror.gcr.io/library/docker:29.0.4-dind@sha256:c9699f4fc7365e8daad3eb48ce3b62dc118b2a5267f7be7bcd3c4e4b2f1cfb4c'
  [docker-29.7]='mirror.gcr.io/library/docker:29.7.2-dind@sha256:3ef33f2e220b79ed3ef3b99d81746f06f306cd6340e2cb7331d17ae996e74cb6'
  [podman-5.8]='quay.io/podman/stable:v5.8.7@sha256:2fb39ca923dd9e0ee33f9e319c3a107a2bfde022a6a31560cbd56a862821e7d3'
)

# What every daemon pulls by digest through the API, then runs.
readonly api_seed_image='mirror.gcr.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'

# One corpus per line: its directory, the daemon image, the runtime and
# the API maximum the daemon must report (Podman's compat layer serves
# 1.44).
readonly api_targets=(
  'api-1.41    docker-20.10  docker  1.41'
  'api-1.44    docker-25.0   docker  1.44'
  'api-1.52    docker-29.0   docker  1.52'
  'api-1.55    docker-29.7   docker  1.55'
  'api-podman  podman-5.8    podman  1.44'
)

# The podman/stable image configures itself for nesting: cgroups
# disabled and the host's namespaces, under which a container can be
# neither paused nor measured. This drop-in restores a rootful host
# install's defaults for the containers the tool creates, and keeps
# the service's own proxy variables (which it needs for the seed pull
# behind a proxy) out of their Env, which inspect records.
readonly api_podman_conf='[containers]
http_proxy = false
cgroups = "enabled"
netns = "bridge"
userns = ""
ipcns = "shareable"
utsns = "private"
cgroupns = "private"'

# Prints the corpus list for --list.
api_list() {
  local entry name key runtime api
  for entry in "${api_targets[@]}"; do
    read -r name key runtime api <<<"$entry"
    echo "api $name ${api_images[$key]} $runtime $api"
  done
}

# Compiles the tool and pulls the daemon images.
api_prepare() {
  local key ref attempt
  mkdir -p "$evidence/docker-api" "$work/api-stage"
  (
    cd "$klab_dir/packages/klabautermann_docker" || exit
    dart compile exe --verbosity=warning tool/capture_api.dart \
      -o "$work/api-stage/capture_api"
  )
  printf '%s\n' "$api_podman_conf" >"$work/podman.conf"
  for key in "${!api_images[@]}"; do
    ref="${api_images[$key]}"
    for ((attempt = 1; ; attempt++)); do
      docker pull --quiet "$ref" >/dev/null && break
      ((attempt < pull_attempts)) || die "cannot pull $ref"
      sleep $((attempt * 10))
    done
  done
}

# Runs one capture into $evidence/docker-api/<corpus>/ and removes its
# containers and volumes again.
api_capture_one() {
  local name="$1" runtime="$3" status=0 ids
  local sock_volume="klab-api-$name-socket-$$"
  local data_volume="klab-api-$name-data-$$"
  docker volume create --label "$run_label" "$sock_volume" >/dev/null ||
    return 1
  docker volume create --label "$run_label" "$data_volume" >/dev/null ||
    return 1
  api_capture_in "$@" "$sock_volume" "$data_volume" || status=1
  # The tool unpauses `paused` itself, but a timeout or an interrupt
  # skips that; under cgroup v1 a frozen container ignores SIGKILL and
  # would keep the daemon's container from stopping.
  local unpause=(podman unpause paused)
  [[ "$runtime" == podman ]] ||
    unpause=(docker --host unix:///run/capture/docker.sock unpause paused)
  docker exec "klab-api-$name-daemon-$$" "${unpause[@]}" >/dev/null 2>&1 ||
    true
  ids="$(docker ps -aq --filter "label=$run_label" \
    --filter "name=klab-api-$name-")" || status=1
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086 # one id per word
    docker rm -fv $ids >/dev/null || status=1
  fi
  docker volume rm "$sock_volume" "$data_volume" >/dev/null || status=1
  return "$status"
}

# Called in a condition, where errexit is off, so every step checks its
# own status.
api_capture_in() {
  local name="$1" key="$2" runtime="$3" api="$4"
  local sock_volume="$5" data_volume="$6"
  local log="$evidence/logs/docker-api-$name.log" daemon socket run
  local daemon_env=()
  local ca="${KLABAUTERMANN_CAPTURE_CA_BUNDLE:-}"
  [[ -z "$ca" ]] || daemon_env+=(-e SSL_CERT_FILE=/run/klab-ca.pem)

  if [[ "$runtime" == podman ]]; then
    socket=/run/capture/podman.sock
    daemon="$(docker create --name "klab-api-$name-daemon-$$" \
      --label "$run_label" --hostname "$api_hostname" \
      --privileged --cgroupns private "${daemon_env[@]}" \
      -e CONTAINERS_CONF_OVERRIDE=/run/klab-podman.conf \
      -v "$sock_volume:/run/capture" -v "$data_volume:/var/lib/containers" \
      "${api_images[$key]}" \
      podman system service --time=0 unix:///run/capture/podman.sock)" ||
      return 1
    docker cp "$work/podman.conf" "$daemon:/run/klab-podman.conf" || return 1
  else
    socket=/run/capture/docker.sock
    daemon="$(docker create --name "klab-api-$name-daemon-$$" \
      --label "$run_label" --hostname "$api_hostname" \
      --privileged --cgroupns private "${daemon_env[@]}" -e DOCKER_TLS_CERTDIR= \
      -v "$sock_volume:/run/capture" -v "$data_volume:/var/lib/docker" \
      "${api_images[$key]}" \
      dockerd --host=unix:///run/capture/docker.sock)" ||
      return 1
  fi
  if [[ -n "$ca" ]]; then
    docker cp "$ca" "$daemon:/run/klab-ca.pem" || return 1
  fi
  docker start "$daemon" >/dev/null || return 1

  local tool
  tool="$(docker create --name "klab-api-$name-tool-$$" \
    --label "$run_label" --network none \
    -v "$sock_volume:/run/capture" \
    "${images[debian-13]}" sleep infinity)" || return 1
  docker cp "$work/api-stage/." "$tool:/opt/klab" || return 1
  docker start "$tool" >/dev/null || return 1

  run='a local run'
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    run="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"
    run+="/actions/runs/$GITHUB_RUN_ID"
  fi
  if ! timeout "$api_capture_timeout_seconds" docker exec "$tool" \
    /opt/klab/capture_api capture --socket "$socket" \
    --out "/opt/klab/out/$name" --expect-api "$api" \
    --seed-image "$api_seed_image" --daemon-image "${api_images[$key]}" \
    --run "$run" --wait "$api_wait_seconds" >"$log" 2>&1; then
    sed 's/^/    /' "$log" >&2
    docker logs "$daemon" >"$evidence/logs/docker-api-$name-daemon.log" 2>&1
    return 1
  fi
  docker logs "$daemon" >"$evidence/logs/docker-api-$name-daemon.log" 2>&1
  docker cp "$tool:/opt/klab/out/$name" "$evidence/docker-api/$name"
}

# Captures every corpus, adding the names of failed or (in check mode)
# differing ones to the caller's `failed` array.
api_captures() {
  local entry name key runtime api committed
  for entry in "${api_targets[@]}"; do
    read -r name key runtime api <<<"$entry"
    echo "== $name: $runtime from ${api_images[$key]}"
    if ! api_capture_one "$name" "$key" "$runtime" "$api"; then
      echo "!! $name: capture failed (log: $evidence/logs/docker-api-$name.log)" >&2
      failed+=("$name")
      continue
    fi

    [[ "$mode" == check ]] || continue
    committed="$api_fixtures_root/$name"
    if [[ ! -d "$committed" ]]; then
      echo "!! $name: no committed corpus; run capture.sh --docker-api-only --update" >&2
      failed+=("$name")
    elif ! "$work/api-stage/capture_api" check "$committed" \
      "$evidence/docker-api/$name"; then
      echo "!! $name: the capture differs from the committed corpus" >&2
      failed+=("$name")
    fi
  done
}

# --update: replaces the committed corpora with the evidence copies and
# removes the api-* directories no longer listed.
api_update() {
  local dir entry name stale names=()
  for entry in "${api_targets[@]}"; do
    read -r name _ <<<"$entry"
    names+=("$name")
  done
  for dir in "$api_fixtures_root"/api-*/; do
    stale="$(basename "$dir")"
    [[ -d "$dir" && " ${names[*]} " != *" $stale "* ]] || continue
    echo "removing $stale, which capture.sh no longer lists"
    rm -rf -- "${api_fixtures_root:?}/$stale"
  done
  for name in "${names[@]}"; do
    rm -rf -- "${api_fixtures_root:?}/$name"
    cp -R -- "$evidence/docker-api/$name" "$api_fixtures_root/$name"
  done
}
