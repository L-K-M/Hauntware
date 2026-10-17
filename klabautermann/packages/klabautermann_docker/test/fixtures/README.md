# Fixtures

The flat files in this directory were written by hand from the Docker
Engine API documentation and the version notes in
`docs/design/klabautermann/03` section 5.8; they stay as unit fixtures.
The `api-*/` directories are recordings from real daemons (below).

## Recorded API corpora (`api-*/`)

Spike S1's recorded-API corpus (03 sections 11.1 and 5.8, D21): one
directory per daemon, each at its native API maximum, recorded by
`klabautermann_docker/tool/capture_api.dart` through
`klabautermann/test/integration/capture.sh` (its
`capture_docker_api.sh` holds the daemon pins).

| Directory | Daemon |
|---|---|
| `api-1.41/` | Docker 20.10.24 |
| `api-1.44/` | Docker 25.0.5 |
| `api-1.52/` | Docker 29.0.4 |
| `api-1.55/` | Docker 29.7.2 |
| `api-podman/` | Podman 5.8.7, Docker-compatible API 1.44 |

Each directory holds:

- `<exchange>.http`: the response bytes exactly as the daemon sent them,
  status line, headers and body with its chunked framing, so replaying
  them also exercises the HTTP parser. `.gitattributes` keeps them
  byte-exact. `stats-stream.http` ends at the chunk that completes its
  second line.
- `MANIFEST.json`: the daemon's version, API range, OS, kernel, cgroup
  and storage facts; the seed image's digest and id; the ids of
  everything the tool seeded; and the exchanges in order, each with its
  request, status, content type and framing.
- `SOURCE.md`: provenance, what was seeded, and the request table.

Every directory records the same exchanges: `_ping` (HEAD and GET),
`/version`, `/info`, the container list with and without sizes, inspect
of each seeded container and of a missing one (404), one-shot and
streamed stats, logs (tail for a TTY and a non-TTY container, a follow
until the container exits, `since`), images, image inspect, networks,
volumes, `/system/df`, a finite `since`/`until` events window, and
`/info` under versions one below the daemon's minimum, one above its
maximum and at the client floor 1.41.

The seeded secrets are fake and low entropy (`fixture-password`).
`capture.sh --docker-api-only` checks a fresh capture against these
directories by structure, never by value; `--update` replaces them.
Review the diff, and run gitleaks over it, before committing.

## Hand-written fixtures

Version claims follow the plan, not live daemons: Docker 29.0 to 29.2
rejected clients below API 1.44, 29.3 lowered the floor to 1.40, and
Podman's compat layer reports max API 1.44, min 1.24.

## Part 2 shapes (klabautermann_docker)

Each file is named for the API version whose shape it records. They were
written by hand from the Engine API reference and the sections named
below, not captured from a host.

| File | Shape | Section |
|---|---|---|
| `containers-1.41.json` | Container list before health and mounts were common | 7.12 CTR-01 |
| `containers-1.44.json` | Container list with health, ports, mounts, compose labels | 7.12 CTR-01 |
| `containers-podman-1.44.json` | Podman compat container list with a quadlet unit label | 7.12 DKE-10 |
| `container-inspect-1.44.json` | Inspect with env secrets, health log and mounts | 7.12 CTR-03, 8.9 |
| `images-1.52.json` | Image list below the 1.51 `Containers` gate | 7.14 IMG-01 |
| `images-1.55.json` | Image list with the `Containers` count and a dangling image | 7.14 IMG-01 |
| `image-inspect-1.55.json` | Image inspect with a masked env secret | 7.14 IMG-01, 8.9 |
| `networks-1.44.json` | Network list with a built-in and a compose network | 7.15 DNW-01 |
| `volumes-1.44.json` | Volume list with labels and options | 7.15 VOL-01 |
| `info-1.55.json` | Engine info with cgroup and logging drivers | 7.12 DKE-01 |
| `info-podman-1.44.json` | Podman engine info, rootless | 7.12 DKE-01 |
| `events-1.52.ndjson` | Event-v2 stream without the legacy fields | 5.6, 7.12 DKE-02 |
| `events-legacy-1.41.ndjson` | Pre-1.52 event stream with `status`, `id`, `from` | 5.6, 7.12 DKE-02 |
| `stats-1.44.json` | One stats sample (one-shot shape) | 5.6, 7.12 CST-01 |
| `stats-stream-1.52.ndjson` | Two stats samples for the client-side delta | 5.6, 7.12 CST-01 |
| `pull-progress-1.44.json` | Concatenated pull progress values | 5.6, 7.14 IMG-03 |
| `compose-ps-1.55.ndjson` | `docker compose ps --format json` lines | 7.16 STK-02 |
| `compose-config-1.55.json` | `docker compose config --format json` | 7.16 STK-01 |
| `compose-version-1.55.json` | `docker compose version --format json` | 7.16 STK-05 |
