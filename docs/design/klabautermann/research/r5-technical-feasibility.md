# R5: Technical feasibility of a server-management and Docker app over SSH

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Date: 2026-10-10. Scope: a fourth Hauntware app that reuses the synced
`ServerConfig` list and the shared `seance_core` SSH layer (dartssh2 3.0.2) to
provide host observability/management and Docker/Podman management.

Verification legend used throughout:

- **[V-src]** verified by reading source code (file named).
- **[V-doc]** verified against official documentation or a spec (URL in Sources).
- **[V-repo]** verified in the Hauntware repository.
- **[U]** unverified: prior knowledge or secondary sources only. Treat as a
  hypothesis to confirm in a spike.

---

## 0. Executive summary

1. **The Docker Engine API is reachable without installing anything on the
   server.** dartssh2 3.0.2 has `SSHClient.forwardLocalUnix(path)`, which opens
   an OpenSSH `direct-streamlocal@openssh.com` channel straight to
   `/var/run/docker.sock` **[V-src]**. OpenSSH allows this by default
   (`AllowStreamLocalForwarding yes`, `DisableForwarding` not set) **[V-doc]**.
   It is blocked by `AllowStreamLocalForwarding no|remote`, `DisableForwarding
   yes`, or an authorized_keys `restrict`/`no-port-forwarding` key option
   **[V-src: serverloop.c]**. Fallback: exec `docker system dial-stdio`, which is
   exactly what `docker -H ssh://` runs **[V-src: docker/cli connhelper.go]**.
2. **dartssh2 covers the needed SSH primitives**, but its bundled
   `SSHHttpClient` cannot be used. It dials TCP only and has no
   hijack/upgrade support **[V-src]**. Hauntware needs its own HTTP/1.1 layer over
   `SSHForwardChannel`. One option is a small custom client. The other is
   `dart:io` `HttpClient` with a `connectionFactory` and a user-implemented
   `Socket` adapter, plus `HttpClientResponse.detachSocket()` for hijacked
   exec/attach. `Socket` is an `abstract interface class`, so user code can
   implement it **[V-doc]**. Never expose the socket through a local TCP
   listener, because docker.sock is root-equivalent.
3. **API versioning is a real compatibility hazard.** Docker 29.0-29.2
   rejected clients below API 1.44. Docker 29.3 lowered the floor back to 1.40
   **[V-doc via release notes summary]**. The current spec is v1.55 (Docker 29.8)
   and v1.56 on master. Podman's compat layer reports max 1.44 / min 1.24
   **[V-src: podman version.go]**. Recommendation: negotiate via `/_ping`
   (`Api-Version` header) and `/version` (`MinAPIVersion`), baseline the client
   on **v1.44**, and feature-gate newer fields. Several fields changed shape in
   v1.52/v1.53 (events, system df, NetworkSettings).
4. **Compose has no Engine API.** Stacks are discovered from container labels
   (`com.docker.compose.project`, `.project.working_dir`,
   `.project.config_files`, `.config-hash`, ...) **[V-src: compose pkg/api/labels.go]**.
   Files are edited over SFTP and `docker compose` runs over exec. Compose is
   now v5.x (v5.6.0, 2026-10-02) **[V-doc]**.
