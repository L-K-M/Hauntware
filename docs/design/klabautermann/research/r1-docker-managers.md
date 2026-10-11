# R1: Docker and container management tools, survey and feature inventory

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Research date: 2026-10-10. Scope: tools a fourth Hauntware app (native
Flutter, five platforms, SSH via dartssh2 3.0.2, synced `ServerConfig` list)
would be compared against for its Docker half. Primary sources were used where
reachable (official sites, docs, GitHub READMEs/releases, App Store listings).
Secondary sources (blogs, aggregators) are marked as such. "Not verified" means
I could not confirm a claim from a primary source; treat it as a lead.

Legend used in tables: **Y** = has it, **P** = partial/limited, **-** = no or
not found, **BE/Ent/Pro** = paid tier only, **?** = could not verify.

---

## 1. Executive findings

1. **Dockhand is the current homelab favourite and the feature-density
   benchmark.** v1.0.52 shipped 2026-10-10 with a roughly weekly cadence since
   its first release in late 2025. Its distinctive core is the *update pipeline*:
   digest-based update detection, a minimum-image-age cooldown, advisory
   "newer semver tag" suggestions with rendered release notes, and a
   "safe-pull" flow that pulls to a temporary tag, scans it with Grype/Trivy and
   deploys only if a vulnerability policy passes. Around that sit compose
   validation with one-click fixes, a live deploy console with deploy history,
   container and volume file browsers, restic backups, external secret
   managers, 15+ notification channels and customisable per-environment
   dashboard tiles.
2. **No mainstream Docker manager connects over SSH.** Dockhand (socket,
   TCP/TLS, Hawser agent), Portainer (agent, edge agent, TCP), Arcane (direct or
   edge agent), Komodo (Periphery agent) and Dozzle (agent) all require either an
   exposed Docker API or an installed agent. Dockhand's own docs suggest running
   an external `ssh -L` tunnel as a workaround. SSH-native options are limited to
   Podman Desktop (Podman only), Cockpit (multi-host switcher deprecated since
   Cockpit 322), lazydocker (one host via `DOCKER_HOST=ssh://`, with known
   context bugs), VS Code Container Tools (Docker contexts) and a handful of
   mobile apps. An SSH-native app with zero server footprint that reuses an
   existing synced server list is a real gap.
3. **The transport is solved in our stack.** dartssh2 has had
   `forwardLocalUnix()` (the equivalent of `ssh -L port:/var/run/docker.sock`)
   since 2.14.0. So the app can speak the Docker Engine REST API, including
   streaming logs, stats and events and hijacked exec sessions, over an SSH
   channel without CLI scraping. `docker system dial-stdio` over an exec channel
   is the fallback for sudo-only or context-based setups. ServerBox and the
   mobile apps scrape CLI output instead, which is why they feel thin.
4. **Table stakes in 2026** are lifecycle with bulk actions, followed logs with
   download, an exec shell, live per-container CPU and memory, image
   pull/prune with an "unused" flag, volume and network CRUD, compose stack
   edit/up/down/pull with streamed output, an update-available indicator,
   multi-host, and dark mode.
5. **Differentiators worth stealing:**
   - From Dockhand: scan-gated updates, release-note badges, compose
     validation, and generating compose from a running container.
   - From Dozzle (v11): merged multi-container logs, regex/SQL search, JSON and
     log-level parsing, and log/metric/event alert rules.
   - From Docker Desktop: a file browser that highlights changed files, a
     global merged Logs view with saved filter presets, and column
     customisation.
   - From Sencho: drift detection.
   - From Arcane: "back up to Git" and a container processes tab.
   - From Docker Manager: SSH & Compose (iOS): a security review of privileged
     containers and exposed ports.
6. **Gaps nobody fills well:**
   - Network topology visualisation. Dockhand only has a compose dependency
     graph.
   - Merged *host plus container* logs (journald alongside Docker).
   - A real compose diff or preview before deploy.
   - Cross-host search.
   - One native client that combines host observability with Docker management.
     ServerBox and Docker Server Admin try, but their Docker side is shallow.
7. **The hard limit of a client-only app is anything that must run while the
   app is closed:**
   - scheduled update checks and auto-updates
   - alerting
   - metric history
   - GitOps webhooks
   - push notifications
   - enforceable RBAC and audit logging

   Membership in the `docker` group is root-equivalent, so RBAC cannot be
   enforced by a client. The options are: accept the limit, install a
   host-side timer/cron helper over SSH (no daemon), or ship an optional agent.
   ServerBox already ships an optional agent ("ServerBox Monitor") for exactly
   these reasons.
8. **The update-notifier landscape shifted.** containrrr/watchtower was archived
   on 2025-12-17; a community fork (nicholas-fedor/watchtower) continues. WUD
   9.3.0 (2026-10-04) added rollback on HEALTHCHECK failure. Diun is at v4.33.0
   (2026-05-30). Update management is now absorbed into the managers
   themselves: Dockhand, Arcane, Dozzle 11.3 and Komodo.

---

## 2. Connection architectures (taxonomy)

How tools reach a Docker daemon determines what a native SSH client can copy.

| Pattern | Who uses it | Notes for an SSH client |
|---|---|---|
| Mount `/var/run/docker.sock` into a web app container | Dockhand, Portainer, Dockge, Arcane, Dozzle, Sencho, Tugtainer, WUD | Root-equivalent, single host unless combined with below |
| Docker API over TCP (2375 plain / 2376 TLS), often via a socket proxy | Dockhand "Direct", Portainer, Dockpeek, WUD, Tugtainer | Exposes the daemon on the network. Socket proxies (e.g. tecnativa) restrict API sections |
| Inbound agent (manager dials agent) | Portainer Agent (9001), Hawser Standard (2376), Arcane direct agent (3553), Komodo Periphery (classic), Dozzle agent (7007), Beszel agent | Needs an inbound port and an install on every host |
| Outbound/edge agent (agent dials manager over WebSocket, gRPC or polling) | Portainer Edge Agent (9443 + 8000 tunnel), Hawser Edge (`/api/hawser/connect` WebSocket, 30 s heartbeat), Arcane edge agent (WebSocket/gRPC, optional mTLS), Komodo v2 outbound Periphery | Solves NAT. Requires a central, always-on server |
| SSH plus Docker CLI scraping (`docker ps --format '{{json .}}'`) | ServerBox, Docker-Manager (Android), Opsivo, Docker Server Admin | Zero install. Brittle parsing, polling only, no real streaming exec |
| SSH plus Engine API tunnelled over the SSH channel | Docker CLI `DOCKER_HOST=ssh://` (`docker system dial-stdio`), lazydocker, VS Code contexts, Podman remote (`podman system connection`), "Docker Manager: SSH & Compose" (iOS) appears to do this or CLI | Zero install and full API fidelity. **The recommended path for Hauntware** |
| Local VM or desktop | Docker Desktop, OrbStack, Podman Desktop (podman machine) | Local only. UX reference, not an architectural one |
| Cockpit bridge over SSH | Cockpit + cockpit-podman | Cockpit 322 deprecated the multi-host switcher: browser same-origin limits could not isolate hosts from each other. Red Hat now recommends Cockpit Client (flatpak) or one host per session |

Engine API compatibility note: Docker Engine 29.0 to 29.2 raised the minimum
client API version to 1.44, and 29.3.0 (2026-03-05) lowered it back to 1.40. A
client must negotiate the version via `/_ping` or `/version` (`MinAPIVersion`),
not hard-code it. Podman exposes a Docker-compatible API on
`/run/podman/podman.sock` (rootful) or `/run/user/$UID/podman/podman.sock`
(rootless).

---

## 3. Tool profiles

### 3.1 Dockhand (owner's reference)

- **What:** Self-hosted Docker management web UI by Finsys. SvelteKit 2 /
  Svelte 5 / shadcn-svelte / Tailwind frontend, Bun backend, SQLite or
  PostgreSQL 16 via Drizzle. Wolfi/apko hardened image (`fnsys/dockhand`),
  served on port 3000. About 6.7k GitHub stars.
- **Version:** v1.0.52, 2026-10-10. Changelog shows near-weekly releases since
  v1.0.13 (2026-01-23). First release was December 2025 (secondary source).
- **License/pricing:** BSL 1.1. Each version converts to Apache 2.0 four years
  after release (the current line converts on 2029-01-01 per a third-party
  summary).
  - Free: unlimited environments, OIDC/SSO, TOTP MFA, passkeys, Git, scanning.
  - SMB: $499/host/year (commercial-use license, support).
  - Enterprise: $1,499/host/year (LDAP/AD, RBAC with environment scoping,
    audit logging).
  - Here "host" means one machine running Dockhand.
