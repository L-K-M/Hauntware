#!/usr/bin/env bash
# Dependency-free behavioral tests for update.sh. Docker, git, gh, and curl
# are fakes; the assertions protect ordering and rollback state transitions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/seance-update-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "git $*" >>"$TEST_LOG"
if [[ "${1-}" == rev-parse && "${2-}" == --abbrev-ref ]]; then
    echo main
elif [[ "${1-}" == rev-parse && "${2-}" == HEAD ]]; then
    count=0
    [[ ! -f "$TEST_STATE.rev" ]] || count="$(<"$TEST_STATE.rev")"
    count=$((count + 1))
    echo "$count" >"$TEST_STATE.rev"
    if (( count == 1 )); then
        printf '%040d\n' 1
    else
        printf '%040d\n' 2
    fi
fi
EOF

cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "gh $*" >>"$TEST_LOG"
EOF

cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "docker image=${SEANCE_IMAGE-} publish=${SEANCE_PUBLISH_PORT-} $*" >>"$TEST_LOG"
args=" $* "

if [[ "$args" == *" inspect "* ]]; then
    format=
    original_args=("$@")
    while (( $# )); do
        if [[ "$1" == -f ]]; then
            format="$2"
            break
        fi
        shift
    done
    target="${original_args[${#original_args[@]} - 1]}"
    case "$format" in
      *'.State.Running'*)
          [[ "$TEST_SCENARIO" != candidate_still_running ]] || { echo true; exit 0; }
          echo false
          ;;
      *'.Image'*)
          if [[ "$TEST_SCENARIO" == rollback_image_mismatch &&
                -f "$TEST_STATE.rollback" ]]; then
              echo sha256:wrong
          else
              echo sha256:old
          fi
          ;;
      *'com.docker.compose.project'*) echo seance-project ;;
      *'.Mounts'*)
          case "$target" in
            preflight-container) echo preflight-volume ;;
            candidate-container)
                if [[ "$TEST_SCENARIO" == volume_mismatch ]]; then
                    echo wrong-volume
                else
                    echo data-volume
                fi
                ;;
            *) echo data-volume ;;
          esac
          ;;
    esac
    exit 0
fi

if [[ "$args" == *" image tag "* ]]; then
    if [[ "$args" == *"image tag seance-sync:candidate-"* &&
          "$args" == *" seance-sync:latest "* ]]; then
        case "$TEST_SCENARIO" in
          tag_fail|rollback_seed_fail|old_compose_up_fail|rollback_image_mismatch|signal_during_restore)
              exit 1
              ;;
        esac
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" config "* ]]; then
    printf '%s\n' \
        'name: seance-project' \
        'services:' \
        '  seance-sync:' \
        '    image: seance-sync:rollback-test'
    exit 0
fi

if [[ "$args" == *" compose "*" ps -q "* ]]; then
    if [[ "$args" == *"--project-name seance-preflight-"* ]]; then
        echo preflight-container
    elif [[ "$args" == *"rollback-compose.yml"* ]]; then
        echo old-container
    elif [[ -f "$TEST_STATE.production" ]]; then
        echo candidate-container
    else
        echo old-container
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" build --pull "* ]]; then
    [[ "$TEST_SCENARIO" != build_fail ]] || exit 1
    if [[ "$TEST_SCENARIO" == hold_build ]]; then
        : >"$TEST_HOLD_MARKER"
        while [[ ! -f "$TEST_RELEASE_MARKER" ]]; do sleep 0.05; done
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" stop seance-sync "* ]]; then
    if [[ "$TEST_SCENARIO" == rollback_stop_fail && -f "$TEST_STATE.production" &&
          "$args" != *"rollback-compose.yml"* ]]; then
        exit 1
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" start seance-sync "* ]]; then
    if [[ "$TEST_SCENARIO" == old_restart_fail &&
          "$args" == *"rollback-compose.yml"* && ! -f "$TEST_STATE.rollback" ]]; then
        exit 1
    fi
    if [[ "$args" != *"--project-name seance-preflight-"* &&
          "$args" != *"rollback-compose.yml"* && -f "$TEST_STATE.production" ]]; then
        : >"$TEST_STATE.production_started"
        : >"$TEST_STATE.write_after_start"
        if [[ "$TEST_SCENARIO" == signal_during_start ]]; then
            kill -TERM "$PPID"
        fi
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" up --no-start "* ]]; then
    if [[ "$args" == *"rollback-compose.yml"* ]]; then
        [[ "$TEST_SCENARIO" != old_compose_up_fail ]] || exit 1
        : >"$TEST_STATE.rollback"
        if [[ "$TEST_SCENARIO" == signal_during_restore ]]; then
            kill -TERM "$PPID"
        fi
    else
        : >"$TEST_STATE.production"
    fi
    exit 0