5. **Agentless metrics are entirely feasible** from `/proc`, `/sys` and standard
   CLIs. JSON output exists for `systemctl list-units/list-timers/...` since
   **systemd v246** **[V-src: systemctl.c at tag v246 vs v245]**. `systemctl
   show` still has no JSON (issue #39081 open) **[V-doc]**. `journalctl -o json`
   has a documented format **[V-doc]**. `lsblk/findmnt --json` exist since
   util-linux 2.27, `smartctl -j` since 7.0, `sensors -j` since 3.5.0, `ip -j`
   is available, and `ss` has no JSON **[V-doc / V-src man page]**.
6. **Transport recommendation:** one SSH connection per server, carrying one
   persistent non-PTY `sh` exec "sampler" channel that emits framed samples,
   plus on-demand channels for logs, exec and Docker streams. OpenSSH
   `MaxSessions` (default 10) counts shell/exec/subsystem sessions but **not**
   forwarding channels **[V-doc]**, so Docker API streams do not consume the
   session budget. ServerBox does almost exactly this: an uploaded script run
   through a persistent `sh` session, falling back to exec-per-poll, default
   3 s **[V-src: flutter_server_box]**.
7. **Privilege:** the `docker` group is root-equivalent per Docker's own docs
   **[V-doc]**. Journal access needs `systemd-journal`, `adm` or `wheel`
   **[V-doc]**. `sudo -n` / `-S` exist in both sudo and sudo-rs (Ubuntu
   25.10+ default); sudo-rs has `-A` only from 0.2.11, and Ubuntu 25.10 ships
   0.2.8 **[V-doc / V-src]**. A Cockpit-style explicit
   "administrative access" mode is the right UX model.
8. **Anything that must happen while no client is open needs a resident
   component**: alerts, history beyond the app session, scheduled jobs. The
   Hauntware sync server cannot hold SSH credentials without breaking its
   documented "never sees a key" trust model **[V-repo: seance/AGENTS.md,
   docs/INBOX.md]**. The model-preserving path is an **optional on-host agent
   that evaluates rules locally and deposits sealed alerts**, reusing the Inbox
   "producer" pattern. iOS push for a self-hosted server needs a
   publisher-operated relay, as ntfy does **[V-doc]**. Mobile background polling
   cannot substitute: iOS gives ~30 s per refresh at system-chosen times, and
   WorkManager's minimum period is 15 min **[V-doc / V-src]**.
9. **Security:** redact env/inspect secrets in the UI, keep a synced audit log
   of destructive actions, require typed confirmation for irreversible
   operations, and send registry credentials per request (`X-Registry-Auth`).
   Treat on-server scanners as untrusted supply chain: Trivy v0.69.4 was
   backdoored in March 2026 (CVE-2026-33634) **[V-doc: secondary security
   advisories, multiple vendors]**.

---

## 1. Docker Engine API access over SSH

### 1.1 Transport options

| Option | How | Remote requirements | Notes |
|---|---|---|---|
| **A. Unix-socket forward (preferred)** | `client.forwardLocalUnix('/var/run/docker.sock')` opens a `direct-streamlocal@openssh.com` channel | OpenSSH >= 6.7 with streamlocal allowed. The SSH user must be able to `connect()` to the socket (root or `docker` group) | No remote process. Works with Podman/rootless sockets by path. Forwarding channels do not count against `MaxSessions` |
| **B. `docker system dial-stdio` over exec** | `client.execute('docker system dial-stdio')` and speak HTTP over stdin/stdout | docker CLI installed remotely | Exactly what `docker -H ssh://` does. Each connection spawns a CLI process and counts as a session |
| **B'. Podman** | `podman system dial-stdio` | podman CLI | Exists in podman main (`cmd/podman/system/dial_stdio.go`, "Should not be invoked manually") **[V-src]** |
| **C. Generic relays** | `socat STDIO UNIX-CONNECT:/var/run/docker.sock`, `nc -U` | socat/netcat with Unix support | Useful when streamlocal is disabled and no docker CLI is present (rare) **[U]** |
| **D. sudo variants** | `sudo -n docker system dial-stdio` | sudoers rule | For users outside the docker group. Root-equivalent anyway (Section 4) |
| **E. TCP 2375/2376** | `forwardLocal('127.0.0.1', 2375)` | daemon listening on TCP | Discouraged. Unauthenticated TCP is a well-known root hole. Only for users who already run it |

**OpenSSH protocol.** PROTOCOL section 2.4 defines the channel-open as
`string "direct-streamlocal@openssh.com"`, sender channel, window, max
packet, `string socket path`, `string reserved`, `uint32 reserved`. The
client sends an empty string for the reserved field **[V-doc: openssh-portable
PROTOCOL]**. dartssh2 encodes exactly this
(`SSH_Message_Channel_Open.directStreamLocal`, `msg_channel.dart`: path, `''`,
`0`) **[V-src]**. Unix-socket forwarding arrived in OpenSSH 6.7 **[V-doc:
release-6.7]**.

**Server-side gates** (sshd_config(5), OpenBSD-current 2026-09-17 **[V-doc]**,
plus `serverloop.c:server_request_direct_streamlocal` **[V-src]**):

- `AllowStreamLocalForwarding`: default `yes` (`all|no|local|remote`). `local`
  or `yes` is needed for direct-streamlocal.
- `AllowTcpForwarding`: default `yes`. Irrelevant to streamlocal, but relevant
  to option E.
- `DisableForwarding`: off unless set. When set it "overrides all other
  forwarding-related options".
- In source, the check is `(allow_streamlocal_forwarding & FORWARD_LOCAL) &&
  auth_opts->permit_port_forwarding_flag && !disable_forwarding`. An
  authorized_keys `restrict` or `no-port-forwarding` option therefore also
  blocks streamlocal, even though sshd(8) only describes them as port
  forwarding options.
- `ForceCommand` does **not** block forwarding ("does not limit other kinds of
  access") **[V-doc]**.
- sshd opens the socket as the authenticated user (privsep child), so normal
  Unix permissions on `docker.sock` (root:docker 0660) apply. Failure surfaces
  as `SSH_MSG_CHANNEL_OPEN_FAILURE`, which dartssh2 throws as
  `SSHChannelOpenError(reasonCode, description)` **[V-src: ssh_client.dart
  `_waitChannelOpen`]**.

**Dropbear** (common on embedded/OpenWrt/some NAS):

- Server-side Unix stream forwarding was added in **2024.84** (2024-04-04).
- CVE-2025-14282 (2024.84-2025.88) let forwarded Unix connections appear as
  root via `SO_PEERCRED`. 2025.89 (2025-12-16) fixed it by dropping privileges
  after auth. It also disallows Unix stream forwarding when a forced command
  is used **[V-src: dropbear CHANGES]**.
- Current release: 2026.94 (2026-07-23).
- Practical rule: on Dropbear < 2024.84, use option B. On 2024.84-2025.88,
  warn about the CVE.

**Detection algorithm (proposed):**

1. Try streamlocal to each candidate path:
   - `$DOCKER_HOST`, if the user configured one in Hauntware
   - `/var/run/docker.sock`
   - `/run/user/<uid>/docker.sock` (rootless Docker)
   - `/run/podman/podman.sock`
   - `/run/user/<uid>/podman/podman.sock`
2. Interpret the result:
   - Any streamlocal open failure from OpenSSH is `SSH_OPEN_CONNECT_FAILED`
     "open failed": `server_request_direct_streamlocal` returns no reason or
     message, so `server_input_channel_open` sends its defaults
     **[V-src: serverloop.c, channels.c `connect_to`]**. Probe with exec:
     `test -S path` fails means missing; `test -w path` fails means
     `EACCES`; both succeed means forwarding is disabled
     (`AllowStreamLocalForwarding`, `DisableForwarding`,
     `restrict`/`no-port-forwarding`) or a stale socket with no listener.
     Fall back to exec.
3. Get `<uid>` from `id -u` over exec, which is also needed for rootless paths.

### 1.2 What dartssh2 3.0.2 supports (verified in the published archive)

The archive was fetched from `https://pub.dev/api/archives/dartssh2-3.0.2.tar.gz`.
Its sha256 is `fdc8e5e4...3c24`, which matches the hash pinned in the
repository's `pubspec.lock` files **[V-repo]**.

| Capability | API (dartssh2 3.0.2) | Status / caveats |
|---|---|---|
| Unix-socket local forward | `Future<SSHForwardChannel> forwardLocalUnix(String remoteSocketPath)` | Added in 2.14.0 (2026-03-19, #140) **[V-src CHANGELOG]** |
| TCP local forward | `forwardLocal(String remoteHost, int remotePort, {localHost, localPort})` (`direct-tcpip`) | Supported. Already used by `seance_core` **[V-repo]** |
| Remote TCP forward | `forwardRemote({host, port, filter})` / `cancelForwardRemote` | Supported. No `streamlocal-forward@openssh.com` (remote Unix) support **[V-src: no matches]**, which is not needed here |
| SOCKS5 dynamic forward | `forwardDynamic(...)` | `dart:io` platforms only |
| Exec | `execute(command, {SSHPtyConfig? pty, SSHX11Config? x11, Map<String,String>? environment})` returns `SSHSession` | PTY is optional (default none for `execute`) |
| Convenience exec | `run(...)`, `runWithResult(...)` returns stdout, stderr, `exitCode`, `exitSignal` | 3.0.1 fixed hangs on stream errors |
| Shell | `shell({pty = const SSHPtyConfig(), ...})` | Default PTY `xterm-256color` 80x24 |
| Env vars | `environment:` sends `env` requests | **If the server rejects any env request, `execute` closes the channel and throws `SSHChannelRequestError`** **[V-src]**. OpenSSH accepts no env vars by default (`AcceptEnv` empty) **[V-doc]**; Debian ships `AcceptEnv LANG LC_*` **[U]**. Prefix commands instead (`LC_ALL=C cmd`) |
| Window change | `SSHSession.resizeTerminal(width, height, [pixelWidth, pixelHeight])` | Supported |
| Signals | `SSHSession.kill(SSHSignal)` with ABRT, ALRM, FPE, HUP, ILL, INT, KILL, PIPE, QUIT, SEGV, TERM, USR1, USR2 | OpenSSH >= 7.9 delivers via `killpg` to the session's process group, but refuses for forced-command and subsystem sessions **[V-src: session.c; V-doc release-7.9]** |
| Exit status | `exitCode`, `exitSignal`, `waitForExit({timeout})` (2.21.0) | Supported |
| Half-close (EOF) | Closing the sink sends `SSH_MSG_CHANNEL_EOF` while still reading **[V-src: ssh_channel.dart `_uploadLoop`/`_sendEOFIfNeeded`]** | Needed for hijacked exec stdin EOF and dial-stdio |
| SFTP | `sftp()` returns `SftpClient` (SFTPv3, `posix-rename@openssh.com` since 2.19.0). 3.0.2 fixed short-read data loss | Already used by Poltergeist/Séance **[V-repo]** |
| Keepalive | `keepAliveInterval` (default 10 s), sends `keepalive@openssh.com` with want-reply | Supported. Overlap fix in 2.22.1 |
| Flush | `SSHChannel/SSHSession/SSHForwardChannel.flush()` (2.22.2) | Useful for interactive exec |
| Handshake/auth timeouts | `handshakeTimeout`, `authTimeout` (2.22.0) | Supported |
| Compression | Only `none` is offered **[V-src: ssh_transport.dart]** | No SSH zlib. Keep sample payloads small |
| Window/packet | initial window 2 MiB, max packet 32 KiB **[V-src]** | Adequate for log streaming |
| Bundled HTTP | `SSHClient.httpClient()` returns `SSHHttpClient` | **Not usable for Docker**: it dials `forwardLocal(uri.host, uri.port)` (TCP only) **[V-src: http_client.dart:141]**, is "very basic", and has no upgrade/hijack. Chunked decoding exists (2.19.0) |

**Repository integration.** `seance_core`'s `SshSession` exposes
`runCommand(...)` with output caps and timeouts, `openRemoteFileSystem(...)`,
jump-host routing and a session manager **[V-repo:
seance/packages/seance_core/lib/src/ssh/ssh_session.dart]**. It does not yet
expose Unix-socket forwarding: no `forwardLocalUnix` call exists in the repo
**[V-repo]**. The new app needs a small, reviewed addition such as
`SshSession.openUnixStream(path)` returning a domain type, not a raw dartssh2
object (AGENTS.md boundary rules). Long-running exec streams (sampler,
`journalctl -f`) also need a streaming counterpart to `runCommand`.

### 1.3 HTTP/1.1 over the forwarded stream

Two viable designs:

1. **Custom minimal client over `SSHForwardChannel`** (`stream`/`sink`):
   - Required features: request writer, status line and header parser,
     `Content-Length` and chunked bodies, NDJSON line streaming, raw-stream
     hand-off after `101 UPGRADED`/`200` for hijacked endpoints, and
     keep-alive reuse for non-streaming calls.
   - About 500-800 lines of pure Dart. Fully testable and host-neutral, and it
     fits the AGENTS.md rule that UI must use services.
2. **`dart:io` `HttpClient`**:
   - Set `connectionFactory` to return
     `ConnectionTask.fromSocket(Future<Socket>, onCancel)` **[V-doc]**.
   - The `Socket` is a user implementation over the channel (`Socket` is
     `abstract interface`, so it can be implemented **[V-doc]**).
   - Use `HttpClientResponse.detachSocket()` for upgrades **[V-doc]**.
   - The docs' own example uses `connectionFactory` to reach
     `/var/run/docker.sock` locally **[V-doc]**.
   - Risk: `Socket` has many members (address, port, `setOption`,
     `setRawOption`). Whether `HttpClient` handles Docker's `101 UPGRADED` plus
     `detachSocket` cleanly is **[U]**.

Recommendation: start with design 1. It is small, deterministic, and avoids
depending on undocumented `HttpClient` behaviour.

**Do not** bridge through a local `ServerSocket` on 127.0.0.1. On desktop any
local process could then reach a root-equivalent API. If a local endpoint is
ever needed (for example to let a user's own `docker` CLI use the tunnel), use
a 0600 Unix socket in a private directory and make it explicit.

Use any `Host` header (Docker CLI uses `http://docker.example.com` **[V-src:
connhelper.go]**). Open **one forwarded channel per concurrent request or
stream**. Keep one pooled keep-alive channel for short calls, and give
`logs?follow`, `stats?stream`, `events`, attach and exec each their own
channel.

### 1.4 Version negotiation

- `GET|HEAD /_ping` returns header `Api-Version` (max supported) plus
  `Builder-Version`, `Docker-Experimental` and `Swarm` **[V-doc: v1.55 spec]**.
  Podman also returns `Libpod-API-Version`, and its `/_ping` is never versioned
  **[V-src: podman version/version.go comment]**.
- `GET /version` returns `ApiVersion` and `MinAPIVersion`.
- Versioned paths `/v1.xx/...` are required in practice. "Using the API
  without a version-prefix is deprecated and will be removed". An unsupported
  version gets HTTP 400 **[V-doc: spec description]**.
- The open schema means clients must ignore unknown fields **[V-doc]**.
- Current state:
  - Docker Engine 29.9.0 (2026-10-08) is the newest release **[V-doc]**.
  - The version matrix lists 29.3-29.8 as max 1.54/1.55, min 1.40.
  - The spec on moby master is **1.56** **[V-src: swagger.yaml]**.
  - Docker 29.0-29.2 had min 1.44. 29.3.0 (2026-03-05) lowered it to 1.40
    (moby#52067) **[V-doc via search summary of release notes; U for exact
    PR number]**.
  - Podman compat: current **1.44**, min 1.24. Libpod tree: current = Podman
    version, min 4.0.0 **[V-src]**.
  - Latest Podman: v6.1.3 (Latest) and v5.8.8, both 29 Sep 2026 **[V-doc:
    GitHub releases]**.
- **Plan:** `negotiated = min(clientMax, serverApiVersion)`. Refuse with a clear
  message if `negotiated < server MinAPIVersion` or below the client floor.
  Client floor is 1.41 (Docker 20.10) and client baseline is 1.44 [design
  choice].

API changes v1.48-v1.56 that matter (from the official version history
**[V-doc]**):

- v1.48:
  - `error`/`progress` in pull/push/build streams are deprecated. Use
    `errorDetail`/`progressDetail`.
  - `Descriptor`/`ImageManifestDescriptor` are populated only with a
    multi-platform (containerd) image store.
- v1.50: image inspect drops always-empty `Config` fields.
- v1.51: `/images/json` `Containers` becomes a real count.
- v1.52:
  - `/events` drops legacy `status`, `id`, `from`. Use `Type`, `Action`,
    `Actor`.
  - Content negotiation: `application/x-ndjson` or `application/json-seq`.
  - Container inspect removes legacy top-level `NetworkSettings.IPAddress`
    etc. Use `NetworkSettings.Networks`.
  - `/system/df` gains `ImagesUsage`/`ContainersUsage`/`VolumesUsage`/
    `BuildCacheUsage` plus `verbose=1`.
  - `/containers/{id}/stats` adds `os_type`.
- v1.53: legacy `/system/df` fields are removed. `/events` supports
  `application/jsonl`.
- v1.55: `GET /images/{name}/attestations` (in-toto statements).
- v1.56: `annotation` filter on `/containers/json` and `HostConfig.Umask` on
  create.

### 1.5 Endpoint map for the feature set

All paths are present in the v1.55 spec **[V-src: v1.55.yaml, 109 operations]**:

| Feature | Endpoint(s) | Notes |
|---|---|---|
| List / filter containers | `GET /containers/json?all=1&size=0&filters={...}` | `size=1` is expensive. Load sizes lazily |
| Inspect | `GET /containers/{id}/json` | Contains `Config.Env` in plaintext. Redact (Section 6) |
| Create / recreate | `POST /containers/create?name=`; `POST /containers/{id}/update` (resources, restart policy) | "Edit" of image/env/ports means recreate, as Portainer/Dockhand do. Update covers only resources/restart |
| Lifecycle | `POST /containers/{id}/start\|stop?t=\|restart?t=\|kill?signal=\|pause\|unpause`, `POST /containers/{id}/rename?name=`, `DELETE /containers/{id}?v=&force=` | `v=1` deletes anonymous volumes. Require confirmation |
| Wait | `POST /containers/{id}/wait?condition=` | For "run once" jobs |
| Processes | `GET /containers/{id}/top?ps_args=` | Runs `ps` in the container's namespace host-side |
| Filesystem diff / copy | `GET /containers/{id}/changes`, `GET\|PUT\|HEAD /containers/{id}/archive?path=` | tar streams. Enables a container file browser |
| Logs | `GET /containers/{id}/logs?stdout=1&stderr=1&follow=&since=&until=&timestamps=&tail=` | Section 1.6 |
| Stats | `GET /containers/{id}/stats?stream=&one-shot=` | Section 1.7 |
| Exec | `POST /containers/{id}/exec`, `POST /exec/{id}/start`, `POST /exec/{id}/resize?h=&w=`, `GET /exec/{id}/json` | Section 1.8 |
| Attach | `POST /containers/{id}/attach?stream=1&stdin=1&stdout=1&stderr=1&logs=` (also `/attach/ws`) | Hijacked |
| Events | `GET /events?since=&until=&filters=` | Section 1.9 |
| Images | `GET /images/json`, `POST /images/create?fromImage=&tag=&platform=`, `GET /images/{name}/json`, `GET /images/{name}/history`, `POST /images/{name}/tag`, `DELETE /images/{name}?force=&noprune=`, `POST /images/prune`, `GET /images/search`, `POST /images/{name}/push`, `GET /images/{name}/get`, `POST /images/load` | Pull progress is streamed JSON objects (`CreateImageInfo`: `id`, `status`, `progressDetail`, `errorDetail`) |
| Update checks | `GET /distribution/{name}/json` | Section 1.10 |
| Volumes | `GET /volumes`, `POST /volumes/create`, `GET\|DELETE /volumes/{name}`, `POST /volumes/prune` | Volume browsing needs a helper container or host paths (`Mountpoint`, root only) |
| Networks | `GET /networks`, `GET\|DELETE /networks/{id}`, `POST /networks/create`, `POST /networks/{id}/connect\|disconnect`, `POST /networks/prune` | |
| System | `GET /info`, `GET /version`, `GET /system/df`, `POST /build/prune`, `POST /containers/prune` | `system df` is slow on large hosts. Call it on demand |
| Swarm (optional) | `/services`, `/tasks`, `/nodes`, `/secrets`, `/configs`, `/swarm` | Defer |

### 1.6 Log stream format

- With TTY off, the stream is multiplexed. Each frame starts with an 8-byte
  header `{STREAM_TYPE, 0, 0, 0, SIZE1..SIZE4}`, where type 0=stdin (written
  on stdout), 1=stdout, 2=stderr, and SIZE is a big-endian uint32, followed by
  the payload. With TTY on, the stream is raw PTY bytes **[V-doc: attach
  section, v1.55]**.
- The spec's logs response text says it "does not upgrade the connection and
  does not set Content-Type", but that text is stale. From API 1.42 the logs
  endpoint sets `Content-Type` to `application/vnd.docker.multiplexed-stream`
  or `application/vnd.docker.raw-stream` **[V-doc: version history v1.42;
  V-src: moby `container_routes.go` `getContainersLogs`]**. Older daemons do
  not, and a current daemon labels every response raw-stream when the request
  version is below 1.42, so the container's `Config.Tty` (from inspect)
  remains the fallback.
- Frames do not align with lines. Split on `\n` after demultiplexing.
  `timestamps=1` prefixes RFC3339Nano timestamps, which make good cursors for
  `since=` on reconnect.
- The spec says logs work only with `json-file`/`journald`. Dual logging
  (local-driver cache: 20 MB x 5 files, compressed) lets `docker logs` work
  with any driver unless `cache-disabled` is set **[V-doc]**.
- `json-file` is the default driver and does **not rotate** by default. Docker
  recommends `local` **[V-doc]**. A cheap, valuable feature is flagging
  containers whose `HostConfig.LogConfig` has no `max-size` while their
  `LogPath` is growing.
- Cancel a follow by closing the forwarded channel. The daemon ends the
  stream.

### 1.7 Stats and CPU %

Formula, verbatim from the spec **[V-doc]**:

- `used_memory = memory_stats.usage - memory_stats.stats.cache` (cgroup v1),
  or `- memory_stats.stats.inactive_file` (cgroup v2).
- `available_memory = memory_stats.limit`.
- `cpu_delta = cpu_stats.cpu_usage.total_usage - precpu_stats.cpu_usage.total_usage`.
- `system_cpu_delta = cpu_stats.system_cpu_usage - precpu_stats.system_cpu_usage`.
- `number_cpus = cpu_stats.online_cpus`, or `len(percpu_usage)` for older
  daemons.
- `CPU % = cpu_delta / system_cpu_delta * number_cpus * 100`.

Caveats:

- On cgroup v2, `percpu_usage`, most `blkio_stats`, and `max_usage`/`failcnt`
  are absent **[V-doc]**.
- `stream=false&one-shot=true` returns one sample immediately without the
  2-cycle wait **[V-doc]**. `precpu_stats` is then not meaningful [U], so
  compute deltas client-side between successive polls.
- **Cost:** a streaming stats connection per container emits about one object
  per second. On hosts with dozens of containers this adds daemon CPU and
  bandwidth [U: widely reported]. Two cheaper options:
  - one-shot polling at the dashboard cadence for visible containers only, or
  - reading cgroup v2 files (`cpu.stat` `usage_usec`, `memory.current`,
    `memory.stat`, `io.stat`) for all containers in the persistent sampler.
    Paths: `/sys/fs/cgroup/system.slice/docker-<id>.scope/` with the systemd
    cgroup driver, or `/sys/fs/cgroup/docker/<id>/` with cgroupfs [U: confirm
    per driver].

### 1.8 Exec, attach and resize

1. `POST /containers/{id}/exec` with `AttachStdin/Stdout/Stderr`, `Tty`,
   `ConsoleSize: [h, w]`, `Cmd`, optional `Env`, `User`, `WorkingDir`,
   `Privileged`, `DetachKeys`. Returns `Id`.
2. `POST /exec/{id}/start` with `{Detach:false, Tty, ConsoleSize}`. The
   connection is hijacked. Sending `Upgrade: tcp` / `Connection: Upgrade` makes
   the daemon answer `101 UPGRADED`, otherwise `200`, then raw bytes
   **[V-doc: attach hijacking text]**.
3. Use the raw stream if `Tty=true`. Use multiplexed frames if `Tty=false`.
4. `POST /exec/{id}/resize?h=&w=` on window change.
5. `GET /exec/{id}/json` returns `ExitCode` after the stream ends.
6. Half-close stdin with channel EOF (dartssh2 supports it).
7. The Séance terminal (vendored xterm) can render this, so the Docker exec
   terminal reuses Séance's terminal widget **[V-repo: seance vendors xterm]**.

### 1.9 Events

- `GET /events` streams objects for containers (`create`, `start`, `die`,
  `oom`, `health_status`, `exec_*`, ...), images, volumes, networks, daemon
  `reload`, and swarm objects. Filters: `container`, `event`, `image`,
  `label`, `type`, `scope`, and more **[V-doc]**.
- Use `since=<last event time>` for gap-free resume after reconnect.
- From v1.52, parse `Type`/`Action`/`Actor.ID`/`Actor.Attributes` only.
- Events drive UI refresh, avoiding polling `/containers/json`.
- Events are also an audit source: `destroy` and `kill` carry actor
  attributes.

### 1.10 Images, pulls and update detection

- Pull progress via `POST /images/create`: a stream of JSON objects. Use
  `progressDetail {current,total}`, keyed by layer `id`, and surface
  `errorDetail` **[V-doc]**.
- Private registries: the client must send `X-Registry-Auth` (base64url JSON
  `{username,password,serveraddress}` or `{identitytoken}`). "Authentication
  for registries is handled client side" **[V-doc]**. The daemon does not read
  the remote user's `~/.docker/config.json`. Only the CLI does. So:
  - API pulls need credentials from the Hauntware vault, or
  - run `docker pull` / `docker compose pull` over exec to use the server's
    own credential helpers.
- Update detection (digest compare):
  1. Local `RepoDigests` (image inspect) vs remote digest.
  2. `GET /distribution/{name}/json` returns `Descriptor.digest` plus
     platforms, fetched by the daemon with the server's network and the
     supplied `X-Registry-Auth`.
  3. moby's implementation does `Tags(ctx).Get(tag)` and then
     `Manifests(ctx).Get(digest)` **[V-src:
     daemon/server/router/distribution/distribution_routes.go]**.
  4. Docker Hub counts manifest **GET** requests toward pull limits, and HEAD
     does not count (100 / 6 h unauthenticated per IPv4 or IPv6 /64, 200 / 6 h
     authenticated personal) **[V-doc]**. DistributionInspect likely consumes
     quota [U: inferred from the GET in source].
  5. For frequent checks, prefer a HEAD on
     `/v2/<repo>/manifests/<tag>` (`Docker-Content-Digest`), done by the client
     or by `curl -I` on the server. Cache aggressively.
- With the containerd image store (multi-platform), image IDs and descriptors
  differ (`Descriptor`, `Manifests`, `Identity` fields in v1.48+). Compare
  index digests, not config digests [U: confirm with a containerd-store host].
- Supply-chain view: `GET /images/{name}/attestations` (v1.55) gives in-toto
  statements (SBOM/provenance) without extra tools **[V-doc]**.

### 1.11 Podman, rootless Docker and contexts

- **Podman sockets:**
  - Rootful default `unix:///run/podman/podman.sock`. Rootless
    `unix://$XDG_RUNTIME_DIR/podman/podman.sock`.
  - Socket activation via `podman.socket`. The service exits after `--time`
    (default 5 s) idle.
  - "a compatibility layer offering support for the Docker v1.40 API" plus the
    native Libpod layer **[V-doc: podman-system-service(1)]**. Source shows
    compat max 1.44 **[V-src]**.
  - The API doc notes `podman-docker` symlinks `/run/docker.sock` to the
    podman socket **[V-src: swagger info]**.
  - The socket is often **not enabled by default**. The app should detect it
    and offer the exact `systemctl [--user] enable --now podman.socket`
    command.
- **Libpod-only endpoints** worth surfacing (podman main, Go module
  `go.podman.io/podman/v6`, 6.2.0-dev **[V-src]**):
  - `/libpod/pods/*` (create/json/stats/prune)
  - `/libpod/play/kube`, `/libpod/kube/apply`, `/libpod/generate/kube`
  - `/libpod/quadlets` (list/inspect)
  - `/libpod/containers/stats` (multi-container)
  - `/libpod/system/df`, `/libpod/system/check`
  - `/libpod/artifacts/*`, `/libpod/manifests/*`
- **Rootless Docker:**
  - systemd **user** unit `docker.service`, CLI context named `rootless`.
  - Socket example `/run/user/1000/docker.sock` (that is,
    `$XDG_RUNTIME_DIR/docker.sock`) **[V-doc]**.
- **Runtime-dir caveat:** `$XDG_RUNTIME_DIR` (`/run/user/<uid>`) exists while
  the user has a logind session or lingering is enabled. An SSH login creates
  one when `UsePAM`/pam_systemd is active [U]. Rootless containers stop at
  logout without `loginctl enable-linger` [U]. The app should flag "linger
  disabled" for rootless engines.
- **Docker contexts:**
  - The remote user's CLI may point at a non-default endpoint via
    `DOCKER_HOST` or the current context. Non-interactive exec does not source
    `.bashrc` profiles reliably.
  - Discover with `docker context inspect --format '{{json .Endpoints.docker.Host}}'`
    [U: format path], or let `docker system dial-stdio` resolve it.

### 1.12 Compose stacks

- **No Engine API.** Compose is a client that translates YAML into Engine API
  calls.
- **Discovery** uses container labels from compose `pkg/api/labels.go`
  **[V-src]**:
  - `com.docker.compose.project`, `.service`, `.container-number`, `.oneoff`
  - `.project.working_dir`, `.project.config_files`,
    `.project.environment_file`
  - `.config-hash`, `.image` (digest), `.depends_on`, `.version`, `.replace`
  - Volumes and networks carry `com.docker.compose.volume` and
    `com.docker.compose.network`.
  - Group by project, then read `config_files` and `working_dir` to find the
    YAML on disk. This even finds stacks the user never registered, as
    Dockge/Dockhand do.
- **CLI JSON** (Compose v5.6.0, 2026-10-02 **[V-doc]**):
  - `docker compose ls --all --format json` returns a JSON **array** of
    `{ID?, Name, Status, ConfigFiles, Reason?}`. Source has
    `Stack{ID, Name, Status, ConfigFiles, Reason}` and the formatter prints
    slices as one JSON document **[V-src: pkg/api/api.go,
    cmd/formatter/formatter.go]**.
  - `docker compose ps --all --format json` returns **JSON Lines** (one object
    per container) per current docs **[V-doc]**. Older v2 releases printed an
    array [U: change believed to be around v2.21]. Parse both.
    `ContainerSummary` fields: ID, Name, Names, Image, Command, Project,
    Service, Created, State, Status, Health, ExitCode, Publishers, Labels,
    Mounts, Networks, LocalVolumes **[V-src]**.
  - `docker compose config --format json` gives the fully interpolated model
    (validation). `--no-interpolate` keeps `${VAR}` intact for an editor view.
    `--hash`, `--images`, `--services`, `--variables`, `--environment` and
    `--resolve-image-digests` are also available **[V-doc]**.
  - **Security:** `config` output contains interpolated secrets. Never log or
    sync it.
- **Editing:**
  1. Read and write the YAML and `.env` over SFTP. Use atomic
     `posix-rename@openssh.com` replace (dartssh2 >= 2.19) and keep a backup
     copy.
  2. Validate with `docker compose -f <file> config -q` before `up`.
  3. Run `docker compose -p <project> --project-directory <dir> up -d
     --remove-orphans`, `pull`, `down`, `restart`, or `logs -f` over exec.
  4. Without a PTY, pass `--progress plain` / `--ansi never` to get parseable
     progress [U: flag spellings vary by version. Verify against v5 help].
- **Legacy v1:** `docker-compose` (Python) "stopped receiving updates" in July
  2023. v1 names containers with `_`, v2 with `-` **[V-doc: compose/migrate]**.
  The project/service labels are the same family. Detect `docker-compose` only
  as a read-only fallback.

---

## 2. Agentless Linux metrics: sources and formats

All reads should run with `LC_ALL=C` prefixed inside the command (see the env
caveat in 1.2).

### 2.1 Core samplers

| Metric | Source | Format notes | Verified |
|---|---|---|---|
| CPU time | `/proc/stat` `cpu`/`cpuN` lines | Fields: user nice system idle iowait(2.5.41) irq(2.6.0) softirq(2.6.0) steal(2.6.11) guest(2.6.24) guest_nice(2.6.33), in USER_HZ. iowait is "not reliable". Also `ctxt`, `btime`, `processes`, `procs_running`, `procs_blocked` | **[V-doc man-pages 6.19]** |
| | | Read only `^cpu` lines. The `intr` line can be large on many-IRQ machines (922 bytes on a 4-vCPU test VM) | measured |
| | | Guest time is included in user/nice in the kernel accounting [U]. Do not double count | |
| Memory | `/proc/meminfo` (kB) | Use `MemAvailable` (since 3.14) for "used". Also MemTotal, MemFree, Buffers, Cached, SwapTotal, SwapFree, Shmem (2.6.32), SReclaimable (2.6.19) | **[V-doc]** |
| Load | `/proc/loadavg` | `l1 l5 l15 running/total lastpid` | [U, trivial] |
| Uptime | `/proc/uptime` | `uptime_s idle_s` | [U, trivial] |
| Pressure | `/proc/pressure/{cpu,memory,io}` | `some avg10= avg60= avg300= total=` and `full ...`. `total` is in microseconds. CPU `full` is reported since 5.13 (zero at system level) | **[V-doc kernel psi.rst]** |
| | | `CONFIG_PSI`. `CONFIG_PSI_DEFAULT_DISABLED` requires boot param `psi=1` | **[V-src init/Kconfig]** |
| | | Some enterprise kernels ship PSI disabled by default [U: RHEL]. Absence is normal | |
| | | cgroup v2: `cpu.pressure`, `memory.pressure`, `io.pressure` per cgroup | **[V-doc]** |
| Network | `/proc/net/dev` | Per-interface rx/tx bytes, packets, errs, drop counters. Compute rates from deltas | [U, stable format] |
| Disk I/O | `/proc/diskstats` | major minor name + up to 17 fields (reads, merges, sectors, ms, writes..., in-flight, io_ticks, weighted, discard x4, flush x2). Sectors are always **512-byte** units. Field count varies by kernel | **[V-doc iostats, block/stat]** |
| | | Filter out loop/ram/dm duplicates by policy | |
| Processes | `ps -eo pid,ppid,user,stat,pcpu,pmem,rss,etimes,comm --no-headers` or `/proc/[pid]/stat` | About 67 bytes per process line (measured). `ps pcpu` is a lifetime average. True "current CPU" needs `/proc/[pid]/stat` utime+stime deltas | measured / [U] |
| | | BusyBox `ps` may not support `-o` fully [U] | |
| Temps | `/sys/class/thermal/thermal_zone*/{type,temp}` and `/sys/class/hwmon/hwmon*/{name,temp*_input,temp*_label,fan*_input}` | hwmon temperatures are millidegree Celsius (implied by sysfs-interface) | **[V-doc partial]** |

### 2.2 Storage, network and identity

| Need | Command | Notes |
|---|---|---|
| Filesystems | `df -PT` (POSIX format, type column) and `df -Pi` (inodes) | No JSON. `-P` keeps one line per FS [U] |
| Mount tree | `findmnt --json` (or `-J`) | util-linux >= 2.27 (findmnt, lsblk, losetup, lslocks, sfdisk, lsipc gained JSON) **[V-doc: v2.27 release notes]** |
| Block devices | `lsblk --json -b -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,ROTA` | Column names vary by version (`MOUNTPOINTS` is newer) [U] |
| Disk usage explorer | `du -x -d1 -B1 <dir>` incremental, or `ncdu -x -o - <dir>` | ncdu JSON export: `[1, minor, {metadata}, rootDir]`, dirs as arrays whose first element is an info object (`name`, `asize`, `dsize`, `ino`, `nlink`, `read_error`, `excluded`, `notreg`) **[V-doc ncdu jsonfmt]** |
| | | ncdu 2.x adds a binary `-O` format (current 2.9) **[V-doc]** |
| | | Use a streaming JSON parser. Non-UTF-8 names may appear **[V-doc]** |
| Listening ports | `ss -tunlpH` | iproute2 `ss` has **no JSON** (man page lists `-H/--no-header`, `-O/--oneline`, no json) **[V-src ss.8]** |
| | | `-p` shows other users' processes only as root [U] |
| Addresses | `ip -j addr`, `ip -j route`, `ip -j -s link` | `-j/-json` documented in ip(8) **[V-src ip.8]** |
| Sessions | `who`, `last -n 50`, `lastlog`/`lastlog2` | `last` reads wtmp. Distros moving to wtmpdb/lastlog2 change this [U] |
| OS identity | `/etc/os-release` (`ID`, `VERSION_ID`, `PRETTY_NAME`), `hostnamectl --json=short` | hostnamectl gained `--json=` alongside hostnamed `Describe()` in systemd v249 **[V-src NEWS]** |
| | | Fall back to `uname -a` |

### 2.3 Services, timers and logs (systemd)

- `systemctl list-units --all --output=json`, and the same for
  `list-unit-files`, `list-timers --all`, `list-sockets`:
  - JSON table output was added in **systemd v246**. `output_table()` with
    `table_print_json` appears in `src/systemctl/systemctl.c` at tag v246 and
    is absent at v245. It is used by `output_units_list`,
    `output_sockets_list`, `output_timers_list`, `output_unit_file_list` and
    `output_machines_list` **[V-src]**.
  - Not described in NEWS or the man page (man documents `--output=` only for
    journal formatting in `status`) **[V-src systemctl.xml]**.
  - JSON keys mirror the table columns [U].
  - Distros below v246 need text parsing with `--plain --no-legend`. Examples
    from prior knowledge: RHEL/Alma/Rocky 8 = 239, Ubuntu 20.04 = 245 [U].
- `systemctl show -p Id,ActiveState,SubState,MainPID,ExecMainStartTimestamp,MemoryCurrent,CPUUsageNSec,NRestarts,Result <unit>`:
  - Prints `key=value` text. **No JSON yet**. systemd issue #39081 (opened
    2025-09-22) is still open, and the related PR #38035 is unmerged per the
    issue page **[V-doc]**.
  - `MemoryAccounting=` defaults on since v238 **[V-src NEWS]**.
  - CPU usage on cgroup v2 comes from `cpu.stat` without enabling the CPU
    controller since v240 **[V-src NEWS, paraphrase]**.
- Actions:
  - `systemctl start|stop|restart|reload|enable|disable|mask <unit>`
  - `systemctl --user ...` for user units
  - `systemctl daemon-reload` after editing units over SFTP
  - Non-root actions need polkit (Section 4)
- Journal:
  - `journalctl -o json [-u unit] [-p 0..7] [-b [id]] [--since] [--until] [-n N] [-f] [--after-cursor=C] [--cursor-file=F] [--output-fields=...]`.
  - `--list-boots` supports JSON output since **v251** **[V-src NEWS]**.
  - JSON format **[V-doc systemd.io JOURNAL_EXPORT_FORMATS]**:
    - Field name maps to a string value.
    - Non-UTF-8 or binary values become **arrays of byte numbers**.
    - Over-threshold fields may be `null`.
    - Repeated fields become arrays.
    - Addressing fields: `__CURSOR`, `__REALTIME_TIMESTAMP` (usec string),
      `__MONOTONIC_TIMESTAMP`, `__SEQNUM`, `__SEQNUM_ID`.
  - With `--output-fields`, `__CURSOR`, `__REALTIME_TIMESTAMP`,
    `__MONOTONIC_TIMESTAMP` and `_BOOT_ID` are always printed **[V-doc
    journalctl.xml]**.
  - Use `__CURSOR` with `--after-cursor` for gap-free follow/reconnect and
    "load older" paging.
  - Access: own user journal always. System journal only for root or
    `systemd-journal`, `adm`, `wheel` members **[V-doc]**. Without these the
    output silently contains only the user's own entries. Detect this
    (`id -nG`) and say so.
- Classic logs: `/var/log/syslog`, `/var/log/messages`, `/var/log/auth.log`,
  `/var/log/secure`, nginx/apache. Use `tail -n`/`tail -F` over exec. Rotation
  (`.1`, `.gz`) needs `zcat`.

### 2.4 Cron and scheduled work

- Per-user: `crontab -l` (exit 1 with "no crontab for" when empty [U]). Write
  with `crontab -` from stdin, and always back up first.
- System: `/etc/crontab`, `/etc/cron.d/*` (both have a **user** field), and
  `/etc/cron.{hourly,daily,weekly,monthly}/` (run-parts scripts). `run-parts`
  ignores names with dots on Debian [U].
- anacron: `/etc/anacrontab` (period, delay, job-id, command) [U].
- Other user crontabs live in `/var/spool/cron/crontabs/<user>` (Debian) or
  `/var/spool/cron/<user>` (RHEL). Root only [U].
- Run history: journald `-u cron`/`-u crond` or syslog. systemd timers give
  last/next trigger natively (`list-timers`).
- A cron UI should parse 5-field expressions and macros (`@reboot`, `@daily`),
  show next fire times computed client-side, preserve comments and env lines
  (`MAILTO=`, `PATH=`), and diff before writing.

### 2.5 Packages, reboot-required, hardware

| Need | Command | Notes |
|---|---|---|
| Debian/Ubuntu updates | `apt-get -s upgrade` / `-s dist-upgrade` (parse `Inst` lines), or `apt list --upgradable` | `apt` prints "WARNING: apt does not have a stable CLI interface" to stderr when not on a TTY, and maintainers point scripts to apt-get **[V-doc: debian-deity list, secondary]** |
| | | Refreshing lists (`apt-get update`) needs root |
| | | Ubuntu: `/usr/lib/update-notifier/apt-check` gives `updates;security` counts [U] |
| Reboot needed (Debian/Ubuntu) | `/var/run/reboot-required`, `/var/run/reboot-required.pkgs` | [U: update-notifier convention] |
| RHEL/Fedora (dnf4) | `dnf check-update` | Exit 100 = updates, 0 = none, 1 = error **[V-doc dnf]** |
| | `dnf needs-restarting -r` | Exit 1 = reboot needed **[V-doc dnf-plugins-core]**. `-s` lists services |
| RHEL/Fedora (dnf5) | `dnf5 check-upgrade --json` | JSON sections with `name`, `arch`, `evr`, `repository`. Exit 100 = updates **[V-doc dnf5]** |
| Arch | `checkupdates` (pacman-contrib, uses a temp sync DB, avoiding partial-upgrade risk) or `pacman -Qu` after sync | [U] |
| Alpine | `apk version -l '<'` (after `apk update`) | [U] |
| SMART | `smartctl --scan-open`, `smartctl -j -a /dev/X` | JSON since smartmontools 7.0 (2018-12-30, experimental then). NVMe `-j -c` in 7.5 **[V-doc NEWS via secondary]**. Needs root |
| Sensors | `sensors -j` | lm-sensors 3.5.0+. 3.6.0 fixed a stray-comma JSON bug **[V-doc via distro changelogs]** |
| NVIDIA GPU | `nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits` | [U: well known. Check field names against `nvidia-smi --help-query-gpu`] |
| AMD/Intel GPU | `/sys/class/drm/card*/device/gpu_busy_percent` (amdgpu), `intel_gpu_top -J` | [U] |
| cgroup v2 per unit | `/sys/fs/cgroup/<slice>/<unit>/{cpu.stat,memory.current,memory.max,io.stat,pids.current}` | Same files give per-container data (1.7) [U for paths] |

### 2.6 Portability

- **BusyBox/Alpine:**
  - OpenRC (`rc-status`, `rc-service`), busybox `syslogd` to
    `/var/log/messages`, and crond with `/etc/crontabs/<user>` [U].
  - Applet options are reduced (`ps`, `df`, `top`). Probe capabilities once per
    host with `command -v` checks and cache them.
- **Non-systemd distros** (Devuan, Void with runit, Gentoo OpenRC): hide the
  Services/Journal tabs and show service-manager-specific views only if
  implemented.
- **Containers and LXC:**
  - `/proc` may be virtualized by lxcfs or show host values. `/sys` may be
    read-only.
  - PSI and `/sys/class/hwmon` are often absent. Docker-in-LXC needs nesting
    [U].
  - Mark metrics "virtualized/unknown" rather than wrong.
- **macOS hosts:**
  - `sysctl -n hw.memsize hw.ncpu vm.loadavg kern.boottime`, `vm_stat`
    (multiply by the page size printed in its header), `top -l 2 -n 0`
    (CPU), `iostat`, `netstat -ib`, `df -Pk`, `launchctl list`,
    `log show --style json` [U].
- **FreeBSD:**
  - `sysctl kern.cp_time` (user nice sys intr idle), `sysctl vm.stats.vm.*`
    plus `hw.pagesize`, `swapinfo -k`, `gstat -b`/`iostat -x`, `netstat -ibn`,
    `service -e`, `/var/log/messages` [U].
- **Architecture:** a `HostProbe` step classifies the OS family, init system,
  container runtime(s), sudo flavour, and available tools. Collectors are then
  selected per host. ServerBox does this too (separate Linux/BSD/Windows
  parsers **[V-src: crates/sbm_parser/src/{linux,bsd,windows}.rs]**).

---

## 3. Sampling and transport strategy

### 3.1 Options

| Strategy | Server cost | Client complexity | Sessions used | Fit |
|---|---|---|---|---|
| Repeated short execs (`cat /proc/stat ...` every N s) | fork/exec of the login shell per poll. PAM session accounting per exec channel [U]. Possible `lastlog`/audit noise | Simple | 1 transient each | Fine at >= 5 s. Wasteful at 1-2 s |
| **Persistent exec running a sampler loop** (`sh -c 'while :; do ...; printf "\036%s\n" "$MARK"; sleep 2; done'`) | One long-lived `sh`. Each tick costs a few builtin reads plus `cat`/`awk` forks | Framing and resync | 1 persistent | **Recommended default** |
| Persistent `sh` exec fed commands on stdin (ServerBox style) | Same | Request/response with end markers. Supports on-demand commands without new channels | 1 persistent | Good for mixed polling and on-demand probes |
| Uploaded script (`~/.cache/hauntware/sampler.sh`, versioned name) | Same. Script cached on disk | Needs a write location. Version by name (ServerBox: `srvboxm_v83.sh` in a `server_box` directory under the host's temporary directory, or `~/.config/server_box`) **[V-src]** | 1 | Optional. Inline `sh -c` avoids leaving files behind |
| On-host agent | Resident process | Separate deliverable | 0 | Needed only for offline history/alerts (Section 5) |

**Recommended design:**

- One `SSHClient` per server, shared by all features of the app. The app may
  also share connections with Séance/Poltergeist if they run in one process
  (they do not today).
- **Sampler channel** (`execute`, no PTY, so no echo and no CRLF translation):
  - A POSIX `sh` program emits records framed by a sentinel (for example
    `\x1eHWS <seq> <monotonic>\n` followed by tagged sections).
  - Collectors run at different cadences inside the loop: CPU/mem/net/disk
    every tick (1-5 s), processes only while that screen is visible,
    filesystems every 30-60 s, packages hourly.
  - The client toggles collectors by writing control lines to the sampler's
    stdin. `read -t` is not POSIX. Use a FIFO or restart the loop on config
    change [U: pick in spike].
- **Event channels**, each opened only while a view needs it:
  - `journalctl -o json -f --after-cursor=...`
  - `tail -F`
  - Docker `/events`, logs and stats over streamlocal
- **On-demand exec** for actions (`systemctl restart`, `crontab -`,
  `docker compose up`) using `runCommand` with caps and timeouts.
- **Delta computation client-side:**
  - CPU % from `/proc/stat` jiffy deltas.
  - Rates from counter deltas, with counter-wrap and reset (reboot)
    detection via `btime`/uptime decrease.
  - Disk throughput as sectors x 512 / dt.
  - Keep raw counters for the next tick.

### 3.2 Limits and keepalives

- `MaxSessions` default **10** per connection. It counts shell, login and
  subsystem sessions. `0` disables sessions "while still permitting
  forwarding" **[V-doc]**. A realistic budget is sampler 1, journal follow 1,
  one exec action 1, SFTP 1 = 4. Docker streams are forwarding channels and
  are not counted.
- If a host sets `MaxSessions 1`, degrade to a single multiplexed `sh`
  channel. SFTP then competes, so open a second TCP connection.
- `MaxStartups` default `10:30:100` limits **unauthenticated** concurrent
  connections, and `PerSourceMaxStartups` defaults to none **[V-doc]**. This
  argues for one long-lived connection rather than the Docker CLI pattern of
  one `ssh` process per HTTP connection. That pattern is why Docker documents
  `ControlMaster`/`ControlPersist` for SSH contexts **[V-doc
  protect-access]**. fail2ban/sshguard-style tools also penalize bursts of new
  connections [U].
- Dropbear caps channels at `MAX_CHANNELS 1000` by default **[V-src
  default_options.h]**.
- Keepalive: dartssh2 sends `keepalive@openssh.com` every 10 s by default
  **[V-src]**. Server-side `ClientAliveInterval` is 0 (off) by default
  **[V-doc]**. NAT idle timeouts are the usual killer. Keep 10-30 s and
  reconnect with backoff, resuming journal cursors and Docker `since=`.
- **Process cleanup:** closing an exec channel does not necessarily kill the
  remote process. `journalctl -f` lingers until its next write fails [U]. Send
  `SSHSignal.TERM` first. OpenSSH `killpg`s the session's process group, and
  non-PTY exec children are session leaders [U: `setsid` in `do_exec_no_pty`].
  Then close.

### 3.3 Cost estimates

Estimates measured on a 4-vCPU VM. Treat as order-of-magnitude.

- Raw source sizes:
  - `/proc/stat` 1277 B (`cpu` lines about 300 B)
  - `/proc/meminfo` 1503 B (about 300 B after filtering 10 keys)
  - `/proc/net/dev` 694 B
  - `/proc/diskstats` 866 B
  - PSI about 300 B
- A filtered core sample is about **1.5-2.5 KB**. At a 2 s cadence that is
  about 1 KB/s (~3.6 MB/h) per host before SSH framing, with no SSH
  compression available in dartssh2.
- A process list adds about 67 B per process (77 processes = 5.2 KB here). At
  400 processes every 3 s that is about 9 KB/s, so sample processes only
  while visible.
- Mobile: a 10-host fleet overview at a 10 s cadence with a slimmer
  "overview" collector set (~600 B) is about 0.6 KB/s total.
- Server CPU: dominated by fork/exec of helpers per tick. Use shell builtins
  (`read` from `/proc` files) and one `awk` per tick. ServerBox's script reads
  `/proc/loadavg` and `/proc/<pid>/stat` with shell `read -r` **[V-src:
  crates/sbm_parser/src/script.rs, ~lines 947-969]**. That builtins are
  cheaper than forks is the rationale assumed here, not stated there.

### 3.4 How peers do it

- **ServerBox** (lollipopkit/flutter_server_box @ 50e61ed, 2026-10-10)
  **[V-src]**:
  - Default status interval 3 s (`Defaults.updateInterval = 3`).
  - Uploads a versioned script and runs status through a **persistent `sh`
    exec session**. `PtyPersistentShellSession` uses
    `stty raw -echo && printf READY && cat | sh 2>&1` to avoid echo.
  - Falls back to one exec per poll after a timeout. Separates a slower
    "extended status" command so slow probes do not mark a host unreachable.
  - Parsing moved to a Rust crate (`sbm_parser`: linux/bsd/windows,
    container, cron, smart, gpu, service).
  - Ships **ServerBox Monitor**, a server-side agent with HTTP API, history,
    iOS push and webhooks.
- **Beszel** (v0.21.0) **[V-doc]**:
  - Agent-based. In SSH mode the hub connects to the agent's own SSH server
    (port 45876). The hub key is ED25519, and the server provides no PTY and
    accepts no input. The hub does **not** verify the agent host key.
  - In WebSocket mode the agent dials out with a registration token plus
    mutual proof. Details and history tiers are in r3.
- **Cockpit** **[V-src: doc/protocol.md]**:
  - `cockpit-bridge` runs on the host as the user and speaks a framed JSON
    protocol over stdio/SSH. Frames are `<len>\n<channel>\n<payload>`.
  - Channels include `stream`, `dbus-json3`, `fsread1`/`fsreplace1`, and
    `metrics1` (PCP sources `direct`/`pmcd`/archives, default interval
    1000 ms).
  - It is launched over SSH with a Python bootloader ("beiboot") that can ship
    the bridge over stdin, so nothing needs installing beyond Python (r3).
  - The design lesson: a single multiplexed stdio channel with typed
    sub-channels. Hauntware's sampler framing is a light version of this.

---

## 4. Privilege model

- **Unprivileged baseline:** `/proc`, `/sys`, `df`, `ps`, `ss` (without other
  users' process names), own crontab, own journal, `systemctl` status (read is
  unprivileged).
- **Docker access:**
  - Membership in the `docker` group means root. "The `docker` group grants
    root-level privileges to the user" **[V-doc]**. The UI must say so when
    onboarding a server and must not suggest adding users to the group
    casually.
  - Rootless Docker/Podman reduce blast radius (Section 1.11).
- **Journal:** `systemd-journal` is the least-privileged option. `adm` and
  `wheel` carry more distro-defined powers **[V-doc]**.
- **sudo** (sudo.ws "latest", >= 1.9.14 behaviour **[V-doc]**):
  - `-n`: "If a password is required ... sudo will display an error message
    and exit." Always try this first and detect "a password is required".
  - `-S`: reads the password from stdin, with the prompt on stderr.
    - Write the password to the channel's stdin immediately after start, with
      `-p ''` to suppress the prompt.
    - Never put it in the command line (visible in `ps` and shell history) or
      in `env` requests.
    - Risks:
      - The password transits the SSH channel (encrypted) and lives in client
        memory.
      - If sudo does not ask (cached timestamp), the password bytes flow into
        the **command's** stdin. Use `sudo -S -v` first to validate, then run
        the command with `-n`.
      - `timestamp_timeout` defaults to 5 min **[V-doc]**.
  - `-A`: askpass helper via `SUDO_ASKPASS` is cleaner for interactive
    prompts. Cockpit uses it **[r3]**.
  - `use_pty` is on by default since 1.9.14, but it applies only when sudo
    runs in a terminal **[V-doc]**.
  - `requiretty` is off by default **[V-doc]**. Some old RHEL configs set it
    [U]. Detect "sorry, you must have a tty" and retry with a PTY.
- **sudo-rs** (default on Ubuntu 25.10+, Ubuntu 26.04 ships 0.2.13 **[V-doc
  README]**):
  - Supports `-n`, `-S`, `-A` on main **[V-src: docs/man/sudo.8.md]**.
  - `-A`/`--askpass` arrived in 0.2.11 (2025-12-16) **[V-src: CHANGELOG.md]**.
    Ubuntu 25.10 ships 0.2.8 (0.2.8-1ubuntu5.2, no askpass backport in its
    changelog), so `-A` is missing there **[V-doc: packages.ubuntu.com]**.
  - `use_pty` is always on by default, wildcards are allowed only as the final
    argument, and there is no `sudo -E` **[V-doc]**.
  - The sudo flavour (`sudo -V` first line) belongs in the host probe.
- **NOPASSWD scoping:**
  - Recommend narrow rules for read-only privileged collectors, for example
    `smartctl -j -a /dev/*`, `journalctl`, `ss -tunlp`.
  - Warn that wildcard arguments "should be used with care" and can match
    spaces **[V-doc]**. A rule for `/usr/bin/docker *` or `systemctl *` is
    root-equivalent.
  - The app can generate a reviewed sudoers drop-in for the user to install,
    validated with `visudo -cf`.
- **polkit / run0:**
  - Non-root `systemctl restart` asks polkit (`org.freedesktop.systemd1.manage-units`).
    Over non-interactive SSH there is no agent, so it fails. Use
    `--no-ask-password` to fail fast [U: message text].
  - polkit rules can grant specific units/verbs to a group, which is narrower
    than sudo (r3, Cockpit).
  - `run0` (systemd >= 256 **[V-src NEWS]**) is polkit-based sudo. It cannot
    take a password over a pipe [U].
- **Cockpit superuser model** (r3):
  - The session starts unprivileged, with an explicit, remembered
    "Administrative access" toggle that starts a second, privileged bridge.
  - Hauntware equivalent: a per-server "admin mode" that runs privileged
    commands as `sudo -n ...` (or `-S` after an explicit unlock).
  - Visible state, auto-expiry, and every privileged command recorded in the
    audit log.

---

## 5. Agent vs agentless, the watcher question, and mobile limits

### 5.1 What fundamentally needs an always-on component

| Need | Agentless possible? | Why |
|---|---|---|
| Live dashboards, logs, Docker ops | Yes | Client is open |
| History beyond the current app session | Partially | Read existing collectors (sysstat `sar`, PCP archives, Netdata, node_exporter) if installed. Otherwise there is no history before first connect |
| Alerts while all clients are closed | **No** | Someone must evaluate rules continuously |
| Push notifications (APNs/FCM) | **No** | Needs a sender with provider credentials |
| Scheduled jobs (backups, auto-update, image prune) | Use the server's own cron/systemd timers | The app can author timers/cron entries rather than run a scheduler itself |

### 5.2 Agent options compared (details and sources in r1/r3)

- **node_exporter:** pull, `:9100`, no auth by default. Good if already
  present.
- **Netdata:** heavy and featureful. 2026 had `ndsudo` privilege-escalation
  fixes (r3).
- **Beszel agent:** small Go binary, SSH or WebSocket. Read-only.
- **Komodo Periphery:** Rust. Inbound or outbound, PKI. Executes actions.
- **Portainer Agent:** inbound `:9001`, needs docker.sock mount.
- **Dockhand Hawser:** standard `:2376` or edge WebSocket.

All Docker-capable agents hold root-equivalent socket access.

**Hauntware-specific option:** an optional `hauntware-agent` (working name)
compiled from Dart.

- `dart compile exe` cross-compiles to Linux x64/arm64 (Dart 3.8+) and
  arm/riscv64 (3.9+) from any desktop host **[V-doc]**. The agent could share
  `seance_protocol` crypto and record code instead of reimplementing it.
- Whether Dart executables run on musl (Alpine) is [U]. Plan a Go or static
  fallback if Alpine matters.
- Scope:
  - read-only collectors identical to the sampler
  - a local ring buffer (for example 7 days at 1 min, rolled up)
  - local rule evaluation
  - outbound deposit of sealed alerts
- No inbound port and no remote command execution: the app keeps doing
  actions over SSH.
- Install via SSH from the app as a systemd user or system unit. Uninstall
  must be one click.

### 5.3 Can a "watcher" live next to the sync server?

Facts **[V-repo]**:

- Vault key and auth verifier are independent (Argon2id then HKDF, separate
  domains). The server stores only a salted verifier hash and "never sees a
  key".
- Records are sealed client-side. The sync server is a "breach-tolerant blob
  store" (seance/AGENTS.md "Security model").
- The **Inbox** feature already defines a producer pattern:
  - A producer gets an `appId` plus a deposit token (server checks a salted
    hash) plus an **app key** (XChaCha20-Poly1305) that only the producer and
    the vault hold.
  - The server stores sealed items it cannot read or forge.
  - There are no push notifications ("The badge updates on the next sync
    cycle") (seance/docs/INBOX.md).

Options:

1. **Watcher on the sync server holding SSH keys.** Breaks the trust model. A
   breached sync server would hold SSH access to the whole fleet. Reject.
2. **Separate opt-in "watcher" daemon that is a full client:**
   - It enrolls like a device, gets vault access, and polls servers over SSH
     with a **dedicated restricted key** (`restrict`, `command="..."` forced
     sampler, `from=`).
   - It can run on the same box as the sync server, but as a separate trust
     domain. That must be clearly stated, since a compromise of that host
     compromises both.
   - Note that `restrict` also blocks streamlocal (1.1), so the watcher cannot
     use the Docker API. It would rely on a forced read-only script. OpenSSH
     refuses signals to forced-command sessions **[V-src]**.
3. **On-host agent as Inbox-style producer** (recommended):
   - Each server's agent seals alerts with a per-agent app key provisioned by
     the client over SSH at install time.
   - It deposits them to the sync server's inbox-like endpoint. The server
     stores only ciphertext and can trigger a content-free push.
   - The trust model is unchanged. Credentials never leave the monitored host,
     and the agent has no SSH keys.
   - Downsides: one install per server, and no detection of "host down"
     (an agent cannot report its own death). Add **dead-man heartbeats**: the
     agent deposits a sealed heartbeat, and the server only needs to know
     "agent X has not deposited for N minutes", which it can see without
     decrypting.
4. **External integrations:** Uptime Kuma, Healthchecks or ntfy webhooks
   configured by the app on the server (r3 option C). Zero new
   infrastructure, but alerts leave the Hauntware ecosystem.

**Push delivery:**

- APNs requires the app publisher's credentials, so a self-hosted sync server
  cannot push to the App Store build directly.
- ntfy solves the same problem with an `upstream-base-url` relay. The
  self-hosted server forwards only a message ID (`X-Poll-ID`) and a topic
  hash, with generic text "New message", and the app fetches the content from
  the user's server **[V-doc: ntfy config]**.
- Hauntware would need a publisher-run relay that sees only device tokens and
  opaque IDs.
- On iOS, a Notification Service Extension can modify a notification before
  display. It could decrypt a sealed payload locally **[V-doc: Apple
  "choosing background strategies"]**.
- Android FCM data messages can carry ciphertext decrypted in-app [U].

### 5.4 Mobile background execution

- **iOS** **[V-doc: Apple BackgroundTasks docs]**:
  - `BGAppRefreshTask`: "the system decides the best time to launch your
    background task", with "up to 30 seconds of background runtime".
  - Background (silent) pushes are rate-limited "more frequently than three
    times per hour".
  - iOS 26 adds `BGContinuedProcessingTask` for user-initiated work that
    started in the foreground. It shows progress in a Live Activity and may be
    terminated under resource pressure.
  - None of these supports periodic SSH polling.
- **Android:**
  - WorkManager `MIN_PERIODIC_INTERVAL_MILLIS = 15 min`, flex >= 5 min
    **[V-src androidx PeriodicWorkRequest.kt]**. Runs are subject to Doze.
  - Foreground services of type `dataSync` (and `mediaProcessing`) are limited
    to **6 h per 24 h** since Android 15. `onTimeout` is then called, and
    restart throws `ForegroundServiceStartNotAllowedException` until the user
    foregrounds the app **[V-doc]**.
  - A permanent foreground "monitoring" service is not a sanctioned pattern
    for this use.
- **Desktop** (macOS/Linux/Windows): a tray/menu-bar background mode can poll
  while the machine is awake. That is useful for desktop users but is not a
  substitute for server-side alerting.

---

## 6. Security

1. **docker.sock = root.**
   - Anyone who can reach the forwarded socket can mount `/` into a container.
     Show a per-server badge for root-equivalent access.
   - Never expose the tunnel on a local TCP port (1.3). Close idle Docker
     channels.
2. **Secret exposure in API output:**
   - `GET /containers/{id}/json` returns `Config.Env` in plaintext.
     `docker compose config` interpolates `.env` values.
   - Image history `CreatedBy` can reveal build args. Labels sometimes hold
     tokens.
   - Mitigations:
     - Mask values whose keys match
       `/(PASS|PASSWORD|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|AUTH|DSN|DATABASE_URL)/i`
       by default, with reveal-on-tap.
     - Exclude from crash reports and logs.
     - Never sync inspect output. Never send it to the LLM assistant without
       explicit consent (Séance already treats terminal content as untrusted
       **[V-repo]**).
3. **Audit log of destructive actions:**
   - Record actor device, server, action, target, timestamp, and result
     (exit code / HTTP status).
   - Store it as an E2E-synced record type so all the user's devices see it.
   - Optionally also write `logger -t hauntware "<action>"` on the server for a
     host-side trail. Docker `/events` and sudo logs corroborate.
4. **Confirmation UX:**
   - Typed-name confirmation for `DELETE /volumes/{name}`, `docker system
     prune -a --volumes`, removing containers with `v=1`, `compose down -v`,
     `crontab` overwrite, and package upgrades.
   - Prune shows a **dry-run preview** first, by listing matching resources
     with the same filters (`dangling`, `until`, `label`) before calling
     `/prune`.
   - Show the exact command or API call (Cockpit-style transparency).
5. **Registry credentials:**
   - Keep them in the E2E vault and send them per request as `X-Registry-Auth`
     **[V-doc]**. Never write them to the server's `~/.docker/config.json`
     unless the user asks.
   - Prefer identity tokens and short-lived tokens. Scope per registry.
6. **Image vulnerability scanning (run on the server):**
   - **Trivy:**
     - Scans images from the local Docker Engine by default. `--image-src
       podman,containerd`, `--podman-host /run/user/<uid>/podman/podman.sock`.
       Remote Podman is not supported **[V-doc]**.
     - `--format json` for parsing [U: not on the fetched page].
     - **Supply-chain warning:** malicious v0.69.4 and retagged GitHub Actions
       in March 2026 (CVE-2026-33634, on CISA KEV). Pin versions, verify
       signatures/checksums, and never auto-install "latest".
   - **Grype:**
     - Schemes `docker:`, `podman:`, `registry:`, `docker-archive:`,
       `oci-archive:`, `oci-dir:`, `dir:`, `sbom:`.
     - `-o json|sarif|cyclonedx-json`. `--fail-on <severity>` returns exit 2
       **[V-doc: oss.anchore.com CLI reference]**.
   - **Docker Scout:**
     - `docker scout cves --format packages|sarif|spdx|gitlab|markdown|sbom`,
       `--only-severity`, `--exit-code` (2) **[V-doc]**.
     - Requires Docker Hub login per the CLI repo's CI examples. Licensed
       under the Docker Subscription Service Agreement, not open source
       **[V-doc: docker/scout-cli README]**.
   - **No-install alternative:** `GET /images/{name}/attestations` (API 1.55)
     can expose an SBOM attached at build time. The client could match it
     against OSV offline [U: feasibility].
7. **Signature verification:**
   - `cosign verify <image> --certificate-identity=... --certificate-oidc-issuer=...`
     (keyless) or `--key cosign.pub`. Output is JSON **[V-doc]**.
   - Can run on the server before `compose pull/up` as an optional policy:
     "only deploy signed images from these identities".
8. **Host-key and connection hygiene:** reuse Séance's TOFU host-key
   verification and jump-host validation (`seance_core` already prevents a jump
   host impersonating its target **[V-repo]**).

---

## 7. Open risks and suggested spikes

1. **Spike A (1-2 days):** add `openUnixStream` to `seance_core`, plus a
   minimal HTTP/1.1 client.
   - Run `/_ping`, `/version`, `/containers/json`, a `logs?follow` demux, and
     `exec` hijack plus resize against Docker 29.9 and Podman 6.1 (rootful and
     rootless).
   - Test the `HttpClient` + `detachSocket` alternative in the same spike.
2. **Spike B:** a sampler `sh` program on Debian 12, Ubuntu 24.04, RHEL 9,
   Alpine 3.2x and a BusyBox NAS.
   - Measure bytes per tick and server CPU.
   - Validate `--output=json` behaviour on systemd 239/245/252/257.
3. **Spike C:** sudo flows (`-n`, `-S -v` then `-n`, askpass) with sudo
   1.9.x and sudo-rs 0.2.x. Check PTY-required cases.
4. **Spike D:** update-check rate-limit behaviour.
   - DistributionInspect vs registry HEAD against Docker Hub. Check
     `ratelimit-remaining` before and after.
5. **Design review:** an agent-as-Inbox-producer for alerts.
   - Extend the inbox wire format with a sealed "alert" kind and an
     unauthenticated-to-content heartbeat timestamp.
   - Decide whether to operate a push relay.
6. **Unverified items to confirm:**
   - compose `ps` JSON format history
   - JSON keys of `systemctl list-*`
   - distro systemd versions
   - PSI default on RHEL kernels
   - cgroup paths per driver
   - XDG_RUNTIME_DIR/linger behaviour over SSH exec
   - Dart exe on musl
   - `HttpClient` 101 handling
   - `--progress`/`--ansi` flags in Compose v5

---

## Sources

SSH / OpenSSH / Dropbear / dartssh2

- https://pub.dev/api/archives/dartssh2-3.0.2.tar.gz (read locally:
  lib/src/ssh_client.dart, ssh_session.dart, ssh_channel.dart,
  forward/ssh_forward.dart, message/msg_channel.dart, http/http_client.dart,
  ssh_transport.dart, CHANGELOG.md)
- https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL
  (section 2.4)
- https://raw.githubusercontent.com/openssh/openssh-portable/master/serverloop.c ;
  https://raw.githubusercontent.com/openssh/openssh-portable/master/channels.c
- https://raw.githubusercontent.com/openssh/openssh-portable/master/session.c
- https://man.openbsd.org/sshd_config (OpenBSD-current, 2026-09-17)
- https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT
- https://www.openssh.com/txt/release-6.7 ; https://www.openssh.com/txt/release-7.9
- https://raw.githubusercontent.com/mkj/dropbear/master/CHANGES ;
  https://raw.githubusercontent.com/mkj/dropbear/master/src/default_options.h

Docker / Podman / Compose

- https://docs.docker.com/reference/api/engine/ ;
  https://docs.docker.com/reference/api/engine/version/v1.55.yaml ;
  https://raw.githubusercontent.com/moby/moby/master/api/swagger.yaml (1.56)
- https://docs.docker.com/reference/api/engine/version-history/
- https://docs.docker.com/engine/release-notes/ (29.9.0, 2026-10-08; 29.3.0
  min-API change)
- https://www.docker.com/blog/docker-engine-version-29/
- https://raw.githubusercontent.com/docker/cli/master/cli/connhelper/connhelper.go
- https://raw.githubusercontent.com/moby/moby/master/daemon/server/router/distribution/distribution_routes.go
- https://raw.githubusercontent.com/moby/moby/master/daemon/server/router/container/container_routes.go
- https://docs.docker.com/engine/security/protect-access/
- https://docs.docker.com/engine/install/linux-postinstall/
- https://docs.docker.com/engine/security/rootless/
- https://docs.docker.com/engine/logging/dual-logging/ ;
  https://docs.docker.com/engine/logging/configure/
- https://docs.docker.com/docker-hub/usage/pulls/
- https://docs.podman.io/en/latest/markdown/podman-system-service.1.html
- https://storage.googleapis.com/libpod-master-releases/swagger-latest.yaml
- https://raw.githubusercontent.com/containers/podman/main/version/version.go ;
  .../version/rawversion/version.go ; .../cmd/podman/system/dial_stdio.go
- https://github.com/containers/podman/releases
- https://raw.githubusercontent.com/docker/compose/main/pkg/api/labels.go ;
  .../pkg/api/api.go ; .../cmd/formatter/formatter.go ; .../cmd/compose/ps.go
- https://github.com/docker/compose/releases
- https://docs.docker.com/reference/cli/docker/compose/ps/ ; .../ls/ ;
  .../config/
- https://docs.docker.com/compose/migrate

Linux metrics / systemd

- https://man7.org/linux/man-pages/man5/proc_stat.5.html ;
  https://man7.org/linux/man-pages/man5/proc_meminfo.5.html
- https://docs.kernel.org/accounting/psi.html ;
  https://raw.githubusercontent.com/torvalds/linux/master/init/Kconfig
- https://docs.kernel.org/admin-guide/iostats.html ;
  https://docs.kernel.org/block/stat.html
- https://docs.kernel.org/hwmon/sysfs-interface.html
- https://raw.githubusercontent.com/systemd/systemd/main/NEWS ;
  https://raw.githubusercontent.com/systemd/systemd/v246/src/systemctl/systemctl.c
  (vs v245) ; .../main/man/systemctl.xml ; .../main/man/journalctl.xml ;
  .../main/docs/JOURNAL_EXPORT_FORMATS.md
- https://github.com/systemd/systemd/issues/39081
- https://www.kernel.org/pub/linux/utils/util-linux/v2.27/v2.27-ReleaseNotes
- https://git.kernel.org/pub/scm/network/iproute2/iproute2.git/plain/man/man8/ss.8 ;
  .../ip.8
- https://dev.yorhel.nl/ncdu/man ; https://dev.yorhel.nl/ncdu/jsonfmt
- https://fossies.org/linux/smartmontools/NEWS ; https://www.mankier.com/8/smartctl
- lm-sensors 3.5.0 changelog via
  https://src.opensuse.org/pool/sensors/src/branch/factory/sensors.changes
- https://dnf.readthedocs.io/en/latest/command_ref.html ;
  https://dnf5.readthedocs.io/en/latest/commands/check-upgrade.8.html ;
  https://dnf-plugins-core.readthedocs.io/en/latest/needs_restarting.html
- https://lists.debian.org/deity/2020/03/msg00034.html (apt CLI stability)

Privilege

- https://www.sudo.ws/docs/man/sudo.man/ ; https://www.sudo.ws/docs/man/sudoers.man/
- https://github.com/trifectatechfoundation/sudo-rs ;
  https://raw.githubusercontent.com/trifectatechfoundation/sudo-rs/main/docs/man/sudo.8.md ;
  https://raw.githubusercontent.com/trifectatechfoundation/sudo-rs/main/CHANGELOG.md
- https://packages.ubuntu.com/questing/sudo-rs ;
  https://changelogs.ubuntu.com/changelogs/pool/main/r/rust-sudo-rs/rust-sudo-rs_0.2.8-1ubuntu5.2/changelog
- https://raw.githubusercontent.com/cockpit-project/cockpit/main/doc/protocol.md

Peers

- flutter_server_box @ 50e61edc (2026-10-10), read locally:
  lib/data/provider/server/single.dart, lib/data/ssh/persistent_shell.dart,
  lib/data/model/app/scripts/script_consts.dart, lib/data/res/default.dart,
  monitor/README.md, crates/sbm_parser/src/
- https://beszel.dev/guide/what-is-beszel ; https://beszel.dev/guide/security
- Sibling reports r1 (Docker UIs), r3 (server panels/monitoring) for Cockpit,
  Beszel, Komodo, Portainer, Hawser and Netdata details and their sources.

Background execution / push

- https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
  (iOS 26.0+)
- https://raw.githubusercontent.com/androidx/androidx/androidx-main/work/work-runtime/src/main/java/androidx/work/PeriodicWorkRequest.kt
- https://developer.android.com/develop/background-work/services/fgs/timeout
- https://docs.ntfy.sh/config/ (iOS upstream relay)
- https://dart.dev/tools/dart-compile (cross-compilation)
- https://api.dart.dev/dart-io/HttpClient/connectionFactory.html ;
  https://api.dart.dev/dart-io/ConnectionTask-class.html ;
  https://api.dart.dev/dart-io/Socket-class.html ;
  https://api.dart.dev/dart-io/HttpClientResponse/detachSocket.html

Security tooling

- https://trivy.dev/latest/docs/target/container_image/
- https://www.wiz.io/blog/trivy-compromised-teampcp-supply-chain-attack ;
  https://stack.watch/vuln/CVE-2026-33634/ (Trivy v0.69.4 compromise)
- https://oss.anchore.com/docs/reference/grype/cli/
- https://docs.docker.com/reference/cli/docker/scout/cves/ ;
  https://github.com/docker/scout-cli
- https://docs.sigstore.dev/cosign/verifying/verify/

Hauntware repository

- seance/AGENTS.md (security model), seance/docs/INBOX.md (producer pattern,
  no push), seance/packages/seance_core/lib/src/ssh/ssh_session.dart,
  .../remote_command.dart, poltergeist/seance pubspec.lock (dartssh2 sha256).
