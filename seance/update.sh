#!/usr/bin/env bash
# Update a running Séance sync server with preflight and automatic rollback.
set -Eeuo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE=packages/seance_sync_server/docker-compose.yml
ENV_FILE=packages/seance_sync_server/.env
SERVICE=seance-sync
DATA_PATH=/data
PROBE_SECONDS="${SEANCE_UPDATE_PROBE_SECONDS:-30}"
if [[ ! "$PROBE_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "SEANCE_UPDATE_PROBE_SECONDS must be a positive integer." >&2
    exit 2
fi

compose=(docker compose -f "$COMPOSE_FILE")
if [[ -f "$ENV_FILE" ]]; then
    compose+=(--env-file "$ENV_FILE")
fi

run_id="$(date -u +%Y%m%d%H%M%S)-$$"
candidate_project="seance-preflight-$run_id"
preflight_compose=(docker compose --project-name "$candidate_project" -f "$COMPOSE_FILE")
if [[ -f "$ENV_FILE" ]]; then
    preflight_compose+=(--env-file "$ENV_FILE")
fi
recovery_dir=
snapshot_dir=
old_compose_file=
old_compose=()
replacement_started=
candidate_live=
old_stopped=
keep_snapshot=
lock_owned=
lock_dir="${SEANCE_UPDATE_LOCK_DIR:-${TMPDIR:-/tmp}/seance-sync-update.lock}"
rollback_tag=
candidate_tag=
data_volume=
old_image=

cleanup_preflight() {
    SEANCE_IMAGE="${candidate_tag:-seance-sync:latest}" \
    SEANCE_PUBLISH_PORT=0 \
        "${preflight_compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}

cleanup() {
    cleanup_preflight
    if [[ -n "$recovery_dir" && -z "$keep_snapshot" ]]; then
        rm -rf -- "$recovery_dir"
    fi
    if [[ -n "$lock_owned" ]]; then
        rm -f -- "$lock_dir/pid" "$lock_dir/host" "$lock_dir/uid" \
            "$lock_dir/recovery-dir"
        rmdir -- "$lock_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT

acquire_lock() {
    if ! mkdir -m 700 -- "$lock_dir"; then
        echo "A Séance updater lock already exists." >&2
        if [[ -f "$lock_dir/pid" ]]; then
            echo "Updater PID: $(<"$lock_dir/pid")" >&2
        fi
        if [[ -f "$lock_dir/host" ]]; then
            echo "Updater host: $(<"$lock_dir/host")" >&2
        fi
        if [[ -f "$lock_dir/uid" ]]; then
            echo "Updater user ID: $(<"$lock_dir/uid")" >&2
        fi
        if [[ -f "$lock_dir/recovery-dir" ]]; then
            echo "Recovery bundle: $(<"$lock_dir/recovery-dir")" >&2
        fi
        echo "Before removing this lock, confirm that no updater is running" >&2
        echo "on its recorded host and inspect the deployment and recovery bundle." >&2
        echo "Follow the stale-lock recovery procedure in the sync server README." >&2
        echo "Lock directory: $lock_dir" >&2
        return 1
    fi
    lock_owned=1
    printf '%s\n' "$$" >"$lock_dir/pid"
    hostname >"$lock_dir/host"
    id -u >"$lock_dir/uid"
}

# Persist the phase before operations that can stop production or migrate its
# database. An uncatchable interruption loses shell variables, so manual
# recovery needs this evidence even when no signal/EXIT trap could run.
record_recovery_state() {
    local phase="$1"
    printf 'run_id=%s\nphase=%s\nold_commit=%s\nnew_commit=%s\ncompose_project=%s\ndata_volume=%s\nold_image=%s\nrollback_tag=%s\ncandidate_tag=%s\n' \
        "$run_id" "$phase" "${old_commit:-}" "${new_commit:-}" \
        "${old_project:-}" "$data_volume" "$old_image" "$rollback_tag" \
        "$candidate_tag" >"$recovery_dir/update-state.tmp"
    chmod 600 "$recovery_dir/update-state.tmp"
    mv -- "$recovery_dir/update-state.tmp" "$recovery_dir/update-state.txt"
}

normalize_endpoint() {
    local endpoint="$1"
    endpoint="${endpoint/#0.0.0.0/127.0.0.1}"
    endpoint="${endpoint/#\[::\]/127.0.0.1}"
    endpoint="${endpoint/#:::/127.0.0.1:}"
    if [[ ! "$endpoint" =~ ^[^:]+:[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$endpoint"
}

probe() {
    local endpoint="$1"
    local path="$2"
    local deadline=$((SECONDS + PROBE_SECONDS))
    while (( SECONDS < deadline )); do
        if curl -fsS --max-time 2 -o /dev/null "http://$endpoint$path"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

published_endpoint() {
    local endpoint
    endpoint="$("${compose[@]}" port "$SERVICE" 8787 2>/dev/null | head -n1 || true)"
    [[ -n "$endpoint" ]] || return 1
    normalize_endpoint "$endpoint"
}

copy_snapshot_from_volume() {
    local destination="$1"
    docker run --rm --user 0 --entrypoint /bin/sh \
        -v "$data_volume:$DATA_PATH:ro" \
        -v "$destination:/backup" \
        "$rollback_tag" -ec '
          test -f /data/seance.sqlite
          for name in seance.sqlite seance.sqlite-wal seance.sqlite-shm; do
            if [ -f "/data/$name" ]; then cp -p "/data/$name" "/backup/$name"; fi
          done
        '
}

seed_volume_from_snapshot() {
    local volume="$1"
    local image="$2"
    docker run --rm --user 0 --entrypoint /bin/sh \
        -e "UPDATE_RUN_ID=$run_id" \
        -v "$volume:$DATA_PATH" \
        -v "$snapshot_dir:/backup:ro" \
        "$image" -ec '
          test -f /backup/seance.sqlite
          stage="/data/.seance-update-stage-$UPDATE_RUN_ID"
          previous="/data/.seance-update-previous-$UPDATE_RUN_ID"
          rm -rf "$stage" "$previous"
          mkdir "$stage" "$previous"

          for name in seance.sqlite seance.sqlite-wal seance.sqlite-shm; do
            if [ -f "/backup/$name" ]; then
              cp -p "/backup/$name" "$stage/$name"
              chown 10001:10001 "$stage/$name"
            fi
            if [ -f "/data/$name" ]; then
              touch "$previous/$name.existed"
            else
              touch "$previous/$name.absent"
            fi
          done

          restore_previous_files() {
            set +e
            [ -d "$previous" ] || return
            for name in seance.sqlite seance.sqlite-wal seance.sqlite-shm; do
              if [ -f "$previous/$name" ]; then
                rm -f "/data/$name"
                mv "$previous/$name" "/data/$name"
              elif [ -f "$previous/$name.absent" ]; then
                rm -f "/data/$name"
              fi
            done
            rm -rf "$stage" "$previous"
          }
          handle_restore_signal() {
            restore_previous_files
            exit 1
          }
          trap restore_previous_files EXIT
          trap handle_restore_signal HUP INT TERM

          for name in seance.sqlite seance.sqlite-wal seance.sqlite-shm; do
            if [ -f "/data/$name" ]; then mv "/data/$name" "$previous/$name"; fi
          done
          for name in seance.sqlite seance.sqlite-wal seance.sqlite-shm; do
            if [ -f "$stage/$name" ]; then mv "$stage/$name" "/data/$name"; fi
          done

          trap - EXIT HUP INT TERM
          rm -rf "$stage" "$previous"
        '
}

restart_unchanged_service() {
    if "${old_compose[@]}" start "$SERVICE"; then
        old_stopped=
        return 0
    fi
    keep_snapshot=1
    echo "!!! The old service did not restart; recovery bundle retained at:" >&2
    echo "!!! $recovery_dir" >&2
    return 1
}

snapshot_for_preflight() {
    snapshot_dir="$recovery_dir/preflight"
    mkdir -- "$snapshot_dir"
    echo "==> Taking the preflight database snapshot…"
    old_stopped=1
    "${old_compose[@]}" stop "$SERVICE"
    if ! copy_snapshot_from_volume "$snapshot_dir"; then
        echo "!!! Database snapshot failed; restarting the unchanged service." >&2
        restart_unchanged_service || true
        return 1
    fi
    restart_unchanged_service
}

snapshot_for_replacement() {
    local replacement_snapshot
    replacement_snapshot="$(mktemp -d "$recovery_dir/rollback.XXXXXX")"
    echo "==> Taking the final stopped-state database snapshot…"
    old_stopped=1
    "${old_compose[@]}" stop "$SERVICE"
    if ! copy_snapshot_from_volume "$replacement_snapshot"; then
        rmdir -- "$replacement_snapshot" 2>/dev/null || true
        echo "!!! Final database snapshot failed; restarting the unchanged service." >&2
        restart_unchanged_service || true
        return 1
    fi

    rm -rf -- "$snapshot_dir"
    snapshot_dir="$replacement_snapshot"
}

preflight_candidate() {
    echo "==> Preflighting the candidate with its Compose configuration…"
    SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
        "${preflight_compose[@]}" create "$SERVICE" >/dev/null

    local candidate_container candidate_volume
    candidate_container="$(SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
        "${preflight_compose[@]}" ps -a -q "$SERVICE")"
    candidate_volume="$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
        "$candidate_container")"
    if [[ -z "$candidate_container" || -z "$candidate_volume" ]]; then
        echo "!!! Could not identify the candidate's /data volume." >&2
        return 1
    fi
    seed_volume_from_snapshot "$candidate_volume" "$candidate_tag"
    SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
        "${preflight_compose[@]}" start "$SERVICE" >/dev/null

    local raw endpoint
    raw="$(SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
        "${preflight_compose[@]}" port "$SERVICE" 8787 2>/dev/null | \
        head -n1 || true)"
    if [[ -z "$raw" ]] || ! endpoint="$(normalize_endpoint "$raw")"; then
        echo "!!! Candidate has no usable published port." >&2
        SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
            "${preflight_compose[@]}" logs "$SERVICE" >&2 || true
        return 1
    fi
    if ! probe "$endpoint" /readyz; then
        echo "!!! Candidate did not become ready on http://$endpoint/readyz." >&2
        SEANCE_IMAGE="$candidate_tag" SEANCE_PUBLISH_PORT=0 \
            "${preflight_compose[@]}" logs "$SERVICE" >&2 || true
        return 1
    fi
    cleanup_preflight
}

stop_candidate_safely() {
    local deployed_container running
    deployed_container="$(SEANCE_IMAGE="$candidate_tag" \
        "${compose[@]}" ps -a -q "$SERVICE")" || return 1
    if ! SEANCE_IMAGE="$candidate_tag" "${compose[@]}" stop "$SERVICE"; then
        echo "!!! Could not stop the candidate; refusing further recovery changes." >&2
        return 1
    fi
    if [[ -n "$deployed_container" ]]; then
        if ! running="$(docker inspect -f '{{.State.Running}}' \
            "$deployed_container" 2>/dev/null)"; then
            echo "!!! Could not verify candidate shutdown; refusing to rewrite its database." >&2
            return 1
        fi
        if [[ "$running" != false ]]; then
            echo "!!! Candidate is still running; refusing to rewrite its live database." >&2
            return 1
        fi
    fi
}

preserve_live_database_for_manual_recovery() {
    keep_snapshot=1
    stop_candidate_safely || return 1
    echo "!!! Candidate stopped; the live database was left unchanged." >&2
    echo "!!! No older image was started because schema compatibility is unknown." >&2
    echo "!!! Recovery bundle retained at: $recovery_dir" >&2
}

restore_previous_release() {
    echo "==> Restoring the previous database and image…" >&2
    local rollback_container rollback_image rollback_volume
    stop_candidate_safely || return 1
    seed_volume_from_snapshot "$data_volume" "$rollback_tag" || return 1
    "${old_compose[@]}" up --no-start --remove-orphans --no-build || return 1
    rollback_container="$("${old_compose[@]}" ps -a -q "$SERVICE")" || return 1
    [[ -n "$rollback_container" ]] || return 1
    rollback_image="$(docker inspect -f '{{.Image}}' "$rollback_container")" || return 1
    rollback_volume="$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
        "$rollback_container")" || return 1
    if [[ "$rollback_image" != "$old_image" || "$rollback_volume" != "$data_volume" ]]; then
        echo "!!! Preserved Compose configuration did not recreate the previous image and volume." >&2
        return 1
    fi
    "${old_compose[@]}" start "$SERVICE" || return 1
    old_stopped=

    local endpoint
    endpoint="$("${old_compose[@]}" port "$SERVICE" 8787 2>/dev/null | \
        head -n1)" || return 1
    endpoint="$(normalize_endpoint "$endpoint")" || return 1
    if ! probe "$endpoint" /readyz; then
        # A release from before storage readiness can still prove liveness
        # after rollback. Candidate acceptance never uses this fallback.
        local status
        status="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
            "http://$endpoint/readyz" || true)"
        [[ "$status" == 404 ]] && probe "$endpoint" /healthz || return 1
    fi
    docker image tag "$old_image" seance-sync:latest || return 1
}

recover_interrupted_update() {
    if [[ -n "$replacement_started" ]]; then
        if [[ -n "$candidate_live" ]]; then
            preserve_live_database_for_manual_recovery
        else
            restore_previous_release
        fi
    elif [[ -n "$old_stopped" ]]; then
        restart_unchanged_service
    fi
}

handle_error() {
    local status=$?
    if (( BASH_SUBSHELL > 0 )); then
        return "$status"
    fi
    trap - ERR
    trap '' INT TERM HUP
    set +e
    if [[ -n "$replacement_started" ]]; then
        echo "!!! Candidate deployment failed. Recent logs:" >&2
        SEANCE_IMAGE="$candidate_tag" "${compose[@]}" logs --tail=80 "$SERVICE" >&2
        if recover_interrupted_update; then
            if [[ -z "$candidate_live" ]]; then
                echo "!!! The previous release was restored and is answering." >&2
            fi
        else
            keep_snapshot=1
            echo "!!! Automatic rollback failed. Recovery bundle retained at:" >&2
            echo "!!! $recovery_dir" >&2
        fi
    elif [[ -n "$old_stopped" ]]; then
        recover_interrupted_update || keep_snapshot=1
    fi
    exit "$status"
}
trap handle_error ERR

handle_signal() {
    local signal="$1"
    local status="$2"
    trap - ERR
    trap '' INT TERM HUP
    set +e
    if [[ -n "$replacement_started" || -n "$old_stopped" ]]; then
        echo "!!! Update interrupted by $signal; recovering the previous service." >&2
        if ! recover_interrupted_update; then
            keep_snapshot=1
            echo "!!! Automatic recovery failed. Recovery bundle retained at:" >&2
            echo "!!! $recovery_dir" >&2
        fi
    else
        echo "!!! Update interrupted by $signal." >&2
    fi
    exit "$status"
}
trap 'handle_signal SIGHUP 129' HUP
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGTERM 143' TERM

main() {
    command -v git >/dev/null
    command -v docker >/dev/null
    command -v curl >/dev/null
    docker compose version >/dev/null
    acquire_lock
    recovery_dir="$(mktemp -d "${TMPDIR:-/tmp}/seance-update.XXXXXX")"
    chmod 700 "$recovery_dir"
    printf '%s\n' "$recovery_dir" >"$lock_dir/recovery-dir"
    record_recovery_state locked

    local branch old_commit old_container old_project new_commit endpoint
    branch="${1:-$(git rev-parse --abbrev-ref HEAD)}"
    old_commit="$(git rev-parse HEAD)"

    old_container="$("${compose[@]}" ps -q "$SERVICE")"
    if [[ -z "$old_container" ]]; then
        echo "This updater requires an existing $SERVICE deployment." >&2
        echo "Start the initial deployment with docker compose first." >&2
        return 1
    fi
    old_image="$(docker inspect -f '{{.Image}}' "$old_container")"
    old_project="$(docker inspect -f \
        '{{index .Config.Labels "com.docker.compose.project"}}' "$old_container")"
    data_volume="$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
        "$old_container")"
    if [[ -z "$old_image" || -z "$old_project" || -z "$data_volume" ]]; then
        echo "Could not identify the running image, Compose project, or /data volume." >&2
        return 1
    fi
    # Keep addressing the discovered production project even if the fetched
    # Compose file changes its name or project-name environment defaults.
    compose=(docker compose --project-name "$old_project" -f "$COMPOSE_FILE")
    if [[ -f "$ENV_FILE" ]]; then
        compose+=(--env-file "$ENV_FILE")
    fi
    rollback_tag="seance-sync:rollback-$run_id"
    docker image tag "$old_image" "$rollback_tag"
    old_compose_file="$recovery_dir/rollback-compose.yml"
    SEANCE_IMAGE="$rollback_tag" "${compose[@]}" config >"$old_compose_file"
    chmod 600 "$old_compose_file"
    old_compose=(docker compose --project-name "$old_project" -f "$old_compose_file")

    if [[ "$branch" != "$(git rev-parse --abbrev-ref HEAD)" ]]; then
        echo "==> Switching to '$branch'…"
        git checkout "$branch"
    fi

    echo "==> Syncing '$branch' from the remote…"
    if command -v gh >/dev/null 2>&1; then
        gh repo sync --branch "$branch" || git pull --ff-only origin "$branch"
    else
        git pull --ff-only origin "$branch"
    fi
    new_commit="$(git rev-parse HEAD)"
    candidate_tag="seance-sync:candidate-${new_commit:0:12}-$run_id"
    record_recovery_state building

    echo "==> Building candidate ${candidate_tag}…"
    SEANCE_IMAGE="$candidate_tag" "${compose[@]}" build --pull

    record_recovery_state preflight-snapshot
    snapshot_for_preflight
    record_recovery_state preflight
    preflight_candidate
    record_recovery_state replacement-snapshot
    snapshot_for_replacement

    echo "==> Creating candidate deployment…"
    record_recovery_state replacing
    replacement_started=1
    SEANCE_IMAGE="$candidate_tag" "${compose[@]}" up \
        --no-start --remove-orphans --no-build
    local candidate_container candidate_data_volume
    candidate_container="$(SEANCE_IMAGE="$candidate_tag" \
        "${compose[@]}" ps -a -q "$SERVICE")"
    candidate_data_volume="$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
        "$candidate_container")"
    if [[ -z "$candidate_container" || "$candidate_data_volume" != "$data_volume" ]]; then
        echo "Candidate configuration does not preserve the production data volume." >&2
        return 1
    fi
    docker image tag "$candidate_tag" seance-sync:latest
    record_recovery_state candidate-may-have-writes
    candidate_live=1
    SEANCE_IMAGE="$candidate_tag" "${compose[@]}" start "$SERVICE"
    endpoint="$(published_endpoint)"
    if ! probe "$endpoint" /readyz; then
        echo "Candidate did not become ready on http://$endpoint/readyz." >&2
        return 1
    fi

    replacement_started=
    candidate_live=
    old_stopped=
    docker image rm "$candidate_tag" >/dev/null || true
    echo "==> Candidate ready."
    echo "==> Updated $old_commit -> $new_commit; rollback image: $rollback_tag"
    "${compose[@]}" ps
}

main "$@"