- **Architecture/multi-host:** Four environment types:
  - Unix socket.
  - Direct HTTP/HTTPS: TCP 2375/2376 with TLS, or a socket proxy.
  - Hawser Standard: a Go agent on port 2376 that proxies the local socket, with
    Dockhand dialling in.
  - Hawser Edge: the agent opens an outbound WebSocket to
    `/api/hawser/connect`. Token auth is mandatory (Argon2id-hashed, shown
    once), with exponential-backoff reconnect and a 30 s heartbeat.

  Hawser installs via script (systemd/OpenRC), `docker run`, or a manual unit.
  **No SSH transport.** The docs recommend an external SSH tunnel (autossh) as
  a workaround. Activity collection per environment runs in stream or poll mode
  (30 to 300 s).
- **Platforms:** Any Docker host. Docker and Podman, rootless, Synology, ARM64
  (Raspberry Pi 4 advertised), Windows Docker hosts (changelog).
- **Features (exhaustive by area):**
  - *Dashboard:* resizable per-environment tiles. 1x1 shows counts plus CPU/mem
    bars; larger tiles add a health banner, an 8-item recent-events list, top
    containers by CPU and CPU/mem charts. The full 2x4 tile adds a disk usage
    breakdown. Presets: Compact/Standard/Detailed/Full. Data streams over SSE
    with a 30 s CPU/mem refresh. Layout is stored in localStorage.
  - *Containers:*
    - The list sorts by state, health, uptime, CPU %, memory, network and disk
      I/O, IP, ports and stack. Search covers name, image and stack.
    - Row buttons: start, stop, pause, restart, inspect, browse files, edit,
      logs, terminal, delete. Bulk actions: start, stop, restart, remove.
    - The create form covers ports, volumes, env (sensitive values masked),
      network mode, restart policy and CPU/mem limits. CPU, memory and restart
      policy can be updated in place. Networks can be attached and detached
      live.
    - "Config sets" are reusable env/labels/ports/mounts presets.
    - Container and app icons come from selfh.st. A `dockhand.url` label adds a
      globe link. `dockhand.notify=false` mutes a container.
    - The inspect dialog's Compose tab *generates a compose service from any
      container*. It can validate, save as a new stack or append to an existing
      one.
  - *Logs:* SSE streaming with ANSI colour, pause/resume, auto-scroll, a
    download, 10 to 18 px font, a Live/Connecting/Disconnected/Paused
    indicator, and a 500 KB buffer per panel. Stopped containers are supported.
    Merged multi-container logs, search and timestamp toggles are not
    documented.
  - *Terminal:* choice of shell (bash/sh/zsh/ash) and user. Cmd+L clears.
    Through a socket proxy it needs EXEC enabled.
  - *File browser:* breadcrumbs, upload, download as tar, file info, chown,
    edit.
  - *Stacks:*
    - Visual compose editor and a read-only view with a dependency graph.
    - Templates or Git as sources. Untracked stacks can be adopted: scan a
      folder, detect `.env`, use the compose `name`. Stacks can also be adopted
      from other container managers.
    - Live deploy console (since 1.0.47) with search, copy and download.
    - Deploys tab: status, timing, trigger (manual/scheduled/webhook), a
      created/recreated/started summary and the full log.
    - *Validate* (since 1.0.43) runs `docker compose config` plus Dockhand's
      own rules: duplicate host ports, cross-stack port collisions, hard-coded
      secrets, Docker socket mounts. Findings show as gutter markers, with
      one-click fixes only where the fix is unambiguous. Validation never
      blocks a deploy.
    - Stack secrets are encrypted.
  - *Git:* per-stack branch, compose path, context dir and sync schedule. Build
    and no-cache options, plus re-pull and force redeploy. A redeploy happens
    only when files change. Webhooks support HMAC-SHA256
    (GitHub/Gitea/Forgejo) or a token (GitLab), and skip when there are no new
    commits.
  - *Updates:*
    - Manual and scheduled checks, with a per-environment minimum image age
      cooldown (`MINIMUM_RELEASE_AGE_HOURS`).
    - An amber arrow indicator on lists, tiles and stack rows, with
      "update all flagged".
    - Newer-version-tag advisories (1.0.43+): max bump patch/minor/major, flavour
      matching (`-alpine`), a prerelease toggle, and ignoring older builds by
      registry build date. Per-container `dockhand.tag.include/exclude` regex
      labels; WUD labels are honoured.
    - A badge opens release notes rendered from GitHub/Gitea/Forgejo source
      labels.
    - Auto-update per container (daily/weekly/cron, timezone) or per
      environment. Vulnerability gates: never, any, critical+high, critical
      only, or "more than current".
    - Safe-pull: pull to a temporary tag, scan, deploy only on pass.
  - *Images:* pull with per-layer progress, load from tar (air-gapped), and row
    actions run/scan/tag/push/export/history/delete. An "unused" badge drives
    "Prune unused" (`dockhand.prune=false` exempts an image).
    Grype/Trivy scanning is cached by image ID, with exports to MD, CSV, JSON
    and SARIF and a CVE dashboard.
  - *Volumes:*
    - Browse through a `busybox` helper container: read-only if the volume is
      in use, removed on close.
    - Clone through a helper container, keeping driver, options and labels.
    - Export as tar, and inspect.
  - *Networks:* bridge/host/overlay/macvlan/ipvlan/none. The create dialog has
    IPAM (subnet, gateway, range, aux addresses), driver options and labels.
    Connect with DNS aliases and a static IPv4. Built-in networks are
    protected.
  - *Registries:* a registry browser (search, tags, manifest, pull from
    results).
  - *Templates:* card grid with search and category/source filters. Sources
    include Portainer v2 JSON catalogs and Lissy93. Types 1 (container) and 3
    (compose) are supported. Deployed templates become ordinary stacks.
  - *Activity log:* Docker events (create, start, stop, die, kill, restart,
    pause, unpause, oom, health_status) with container/type/environment/label
    and date-range filters. Must be enabled per environment.
  - *Schedules:* a page listing auto-update, Git sync and cleanup jobs, with
    cron presets, a human-readable preview, and last and next run times.
  - *Backups (beta, restic):*
    - Per-volume or per-stack configs with optional stop-before-backup.
      Retention keep-last/daily/weekly/monthly/yearly, bandwidth limits and
      excludes.
    - Destinations: local, S3-compatible, B2, Azure, GCS, REST, SFTP.
    - Snapshot browse, diff and download. Restore to another environment, or
      overwrite live behind a guarded red button.
    - Repository check/prune/unlock/repair.
  - *Secrets:* external providers: 1Password, Vault, Infisical, Doppler,
    Bitwarden, Proton Pass, Azure Key Vault, KeePassXC.
  - *Notifications:* SMTP plus webhooks/Apprise (Discord, Slack, Telegram,
    ntfy, Gotify, Pushover, Signal, Bark, MQTT, Zabbix, Mattermost, Teams).
    Event catalogue:
    - container: started, stopped, exited, unhealthy, OOM, updated, pulled
    - auto-update: success, failed, blocked by policy, newer tag
    - Git sync
    - stack deploy
    - vulnerabilities by severity
    - backup
    - environment online/offline
    - disk-space warning
    - prune results
  - *Platform:* OIDC/LDAP/TOTP/passkeys, API tokens (`dh_`, rate-limited), a
    REST API for every action, OpenAPI at `/api/docs` (opt-in), Prometheus
    `/metrics`, Ctrl/Cmd+K command palette, reorderable sidebar and columns,
    font sizes, light/dark.
  - *Tags:* an instance-wide tag catalogue with per-environment assignment, an
    inline picker, label-driven tags (`dockhand.tags` with colour/icon), and
    grouping/colour bands with match-any/all.
- **UX patterns worth copying:**
  - Information-dense tiles that grow with size.
  - Amber "attention" colour used consistently for updates, unused images and
    activity.
  - A connection-state chip on the log stream.
  - Deploy console plus history as the audit trail.
  - Validation shown as editor gutter markers with conservative auto-fix.
  - Label-driven configuration (`dockhand.*`) so CLI-created containers
    participate.
  - Generating compose from a running container as an on-ramp to stacks.
  - Release notes in a dialog from a badge.
- **Gaps and complaints:**
  - BSL license.
  - RBAC, LDAP and audit are paywalled.
  - No CLI.
  - Smaller contributor base, and an early UI freeze report (Bitdoze,
    2026-02, updated 2026-09).
  - No SSH transport.
  - No merged or stack-level logs and no log search documented.
  - Host observability limited to Docker disk usage.
  - Activity log is opt-in per environment.
  - Users praise it for not jumping the log scroll the way Portainer does
    (Lemmy).
- **Relevance:** Primary feature benchmark. Most container, image, volume and
  network features map 1:1 onto Engine API calls a native client can make over
  SSH. The scheduled and notification parts (auto-update, Git webhooks,
  backups on schedule, notifications) assume an always-on server.
