# Recorded Docker API: api-1.52

Recorded by `klabautermann_docker/tool/capture_api.dart` (03 §11.1, D21)
from Docker Engine 29.0.4, API 1.52 (minimum 1.44), running rootful in a
privileged container of
`mirror.gcr.io/library/docker:29.0.4-dind@sha256:c9699f4fc7365e8daad3eb48ce3b62dc118b2a5267f7be7bcd3c4e4b2f1cfb4c`,
through its Unix socket, on 2026-10-17T16:14:04.521766Z (a local run).
The daemon reported Alpine Linux v3.22, kernel 6.18.44-fc-v139 and
cgroup v1.

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
| `info` | `GET /v1.52/info` | 200 |
| `containers` | `GET /v1.52/containers/json?all=1` | 200 |
| `containers-size` | `GET /v1.52/containers/json?all=1&size=1` | 200 |
| `inspect-web` | `GET /v1.52/containers/web/json` | 200 |
| `inspect-worker` | `GET /v1.52/containers/worker/json` | 200 |
| `inspect-job` | `GET /v1.52/containers/job/json` | 200 |
| `inspect-tty` | `GET /v1.52/containers/tty/json` | 200 |
| `inspect-paused` | `GET /v1.52/containers/paused/json` | 200 |
| `inspect-demo-web-1` | `GET /v1.52/containers/demo-web-1/json` | 200 |
| `inspect-demo-cache-1` | `GET /v1.52/containers/demo-cache-1/json` | 200 |
| `inspect-coolify-app` | `GET /v1.52/containers/coolify-app/json` | 200 |
| `inspect-missing` | `GET /v1.52/containers/klab-missing/json` | 404 |
| `stats-oneshot` | `GET /v1.52/containers/web/stats?stream=false&one-shot=true` | 200 |
| `stats-stream` | `GET /v1.52/containers/web/stats?stream=1` | 200 |
| `logs-tail` | `GET /v1.52/containers/job/logs?stdout=1&stderr=1&timestamps=1&tail=20` | 200 |
| `logs-tail-tty` | `GET /v1.52/containers/tty/logs?stdout=1&stderr=1&timestamps=1&tail=20` | 200 |
| `logs-follow` | `GET /v1.52/containers/job/logs?stdout=1&stderr=1&timestamps=1&follow=1` | 200 |
| `logs-since` | `GET /v1.52/containers/job/logs?stdout=1&stderr=1&timestamps=1&since=1792253639.152216852` | 200 |
| `images` | `GET /v1.52/images/json` | 200 |
| `image-inspect` | `GET /v1.52/images/mirror.gcr.io/library/busybox:1.37.0/json` | 200 |
| `networks` | `GET /v1.52/networks` | 200 |
| `volumes` | `GET /v1.52/volumes` | 200 |
| `system-df` | `GET /v1.52/system/df` | 200 |
| `events` | `GET /v1.52/events?since=1792253623&until=1792253643` | 200 |
| `below-min` | `GET /v1.43/info` | 400 |
| `above-max` | `GET /v1.53/info` | 400 |
| `floor-1.41` | `GET /v1.41/info` | 400 |
