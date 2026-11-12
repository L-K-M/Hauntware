# seance_sync_server

A tiny, self-hostable sync server for Séance. It stores **end-to-end encrypted**
record blobs and resolves conflicts by last-write-wins. It can decrypt nothing:
a full database compromise exposes ciphertext and account metadata, and lets an
attacker guess weak passwords offline (see [Security model](#security-model)).

## Run with Docker

```bash
# from the seance/ directory of a Hauntware clone
docker compose -f packages/seance_sync_server/docker-compose.yml up -d --build
```

Or build the image directly (build context must be `seance/` so the pub
workspace resolves):

```bash
docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .
docker run -p 127.0.0.1:8787:8787 -v seance-data:/data \
  -e SEANCE_OPEN_REGISTRATION=true seance-sync
```

Flip `SEANCE_OPEN_REGISTRATION=true` only long enough to enrol your devices,
then set it back to `false` and restart. Put a TLS-terminating reverse proxy
(Caddy, nginx, Traefik) in front — the server speaks plain HTTP by design.
The compose file and `docker run` example bind the host port to loopback only;
publish it more broadly only behind TLS or on a trusted private network.

To update a running deployment, run `./update.sh` from `seance/`. It builds a
versioned candidate, snapshots the stopped SQLite/WAL files, restarts the old
service, and preflights the candidate against a temporary copy. Only then does
it stop the old service again for a fresh rollback snapshot, replace production,
and require `/readyz`. A failure before candidate startup restores both that
final snapshot and the tagged previous image with its preserved Compose
configuration. Once the candidate may have accepted writes, automatic recovery
instead stops it and retains the unchanged live database plus snapshot for
explicit recovery. It does not start an older image against a potentially
migrated schema or erase writes accepted during the readiness probe. Cleanup
happens only after the candidate is ready; the previous tagged image is retained
for manual rollback too. The updater refuses concurrent runs and keeps its
recovery bundle whenever manual recovery is required.

An uncatchable interruption such as power loss or `SIGKILL` can leave the
updater lock behind. A later run prints the recorded PID, host, user ID and
recovery-bundle path and stops. Check the recorded host and confirm that the
updater and its Docker operations have stopped before removing the lock;
a PID may have been reused, so a failed local PID lookup alone is not proof.
Inspect the running deployment and the bundle's `update-state.txt`, preserved
Compose configuration and snapshots first. A `candidate-may-have-writes`
phase means the candidate could have migrated the database or accepted writes;
preserve the live volume and do not restore an older snapshot automatically.

After completing recovery, remove only `pid`, `host`, `uid` and `recovery-dir`
from the printed lock directory, then remove that empty directory with
`rmdir`. Keep the recovery bundle until its data is no longer needed. Older
locks may contain only `pid`; inspect the deployment and any retained bundles
before removing those too. The default lock is
`${TMPDIR:-/tmp}/seance-sync-update.lock`; `SEANCE_UPDATE_LOCK_DIR` overrides it.

For a real Docker integration check, prebuild a protocol-v1 runtime image, its
`build` stage (with Python3 and SQLite), and the candidate runtime. Then run:

```bash
python3 scripts/test-update-docker.py \
  --old-image seance-updater-old \
  --helper-image seance-updater-old-helper \
  --candidate-image seance-updater-candidate \
  --candidate-ref "$(git rev-parse HEAD)"
```

The harness uses private temporary directories, unique Compose projects and
volumes, loopback-only ephemeral ports, and test-owned image tags. Repository
synchronization and Compose build are intercepted to use those prebuilt images;
server starts, probes, snapshots and SQLite migration are real. It checks a
successful migration and a failure after readiness plus a durable concurrent
write. It retains fixture logs and recovery evidence and removes only its own
Docker resources; it never prunes or changes an existing deployment's image tag.

### Moving from a standalone Séance clone

The standalone `L-K-M/Seance` repository is archived, and its `./update.sh`
now only prints these instructions. Deploy from a Hauntware clone instead. The
compose project name comes from the compose file's directory, so the new clone
reuses the existing container and its `seance-data` volume. Run this from the
directory that contains your `Seance` clone:

```bash
git clone https://github.com/L-K-M/Hauntware.git
if [ -f Seance/packages/seance_sync_server/.env ]; then
  cp Seance/packages/seance_sync_server/.env \
    Hauntware/seance/packages/seance_sync_server/.env
else
  echo "No Seance/packages/seance_sync_server/.env here; continuing without overrides." >&2
fi
cd Hauntware/seance && ./update.sh
```

### Reverse proxy in a container (Nginx Proxy Manager, Traefik, …)

The default `127.0.0.1:8787` publish is only reachable from processes on the
host itself — inside a proxy *container*, `127.0.0.1` is that container, so it
gets connection-refused and serves **502 Bad Gateway**. Publish on the Docker
bridge gateway instead, which only the host and its containers can reach, and
point the proxy at that same address:

```bash
cp packages/seance_sync_server/.env.example packages/seance_sync_server/.env
echo 'SEANCE_PUBLISH_ADDR=172.17.0.1' >> packages/seance_sync_server/.env
./update.sh   # or: docker compose --env-file packages/seance_sync_server/.env \
              #     -f packages/seance_sync_server/docker-compose.yml up -d
```

The `.env` file is gitignored, so updates keep the setting. Use
`SEANCE_PUBLISH_ADDR=0.0.0.0` for every interface (firewall it), or attach the
proxy and this service to a shared Docker network and skip publishing entirely.

### Client addresses behind a reverse proxy

Login, prelogin and registration are rate-limited per source address. Behind a
proxy the server sees the proxy (or Docker's gateway) as the source of every
request, so all your devices share one allowance, and anyone who sends 60
prelogin requests a minute locks every device out of signing in until they
stop. Tell the server which peers may report the real client address:

1. Make the proxy send `X-Forwarded-For`. Caddy, Traefik and Nginx Proxy
   Manager do so by default; plain nginx needs
   `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`.
2. Set `SEANCE_TRUSTED_PROXIES` in `packages/seance_sync_server/.env` to the
   address the server sees the proxy connect from. It takes comma-separated
   IP addresses and CIDR networks, so an address Docker may change when the
   stack is recreated can be covered by its network:

   ```bash
   # Proxy on the host or in another container, reaching the published port:
   # connections arrive from the gateway of this stack's Docker network.
   SEANCE_TRUSTED_PROXIES=172.16.0.0/12,192.168.0.0/16
   ```

   `docker network inspect` shows the subnet Compose chose. An address or
   network that is not a valid IP or CIDR stops the server at startup with a
   message naming the setting, and `/0` is refused.

Trust only peers that cannot be reached by anyone else. Docker's port
publishing relays every connection through the gateway, so trusting it is safe
only while the port is published on `127.0.0.1` or on the bridge gateway (the
setups above), never on `0.0.0.0` without a firewall, where every internet
client would arrive through the gateway and could choose its own rate-limit
key with the header. A header from a peer that is not trusted is ignored.

### Troubleshooting: the app reports a 502

A 502 is never produced by this server — it comes from whatever sits in front
(reverse proxy or CDN) when the sync container doesn't answer. On the host:

```bash
docker compose -f packages/seance_sync_server/docker-compose.yml ps    # running? healthy?
docker compose -f packages/seance_sync_server/docker-compose.yml logs --tail=40
curl -i "http://$(docker compose -f packages/seance_sync_server/docker-compose.yml \
  port seance-sync 8787)/healthz"                                      # expect: ok
```

If `/healthz` answers on the host but the proxy still serves 502, the proxy is
pointing somewhere the port isn't published (see the section above).

## Run without Docker

```bash
dart pub get
dart run packages/seance_sync_server/bin/seance_sync_server.dart \
  --port 8787 --db ./seance.sqlite --open-registration
# or compile a native binary:
dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart -o seance-sync
./seance-sync --help
```

SQLite mode needs `libsqlite3` at runtime (`libsqlite3-0` on Debian/Ubuntu).
Omit `--db` for an ephemeral in-memory store.

## Configuration

| Env var | CLI flag | Default | Meaning |
|---|---|---|---|
| `SEANCE_BIND` | `--bind` | `0.0.0.0` | Bind address |
| `SEANCE_PORT` | `--port` | `8787` | Listen port |
| `SEANCE_DB_PATH` | `--db` | *(in-memory)* | SQLite file path |
| `SEANCE_OPEN_REGISTRATION` | `--open-registration` | `false` | Allow `/v1/register` |
| `SEANCE_LOGIN_MAX_ATTEMPTS` | — | `10` | Login attempts per window |
| `SEANCE_LOGIN_WINDOW_SECONDS` | — | `60` | Rate-limit window |
| `SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS` | — | `1000` | Auth requests across all sources per global window |
| `SEANCE_AUTH_GLOBAL_WINDOW_SECONDS` | — | `60` | Global auth window |
| `SEANCE_AUTH_SOURCE_MAX_ATTEMPTS` | — | `60` | Auth requests per network source per source window |
| `SEANCE_AUTH_SOURCE_WINDOW_SECONDS` | — | `60` | Source auth window |
| `SEANCE_RATE_LIMIT_MAX_BUCKETS` | — | `4096` | Maximum keyed buckets per limiter before overflow sharing |
| `SEANCE_TRUSTED_PROXIES` | — | *(empty)* | Comma-separated proxy IPs or CIDR networks allowed to supply `X-Forwarded-For` (see [Client addresses behind a reverse proxy](#client-addresses-behind-a-reverse-proxy)) |
| `SEANCE_SESSION_TTL_SECONDS` | — | `2592000` | Bearer-session lifetime (30 days) |
| `SEANCE_MAX_SESSIONS_PER_ACCOUNT` | — | `20` | Active sessions retained per account, evicting least recently used |
| `SEANCE_MAX_RECORDS_PER_PULL` | — | `1000` | Records or inbox items returned per page |
| `SEANCE_MAX_PULL_BODY_BYTES` | — | `8388608` | Maximum encoded JSON bytes per record or inbox page |
| `SEANCE_MAX_RECORDS_PER_ACCOUNT` | — | `5000` | Live records (deletions do not count) and, separately, pending inbox items per account |
| `SEANCE_MAX_ACCOUNT_BYTES` | — | `41943040` | Encoded record bytes, deletions included, and, separately, inbox-item bytes per account |

## API (protocol v4)

Request and response bodies are JSON. Registration, login, and push carry a
`protocolVersion`, so an old client and new server reject a breaking account or
record write before changing storage.

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /healthz` | — | Liveness check |
| `GET /readyz` | — | Storage readiness check |
| `POST /v1/register` | — | Create an account, returns a bearer token |
| `POST /v1/prelogin` | — | Return the KDF salt/params for a username |
| `POST /v1/login` | — | Exchange the auth verifier for a token |
| `GET /v1/sync?since=<seq>` | Bearer | Legacy full pull of records newer than a sequence number |
| `GET /v1/sync?since=<seq>&page=1[&through=<seq>]` | Bearer | Bounded pull from a stable watermark |
| `PUT /v1/records` | Bearer | Push a batch of encrypted records (LWW) |
| `GET /v1/records/legacy[?after=<id>]` | Bearer | Read a bounded page of legacy rows for migration |
| `PUT /v1/records/legacy` | Bearer | Replace exact observed legacy rows and finalize the account envelope floor |
| `DELETE /v1/session` | Bearer | Revoke the current session |
| `GET /v1/sessions` | Bearer | List active sessions and public device metadata |
| `DELETE /v1/sessions/current` | Bearer | Alias for revoking the current session |
| `DELETE /v1/sessions` | Bearer | Revoke every session for the account |
| `DELETE /v1/sessions/<id>` | Bearer | Revoke one opaque session id owned by this account |
| `PUT /v1/account/vault-key-check` | Bearer | Initialize an empty legacy account's encrypted key check once |
| `DELETE /v1/account` | Bearer | Delete the account and all its data |

The server returns a raw bearer token only once and stores its SHA-256 digest.
Sessions expire after the configured lifetime and issuing a session beyond the
per-account cap revokes the least recently used one. Last-use timestamps update
at most hourly and never extend expiry. Upgrading from protocol v1 deliberately
invalidates legacy plaintext token rows, so each device must sign in once. The
protocol bump prevents an older client or server from partly creating an
account without the registration-time encrypted vault-key check.
An already enrolled device may initialize that check for an empty legacy
account; the official client requires its locally persisted vault key to match
before calling the set-once endpoint. New devices cannot silently choose one.

Current clients write authenticated v2 record envelopes. Protocol v4 migrates
legacy rows by exact compare-and-swap using independently authenticated local
state. Unmatched legacy rows remain held; an unauthenticated old tombstone
cannot authorize deletion. The account floor advances only when no legacy row
remains, and clients persist that floor to reject downgrade or replay.

Pending inbox items also have a 32 MiB raw-blob cap and a 5,000-item cap across
all apps, in addition to the encoded-byte quota above and each app's 100-item
cap. The 50-app registration cap is checked atomically with insertion.

Registration and login may supply `X-Seance-Device-Id` and
`X-Seance-Device-Name` together. Both are limited to 128 UTF-8 bytes; ids use
ASCII letters, digits, `.`, `_`, `:`, or `-`, and names cannot contain control
or invisible formatting characters or surrounding whitespace. A malformed pair
returns `400 bad_device`. Older clients may omit both and receive an unlabeled
session. Signing in again with the same device id rotates that device's earlier
session within this account generation.

Session listings contain opaque ids, device labels, creation/expiry/last-use
timestamps, and `legacy`/`current` flags. They expose no bearer token or digest.
Selective revocation returns `{"revoked":true,"current":false}` (or `true` for
the current flag when revoking yourself); a missing or foreign id is
`404 not_found`. Listing and revocation revalidate the caller's account
generation and live session inside the storage transaction. Existing current
and all-session revocation endpoints retain their `204` responses.

Register, prelogin and login run before any authentication, so they read at
most 16 KiB of request body (less if `SEANCE_MAX_BODY_BYTES` is lower) and
answer a larger one with 413 `payload_too_large`; only a push gets the full
body cap. A username is 1 to 256
bytes of UTF-8 on every route, and registration also refuses control
characters (C0, DEL, C1) and invisible format characters (zero-width and bidi
marks, soft hyphen, byte-order mark); either failure is a 400 `bad_username`.
Login and prelogin skip the character check, so an account registered before
it existed keeps working as long as its name is 1 to 256 bytes. Registration also requires a 32-byte auth verifier and
an Argon2 salt of at least 16 bytes.

### Sync transaction semantics

A push resolves LWW, allocates sequences and commits all accepted records in one
storage transaction. Entries run in list order, including repeated ids; empty
batches return the current watermark. An LWW rejection is a per-record result,
not a batch failure. Existing request limits apply before storage: by default,
1,000 records, 1 MiB per blob and 8 MiB per request body. All three are
env-tunable, so every pull response advertises them under `limits`
(`maxBodyBytes`, `maxRecordsPerPush`, `maxBlobBytes`) and a client can split a
large push into requests this deployment accepts instead of having one
oversized request rejected whole, every round. The blob cap is advertised for
a different reason than the other two: a record past it cannot be batched into
compliance at all, and it is refused with a 413 for the *whole* push — so a
client that does not know the cap batches such a record beside records the
server would have taken and loses all of them, identically every round. Knowing
it, the client sends that record alone and last, and the failure stays with the
one record that caused it. Falling back has two shapes, and the second is the
easy one to miss: a client that sees no `limits` at all is talking to a server
older than the field, but a client whose server advertises only `maxBodyBytes`
and `maxRecordsPerPush` — every deployment predating `maxBlobBytes` — falls
back for the blob cap alone, since an absent field takes its default. Either
way the defaults match that server only if it also ran with them. So a
deployment with `SEANCE_MAX_BLOB_BYTES` tuned below 1 MiB keeps losing whole
pushes until the *server* is upgraded too: a new client cannot learn a cap the
old one never sends, and upgrading only the clients does not unstick it.
Invalid values for these three caps — unlike this server's other settings —
abort startup with an error naming the variable, rather than silently falling
back to the default; an unset or empty variable still means "use the default".
A database failure rolls back the batch and its sequence changes. A lost HTTP
reply can still follow a successful commit; clients must reconcile by pulling.

An explicit `page=1` pull is capped by both `SEANCE_MAX_RECORDS_PER_PULL` and
the exact compact-JSON size in `SEANCE_MAX_PULL_BODY_BYTES`. Its first response
captures `throughSeq`; continuations send that value as `through`, advance
`since` only to the last record they observed, and use `hasMore` to decide
whether to continue. Records written after the captured watermark wait for the
next sync window. A single stored row that cannot fit the configured page is a
rejected before it is committed; an incompatible row left by an older build is
reported as a server configuration error rather than returned without a bound.
Omitting `page=1` retains the full-response shape for already enrolled clients.
If the pull-page cap is tighter than the request cap, the server advertises a
smaller effective push-body limit. Current clients then send a record that
cannot fit a page by itself, so its `413` does not hold back valid neighbours.

Record pushes enforce the per-account count and encoded-byte ceilings in the
same transaction as LWW resolution and sequence allocation. Inbox deposits use
the same configured ceilings independently, so producer traffic cannot consume
the record catalog's budget; inbox listing returns the same stable page
metadata. A write that would exceed either ceiling changes nothing. An account
already beyond a newly lowered ceiling may replace or delete data only when the
over-limit dimension does not grow, allowing it to shrink back under the cap.

SQLite uses `BEGIN IMMEDIATE` for writes and a read transaction for snapshots.
Transaction lock contention returns `503 storage_busy` without committing the
batch; retry later. There is no synchronous wait or non-atomic fallback.
If transaction cleanup itself fails, SQLite storage fails closed and returns
`503 storage_unavailable` for the triggering and subsequent storage requests.
Diagnostics retain the original cause and log only exception types/SQLite numeric
codes—not messages, SQL, parameters or blobs. Restart after investigating the
database failure; automatic reopen could
silently replace an injected or in-memory database. `/healthz` reports only
process liveness; `/readyz` performs a real storage access and returns 503 when
the backend is busy or unavailable. Deployment health checks use `/readyz`.
Closing the disabled connection is safe to repeat.
The memory backend stages batches without yielding, then swaps state together.

Custom server `Storage` implementations must implement `pushRecords` and
`pullSnapshot` with these guarantees. The older primitives remain for source
compatibility with callers, but must not be composed into sync operations. Wire
DTOs and the database schema are unchanged; this is not an account migration.

## Security model

- The client derives an auth verifier from the account password and a vault
  key from the encryption passphrase (Argon2id, then HKDF with separate
  labels). Only the verifier reaches the server, which stores a salted SHA-256
  hash of it, so a copy of the database cannot be replayed to sign in. It does
  let an attacker guess the password offline: each guess costs one Argon2id
  run with the account's parameters, which slows guessing but does not stop it
  for a weak or common password. A compromised server sees the raw verifier at
  every sign-in and can guess the same way.
- When the account password and the encryption passphrase are the same
  string, both keys come from the same Argon2id result, so a guessed password
  also opens every record. A separate, strong encryption passphrase keeps the
  records sealed even if the password is guessed.
- Record payloads are sealed client-side with XChaCha20-Poly1305. The server
  stores `nonce ‖ ciphertext ‖ mac` and never holds a key.
- Registration, prelogin and login have global and network-source limits.
  Failed logins also have an account limit; a correct verifier remains usable.
  Forwarded addresses are accepted only from configured proxy addresses or
  CIDR networks, including equivalent IPv4-mapped IPv6 addresses. Malformed or
  oversized forwarding chains fall back to the immediate peer.
- Active limiter buckets are never evicted. When all keyed buckets are active,
  unseen keys share a bounded overflow bucket, so saturation can temporarily
  throttle new clients. Set the global/source budgets and bucket capacity for
  your deployment; refusals return `Retry-After`.
- Conflict resolution is deterministic last-write-wins keyed by
  `(updatedAt, deviceId)`, identical to the client, so both sides agree.

## Tests

```bash
dart test packages/seance_sync_server
```

Covers the endpoints (register/prelogin/login/push/pull/delete, auth, rate
limiting, protocol-version and open-registration gating), the SQLite backend
(round-trips + durability across reopen), and a full end-to-end run of the real
client against a live server with two devices converging. Atomic-sync regressions
force stale-write and watermark races over HTTP, a separate-connection SQLite
commit during a pull, and a late batch-write failure followed by reopen/retry.