- **Sources:** https://dockhand.pro/ · https://dockhand.pro/manual ·
  https://github.com/Finsys/dockhand ·
  https://mintlify.com/Finsys/dockhand/integrations/remote-hosts (SSH tunnel
  workaround) · https://www.bitdoze.com/arcane-vs-dockhand/ ·
  https://mariushosting.com/portainer-vs-dockhand-which-to-choose/ ·
  https://discuss.mschae23.de/post/53821

### 3.2 Portainer CE / BE

- **What:** The incumbent container management UI for Docker standalone,
  Swarm, Podman and Kubernetes. Go backend.
- **Version:** CE 2.45.2 LTS (2026-10-08), with 2.39.x LTS patches in parallel
  and 2.44.0 STS (2026-07-30). Recent work centres on security (SSRF allow-list,
  Docker-proxy authorization bypass fix in 2.45.0/2.39.7, server-side EdgeID
  enforcement), a GitOps Sources wizard (2.43) and Kubernetes APIs.
- **License/pricing:** CE is zlib-licensed and free. BE is free for 3 nodes.
  Starter is $1,045/yr (5 to 15 nodes) and Scale $2,095/yr (5 to 25 nodes);
  Enterprise is custom. BE adds:
  - full RBAC across teams and environments
  - registry browsing and management
  - authentication and activity logs with syslog export
  - image up-to-date indicators
  - relative-path volumes for Git stacks
  - container webhooks (my recollection; not re-verified)
- **Architecture:** Portainer server plus one of four connection types:
  - local socket
  - Docker API over TCP/TLS
  - Portainer Agent: inbound, HTTPS on 9001 with a self-generated cert
  - Edge Agent: outbound polling to 9443, with a reverse tunnel on 8000 opened
    on demand; async mode sends snapshots

  Edge has a waiting room and pre-staged join tokens.
- **Features:** container list and details (logs, inspect, stats with
  processes, console with user and command selection, attach for interactive
  containers, create image from container, duplicate/edit = recreate), images
  (pull, build, import/export, tag, push), volumes, networks, Swarm
  services/configs/secrets, stacks (web editor, upload, Git repo with polling
  or webhook, force redeploy, re-pull; custom templates), app templates (the
  "Portainer v2 JSON" format, a de-facto standard reused by Dockhand and
  Yacht), registries, users/teams, environments with tags and groups, events
  list.
- **UX patterns:** environment-first navigation (pick an environment, then
  resources). Ownership and access-control panel on each resource. "Limited"
  badge for stacks created outside Portainer. Image status column with green
  tick, orange cross or grey dash, plus click-to-recheck (BE).
- **Gaps/complaints:**
  - Heavy for homelab use ("a dump truck to carry groceries").
  - Gets in the way of debugging.
  - Features gated behind BE and node caps (users cite 3 to 5 free nodes).
  - External stacks only have limited control.
  - The log viewer jumps to the bottom.
  - Stack deploy gives a toast rather than streamed output.
- **Relevance:** Defines vocabulary and the template format. Its edge-agent
  design is the canonical answer to NAT, which SSH sidesteps.
- **Sources:** https://github.com/portainer/portainer/releases ·
  https://www.portainer.io/pricing · https://www.portainer.io/features ·
  https://docs.portainer.io/user/docker/stacks/add ·
  https://docs.portainer.io/user/docker/containers/view ·
  https://oneuptime.com/blog/post/2026-03-20-portainer-image-update-indicators/view
  (secondary) ·
  https://blog.websoft9.com/?p=5465 (agent vs edge, secondary)

### 3.3 Dockge

- **What:** A compose-only stack manager by Louis Lam (Uptime Kuma author).
  TypeScript, Socket.IO, xterm-based output. About 24.6k stars.
- **Version:** 1.5.0 (30 Mar; the year is not shown on the releases page, and
  no release after it is listed). 1.5.0 disabled the host console by default
  (`DOCKGE_ENABLE_CONSOLE`) after a security advisory. Release cadence has
  slowed; Bitdoze advises pinning the tag.
- **License:** MIT, free.
- **Architecture:** web app with the socket mounted and a stacks dir
  (`/opt/stacks`). Since 1.4.0 a primary instance can proxy other Dockge
  instances ("multiple agents").
- **Features:** create, edit, start, stop, restart, down and delete stacks;
  update images; interactive compose editor and `.env` editor; real-time
  pull/up/down progress in terminal panes; docker run to compose converter;
  web terminal; "Scan Stacks Folder".
- **UX patterns:**
  - "Won't kidnap your compose files": files stay on disk as the source of
    truth.
  - The stack page is split into an editor and a live terminal output.
  - Uptime-Kuma-style responsive list.
  - Simplicity is its selling point ("just works").
- **Gaps:** no single-container, network, volume or image management. Stacks
  must live in the stacks directory, and container and host paths must match.
  Single user, no Windows, slow maintenance (122 open issues, 51 PRs).
- **Relevance:** Shows that "compose files on disk are the truth" plus live
  command output is enough for many users. An SSH app can do this natively,
  with SFTP for the files and an exec channel for `docker compose`.
- **Sources:** https://github.com/louislam/dockge ·
  https://github.com/louislam/dockge/releases

### 3.4 Komodo

- **What:** A build-and-deploy manager across many servers by Mogh
  Technologies. Rust Core and Periphery, web UI. About 12.7k stars.
- **Version:** v2.3.3 (1 Sep 2026). v2.0.0 (24 Mar 2026) added:
  - outbound Periphery (agent dials Core)
  - Docker Swarm management
  - a Terminals dashboard and `km ssh`
  - PKI auth between Core and Periphery with auto-rotating keys
  - onboarding keys

  v2.3.0 added pagination, a multi-server Stats page, a used/cache memory
  breakdown with ZFS support, and cancellation of runs.
- **License:** GPL-3.0. Free, with no server limits.
- **Architecture:** Core (API, UI, database) plus a stateless Periphery agent
  per server that executes actions, reports system usage and fetches logs.
  Connection is inbound or, since v2, outbound.
- **Resources:**
  - Server: connection, alert thresholds.
  - Deployment: a single container.
  - Stack: compose, in the UI or from Git with webhooks, multiple compose files.
  - Repo: scripts.
  - Build and Builder: image builds, including single-use AWS builders.
  - Procedure: staged pipelines.
  - Action: TypeScript against the API with type-aware editor completions.
  - Alerter.
  - ResourceSync: declarative TOML in Git with ordered deploys across servers.
  - Variables/secrets interpolated across resources.
- **Monitoring:** CPU, memory and disk per server with threshold alerts and a
  stats history. Server shell and container exec terminals.
- **UX patterns:** everything is a "resource" with a uniform page layout
  (config, logs, updates log). An "Updates" feed records who ran what. Batch
  execution by tag. A TOML schema served for editor autocomplete.
- **Gaps/complaints:** a heavier setup (database, more RAM), a learning curve,
  and GitOps-centric concepts. Over-scoped for "just look at my containers".
- **Relevance:** The closest prior art for *server metrics plus Docker in one
  tool*, and for alert thresholds per server. Its resource model is too
  DevOps-heavy for our app's first versions.
- **Sources:** https://github.com/moghtech/komodo ·
  https://github.com/moghtech/komodo/releases · https://komo.do/docs/intro ·
  https://komo.do/docs/resources

### 3.5 Arcane

- **What:** A "Modern Docker Management, Designed for Everyone" web UI. Go
  backend (single binary), SvelteKit frontend, plus a CLI. About 7.8k stars.
  Active development under the getarcaneapp org.
- **Version:** v2.15.1 (2026-10-07). Releases arrive every few days. Recent
  additions:
  - registry browsing (2.15)
  - mobile table sorting (2.15)
  - a risk-based security view, a container processes tab and template search
    (2.14)
  - bulk updates and sorting by live CPU/mem (2.13)
  - "Back up to Git" sync mode, vulnerability CSV export and a "Fix available"
    filter (2.12)
  - durable jobs with offline recovery, daemon event streaming and tag-based
    updates (2.11)
- **License:** BSD-3-Clause, "Always free". **iOS app in TestFlight beta**
  (iOS/iPadOS 18+, macOS 26+).
- **Architecture:** web app with the socket mounted. Remote environments via a
  direct agent (manager dials agent on TCP 3553 with an API key) or an edge
  agent (dials out over WebSocket, gRPC or polling, with optional mTLS).
- **Features:**
  - Containers, images, volumes, networks and compose "Projects" with Git sync
    and GitOps lifecycle hooks.
  - Templates and template registries.
  - Auto-updates (scheduled, tag-based) and Trivy scanning.
  - Notifications (including Signal and Telegram topics).
  - Activity and events.
  - Roles and permissions, OIDC, passkeys, MFA, federated credentials.
  - REST API with OpenAPI 3.1, a CLI, a community MCP server (125 tools),
    SBOM, and a Compose Generator.
  - Swarm nodes.