fi

if [[ "$args" == *" compose "*" port seance-sync 8787 "* ]]; then
    [[ "$TEST_SCENARIO" != missing_port || "$args" != *"--project-name seance-preflight-"* ]] || exit 0
    echo 127.0.0.1:49152
    exit 0
fi

if [[ "$args" == *" run "* ]]; then
    if [[ "$args" == *"data-volume:/data:ro"* ]]; then
        count=0
        [[ ! -f "$TEST_STATE.snapshots" ]] || count="$(<"$TEST_STATE.snapshots")"
        count=$((count + 1))
        echo "$count" >"$TEST_STATE.snapshots"
        if [[ "$TEST_SCENARIO" == backup_fail && "$count" -eq 1 ]] ||
           [[ "$TEST_SCENARIO" == missing_database && "$count" -eq 1 ]] ||
           [[ "$TEST_SCENARIO" == final_snapshot_fail && "$count" -eq 2 ]]; then
            exit 1
        fi
    elif [[ "$TEST_SCENARIO" == rollback_seed_fail &&
            "$args" == *"data-volume:/data"* && -f "$TEST_STATE.production" ]]; then
        exit 1
    fi
    exit 0
fi
EOF

cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
echo "curl $*" >>"$TEST_LOG"
case "$TEST_SCENARIO" in
  preflight_fail)
      [[ -f "$TEST_STATE.production" ]] || exit 1
      ;;
  production_fail|rollback_stop_fail|candidate_still_running)
      if [[ -f "$TEST_STATE.production_started" && ! -f "$TEST_STATE.rollback" ]]; then
          exit 1
      fi
      ;;
esac
EOF

chmod +x "$bin/git" "$bin/gh" "$bin/docker" "$bin/curl"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_has() {
    if ! grep -q -- "$1" "$2"; then
        cat "$2" >&2
        [[ ! -f "${2%/log}/out" ]] || cat "${2%/log}/out" >&2
        fail "missing '$1' in $2"
    fi
}

assert_lacks() {
    if grep -q -- "$1" "$2"; then
        cat "$2" >&2
        fail "unexpected '$1' in $2"
    fi
}

line_of() {
    grep -n -- "$1" "$2" | head -n1 | cut -d: -f1
}

last_line_of() {
    grep -n -- "$1" "$2" | tail -n1 | cut -d: -f1
}

run_case() {
    local scenario="$1" expected="$2"
    local case_dir="$tmp/$scenario"
    mkdir -p "$case_dir/tmp"
    local log="$case_dir/log" state="$case_dir/state"
    : >"$log"
    local status=0
    PATH="$bin:/usr/bin:/bin" \
    TEST_SCENARIO="$scenario" TEST_LOG="$log" TEST_STATE="$state" \
    TEST_HOLD_MARKER="$case_dir/hold" TEST_RELEASE_MARKER="$case_dir/release" \
    TMPDIR="$case_dir/tmp" SEANCE_UPDATE_PROBE_SECONDS=1 \
        "$ROOT/update.sh" main >"$case_dir/out" 2>&1 || status=$?
    if [[ "$expected" == success && "$status" -ne 0 ]]; then
        cat "$case_dir/out" >&2
        fail "$scenario unexpectedly failed"
    fi
    if [[ "$expected" == failure && "$status" -eq 0 ]]; then
        cat "$log" >&2
        cat "$case_dir/out" >&2
        fail "$scenario unexpectedly succeeded"
    fi
    printf '%s\n' "$log"
}

