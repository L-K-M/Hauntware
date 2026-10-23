# Recorded Docker API: api-podman

Recorded by `klabautermann_docker/tool/capture_api.dart` (03 §11.1, D21)
from Podman 5.8.7, Docker-compatible API 1.44 (minimum 1.24), running
rootful in a privileged container of
`quay.io/podman/stable:v5.8.7@sha256:2fb39ca923dd9e0ee33f9e319c3a107a2bfde022a6a31560cbd56a862821e7d3`,
through its Unix socket, on 2026-10-20T17:14:44.869364Z (a local run).
The daemon reported fedora, kernel 6.18.44-fc-v139 and cgroup v1.

The tool seeded the daemon through the API first:
`mirror.gcr.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e`
pulled by digest and tagged; containers `web`, `worker`, `job`, `tty`,
`paused`, `demo-web-1`, `demo-cache-1`, `coolify-app` (`web` with a
passing health check, `worker` with a failing one, `job` printing 2000
lines on stdout and stderr, `tty` with a TTY, `paused` paused, a compose
project `demo` of two services, a `coolify.managed=true` container); the
network `demo_default`; the volume `demo_data`; and a dangling image
committed from `job`. The only secrets are fake and low entropy:
`DB_PASSWORD=fixture-password` in `worker`'s environment and a URL
credential in its labels.

Podman schedules health checks with systemd timers, and its container
runs no systemd, so while waiting for each health state the tool also
ran the check through `/libpod/containers/{name}/healthcheck`. The
`[containers]` settings of capture_docker_api.sh replace the image's
nesting defaults (cgroups disabled, host namespaces), under which a
container can be neither paused nor measured.

Each `<name>.http` file holds the response bytes exactly as the daemon
sent them: status line, headers and the body with its chunked framing.
`stats-stream` is cut at the end of the chunk that completes its second
line. MANIFEST.json lists the requests in order; capture.sh's check mode
compares a fresh capture with this directory by exchange list, status,
content type, header names, body kind and JSON key paths, never by
value.

| Exchange | Request | Status |
|---|---|---|
| `ping-head` | `HEAD /_ping` | 200 |
| `ping-get` | `GET /_ping` | 200 |
| `version` | `GET /version` | 200 |
| `info` | `GET /v1.44/info` | 200 |
| `containers` | `GET /v1.44/containers/json?all=1` | 200 |
| `containers-size` | `GET /v1.44/containers/json?all=1&size=1` | 200 |
| `inspect-web` | `GET /v1.44/containers/web/json` | 200 |
| `inspect-worker` | `GET /v1.44/containers/worker/json` | 200 |
| `inspect-job` | `GET /v1.44/containers/job/json` | 200 |
| `inspect-tty` | `GET /v1.44/containers/tty/json` | 200 |
| `inspect-paused` | `GET /v1.44/containers/paused/json` | 200 |
| `inspect-demo-web-1` | `GET /v1.44/containers/demo-web-1/json` | 200 |
| `inspect-demo-cache-1` | `GET /v1.44/containers/demo-cache-1/json` | 200 |
| `inspect-coolify-app` | `GET /v1.44/containers/coolify-app/json` | 200 |
| `inspect-missing` | `GET /v1.44/containers/klab-missing/json` | 404 |
| `stats-oneshot` | `GET /v1.44/containers/web/stats?stream=false&one-shot=true` | 200 |
| `stats-stream` | `GET /v1.44/containers/web/stats?stream=1` | 200 |
| `logs-tail` | `GET /v1.44/containers/job/logs?stdout=1&stderr=1&timestamps=1&tail=20` | 200 |
| `logs-tail-tty` | `GET /v1.44/containers/tty/logs?stdout=1&stderr=1&timestamps=1&tail=20` | 200 |
| `logs-follow` | `GET /v1.44/containers/job/logs?stdout=1&stderr=1&timestamps=1&follow=1` | 200 |
| `logs-since` | `GET /v1.44/containers/job/logs?stdout=1&stderr=1&timestamps=1&since=1792516474.895326341` | 200 |
| `images` | `GET /v1.44/images/json` | 200 |
| `image-inspect` | `GET /v1.44/images/mirror.gcr.io/library/busybox:1.37.0/json` | 200 |
| `networks` | `GET /v1.44/networks` | 200 |
| `volumes` | `GET /v1.44/volumes` | 200 |
| `system-df` | `GET /v1.44/system/df` | 200 |
| `events` | `GET /v1.44/events?since=1792516468&until=1792516479` | 200 |
| `below-min` | `GET /v1.23/info` | 200 |
| `above-max` | `GET /v1.45/info` | 200 |
| `floor-1.41` | `GET /v1.41/info` | 200 |
| `exec-create` | `POST /v1.44/containers/web/exec` | 201 |
| `exec-start` | `POST /v1.44/exec/21dd181c6762b05ad22434af4d521f560b453731f7e9eb8ef391dd6206b9aa8d/start` | 101 |
| `exec-inspect` | `GET /v1.44/exec/21dd181c6762b05ad22434af4d521f560b453731f7e9eb8ef391dd6206b9aa8d/json` | 200 |
| `exec-resize` | `POST /v1.44/exec/cc2c5b67b72f60bc5c850336afe245ba9a71cebb97bf7d6d2156920310c1d582/resize?h=40&w=120` | 201 |
