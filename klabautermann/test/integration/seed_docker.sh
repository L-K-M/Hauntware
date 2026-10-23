#!/bin/sh
# Seeds the Docker fixture's engine (03 §11.3) as the fixture user, over
# the Docker host's /var/run/docker.sock, so the Docker suites find
# containers in each state they read. run.sh loads the busybox image it
# pulled by digest into the engine, then pipes this script to `sh -s`
# over SSH with the loaded image's ID, which it tags for the stacks:
#
# - stack `demo` under ~/stacks/demo: `web` healthy and `broken`
#   unhealthy, both logging without a TTY, `console` logging with one,
#   and `vault`, which carries fake secrets in its environment, a label,
#   its command line and its health check's output, one of them from
#   the stack's `.env`, so the suites see each cross masked (03 §8.9);
# - stack `gone`, whose files are deleted once it runs, so its source is
#   missing on the host;
# - `coolify-app`, labelled `coolify.managed=true` (03 §8.7);
# - a dangling image, committed from `coolify-app` without a tag and
#   labelled `klabautermann.fixture=dangling`;
#
# and, for the mutation suites (M4 E27), with the image pushed to the
# fixture's registry as `registry:5000/klab/app:1`:
#
# - stack `redeploy` under ~/stacks/redeploy, whose image a redeploy pulls;
# - stack `orphans`, whose `old` service left its compose file after it
#   started, so its container is an orphan;
# - stack `managed`, labelled `coolify.managed=true`;
# - `ssh-port`, publishing port 22, a protected target (03 §8.6).
#
# and, for the v1 stack suite (M5 M29), with the same image:
#
# - stack `services`, with services `app` and `worker` for per-service
#   actions, and stack `downable`, which the suite takes down;
# - stack `override`, deployed from `compose.yaml` and
#   `compose.override.yaml`, so its labels record two files;
# - stack `profiled`, whose `debug` service sits behind a profile;
# - a folder `idle` holding a compose file that never ran, which only a
#   folder scan finds (STK-08).
#
# Only the fixture's registry is pulled from: the engine has no route to
# any other it may rely on.
#
# The secrets are fake and low in entropy, so the secret scan passes.
set -eu

if [ "$#" -ne 1 ]; then
  echo 'usage: seed_docker.sh IMAGE-ID' >&2
  exit 2
fi
readonly image='klabautermann-fixture/busybox:1.37'
readonly stacks="$HOME/stacks"
# Covers `web`'s and `vault`'s first checks (start_interval) and
# `broken`'s first failed one (interval, retries 1).
readonly settle_attempts=60
readonly app_image='registry:5000/klab/app:1'
# Seconds the registry may take to accept the push after it starts.
readonly push_attempts=60

docker image tag "$1" "$image"
docker image tag "$1" "$app_image"
attempt=0
until docker push --quiet "$app_image" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$push_attempts" ]; then
    echo "cannot push $app_image after ${push_attempts} attempts" >&2
    exit 1
  fi
  sleep 1
done

mkdir -p "$stacks/demo" "$stacks/gone"
cat >"$stacks/demo/compose.yaml" <<EOF
services:
  web:
    image: $image
    pull_policy: never
    command: ["sh", "-c", "while :; do echo web tick; sleep 5; done"]
    healthcheck:
      test: ["CMD", "true"]
      interval: 60s
      start_period: 60s
      start_interval: 1s
  broken:
    image: $image
    pull_policy: never
    command: ["sh", "-c", "while :; do echo broken tick >&2; sleep 5; done"]
    healthcheck:
      test: ["CMD", "false"]
      interval: 5s
      retries: 1
  console:
    image: $image
    pull_policy: never
    tty: true
    command: ["sh", "-c", "while :; do echo console tick; sleep 5; done"]
  vault:
    image: $image
    pull_policy: never
    command:
      - sh
      - -c
      - while :; do sleep 60; done
      - vault
      - --password
      - \${FIXTURE_PASSWORD}
      - --dsn=postgres://app:fixture-password@db/app
    environment:
      - DB_PASSWORD=fixture-password
      - API_TOKEN=fixture-token
      - FIXTURE_MODE=plain
    labels:
      fixture.api-token: fixture-token
    healthcheck:
      test: ["CMD", "sh", "-c", "echo DB_PASSWORD=\$\$DB_PASSWORD"]
      interval: 60s
      start_period: 60s
      start_interval: 1s