- **UX patterns:** Portainer-like navigation with modern styling. Live CPU/mem
  sorting in lists. "Unsaved changes" guard on deploys. Reportedly
  phone-friendly.
- **Gaps:** tag-based updates do not gate on scan results (Bitdoze). A young
  repository (transferred org).
- **Relevance:** The permissively licensed open-source alternative to
  Dockhand, and an iOS client is in development, so mobile Docker management
  is a recognised direction. Still agent-based, not SSH.
- **Sources:** https://github.com/getarcaneapp/arcane ·
  https://github.com/getarcaneapp/arcane/releases · https://getarcane.app/ ·
  https://getarcane.app/docs · https://www.bitdoze.com/arcane-vs-dockhand/ ·
  https://www.virtualizationhowto.com/2025/12/why-arcane-might-be-the-next-big-docker-ui-for-the-home-lab/

### 3.6 Others in the web-manager space (brief)

- **Sencho** (Studio-Saelix, AGPL-3.0, pre-1.0, v0.94.x July 2026): a compose
  "control plane". Files stay on disk, with multi-host, volume browsing, stack
  health, **drift detection** and scheduling. It now has a Community tier,
  which implies a paid tier.
  Sources: https://github.com/Studio-Saelix/sencho ·
  https://newreleases.io/project/github/Studio-Saelix/sencho/release/v0.94.0
- **1Panel** (GPL-3.0, about 37k stars): a full Linux server panel with
  container management, an app store, websites/SSL, file and database
  management, backups and a WAF. Core plus agent architecture. The closest web
  analogue to a "server management + Docker" product.
  Source: https://github.com/1Panel-dev/1Panel
- **Yacht** (MIT): a template-centric Docker UI that is effectively dormant.
  Its README says it "has not been updated in a while", and a TypeScript
  rewrite is pending. Notable only for Portainer-template compatibility and
  `!variable` substitution in templates.
  Source: https://github.com/SelfhostedPro/Yacht
- **Coolify, Dokploy, CapRover**: self-hosted PaaS with large one-click
  catalogues. Adjacent, not direct competitors.
  Source: https://www.bitdoze.com/portainer-alternatives/ (2026-09-23).

### 3.7 Dozzle (log viewer, now growing into a manager)

- **What:** A real-time Docker/Swarm/Kubernetes log viewer that stores no logs.
  Go plus Vue 3, streaming over SSE/WebSocket, a 7 MB scratch image. About
  14.6k stars.
- **Version:** v11.3.0 (5 Oct 2026). v11 (11 Sep 2026) redesigned the UI.
  Later 11.x releases added:
  - OIDC
  - self-update
  - SQL analytics charts (DuckDB served locally)
  - adding agents from the UI
  - bulk and auto-updates
  - host metrics (load, disk, uptime)
  - log time-range filtering
  - a native-feeling mobile shell with a floating tab bar (11.2)
  - safe updates with rollback, plus container and volume disk sizes (11.3)
- **License:** MIT. An optional paid "Dozzle Cloud" handles notification
  delivery and summarisation.
- **Architecture:** socket mount. Agent mode (`agent` command on 7007) for
  multi-host. Swarm global service.
- **Features:**
  - Fuzzy container search, regex log search and SQL queries over logs.
  - Split-screen and merged/grouped log views. Groups come from compose
    projects or labels (`dev.dozzle.group`, `dev.dozzle.name`).
  - JSON detection with colour-coding and multi-line stack-trace grouping.
  - Live CPU/mem/network with history.
  - Shell and attach drawers, and start/stop/restart/update actions.
  - Download as zip.
  - Alert rules over logs, metrics and events (details below).
  - MCP server with OAuth.
- **Alert rules:** Three alert types:
  - *Log:* `message`, `level`, `stream`, with JSON dot paths such as
    `message.status >= 500`.
  - *Metric:* `cpu`, `memory`, `memoryUsage`, evaluated on a smoothed
    sample-window average with a cooldown.
  - *Event:* `die`, `oom`, `health_status`.

  Each rule pairs a container expression (`name contains "api" &&
  labels["env"]=="prod"`) with a trigger expression. Destinations are
  Slack/Discord/ntfy/generic webhooks with Go templates and a "Test" button.
- **UX patterns:**
  - A command palette.
  - Log-level colouring.
  - Expandable JSON rows.
  - Pinned or split panes.
  - A host-grouped sidebar.
  - `dev.dozzle.url` linking a container to its web UI.
- **Gaps:** logs are only what Docker retains (no storage). Not a full manager
  (no volume, network or compose editing).
- **Relevance:** Best-in-class log UX to emulate. Alert expressions are a good
  model for in-app filters even without background alerting.
- **Sources:** https://github.com/amir20/dozzle ·
  https://github.com/amir20/dozzle/releases ·
  https://dozzle.dev/guide/what-is-dozzle ·
  https://dozzle.dev/guide/alerts-and-webhooks

### 3.8 Lazydocker

- **What:** A keyboard-driven Docker and compose terminal UI by Jesse Duffield
  (gocui). About 53k stars. MIT.
- **Architecture:** a local Docker client, which honours `DOCKER_HOST`.
  `ssh://` contexts had bugs (issues #213, #510), and `DOCKER_HOST=ssh://...`
  is the documented workaround. One host at a time.
- **Features:**
  - Panels for project, services, containers, images, volumes and networks.
  - The right pane switches tabs for logs, stats (ASCII graphs, configurable
    metrics), env, config and top.
  - Attach, exec, restart, remove, rebuild, image ancestor layers and prune.
  - Custom commands (`commandTemplates`), mouse support and a one-hour default
    log window.
- **UX patterns:** everything one keypress away. The selection drives the
  detail pane. Context-aware keybinding hints in the footer. Fast with no
  page loads. This translates well to desktop keyboard shortcuts and a
  master-detail layout.
- **Gaps:** single host, no compose editing, terminal only.
- **Sources:** https://github.com/jesseduffield/lazydocker ·
  https://github.com/jesseduffield/lazydocker/issues/510

### 3.9 ctop

- **What:** a `top`-like condensed metrics view for many containers with a
  single-container view. Docker and runC connectors. MIT, about 17.8k stars.
  Effectively unmaintained: the last version referenced is v0.7.7, with 95
  open issues and 25 PRs.
- **UX patterns:**
  - A dense sortable table (CPU, mem, net, IO) with configurable columns saved
    to config.
  - Filter `f`, sort `s`/`r`, toggle all `a`, logs `l`, exec `e`.
  - A model for a "Top containers" screen.
- **Source:** https://github.com/bcicen/ctop

### 3.10 Docker Desktop

- **What:** Docker's official desktop app (local VM on macOS and Windows, plus
  Linux). Version 4.94.0 (2026-10-05) with Engine 29.8.0 and Compose 5.5.1 (in
  4.91).
- **License/pricing:** Personal is free. Pro $9 to $11, Team $15 to $16 and
  Business $24 per user per month. A paid subscription is required for larger
  commercial use under Docker's terms (the threshold is not on the pricing
  page).
- **Architecture:** local only. The GUI targets the Desktop engine and is not
  an SSH or remote manager.
- **Features and UX worth copying:**
  - *Containers view:* search, a "running only" toggle and a **Columns**
    picker. Live CPU %, mem usage/limit, mem %, disk R/W, net I/O, PIDs and
    last started can be shown, hidden and reordered, and the choice persists.
    Compose projects group with expand/collapse. Bulk checkbox actions. Row
    actions open the port in a browser, copy the `docker run` command, show
    image CVEs, or use Docker Debug.
  - *Container detail tabs:* Logs (Ctrl/Cmd+F search with match navigation,
    regex, timestamps, clickable links, per-container filter in compose apps),
    Inspect, Bind mounts, Exec, **Files** (browse, highlights recently
    added/changed/deleted files, in-place editor, drag-and-drop to or from
    host, download), Stats over time, and Debug.
  - *Docker Debug:* a toolbox shell (vim, htop, curl) for shell-less or
    distroless images.
  - *Global Logs view* (GA 4.72, export 4.77, clear 4.79): one merged stream
    of up to 100,000 entries across all containers and builds. Rows show
    timestamp, source and message, and expand. Filters cover containers and
    whole compose stacks. **Saved presets** hold selection plus search. Wrap
    and timestamp toggles.
  - *Ask Gordon (AI):* a right-side drawer with one-click diagnosis on problem
    rows (crash loops, error exits).
  - Customisable left navigation, global quick search, and a notification
    bell.
  - The Scout view was removed in 4.75.
- **Relevance:** The UX gold standard for detail tabs, the file browser and
  merged logs. Its row-level "diagnose this" affordance is a good pattern even
  without AI, using heuristics such as restart count or last exit code.