log="$(run_case success success)"
[[ "$(grep -c 'run .*data-volume:/data:ro' "$log")" -eq 2 ]] ||
    fail 'success did not take two isolated snapshots'
assert_has 'publish=0 compose --project-name seance-preflight-.* create seance-sync' "$log"
assert_has 'compose --project-name seance-project -f .*rollback-compose.yml stop seance-sync' "$log"
assert_has 'compose .* up --no-start .*--no-build' "$log"
assert_has 'image tag .*seance-sync:latest' "$log"
assert_lacks 'image prune' "$log"
first_copy="$(line_of 'run .*data-volume:/data:ro' "$log")"
preflight_ready="$(line_of 'curl .*\/readyz' "$log")"
second_copy="$(last_line_of 'run .*data-volume:/data:ro' "$log")"
production_create="$(last_line_of 'compose .* up --no-start' "$log")"
production_ready="$(last_line_of 'curl .*\/readyz' "$log")"
candidate_tag_line="$(line_of 'image tag seance-sync:candidate-.*seance-sync:latest' "$log")"
(( first_copy < preflight_ready && preflight_ready < second_copy &&
   second_copy < production_create && production_create < candidate_tag_line &&
   candidate_tag_line < production_ready )) ||
    fail 'snapshot/preflight/deployment ordering is unsafe'

log="$(run_case build_fail failure)"
assert_lacks ' stop seance-sync' "$log"

for scenario in backup_fail missing_database; do
    log="$(run_case "$scenario" failure)"
    assert_has 'rollback-compose.yml start seance-sync' "$log"
    assert_lacks 'preflight-.* create seance-sync' "$log"
done

log="$(run_case old_restart_fail failure)"
assert_has 'bundle retained at' "$tmp/old_restart_fail/out"
compgen -G "$tmp/old_restart_fail/tmp/seance-update.*" >/dev/null ||
    fail 'restart failure discarded its recovery bundle'

for scenario in preflight_fail missing_port; do
    log="$(run_case "$scenario" failure)"
    [[ "$(grep -c 'run .*data-volume:/data:ro' "$log")" -eq 1 ]] ||
        fail "$scenario unexpectedly took a replacement snapshot"
    assert_lacks 'compose .* up --no-start .*--no-build' "$log"
done

log="$(run_case final_snapshot_fail failure)"
assert_has 'preflight-.* create seance-sync' "$log"
assert_has 'rollback-compose.yml start seance-sync' "$log"
assert_lacks 'compose .* up --no-start .*--no-build' "$log"

log="$(run_case production_fail failure)"
assert_has 'image=.*candidate-.* compose .* stop seance-sync' "$log"
assert_lacks 'rollback-compose.yml up --no-start .*--no-build' "$log"
assert_lacks 'run .*data-volume:/data .*:/backup:ro' "$log"
assert_lacks 'image tag sha256:old seance-sync:latest' "$log"
assert_has 'Candidate stopped; the live database was left unchanged' \
    "$tmp/production_fail/out"
assert_has 'No older image was started' "$tmp/production_fail/out"
[[ -f "$tmp/production_fail/state.write_after_start" ]] ||
    fail 'production failure did not model a write after candidate start'
compgen -G "$tmp/production_fail/tmp/seance-update.*" >/dev/null ||
    fail 'live-database rollback discarded its recovery bundle'

log="$(run_case rollback_stop_fail failure)"
assert_lacks 'run .*data-volume:/data .*:/backup:ro' "$log"
assert_has 'refusing further recovery changes' "$tmp/rollback_stop_fail/out"
compgen -G "$tmp/rollback_stop_fail/tmp/seance-update.*" >/dev/null ||
    fail 'failed rollback discarded its recovery bundle'

log="$(run_case candidate_still_running failure)"
assert_lacks 'run .*data-volume:/data .*:/backup:ro' "$log"
assert_has 'Candidate is still running' "$tmp/candidate_still_running/out"
compgen -G "$tmp/candidate_still_running/tmp/seance-update.*" >/dev/null ||
    fail 'running-candidate rollback discarded its recovery bundle'

