# Spike S8: update checks

Spike S8 (04 S8; 03 §7.14 IMG-05, D68) asks how Klabautermann learns
that a tag now points at a different image. It compares three routes:

- a registry manifest `HEAD`;
- the daemon's DistributionInspect (`GET /distribution/{name}/json`);
- the host's Docker CLI for private registries.

It also measures what Docker Hub's `ratelimit-remaining` header says.
What the engine does with the results is D68 in 03.

`run.txt` is the output of `probe.sh --private`, run on 2026-10-27 in a
Linux x86_64 container. The container ran Docker 29.8.2 (API 1.56) on the
containerd image store, with buildx 0.37.1, behind an HTTPS proxy whose
egress rotates across a pool of addresses. The addresses Docker Hub
reported in `docker-ratelimit-source` are replaced by `addr-a`, `addr-b`
and so on, one label per address. The private part made its own
registry, account and random password; no credential is in either file.

## What it shows

1. **A `HEAD` does not spend Docker Hub quota.** Docker Hub counts
   anonymous requests per source address (`ratelimit-limit:
   100;w=3600`). Within one run, repeated `HEAD`s from one address
   reported the same `ratelimit-remaining` each time: `addr-b` stayed at
   57 across six `HEAD`s. DistributionInspect does spend quota: moby
   resolves the tag with a `HEAD` (`distrepo.Tags(ctx).Get`) and then
   fetches the manifest by digest with a `GET` (`Manifests(ctx).Get`;
   `api/server/router/distribution/distribution_routes.go` at v28.5.2),
   and Docker Hub counts that `GET` as a pull. The run did not isolate
   the `GET`'s decrement, because the proxy sent it from an address
   that other traffic also used.
2. **A `HEAD` is refused once the address's quota is spent.** `addr-c`
   and `addr-i` answered `HEAD` with `429` and `ratelimit-remaining: 0`.
   A check from a host behind a shared NAT can therefore fail even though
   it costs nothing.
3. **The window is one hour.** Docker Hub reported `w=3600`, not the six
   hours r5 recorded.
4. **The registry digest is the index digest.** With the usual `Accept`
   list (OCI index, Docker manifest list, Docker v2 manifest, OCI
   manifest), Docker Hub, GHCR and Quay answer a multi-platform tag with
   its index digest. Docker Hub returns the index even when only the v2
   manifest type is accepted.
5. **Each registry has its own token flow.** Docker Hub needs an
   anonymous token from `auth.docker.io`. GHCR's first `HEAD` answers
   `401` with `WWW-Authenticate: Bearer realm=...,service=...,scope=...`,
   and a token from that realm works. Quay answers the first `HEAD`
   anonymously. A `Basic` challenge means the registry needs credentials,
   so the check is private (point 8).
6. **DistributionInspect returns the same index digest.** It also
   returns the platform list (16 for `alpine:3.22`) that a `HEAD` does
   not give.
7. **Comparing against `RepoDigests` alone gives false updates on the
   containerd store.** After a pull, `RepoDigests` and the image's
   `Descriptor` carry the index digest, and that matches the registry.
   `docker push` from the containerd store, with one platform present,
   wrote a single-platform image manifest (`dc92f017…`) to the registry.
   The local `RepoDigests` for that repository still named the index
   (`2e0b81d6…`). `GET /images/{name}/json?manifests=1` (API 1.48 and
   later) lists the index's children. `dc92f017…` is the available amd64
   child.
8. **Private registries go through the host CLI, not the device.** A
   `curl -sI` without credentials gets `401` with `Basic realm=...`.
   DistributionInspect without `X-Registry-Auth` fails with "no basic auth
   credentials", and Klabautermann holds no registry credentials until
   REG-02 (v1.x). `docker buildx imagetools inspect --format '{{json
   .Manifest}}'` reads the CLI's own credential store and returns the
   digest. Its error after a logout shows that it resolves with a `HEAD`.
   `docker manifest inspect` needs `--insecure` for a plain-HTTP
   registry; without it, it says "no such manifest", and with `-v` it
   prints a single manifest's digest. For an index it prints only the
   children: a follow-up run pushed a one-child index
   (`docker manifest create` and `push`, digest `36df10af…`) to a second
   local registry, and `-v` listed the child `dc92f017…` while buildx and
   a `HEAD` both named `36df10af…`.

## What it does not cover

- Docker Hub's counting of authenticated requests (REG-02 is v1.x).
- Podman: `podman manifest inspect` and `skopeo inspect` stay [U] until
  a Podman host check runs them.
- Registries that answer `HEAD` without `Docker-Content-Digest`. The
  distribution spec allows this, and Docker's client then falls back to
  `GET`. None of the three registries tried did it.