- **Sources:** https://docs.docker.com/desktop/release-notes/ ·
  https://docs.docker.com/desktop/use-desktop/ ·
  https://docs.docker.com/desktop/use-desktop/container/ ·
  https://docs.docker.com/desktop/use-desktop/logs/ ·
  https://www.docker.com/pricing/

### 3.11 OrbStack

- **What:** A native Swift macOS Docker/Linux VM app positioned as a Docker
  Desktop replacement. Free for personal use, Pro $8/user/month for commercial
  use (adds the Debug Shell), Enterprise custom.
- **UX worth copying:** a menu-bar app with quick global actions. Local domain
  names for containers. Volume and image files browsable in Finder. A Debug
  Shell. "Bind mounts and port forwards just work."
- **Relevance:** Shows that a native menu-bar or tray presence with quick
  actions is valued on desktop. Local only.
- **Sources:** https://orbstack.dev/ · https://orbstack.dev/pricing

### 3.12 Podman Desktop

- **What:** A CNCF sandbox, Red Hat-backed desktop GUI for Podman (also Docker
  and Kubernetes) on Linux, macOS and Windows. Free and open source (Apache-2.0,
  from my knowledge). Podman itself is at v6.0.x (July 2026).
- **Architecture:** local podman machine VMs. **Remote SSH connections** list
  `podman system connection` entries once a setting is enabled. They need an
  ed25519 key and the Podman socket enabled on the remote host.
- **Features:** containers, pods, images (build, push, pull), volumes,
  networks, compose support, Kubernetes (Kind, Minikube, remote contexts),
  generate Kube YAML from pods, an extensions marketplace, GPU support, and
  air-gapped install.
- **Relevance:** The only mainstream desktop GUI with first-class SSH remotes,
  but Podman-only and one connection at a time. Validates key-based SSH as an
  acceptable onboarding path.
- **Sources:** https://podman-desktop.io/ ·
  https://podman-desktop.io/docs/podman/podman-remote ·
  https://docs.podman.io/en/stable/markdown/podman-remote.1.html

### 3.13 Cockpit and cockpit-podman

- **What:** Cockpit is a web server-admin console (RHEL, Fedora, Debian).
  cockpit-podman (LGPL-2.1, upstream release 126 in May 2026; RHEL 10.2 ships
  121) talks to the Podman REST API.
- **Features:** containers and pods (pause/resume, force restart), images
  (pull latest before create), user versus system (rootless/rootful)
  containers, logs, console. Health checks and checkpoint/restore are from my
  knowledge, not re-verified. Cockpit itself covers overview metrics, logs
  (journal), services, storage, networking, accounts, a terminal and updates.
- **Architecture:** Cockpit reaches other hosts over SSH. **The multi-host
  switcher was deprecated in Cockpit 322**: the team found no way to stop hosts
  affecting each other within web-platform limits. It is disabled by default on
  Fedora 41+, RHEL 10, CentOS Stream 10, Debian testing and Arch, and can be
  re-enabled with `AllowMultiHost=yes`. Cockpit Client (flatpak) is the
  recommended alternative.
- **Relevance:** Strong evidence that *multi-host over SSH is better done in a
  native client than in a browser*. Cockpit is also the reference for the
  host-management half (journal, services, storage).
- **Sources:** https://github.com/cockpit-project/cockpit-podman ·
  https://cockpit-project.org/blog/cockpit-322.html ·
  https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/considerations_in_adopting_rhel_10/the-web-console ·
  https://www.cockpit-project.org/blog/cockpit-261.html ·
  https://access.redhat.com/errata/RHBA-2026:18282

### 3.14 Update notifiers and updaters

| Tool | Status / version | License | What it does | Notable mechanics |
|---|---|---|---|---|
| **Watchtower** (containrrr) | **Archived 2025-12-17**. Last release v1.7.1 (2023) | Apache-2.0 | Auto-pull and recreate | Community fork **nicholas-fedor/watchtower** is active (v1.19.0 reportedly 2026-06-30, secondary source). For homelabs, "not production" |
| **What's Up Docker (WUD)** | 9.3.0 (2026-10-04) | MIT | Watchers (Docker, TLS remote, Compose, Swarm, K8s, Nomad), registries (Hub, GHCR, ECR, GCR/GAR, ACR, Quay, GitLab, OCI), 30+ triggers, auto-update | Semver levels, regex `wud.tag.include/exclude` labels, registry webhooks, pre/post hooks (9.2), digest updates reporting version label and build date (9.2), one-shot CI mode, **rollback on HEALTHCHECK failure (9.3)**, RBAC/OIDC, Prometheus |
| **Diun** | v4.33.0 (2026-05-30) | MIT | Notify only | Providers: Docker, Swarm, K8s, Nomad, containerd (4.33), file. Many notifiers with templates. Prometheus metrics (4.32) |
| **Tugtainer** | Active. About 1.4k stars | MIT | Web UI auto-updater | Per-container "check only" or "auto-update", cron, multi-host via agent, socket-proxy support, image prune. Cannot update itself. "Not recommended for production" |
| **Cup** | About 1.4k stars | AGPL-3.0 | Fast update checker (Rust CLI and web) | Claims not to exhaust registry rate limits. JSON API (`/api/v3/json`). Doesn't trigger actions itself |
| Built into managers | Dockhand, Arcane, Komodo, Dozzle 11.3, Dockge, Portainer BE | - | - | Dockhand is richest (cooldown, semver advisories, release notes, scan gate). Dozzle and WUD now roll back |

Takeaways:
- *Digest comparison* is the baseline. Compare the local `RepoDigests` with the
  remote manifest digest from the registry, or from the Engine
  `/distribution/{name}/json` endpoint, which uses the host's credentials and
  IP.
- *Semver tag suggestion* and *release notes* (from the
  `org.opencontainers.image.source` label linking to GitHub releases) are the
  current differentiators.
- WUD label compatibility (`wud.*`) is a cheap interoperability win; Dockhand
  already honours them.

Sources: https://linuxiac.com/docker-update-tool-watchtower-reaches-end-of-maintenance/ ·
https://github.com/nicholas-fedor/watchtower · https://github.com/getwud/wud ·
https://github.com/getwud/wud/releases · https://github.com/crazy-max/diun ·
https://github.com/crazy-max/diun/releases · https://github.com/Quenary/tugtainer ·
https://github.com/sergi0g/cup

### 3.15 Dockpeek (port dashboard)

- **What:** A dashboard listing every published port and container web UI with
  one-click open. It extracts service URLs from Traefik labels and shows logs
  and update checks (floating-tag modes latest/major/minor). MIT, about 2.1k
  stars, around v1.6.6.
- **Multi-host:** remote daemons are reached over TCP (socket proxy). No
  install is needed on remote hosts.
- **Relevance:** An "Apps / Ports" view (host:port and Traefik/Caddy URLs,
  open in browser) is cheap for us to build and highly useful. With SSH we can
  even offer one-tap local port forwarding to unexposed ports.
- **Source:** https://github.com/dockpeek/dockpeek

### 3.16 VS Code Container Tools (ms-azuretools.vscode-containers)

- **What:** Microsoft's successor to the Docker extension. It is evolving to
  support Podman as well as Docker.
- **Container Explorer:** containers, images, volumes, networks and registries
  (Hub, GHCR, ACR), in panes that can be reordered and hidden.
- **Compose:** Compose Up, plus "Compose Up - Select Services". Compose groups
  can be started, stopped and viewed as logs per service.
- **Editing:** Dockerfile and compose IntelliSense, plus Docker's DX language
  service.
- **Commands:** "Prune System", and debugging.
- **Remote hosts:** a Contexts pane switches the target, including `ssh://`
  contexts. This is from my knowledge of the predecessor Docker extension and
  was not re-verified on the current docs page.
- **UX:** a tree explorer with context menus. "Attach Shell" opens the IDE
  terminal. Logs open in the terminal panel.
- **Relevance:** Developer users expect compose IntelliSense and validation. A
  compose editor with schema-aware completion would close that gap.
- **Sources:** https://code.visualstudio.com/docs/containers/overview ·
  https://marketplace.visualstudio.com/items/ms-azuretools.vscode-containers ·
  https://podman-desktop.io/blog/tags/vscode

### 3.17 Mobile and native Docker clients