log="$(run_case rollback_seed_fail failure)"
assert_has 'run .*data-volume:/data .*:/backup:ro' "$log"
assert_has 'bundle retained at' "$tmp/rollback_seed_fail/out"
compgen -G "$tmp/rollback_seed_fail/tmp/seance-update.*" >/dev/null ||
    fail 'failed restore discarded its recovery bundle'

log="$(run_case volume_mismatch failure)"
assert_has 'Candidate configuration does not preserve the production data volume' \
    "$tmp/volume_mismatch/out"
assert_has 'rollback-compose.yml up --no-start .*--no-build' "$log"
assert_has 'run .*data-volume:/data .*:/backup:ro' "$log"

log="$(run_case tag_fail failure)"
assert_has 'image tag .*seance-sync:latest' "$log"
assert_has 'image=.*candidate-.* compose .* stop seance-sync' "$log"
assert_has 'run .*data-volume:/data .*:/backup:ro' "$log"
assert_has 'rollback-compose.yml up --no-start .*--no-build' "$log"
[[ ! -f "$tmp/tag_fail/state.write_after_start" ]] ||
    fail 'candidate started before latest tag was established'

log="$(run_case signal_during_start failure)"
assert_has 'interrupted by SIGTERM' "$tmp/signal_during_start/out"
assert_lacks 'rollback-compose.yml up --no-start .*--no-build' "$log"
assert_lacks 'run .*data-volume:/data .*:/backup:ro' "$log"

for scenario in old_compose_up_fail rollback_image_mismatch; do
    log="$(run_case "$scenario" failure)"
    assert_has 'bundle retained at' "$tmp/$scenario/out"
    rollback_attempt="$(last_line_of 'rollback-compose.yml up --no-start' "$log")"
    last_old_start="$(last_line_of 'rollback-compose.yml start seance-sync' "$log")"
    (( last_old_start < rollback_attempt )) ||
        fail "$scenario restarted a container that was not verified"
    compgen -G "$tmp/$scenario/tmp/seance-update.*" >/dev/null ||
        fail "$scenario discarded its recovery bundle"
done

log="$(run_case signal_during_restore failure)"
assert_has 'rollback-compose.yml start seance-sync' "$log"
assert_has 'image tag sha256:old seance-sync:latest' "$log"
[[ "$(grep -c 'interrupted by' "$tmp/signal_during_restore/out" || true)" -eq 0 ]] ||
    fail 'a second signal interrupted recovery'

concurrent="$tmp/concurrent"
mkdir -p "$concurrent/tmp"
: >"$concurrent/first.log"
: >"$concurrent/second.log"
PATH="$bin:/usr/bin:/bin" TEST_SCENARIO=hold_build \
TEST_LOG="$concurrent/first.log" TEST_STATE="$concurrent/state" \
TEST_HOLD_MARKER="$concurrent/hold" TEST_RELEASE_MARKER="$concurrent/release" \
TMPDIR="$concurrent/tmp" SEANCE_UPDATE_PROBE_SECONDS=1 \
    "$ROOT/update.sh" main >"$concurrent/first.out" 2>&1 &
first_pid=$!
for _ in {1..100}; do
    [[ -f "$concurrent/hold" ]] && break
    sleep 0.05
done
[[ -f "$concurrent/hold" ]] || fail 'first updater did not reach its hold point'
second_status=0
PATH="$bin:/usr/bin:/bin" TEST_SCENARIO=hold_build \
TEST_LOG="$concurrent/second.log" TEST_STATE="$concurrent/second-state" \
TEST_HOLD_MARKER="$concurrent/second-hold" TEST_RELEASE_MARKER="$concurrent/release" \
TMPDIR="$concurrent/tmp" SEANCE_UPDATE_PROBE_SECONDS=1 \
    "$ROOT/update.sh" main >"$concurrent/second.out" 2>&1 || second_status=$?
[[ "$second_status" -ne 0 ]] || fail 'concurrent updater acquired the same lock'
assert_has 'Another Séance update is already running' "$concurrent/second.out"
assert_lacks ' inspect ' "$concurrent/second.log"
: >"$concurrent/release"
wait "$first_pid" || fail 'first updater failed after lock test release'

assert_lacks 'chown -R' "$ROOT/update.sh"
echo 'update.sh regression tests passed'