EOF
printf 'FIXTURE_PASSWORD=fixture-password\n' >"$stacks/demo/.env"
cat >"$stacks/gone/compose.yaml" <<EOF
services:
  idle:
    image: $image
    pull_policy: never
    command: ["sh", "-c", "while :; do sleep 60; done"]
EOF

docker compose --project-name demo --file "$stacks/demo/compose.yaml" \
  up --detach
docker compose --project-name gone --file "$stacks/gone/compose.yaml" \
  up --detach
rm -rf -- "$stacks/gone"
docker run --detach --pull never --name coolify-app \
  --label coolify.managed=true "$image" \
  sh -c 'while :; do sleep 60; done' >/dev/null
docker commit --change 'LABEL klabautermann.fixture=dangling' coolify-app \
  >/dev/null

# A sleeping service of the app image, for the mutation stacks' files.
app_service() {
  printf '  %s:\n    image: %s\n' "$1" "$app_image"
  printf '    command: ["sh", "-c", "while :; do sleep 60; done"]\n'
}

mkdir -p "$stacks/redeploy" "$stacks/orphans" "$stacks/managed"
{ echo services:; app_service app; } >"$stacks/redeploy/compose.yaml"
{ echo services:; app_service app; app_service old; } \
  >"$stacks/orphans/compose.yaml"
{
  echo services:
  app_service app
  printf '    labels:\n      coolify.managed: "true"\n'
} >"$stacks/managed/compose.yaml"
for stack in redeploy orphans managed; do
  docker compose --project-name "$stack" \
    --file "$stacks/$stack/compose.yaml" up --detach
done
# `old` leaves the file once it runs, so its container is an orphan.
{ echo services:; app_service app; } >"$stacks/orphans/compose.yaml"
mkdir -p "$stacks/services" "$stacks/downable" "$stacks/override" \
  "$stacks/profiled" "$stacks/idle"
{ echo services:; app_service app; app_service worker; } \
  >"$stacks/services/compose.yaml"
{ echo services:; app_service app; } >"$stacks/downable/compose.yaml"
{ echo services:; app_service app; } >"$stacks/override/compose.yaml"
printf 'services:\n  app:\n    labels:\n      klabautermann.fixture: override\n' \
  >"$stacks/override/compose.override.yaml"
{
  echo services:
  app_service app
  app_service debug
  printf '    profiles: ["debug"]\n'
} >"$stacks/profiled/compose.yaml"
{ echo services:; app_service app; } >"$stacks/idle/compose.yaml"
for stack in services downable profiled; do
  docker compose --project-name "$stack" \
    --file "$stacks/$stack/compose.yaml" up --detach
done
docker compose --project-name override \
  --file "$stacks/override/compose.yaml" \
  --file "$stacks/override/compose.override.yaml" up --detach

# Port 22 on dind's own network namespace, which nothing publishes.
docker run --detach --pull never --name ssh-port --publish 22:22 "$image" \
  sh -c 'while :; do sleep 60; done' >/dev/null

health() {
  docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null \
    || echo missing
}
attempt=0
until [ "$(health demo-web-1)" = healthy ] \
  && [ "$(health demo-vault-1)" = healthy ] \
  && [ "$(health demo-broken-1)" = unhealthy ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$settle_attempts" ]; then
    echo "demo-web-1 is $(health demo-web-1), demo-vault-1" \
      "$(health demo-vault-1) and demo-broken-1" \
      "$(health demo-broken-1) after ${settle_attempts} s" >&2
    exit 1
  fi
  sleep 1
done

docker ps --all --format '{{.Names}}\t{{.Status}}'