| App | Platforms | Transport | Docker features | Pricing / notes |
|---|---|---|---|---|
| **ServerBox** (lollipopkit/flutter_server_box, **Flutter**) | iOS, Android, macOS, Linux, Windows, watchOS widget | SSH. Optional "ServerBox Monitor" agent for push, widgets, watch and history | Containers tab: start/stop/restart/delete/**logs**/**terminal** per container. Images tab: pull/delete. Prune containers, images, volumes or system (`system df`-driven summary such as "3 running, 1 stopped, 12 images, 809 MB"). Run log for `docker run`. Edit `DOCKER_HOST`. **Switch Docker/Podman per host** | AGPL-3.0, about 8.8k stars. Vendors dartssh2 as a path package and uses a Rust FFI parser (`sbm_parser`) for command output. Stats via `docker stats --no-stream`, flagged as a performance cost |
| **Docker Manager: SSH & Compose** (A. Freris) | iOS/iPadOS 17.6+ | SSH or Engine API, nothing installed | Start/stop/restart/pause/rename and CPU/mem limits. Live stats. Time-ranged shareable logs. Terminal plus **file manager in container**. Compose deploy/edit/update with per-service scale/restart/logs and `.env` editing with auto-backup. Pull/inspect/prune with **delete preview**. **Trivy/Grype scans**, disk usage breakdown, **volume backup/restore**, network connect/disconnect. Multi-host dashboard, **Docker event log**, alerts, widgets, Face ID, **SSH host-key pinning**, **security review of privileged containers and exposed ports** | Free with "Supporter" in-app purchases. v1.5.0 (October 2026). The most complete SSH-based mobile Docker app found, and the closest analogue to our Docker half |
| **Docker Server Admin** | iOS/iPadOS, Apple silicon Mac | SSH (jump host, SOCKS5) | Container CPU/mem/disk/net charts. Host dashboard (load, per-core CPU, mem, swap, disk, net). Container and image lifecycle. Logs, SSH terminal with snippets, SFTP explorer | IAP $29.99 / $59.99, 4.7 stars from 144 ratings. v2.0 "adapted for iOS 26". Shows the combined host-plus-Docker niche |
| **Opsivo: SSH, SFTP & Docker** (listing formerly "DockSSH") | iOS/iPadOS | SSH | Start/stop, logs, images, container creation (1.1.1), SFTP editing | Subscriptions plus lifetime $19.99. Has ads and tracking identifiers |
| **ServerCat** | iOS/macOS | SSH | Container management in the premium tier | Server-monitoring-first app |
| **Docker-Manager** (theSoberSobber, **Flutter**) | Android (Play), Windows | SSH (CLI) | Start/stop/restart/inspect/logs/live stats, container or host shell, compose filter, image build/pull/rename/delete, networks, volumes, host CPU/mem/load, prune, custom CLI path (Podman) | GPL-3.0, about 286 stars |
| **Harbour**, **Yomo**, **Pourtainer**, **Kontainer**, **Portarius** | iOS (Portarius is cross-platform but stale since 2023) | **Portainer API** | Containers, stacks, logs. Harbour adds widgets, Handoff and background notifications | Harbour $2.99. They depend on a Portainer install |
| **DeckOps** | iOS | Docker Engine API over HTTP(S) | Native Engine API client | Requires an exposed API |
| **Arcane iOS** | iOS/iPadOS 18+, macOS 26+ | Arcane server | TestFlight beta | Signals that web managers are going mobile |

Takeaways:
- Mobile users want widgets, biometric lock, shareable logs, push alerts and a
  quick status glance.
- The SSH-scraping apps are shallow on streaming (stats via `--no-stream`
  polling) and on compose.
- "Docker Manager: SSH & Compose" proves a deep feature set over SSH is
  feasible on iOS.

Sources: https://github.com/lollipopkit/flutter_server_box ·
https://raw.githubusercontent.com/lollipopkit/flutter_server_box/main/lib/data/model/app/menu/container.dart ·
https://deepwiki.com/lollipopkit/flutter_server_box/8-container-management
(AI-generated, secondary) · https://apps.apple.com/app/id6769207135 ·
https://apps.apple.com/us/app/docker-server-admin/id1591150334 ·
https://apps.apple.com/us/app/dockssh-ssh-docker-manager/id6757322033 ·
https://apps.apple.com/us/app/servercat-ssh-terminal/id1501532023 ·
https://github.com/theSoberSobber/Docker-Manager ·
https://apps.apple.com/us/app/id1582439659 · https://apps.apple.com/DE/app/id6479982236 ·
https://apps.apple.com/app/id6739602404 · https://apps.apple.com/us/app/deckops/id6761782141 ·
https://getarcane.app/

### 3.18 Adjacent: Beszel

A lightweight hub (PocketBase) plus agent for server monitoring. It covers
per-container CPU, memory and network history, alerts, S.M.A.R.T., multi-user
and OIDC. MIT, about 26k stars. From my knowledge (not re-verified), the hub
historically connected to agents over SSH with its key, and newer versions also
let agents dial in over WebSocket. It is relevant to the observability half and
shows demand for *history and alerts*, which need an always-on component.
Source: https://github.com/henrygd/beszel

---

## 4. Consolidated feature inventory

Columns:

| Code | Tool |
|---|---|
| DH | Dockhand |
| PT | Portainer CE (BE marks paid features) |
| DG | Dockge |
| KO | Komodo |
| AR | Arcane |
| DZ | Dozzle |
| LD | Lazydocker |
| DD | Docker Desktop |
| PD | Podman Desktop |
| CK | Cockpit Podman |
| SB | ServerBox |
| DM | Docker Manager: SSH & Compose (iOS) |

Marks come from the sources above. "?" means not verified, not "absent".

### 4.1 Containers

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Start/stop/restart/remove | Y | Y | stack | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Pause/unpause | Y | Y | - | ? | ? | - | Y | Y | ? | Y | - | Y |
| Bulk actions | Y | Y | - | P (by tag) | Y | Y | - | Y | ? | ? | - | ? |
| Create from form (ports, env, mounts, limits) | Y | Y | - (compose) | Y (Deployment) | Y | - | - | P | Y | Y | P (run cmd) | ? |
| Edit/recreate with changed config | Y | Y (duplicate/edit) | via compose | Y | ? | - | - | - | - | - | - | P |
| In-place update of CPU/mem/restart policy | Y | ? | - | - | ? | - | - | - | - | - | - | Y |
| Inspect (env, labels, mounts, ports, raw JSON) | Y | Y | - | Y | Y | P | Y | Y | Y | Y | - | Y |
| Health status shown | Y | Y | ? | ? | Y | Y | ? | ? | ? | ? | - | ? |
| Processes (`top`) | - | Y | - | ? | Y (2.14) | - | Y | - | ? | ? | - | ? |
| Generate compose from container / run-to-compose | Y | - | Y (run to compose) | - | Y (generator) | - | - | P (copy run cmd) | P (kube YAML) | - | - | - |
| Open port/URL, URL label | Y | Y | ? | ? | ? | Y | - | Y | ? | - | - | ? |
| Rename | ? | Y | - | - | ? | - | - | - | ? | Y | - | Y |
| Icons/tags/grouping | Y | P (env tags) | - | Y (tags) | P (labels) | Y (groups) | - | Y (compose) | ? | - | - | ? |

### 4.2 Logs

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Follow/stream | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Search/filter in log | ? | Y | - | Y | ? | Y (regex, SQL) | P | Y (regex) | ? | ? | ? | ? |
| Multi-container merged view | - | - | Y (stack) | Y (stack) | Y (project) | Y | P | Y (global, 100k) | ? | - | - | P (per service) |
| Timestamps toggle | ? | Y | - | ? | ? | Y | Y | Y | ? | ? | ? | ? |
| Time-range (since/until) | - | Y | - | ? | ? | Y (11.2) | Y | P (clear-to) | ? | ? | - | Y |
| Download/export/share | Y | Y | - | ? | ? | Y (zip) | - | Y | ? | ? | - | Y |
| ANSI colour, JSON/level parsing | ANSI | ANSI | ANSI | ANSI | ? | Y (JSON, levels, multi-line) | ANSI | Y (links) | ? | ? | ? | ? |
| Saved filter presets | - | - | - | - | - | P | - | Y | - | - | - | - |
| Alerts on log patterns | - | - | - | - | - | Y | - | - | - | - | - | - |

### 4.3 Exec, terminal, attach, files

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Exec shell (choose shell/user) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Attach to PID 1 | ? | Y | - | ? | ? | Y | Y | - | ? | ? | - | ? |
| Host shell | - | - | opt-in | Y | ? | - | - | - | - | Y (Cockpit) | Y | Y |
| Debug shell for distroless | - | - | - | - | - | - | - | Y (Docker Debug) | - | - | - | - |
| Container file browser (up/down/edit) | Y | - | - | - | ? | - | - | Y (+changed-file highlight) | ? | - | - | Y |

### 4.4 Stats and host metrics

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live per-container CPU/mem | Y | Y | - | Y | Y | Y | Y | Y | Y | Y | Y (polled) | Y |
| Net/block I/O, PIDs | Y | Y | - | ? | Y (net) | Y (net) | Y | Y | ? | ? | ? | ? |
| Sort list by live CPU/mem | Y | - | - | ? | Y | ? | Y | Y | ? | ? | - | ? |
| History charts | P (dashboard) | - | - | Y | Y | Y | P (session) | Y | ? | - | - | ? |
| Host CPU/mem/disk/load | P (disk, summary) | P (info) | - | Y (+alerts) | ? | Y (11.2) | - | - | - | Y | Y | Y |
| Docker disk usage (`system df`) | Y | ? | - | ? | ? | Y (11.3) | - | P | ? | - | Y | Y |
| Prometheus export | Y | - | - | ? | ? | - | - | - | - | - | - | - |

### 4.5 Images

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| List with size, in-use/unused flag | Y | Y | - | Y | Y | - | Y | Y | Y | Y | Y | Y |
| Pull with progress | Y (per layer) | Y | via compose | ? | Y | - | - | Y | Y | Y | Y | Y |
| Tag / push | Y | Y | - | (build push) | ? | - | - | Y | Y | ? | - | ? |
| History/layers | Y | Y | - | ? | ? | - | Y | Y | ? | ? | - | ? |
| Prune dangling/unused (with exemptions) | Y (label exempt) | P | - | Y | Y | - | Y | Y | Y | Y | Y | Y (preview) |
| Import/export tar | Y | Y | - | - | ? | - | - | ? | Y | ? | - | - |
| Build | - | Y | - | Y | ? | - | P (rebuild) | (CLI) | Y | ? | - | - |
| Update detection by digest | Y | BE | Y | Y | Y | Y | - | - | - | - | - | P |
| Newer semver tag advisory | Y | - | - | - | Y (tag-based) | - | - | - | - | - | - | - |
| Release notes for update | Y | - | - | - | - | - | - | - | - | - | - | - |
| Vulnerability scan | Y (Grype/Trivy, SARIF) | - | - | - | Y (Trivy) | - | - | P (CVE list) | - | - | - | Y (Trivy/Grype) |
| Registry browser | Y | BE | - | - | Y (2.15) | - | - | Y (Hub) | ? | - | - | ? |

### 4.6 Volumes and networks

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Volume list/create/remove | Y | Y | - | ? | Y | - | Y | Y | Y | ? | P (prune) | Y |
| Volume file browser | Y (helper) | BE | - | - | ? | - | - | Y | ? | - | - | ? |
| Volume size | ? | - | - | - | ? | Y (11.3) | - | Y | ? | - | - | Y |
| Volume clone | Y | - | - | - | ? | - | - | Y | - | - | - | - |
| Volume export/backup/restore | Y (tar, restic) | - | - | - | ? | - | - | Y (export/import) | - | - | - | Y |
| Network list/create (IPAM) | Y | Y | - | ? | Y (2.12) | - | Y | - | Y | ? | - | Y |
| Connect/disconnect container (alias, IP) | Y | Y | - | ? | ? | - | - | - | ? | - | - | Y |
| Topology visualisation | P (compose dep graph) | - | - | - | - | - | - | - | - | - | - | - |

### 4.7 Compose stacks

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Discover/adopt external stacks (labels or folder) | Y | P ("Limited") | P (stacks dir scan) | ? | ? | Y (groups) | Y | Y | Y | - | - | Y |
| Edit compose and `.env` | Y | Y | Y | Y | Y | - | - | - | - | - | - | Y (+auto-backup) |
| Up/down/pull/redeploy | Y | Y | Y | Y | Y | - | P | P (start/stop) | P | - | - | Y |
| Per-service scale/restart | ? | ? | - | ? | ? | - | Y (restart) | Y | ? | - | - | Y |
| Live deploy output | Y (console) | P (toast) | Y | Y | ? | - | - | - | - | - | - | ? |
| Deploy history | Y | - | - | Y (updates log) | ? | - | - | - | - | - | - | - |
| Validation/lint | Y (rules + fixes) | - | - | P (schema) | ? | - | - | - | - | - | - | - |
| Diff/drift before deploy | - | - | - | P (sync diff) | - | - | - | - | - | - | - | - |
| Git-backed (webhook/poll) | Y | Y (poll/webhook; rel. paths BE) | - | Y (+TOML sync) | Y (+back up to Git) | - | - | - | - | - | - | - |
| Multiple compose files / includes | ? | P | - | Y | Y (2.15.1 include interp.) | - | - | - | - | - | - | ? |
| Secrets (encrypted, external managers) | Y | P (Swarm) | - | Y (variables/secrets) | Y | - | - | - | - | - | - | - |

### 4.8 Registries, updates, events, templates

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Registry credentials | Y | Y (mgmt BE) | - | Y | Y | - | - | Y (Hub) | Y | ? | - | ? |
| Update check manual/scheduled | Y | BE | Y (manual) | Y | Y | Y | - | - | - | - | - | P |
| Update notifications | Y | - | - | Y | Y | Y | - | - | - | - | - | Y |
| Auto-update policy (cron, per container) | Y | P (GitOps re-pull) | - | Y | Y | Y | - | - | - | - | - | - |
| Scan-gated / safe update | Y | - | - | - | - | Y (11.3 rollback) | - | - | - | - | - | - |
| Rollback | P (safe-pull gate) | - | - | - | P | Y | - | - | - | - | - | - |
| Minimum image age cooldown | Y | - | - | - | - | - | - | - | - | - | - | - |
| Events timeline | Y (opt-in, filters) | Y | - | P | Y | P (event alerts) | - | - | ? | ? | - | Y |
| Templates / app catalogue | Y (multi-source) | Y | - | - | Y | - | - | P (extensions) | P (extensions) | - | - | - |

### 4.9 Multi-host, security, team

| Feature | DH | PT | DG | KO | AR | DZ | LD | DD | PD | CK | SB | DM |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Multi-host | Y | Y | Y (1.4 proxy) | Y | Y | Y | - | - | Y (SSH) | P (deprecated) | Y | Y |
| Transport | sock/TCP/agent | sock/TCP/agent/edge | instance proxy | agent in/out | agent/edge | agent | local/ssh env | local | SSH/local | SSH | **SSH** | **SSH**/API |
| Agentless | P (TCP) | P (TCP) | - | - | - | - | Y | n/a | Y | Y | Y | Y |
| Podman/rootless | Y | Y | P | ? | ? | Y | ? | - | Y | Y | Y | ? |
| Socket-mount / privileged warnings | Y (validate) | P (BE bind-mount restrictions) | - | - | P (risk view) | - | - | - | - | - | - | Y (security review) |
| SSH host-key pinning | n/a | n/a | n/a | n/a | n/a | n/a | OS | n/a | OS | OS | ? | Y |
| SSO/OIDC/MFA | Y | Y (AD BE) | - | Y | Y | Y | n/a | Docker acct | n/a | OS | n/a | Face ID |
| RBAC | Ent | P / BE | - | Y | Y | Y (roles) | n/a | n/a | n/a | OS | n/a | n/a |
| Audit log | Ent | BE | - | P (updates) | ? | - | - | Team plan | - | journal | - | - |
| Notifications | Y (15+) | - | - | Y (Alerters) | Y | Y | - | - | - | - | Y (agent) | Y |
| Backups | Y (restic beta) | - | - | - | ? | - | - | P | - | - | - | Y (volumes) |
| API/CLI/MCP | API | API | - | API, TS client | API, CLI, MCP | MCP | - | CLI | CLI | - | - | - |

---

## 5. Insights

### 5.1 What makes Dockhand distinctive

1. **An update pipeline treated as a security feature.**
   - Detection by digest.
   - Advisory semver bumps that never edit compose.
   - Release notes inline.
   - A cooldown against freshly published (possibly compromised) images.
   - Safe-pull with scan gating per severity policy.
   - WUD label compatibility.

   No other tool combines all of these.
2. **Compose quality tooling.** Validate (compose config plus custom rules with
   gutter markers and conservative fixes), generating compose from running
   containers, and adopting stacks from other managers lower migration
   friction.
3. **Operational transparency.** A live deploy console, a deploy history with
   trigger and summary, an activity log of Docker events, and a schedules page
   with next and last runs.
4. **A dense, customisable UI.** Tile dashboard, sortable columns with live
   metrics, reorderable sidebar and columns, tags (including label-driven
   tags), selfh.st icons, a command palette and a consistent amber attention
   colour.
5. **Breadth beyond containers.** File and volume browsers, volume clone and
   export, restic backups with cross-environment restore, external secret
   managers, Prometheus, OpenAPI and many notification channels.
6. **A generous free tier** (SSO, MFA, scanning, unlimited environments), with
   teams features paywalled under BSL.

Weak spots to beat:
- No SSH.
- No merged or stack logs and no log search.
- Minimal host observability.
- Opt-in activity logging.
- Web-only. A responsive web UI, but no native or mobile client, widgets or
  notifications without a server.

### 5.2 Table stakes versus differentiators (2026)

**Table stakes**:
- Container lifecycle with bulk actions.
- Followed logs with download.
- An exec shell.
- Live CPU/mem per container.
- Inspect: env, ports, mounts, labels.
- Images: list, pull, delete, prune, with an unused flag.
- Volume and network CRUD.
- Compose stack list, edit, up, down, pull and redeploy with streamed output.
- An update-available indicator.
- Multiple hosts.
- Registry credentials.
- Dark mode.

**Differentiators**, ranked by observed user enthusiasm and rarity:
1. Safe or scan-gated updates with rollback, semver advisories and release
   notes (Dockhand, Dozzle 11.3, WUD 9.3).
2. Merged multi-container logs with regex search, JSON/level parsing, saved
   presets and time ranges (Dozzle, Docker Desktop).
3. Container and volume file browsers with editing and changed-file
   highlighting (Docker Desktop, Dockhand).
4. Compose validation, drift detection and dependency graphs (Dockhand,
   Sencho).
5. Volume backup and restore (Dockhand restic, Docker Manager iOS, Docker
   Desktop export).
6. Events timeline and deploy history.
7. A security posture review: privileged containers, socket mounts, exposed
   ports and CVEs (Docker Manager iOS, Dockhand validate, Arcane risk view).
8. Templates and app catalogues using the Portainer v2 JSON format.
9. Mobile niceties: widgets, biometric lock, shareable logs, host-key pinning.
10. "Diagnose this container" affordances (Docker Desktop's Gordon). These can
    be done heuristically from restart count, exit code, OOMKilled and the
    health log.

**Unfilled gaps** (opportunity):
- Network topology graph.
- Host-plus-container unified logs (journald alongside Docker).
- Real `docker compose up --dry-run` style previews and diffs.
- Cross-host search for containers, images and ports.
- One-tap SSH port-forward to a container's unexposed port.
- A unified host observability plus Docker client that is native and
  agentless.

### 5.3 What a client-side (no server component) SSH app can and cannot do

**Can do, with full fidelity over SSH:**
- **Engine API transport.**
  - Primary: `SSHClient.forwardLocalUnix('/var/run/docker.sock')` (dartssh2
    2.14.0+, available in our pinned 3.0.2). This is equivalent to
    `ssh -L port:/var/run/docker.sock`.
  - Fallback: an exec channel running `docker system dial-stdio`. This is the
    Docker CLI's own `ssh://` mechanism and works with `sudo` and contexts.
  - Podman: `/run/user/$UID/podman/podman.sock` or `/run/podman/podman.sock`.
  - Negotiate the API version from `/_ping` or `/version`.
  - Server side, OpenSSH must allow stream-local forwarding
    (`AllowStreamLocalForwarding`, default yes), and the SSH user needs socket
    permission (docker group, rootless socket, or sudo through dial-stdio).
- **Everything in the Engine API:**
  - lifecycle, create, update (`/containers/{id}/update` for in-place limits),
    rename, inspect, top
  - logs (follow, timestamps, since/until, multiplexed stdout and stderr)
  - streaming stats and events
  - exec with TTY resize over a hijacked connection
  - archive GET/PUT (tar) for a container file browser
  - image pull with progress, history, tag, push, import/export
  - `/distribution/{name}/json`: remote digest from the host's own credentials
    and IP, so no client-side registry rate-limit issues
  - `system df`, prune endpoints, volumes, networks with connect/disconnect
- **Compose:** not in the Engine API. Run `docker compose` over an exec channel
  (`--progress plain`/json for streamed output; `config` for validation;
  `up --dry-run` for previews where supported). Discover stacks from
  `com.docker.compose.project`, `.working_dir` and `.config_files` labels.
  Read and write compose and `.env` files over SFTP, which Poltergeist already
  implements.
- **Volume browsing:** a helper container (Dockhand's approach), or SFTP
  directly to `/var/lib/docker/volumes/...` if the SSH user can read it.
- **Scanning:** run Trivy or Grype as an ephemeral container on the host
  (Dockhand's approach) and parse the JSON.
- **Multi-host fan-out:** parallel SSH sessions with on-device aggregation and
  cross-host search.
- **Port access:** an SSH local forward to any container port for "open in
  browser", even when not published.
- **Host observability over the same session:** `/proc`, `journalctl`,
  `systemctl` and `crontab`. That is the other half of the planned app.
- **Interop:** read `wud.*` and `dockhand.*` labels. Import Portainer v2 JSON
  template catalogues.

**Cannot do (or only while the app is open):**
- Scheduled update checks and auto-update policies.
- Alerting on events, logs and metrics.
- Metric history beyond the session.
- Push notifications, with iOS background execution especially unreliable.
- GitOps webhooks, which need a listening endpoint.
- Scheduled backups.
- A persistent activity log. Docker keeps only a bounded in-memory events
  buffer, so gaps appear while disconnected.
- **RBAC and audit cannot be enforced.** Docker socket access is
  root-equivalent, so a client cannot restrict a user who has the SSH key.
  Read-only modes are UX guardrails, not security.
- Shared team state (tags, notes, pinned stacks). The existing E2E sync
  service can carry *user-side* metadata, but it is not a control plane.

**Mitigation options** (for the product plan to decide):
- (a) Accept the limit and present "check now" UX.
- (b) A host-side helper installed over SSH with no daemon: a systemd timer or
  cron entry plus a small script. It runs update checks or metric sampling,
  writes JSON state to a file the app reads on connect, and can call ntfy or
  webhooks directly. This fits a "no agent" stance best.
- (c) An optional agent, the ServerBox Monitor model, for push, widgets and
  history.
- (d) Interoperate with existing tools: read WUD or Diun state, link to Dozzle,
  Beszel or Dockhand.

---

## 6. Source index (primary unless noted)

- Dockhand: https://dockhand.pro/ · https://dockhand.pro/manual ·
  https://github.com/Finsys/dockhand ·
  https://mintlify.com/Finsys/dockhand/integrations/remote-hosts (docs mirror)
- Portainer: https://github.com/portainer/portainer/releases ·
  https://www.portainer.io/pricing · https://www.portainer.io/features ·
  https://docs.portainer.io/user/docker/stacks/add ·
  https://docs.portainer.io/user/docker/containers/view
- Dockge: https://github.com/louislam/dockge · https://github.com/louislam/dockge/releases
- Komodo: https://github.com/moghtech/komodo/releases · https://komo.do/docs/intro ·
  https://komo.do/docs/resources
- Arcane: https://github.com/getarcaneapp/arcane/releases · https://getarcane.app/ ·
  https://getarcane.app/docs
- Sencho: https://github.com/Studio-Saelix/sencho · 1Panel: https://github.com/1Panel-dev/1Panel ·
  Yacht: https://github.com/SelfhostedPro/Yacht
- Dozzle: https://github.com/amir20/dozzle/releases · https://dozzle.dev/guide/what-is-dozzle ·
  https://dozzle.dev/guide/alerts-and-webhooks
- Lazydocker: https://github.com/jesseduffield/lazydocker ·
  https://github.com/jesseduffield/lazydocker/issues/510
- ctop: https://github.com/bcicen/ctop
- Docker Desktop: https://docs.docker.com/desktop/release-notes/ ·
  https://docs.docker.com/desktop/use-desktop/container/ ·
  https://docs.docker.com/desktop/use-desktop/logs/ · https://www.docker.com/pricing/
- Docker Engine API versions: https://docs.docker.com/engine/release-notes/29.md ·
  https://www.docker.com/blog/docker-engine-version-29/
- OrbStack: https://orbstack.dev/ · https://orbstack.dev/pricing
- Podman Desktop: https://podman-desktop.io/ · https://podman-desktop.io/docs/podman/podman-remote
- Cockpit: https://github.com/cockpit-project/cockpit-podman ·
  https://cockpit-project.org/blog/cockpit-322.html
- Update tools: https://linuxiac.com/docker-update-tool-watchtower-reaches-end-of-maintenance/ (secondary) ·
  https://github.com/nicholas-fedor/watchtower · https://github.com/getwud/wud/releases ·
  https://github.com/crazy-max/diun/releases · https://github.com/Quenary/tugtainer ·
  https://github.com/sergi0g/cup
- Dockpeek: https://github.com/dockpeek/dockpeek
- VS Code: https://code.visualstudio.com/docs/containers/overview
- Mobile: https://github.com/lollipopkit/flutter_server_box ·
  https://apps.apple.com/app/id6769207135 ·
  https://apps.apple.com/us/app/docker-server-admin/id1591150334 ·
  https://apps.apple.com/us/app/dockssh-ssh-docker-manager/id6757322033 ·
  https://github.com/theSoberSobber/Docker-Manager · https://apps.apple.com/us/app/id1582439659
- dartssh2 Unix socket forwarding: https://pub.dev/packages/dartssh2/changelog
- Landscape (secondary): https://www.bitdoze.com/portainer-alternatives/ ·
  https://www.bitdoze.com/arcane-vs-dockhand/ ·
  https://mariushosting.com/portainer-vs-dockhand-which-to-choose/
- Beszel: https://github.com/henrygd/beszel
