# 01. Research, landscape and technical findings

This chapter condenses the nine research reports in
[research/](research/README.md) into one view of the market and of the
technical ground the server app stands on. The appendices hold the detail:
per-tool profiles, feature matrices and full source lists. The feature
catalog that grades each capability is [02-FEATURES.md](02-FEATURES.md); the
decisions built on these findings are in
[03-ARCHITECTURE.md](03-ARCHITECTURE.md).

How to read it:

- References such as `r1 §3.1`, `c1 §2.4` or `c2 R3` point to a report and a
  section or numbered item inside it. The keys are explained in
  [research/README.md](research/README.md#abbreviation-key).
- External facts (versions, dates, prices, licenses, CVEs, platform limits)
  are as of 2026-10-10. Codebase facts are as of commit `bf1da58`.
- Claims the reports did not verify keep their marker: "(unverified)" for
  secondary sources and prior knowledge, `[U]` for r5's unverified technical
  claims. Everything else was read from a primary source by the report cited.
- `03 §5` means section 5 of [03-ARCHITECTURE.md](03-ARCHITECTURE.md), and
  `04 Appendix A` refers to [04-IMPLEMENTATION.md](04-IMPLEMENTATION.md).
- `<app>` is the lowercase ASCII stem and `<App>` the display name; the
  product name is undecided ([05-NAMES.md](05-NAMES.md)).

## 1. Purpose and method

### 1.1 Questions

The research answered five questions before design work began:

1. Which tools does the app compete with or learn from, across Docker
   managers, self-hosting platforms, server panels, monitoring tools and
   native clients?
2. What do users treat as table stakes in 2026, and what is rare enough to
   differentiate?
3. Can a native client do this over plain SSH, with nothing installed on the
   host, and where does that model stop?
4. What does the Hauntware codebase already provide for a fourth app that
   shares the synced server list, and what must change first?
5. Where is the gap the app can fill?

### 1.2 Method

- **External and technical reports (r1 to r5).** Written on 2026-10-10 from
  primary sources where reachable: project sites, official documentation,
  READMEs, LICENSE files, release pages, App Store listings and source code.
  r4 read ServerBox from a clone at commit `50e61ed`. r5 read the dartssh2
  3.0.2 archive (its hash matches the repository lockfiles), OpenSSH's
  `PROTOCOL`, `serverloop.c` and `session.c`, docker/cli's `connhelper.go`,
  and the moby, Compose, Podman and systemd sources. r2 could not use the
  GitHub REST API, so its release numbers come from Docker Hub tags, release
  pages and vendor manifests.
- **Codebase reports (c1 to c4).** Read-only investigations of the
  repository at `bf1da58` (suite version 1.9.0), each claim cited as
  `path:line`. No Dart or Flutter tooling was run (c2, c3). c4 checked a few
  live GitHub figures: CI minutes and concurrency limits.
- **Markers.** Each report kept its own legend (listed in
  [research/README.md](research/README.md#marker-legend-used-in-the-reports)).

### 1.3 Limits

- The space moves weekly. Dockhand ships roughly every week and Arcane every
  few days (r1 §3.1, §3.5). Re-check versions before quoting them.
- Several claims rest on secondary sources: Easypanel's license, Unraid's
  versions and licensing, TrueNAS 26's REST removal, Cloudron's license
  model, JuiceSSH's removal date (r2 §1, r4 §1.8). They stay marked in the
  appendices.
- No spike was run. The shell and sudo experiments the plan depends on were
  done later and are recorded in
  [04-IMPLEMENTATION.md](04-IMPLEMENTATION.md) Appendix A.

## 2. The landscape by category

The architecture column uses these terms:

| Term | Meaning |
|---|---|
| socket | A web app container with `/var/run/docker.sock` mounted (root-equivalent) |
| TCP | Docker API over TCP 2375 or 2376, often behind a socket proxy |
| agent in / agent out | An installed agent that the manager dials, or that dials the manager |
| panel | A resident web panel on the host |
| OS | The product is the operating system or appliance |
| SSH | A client that talks SSH and installs nothing |

### 2.1 Docker managers (r1)

| Tool | License | Architecture | Platforms | Worth learning |
|---|---|---|---|---|
| Dockhand v1.0.52 | BSL 1.1, each version Apache 2.0 after four years; SMB $499 and Enterprise $1,499 per host per year | socket, TCP/TLS, Hawser agent (in on 2376 or out over WebSocket); no SSH, docs suggest an autossh tunnel | Any Docker host, Podman, rootless, Synology, ARM64 | The update pipeline (digest detection, minimum-age cooldown, semver advisories, release notes, scan-gated "safe-pull"); compose validation as editor gutter markers with conservative fixes; compose generated from a running container; deploy console with history; one amber attention colour; `dockhand.*` labels so CLI-created containers participate |
| Portainer CE 2.45.2 LTS, BE | CE zlib; BE free for 3 nodes, then paid | socket, TCP, agent in (9001), edge agent out (polling, tunnel on 8000) | Docker, Swarm, Podman, Kubernetes | The vocabulary and the Portainer v2 JSON template format others reuse; the edge agent is the canonical NAT answer that SSH sidesteps. Complaints: heavy, the log view jumps to the bottom, stack deploys report only a toast |
| Dockge 1.5.0 | MIT | socket plus `/opt/stacks`; an instance can proxy others | Docker hosts, no Windows | "Won't kidnap your compose files"; editor beside live command output; `docker run` to compose; host console disabled by default after an advisory |
| Komodo v2.3.3 | GPL-3.0 | Core plus a Periphery agent per server, in or (since v2) out | Many servers | Server metrics and Docker in one tool; per-server alert thresholds; an "Updates" feed of who ran what. Too DevOps-heavy for a first version |
| Arcane v2.15.1 | BSD-3-Clause | socket; direct agent (3553) or edge agent | Docker hosts; iOS app in TestFlight | Permissive Dockhand alternative; live CPU and memory sorting, a risk view, a processes tab, "back up to Git"; mobile is a recognised direction |
| Dozzle v11.3.0 | MIT; optional paid cloud for notifications | socket; agent mode (7007) | Docker, Swarm, Kubernetes | Best log UX: merged and grouped logs, regex and SQL search, JSON and level parsing, alert rules over logs, metrics and events; safe updates with rollback in 11.3 |
| Sencho v0.94 | AGPL-3.0 | socket, files on disk, multi-host | Docker hosts | Drift detection |
| lazydocker | MIT | Local client honouring `DOCKER_HOST`; one host, `ssh://` contexts buggy | Terminal | One keypress per action; selection drives the detail pane; context key hints in the footer |
| Docker Desktop 4.94.0 | Personal free; paid per user | Local VM only | macOS, Windows, Linux | Persisted column chooser; Files tab with changed-file highlighting; a global merged Logs view (100,000 entries, saved presets); a row-level "diagnose this" affordance |
| Podman Desktop | Apache-2.0 (unverified) | Local VMs; SSH connections to remote Podman sockets | Linux, macOS, Windows | The only mainstream desktop GUI with first-class SSH remotes; Podman only, one connection at a time |
| Cockpit with cockpit-podman | LGPL-2.1 | Web console; other hosts over SSH; multi-host switcher deprecated in 322 | RHEL, Fedora, Debian | Evidence that multi-host over SSH belongs in a native client; the host-management reference (journal, services, storage) |
| Dockpeek v1.6.6 | MIT | TCP through a socket proxy | Docker hosts | An apps and ports view built from published ports and Traefik labels; over SSH this becomes a one-tap forward even to unpublished ports |

Smaller references: ctop (MIT, unmaintained) for a dense "top containers"
table; OrbStack for menu-bar quick actions; VS Code Container Tools for the
expectation of compose completion and validation; Yacht as a dormant
template-centric UI.

**Update notifiers.** containrrr/watchtower was archived on 2025-12-17 (a
fork continues); What's Up Docker 9.3.0 defines the `wud.*` labels Dockhand
honours; Diun only notifies. Update management has moved into the managers
(r1 §3.14).

**Connection taxonomy (r1 §2).** Of the eight ways tools reach the daemon
(socket, TCP, inbound agent, outbound agent, SSH with CLI scraping, SSH with
the Engine API tunnelled, local VM, Cockpit's bridge), only SSH with the
tunnelled API gives zero install and full API fidelity.

**Table stakes in 2026 (r1 §5.2):** container lifecycle with bulk actions;
followed logs with download; an exec shell; live per-container CPU and
memory; inspect (env, ports, mounts, labels); image list, pull, delete and
prune with an "unused" flag; volume and network CRUD; compose stack list,
edit, up, down, pull and redeploy with streamed output; an update-available
indicator; multiple hosts; registry credentials; dark mode.

### 2.2 Self-hosting platforms and PaaS (r2)

| Tool | License | Architecture and footprint | Target | Worth learning |
|---|---|---|---|---|
| Coolify 4.4.6 | Apache-2.0 | panel on one host managing others **over SSH only**; optional Sentinel agent container; owns a proxy on 80/443; validation may restart Docker | Linux servers; can create cloud servers | The agentless existence proof (section 3.1); a per-channel, per-event notification matrix; honest backup wording; generated secrets that persist across deploys |
| Dokploy v0.30.8 | Apache-2.0, plus the source-available DSAL for `/proprietary` | Next.js panel, PostgreSQL, Traefik and Swarm; ports 80, 443 and 3000 must be free | Linux servers | Four scheduled-job types with a log per run; volume backups only for named volumes; warns against preview deploys on public repos |
| CapRover 1.15.4 | Apache-2.0 | Captain container with the socket; Swarm, nginx, wildcard DNS; default password `captain42` | Public servers | "No lock-in! Remove CapRover and your apps keep working!"; its template format honours only 8 compose keys; backups exclude volumes and images |
| Dokku 0.38.31 | MIT | Host CLI and plugins; owns the proxy and the `dokku` user's crontab | Ubuntu, Debian | Health-checked zero-downtime deploys; cron jobs installed in a host crontab, a precedent for host-native delegation |
| Kamal 2.12.0 | MIT | Agentless deploy tool on the developer's machine; kamal-proxy on hosts | Hosts reachable over SSH; installs Docker on fresh Ubuntu | Deploy lock and audit log kept **on the servers**; "just basic Docker commands"; health-gated cutover that drains in-flight requests |
| Cosmos Cloud 0.23.4 | Apache 2.0 with Commons Clause and an Anti-Tampering clause | One container with the socket; becomes the front door on 80/443 | Home servers | restic backups chosen so users keep control "even if you were to stop using Cosmos"; exposed public ports shown in orange |
| CasaOS, ZimaOS | Apache-2.0; no LICENSE in the public ZimaOS repo | Web UI on Debian; ZimaOS is the whole OS | Home | The `x-casaos` compose extension with multilingual field descriptions. CasaOS core stalled after v0.4.15 (unverified) |
| Umbrel 2.0 | PolyForm Noncommercial; umbrel-apps has no LICENSE | OS | Umbrel Home, Pi, Ubuntu, Debian | Images pinned by digest; the App Store Standard (every app opens to a UI without SSH or file edits); an update shelf. One package ships static DB passwords, an anti-pattern |
| Runtipi v4.10.2 | GPL-3.0 | One compose project per app behind Traefik | Home | Updates pull before stopping and restore files, environment and containers on failure; docs recommend host cron for auto-backup and auto-update |
| YunoHost | AGPL-3.0 | OS layer on Debian; no Docker | Debian | The diagnosis checklist: what is wrong with this server and how to fix it |
| Cloudron | Source-available behind a subscription (unverified) | Takes over a fresh Ubuntu 26.04 | Linux servers | Best-in-class backups (section 3.6) |
| Unraid 7.3.x | Proprietary (unverified) | NAS OS | NAS | Start order with wait delays. No native compose; a plugin hides compose containers from the Docker tab |
| TrueNAS 25.10 | Catalog LGPL-3.0 | NAS OS; middleware generates and owns compose | NAS | States plainly that rollback covers only the apps dataset; 25.10 started rejecting include-only YAML |
| 1Panel v2.3.2 | GPL-3.0; multi-node is Pro | panel (core plus agent) | Linux | The closest match for the server half: typed cron jobs with run records, firewall, SSH management with login logs, a process manager |

**Template formats converge on "compose plus metadata"** (r2 §0): CapRover's
`$$cap_*` variables, CasaOS's `x-casaos`, Runtipi's `x-runtipi`, Umbrel's
manifest, Coolify's `SERVICE_PASSWORD_*` variables. A standard compose file
with an `x-<app>` block is the interoperable choice.

Easypanel (proprietary, Swarm on a fresh Ubuntu) and Synology Container
Manager (projects fail when bind-mount sources are missing) complete the set.

**Footprint takeaway (r2 §2).** Every PaaS takes over the host, and every
home-server product is or wants a fresh OS. Only Kamal resembles the planned
app (a client that holds config and speaks SSH), and Kamal is a deploy tool,
not a manager. Nothing in this set is a native GUI client that manages
arbitrary existing hosts without installing a panel.

### 2.3 Server panels and monitoring (r3)

**Panels.**

| Tool | License | Architecture | Worth learning |
|---|---|---|---|
| Cockpit 366 | LGPL-2.1-or-later; Python bridge GPL-3.0-or-later | panel, or agentless: "beiboot" sends the Python bridge over the SSH stdin | The health card (failed units, updates, reboot needed); logs in context; an explicit, remembered "Administrative access" mode; pages hidden when their backing feature is missing. Gaps: no alerts, crontab, listening ports or fleet view; history only with PCP |
| Webmin 2.670 | BSD-3-Clause | panel (Perl web server as root) | The cron module lists every user's and the system's jobs; disable without deleting; monitors that run a command when a service goes down or comes back |
| Ajenti | MIT | panel (Python) | Edits existing config without destroying comments |
| 1Panel v2.3.2 | GPL-3.0 | panel | Cron jobs as first-class objects with per-run logs; one SSH page for port, root login, auth methods and login logs; Fail2ban and ClamAV as toolbox items |
| aaPanel, CloudPanel, HestiaCP | No license named; unclear; GPL-3.0 | Hosting panels | Hosting is a different product. HestiaCP's `v-*` CLI is scriptable over SSH |

**Monitoring and alerting.**

| Tool | License | Architecture | Worth learning |
|---|---|---|---|
| Netdata 2.x | Agent GPL-3.0+; dashboard UI proprietary (NCUL1) | Per-second agent, about 5% CPU and 150 MiB by default | The faceted journal explorer (field facets with counts, histogram, live tail); on-demand "Functions" tables; tiered storage. Several Functions need Netdata Cloud |
| Glances 4.5.7 | LGPL-3.0 | Python process; `--stdout-json` | A dense threshold-coloured summary; a cheap data source when already installed |
| Beszel v0.21.0 | MIT | Hub plus Go agent; SSH mode (the agent runs its own SSH server, accepts only the hub key, no PTY) or WebSocket mode (agent dials out) | The model for a non-interactive optional collector; rollup tiers from 1 to 480 minutes; a fleet table with inline bars; alerts with threshold plus duration. The hub does not verify the agent's host key |
| Uptime Kuma 2.5.6 | MIT | Node server | Heartbeat bars, status pages, the Push monitor as a dead-man switch |
| Gatus | Apache-2.0 (unverified) | Go binary with YAML; SSH tunnels and `ssh://` checks | A readable condition language, including `[CERTIFICATE_EXPIRATION] > 48h`; maintenance windows |
| Prometheus, node_exporter, Grafana | Apache-2.0; Grafana AGPL-3.0 | Pull TSDB scraping exporters | The collector list is a checklist of Linux signals; if node_exporter runs, `localhost:9100/metrics` over SSH is a rich source |
| Zabbix 7.4 | AGPL-3.0 since 7.0 | Server, proxies and agents; agentless `ssh.run` checks | Problem lifecycle (open, acknowledged, resolved); maintenance periods; `nodata()` triggers as dead-man switches |
| Checkmk 2.5.0 | GPL Community edition (unverified); commercial editions | The agent is a shell script printing `<<<section>>>` blocks; the community runs it over SSH with a forced command | The strongest precedent for "one script, one exec, many sections" |

Agent-based smaller tools add Pulse's "attention queue" instead of charts,
Scrutiny's drive scoring from real-world failure rates, and Monit's "if X then
restart" rules (all MIT or AGPL).

**Jobs, logs and security tools** (r3 §3.19 to §3.25): Cronicle and xyOps
(live log per run, a snapshot when an alert fires), crontab-ui, Healthchecks
(section 3.5), lazyjournal (section 3.4), Logdy, GoAccess, Fail2Ban UI and
CrowdSec (banned IPs with one-tap unban), and Lynis (a flat audit report that
parses into a fleet-wide hardening index).

### 2.4 Native, mobile and TUI clients (r4, r1 §3.17)

| App | Platforms | Collection | License, price | Worth learning |
|---|---|---|---|---|
| ServerBox v1.0.1719 | iOS, Android (not on Google Play), macOS, Linux, Windows, watchOS | SSH script; optional Monitor agent | AGPL-3.0 with a CLA; free | The reference agentless implementation (section 3.1); density modes and a "pressure bar"; a start-time check before killing a PID; one command and parser layer shared by app and agent with per-distro fixtures. Docker is shallow: no compose subcommands |
| ServerCat | iOS, macOS, visionOS | SSH; "will not install any tools" | Free; Premium $5.99 per year or $18.99 lifetime | Reviews: stats work only on Debian and Ubuntu, container management unreliable, sync slow |
| NeoServer | iOS, macOS | SSH | Subscription or $59.99 lifetime | Docker and Podman CRUD; batch scripts across groups with history; post-quantum key exchange |
| ServerBuddy | macOS | SSH | $59 one-time | Sortable tables for processes, containers, services, ports and logs; one user prefers it to installing Cockpit on servers "which I then tend to forget about" |
| XPipe 24.5 | Windows, macOS, Linux | Local CLIs (ssh, docker, kubectl) | Apache-2.0 core, paid extensions | One tree from fleet to host to container to shell; vault synced through a self-hosted git repository |
| Termius | Desktop, iOS, Android | SSH | Subscription | The benchmark for a polished synced host list; no monitoring at all |
| Termix | Web, Electron, iOS, Android | A central server polls over SSH | Apache-2.0 | Alerts work with clients closed because the server holds credentials, which makes it a high-value target; Linux only; disk metrics only for `/` |
| Docker Manager: SSH & Compose | iOS, iPadOS | SSH or Engine API | Free with supporter purchases | The deepest SSH mobile Docker app: compose edit and deploy, Trivy and Grype scans, volume backup, host-key pinning, a review of privileged containers and exposed ports |
| Docker Server Admin | iOS, Apple silicon Mac | SSH | $29.99 or $59.99 | The combined host plus Docker niche exists |
| ServerGlance, ServerKeep | iPhone | SSH | One-time purchase | Share a status card with host and IP hidden by default; compose grouping; alerts only while the app runs |
| DaRemote, Meows | Android | SSH | One-time purchase | Meows alerts only while monitoring runs on the device |
| Secure ShellFish | iOS | SSH plus a `widget` shell command | Freemium | Server-driven widgets and watch complications, pushed from cron when the user decides |
| k9s v0.51.0 | Terminal | Kubernetes API | OSS | `:` command mode, `/` filters, `--readonly`, delete confirmed by Tab then Enter, XRay drill-down |

Also surveyed: iStat (polished charts for a daemon on every host), Cockpit
Client (a transient Python bridge per session), Lens (a bottom dock for
terminals and logs), Raycast's Docker extension (`docker context` as an
importable endpoint list) and Portainer API clients. JuiceSSH was
unpublished from Google Play on 2025-12-11 (unverified), and ServerBox is not
on Play, which leaves Android users few maintained options (r4 §0).

## 3. Cross-cutting lessons

### 3.1 Agentless is proven

Three mature products manage hosts over SSH without a resident agent:

- **Coolify** manages remote hosts over SSH only; the docs say "You only need
  an SSH connection". It later added Sentinel, an optional Rust agent, for
  three things SSH polling handles badly: heartbeat, container health push and
  metric history. When Sentinel goes stale, Coolify "falls back to SSH-based
  checks" (r2 §1.1). SSH covers the live management surface; only history and
  push need something resident.
- **Cockpit** reaches other hosts by running `python3 -ic` over OpenSSH and
  streaming its bridge into it, so nothing is installed beyond Python 3.6
  (r3 §3.1). The cost is the Python requirement, which rules out hosts such
  as Fedora CoreOS.
- **ServerBox**, built on Flutter and dartssh2 like Hauntware, uploads one
  POSIX `sh` script per server and calls it by flag. One call returns every
  metric as segments separated by base64url markers that output cannot forge.
  Status runs every 3 s over a persistent shell channel, falling back to one
  exec per poll; slow probes (SMART, IP addresses) run on a 5-minute cadence,
  and SMART uses `smartctl -n standby` so polling does not wake disks. At most
  4 servers refresh at once (r4 §1.1).

Smaller precedents point the same way: Checkmk's community runs its shell
agent over SSH with a forced command; Zabbix has `ssh.run`; Kamal deploys
agentlessly and keeps its lock and audit log on the servers; ServerCat,
NeoServer, ServerBuddy and Docker Manager install nothing.

Cockpit also shows why the model fits a **native** client better than a web
one. Cockpit 322 deprecated its multi-host switcher because all hosts' code
ran in one browser origin, where connected hosts "can control each other"
(r3 §3.1, r1 §3.13). A native client isolates hosts by construction.

### 3.2 No Docker manager speaks SSH natively

Dockhand, Portainer, Arcane, Komodo and Dozzle all need an exposed Docker API
or an installed agent. Dockhand's docs suggest running an external `ssh -L`
tunnel as a workaround (r1 §1). The SSH-native options are narrow: Podman
Desktop (Podman only, one connection), Cockpit (multi-host deprecated),
lazydocker (one host, buggy contexts), VS Code contexts, and a few mobile
apps. The mobile SSH apps mostly scrape CLI output and poll `docker stats
--no-stream`, which is why they feel thin; ServerBox deliberately runs no
`docker compose` subcommands (r4 §1.1). Docker Manager: SSH & Compose on iOS
proves that a deep feature set over SSH is feasible (r1 §3.17).

### 3.3 Update pipelines

Update handling is where Docker tools differentiate most in 2026:

- Dockhand treats updates as a security feature: digest-based detection, a
  minimum image age before an update is offered (against freshly published,
  possibly compromised images), advisory semver bumps that never edit
  compose, release notes from the `org.opencontainers.image.source` label, and
  safe-pull (pull to a temporary tag, scan with Grype or Trivy, deploy only if
  a severity policy passes) (r1 §5.1).
- Rollback arrived in several tools in 2026: WUD 9.3 rolls back on
  HEALTHCHECK failure, Dozzle 11.3 rolls back safe updates, and Runtipi 4.10.2
  pulls before stopping and restores files, environment, network and
  containers on failure (r1 §3.14, r2 §1.2).
- Cloudron backs up before every update and keeps those backups three weeks;
  Umbrel pins images by digest and shows an update shelf with release
  history, instead of Cosmos-style silent auto-updates that need `latest`
  tags (r2 §1.2).
- Detection mechanics (r1 §3.14, r5 §1.10): compare the local `RepoDigests`
  with the remote digest. The Engine's `GET /distribution/{name}/json` asks
  the registry from the host with supplied credentials but likely counts
  toward Docker Hub pull limits `[U]`, because it issues a manifest GET; a
  HEAD on `/v2/<repo>/manifests/<tag>` does not count. Docker Hub allows 100
  pulls per 6 hours unauthenticated and 200 for authenticated personal
  accounts.

Scanners themselves are supply chain: Trivy v0.69.4 and the Docker Hub images
0.69.5 and 0.69.6 were backdoored in March 2026 (section 3.8).

### 3.4 Logs

- **Best practice.** Dozzle merges and groups container logs, searches them
  with regex and SQL, parses JSON and levels, and alerts on log patterns.
  Docker Desktop has a global merged Logs view with saved filter presets.
  Netdata's journal explorer offers facets with live counts and a histogram.
  lazyjournal puts journal units, `/var/log` files (including rotated
  archives) and containers in one searchable list (r1 §3.7, §3.10; r3 §3.8,
  §3.22).
- **Complaints.** Portainer's log view jumps to the bottom while users read;
  Dockhand documents no merged logs and no log search (r1 §3.1, §3.2).
- **Unfilled.** Nobody merges host logs (journald) with container logs in
  one view (r1 §5.2).
- **A cheap win.** Docker's default `json-file` driver does not rotate.
  Flagging containers with no `max-size` whose log keeps growing is cheap and
  valuable (r5 §1.6).

### 3.5 Scheduled jobs: the cron gap

No surveyed tool offers a unified view of user crontabs, `/etc/crontab`,
`/etc/cron.d`, the `cron.{hourly,daily,...}` directories, systemd timers and
anacron, with last and next run, captured output, human-readable schedules
and missed-run detection (r3 §4.8, §5.2). The pieces exist separately:
Cockpit handles timers but not crontabs, Webmin lists every user's jobs,
1Panel keeps per-run records, crontab-ui pauses by commenting out and backs
up before saving, Healthchecks previews next runs, and ServerBox edits only
the login user's crontab (r3 §3, r4 §1.1).

Constraints: cron does not log exit status by default; systemd timers give
last and next trigger and keep history in the journal (r3 §4.8, r5 §2.4).
Dokku reserves its user's crontab and Dokploy and Coolify manage their own
jobs, so other managers' entries are read-only (r2 §3.9).

### 3.6 Backups are the weakest area

Platforms repeatedly present partial backups as complete (r2 §0, §6.5):

| Product | Gap |
|---|---|
| CapRover | Backs up only `/captain/data`; not volumes, not images |
| Dokploy | Volume backups work only with named volumes, not bind mounts |
| Coolify | No Redis, Dragonfly or KeyDB backups; "A successful backup only proves that Coolify created a file" |
| TrueNAS | Rollback reverts only the apps dataset; host paths are not rolled back |
| Umbrel 1.5 | Users cannot change the backup schedule (community post) |

Cloudron is the gold standard: about 25 storage targets, AES-256 encryption
with a password it does not store, integrity checks against signed SHA-256
records, retention it explains precisely, pre-update backups kept three
weeks, and a whole-server dry-run restore (r2 §1.2). Cosmos chose restic so
backups outlive the product. Dockhand's restic backups are beta (r1 §3.1).

Lessons: enumerate every mount of every service and classify it as backed
up, excluded by choice or unsupported; make "verify by test restore" a
first-class action; use a standard tool such as restic so data is restorable
without the app.

### 3.7 Ownership, rewriting and lock-in

- **Host takeover.** Panels need 80 and 443 (Dokploy and CapRover also
  3000), a proxy they own and often Swarm. Cloudron needs a fresh Ubuntu
  26.04 and manages iptables. Umbrel and ZimaOS are whole operating systems.
  Coolify's validation "can restart the Docker service, which may temporarily
  take down existing containers" (r2 §6.1).
- **No adoption.** None of the PaaS adopts hand-written compose projects. A
  secondary source says Coolify "may conflict with Docker Compose stacks you
  deployed manually"; Unraid's compose plugin hides compose containers from
  the native Docker tab (r2 §6.2).
- **Rewriting files and central state.** Coolify injects labels and
  networks; CapRover ignores all but 8 compose keys; Cosmos "silently
  ignores" unsupported features; panel databases become the source of truth
  (r2 §6.3, §6.4).
- **What earns trust.** Dockge "won't kidnap your compose files"; CapRover
  promises apps keep working after removal; Cosmos backs up with restic;
  Kamal keeps coordination state on the servers (r2 §0).
- **Ownership markers to detect** (r2 §6.2): `coolify.managed=true`,
  `runtipi.managed: true`, Umbrel `app_proxy`, CasaOS `x-casaos`, Swarm
  `com.docker.stack.namespace`, TrueNAS projects (the last three are prior
  knowledge, to check during implementation).
- **Licensing drift.** Dokploy, Cosmos, umbrelOS, Cloudron and Easypanel
  moved away from OSI terms. CapRover, CasaOS and Coolify templates are
  Apache-2.0 and Dokploy's MIT; Runtipi and 1Panel stores are GPL-3.0;
  umbrel-apps has no LICENSE. For public-domain Hauntware, r2 recommends
  bundling only permissive templates with attribution and at most fetching
  GPL catalogs at runtime, a legal question to confirm (r2 §6.7).

### 3.8 Security lessons, including 2026 CVEs

| Event | Lesson |
|---|---|
| Cockpit CVE-2026-4631, fixed in 360 (April 2026): unauthenticated RCE through SSH argument and `%r` token injection from unvalidated host names and user names (r3 §1) | Validate host and user strings; shell-quote every interpolated unit name, path, user, container and package name with one tested escaper; validate systemd unit names against the unit grammar |
| Netdata 2.10.4 fixed a privilege escalation in its setuid-root `ndsudo` helper (r3 §3.8) | Never install setuid or privileged helpers; setup actions are previewed package-manager commands |
| Trivy v0.69.4 backdoored and GitHub Actions retagged in March 2026, plus the Docker Hub images 0.69.5 and 0.69.6 (and `latest` during the exposure window), CVE-2026-33634, GHSA-69fq-xp46-6x23, on CISA KEV (r5 §6) | Treat on-host scanners as untrusted supply chain: pin a verified digest, never a tag; verify signatures and checksums; never auto-install "latest" |
| Dropbear CVE-2025-14282 (2024.84 to 2025.88): forwarded Unix connections appeared as root through `SO_PEERCRED`; fixed in 2025.89 (r5 §1.1) | Check the Dropbear version before using Unix-socket forwarding, and warn on affected releases |
| Portainer 2.45.0 and 2.39.7 fixed a Docker-proxy authorization bypass (r1 §3.2) | Proxying the Docker API is itself attack surface |
| Dockge 1.5.0 disabled its host console by default after an advisory (r1 §3.3) | A web terminal on the host is a liability |

Older lessons repeat: CapRover's default password `captain42`, exposed web
panels, static database passwords in Umbrel templates, Beszel's hub not
verifying agent host keys, Termix's server holding every host's credentials
(r2 §6.6, r3 §3.10, r4 §1.6). `docker` group membership is root-equivalent
per Docker's own documentation, so a client cannot enforce RBAC; read-only
modes are guardrails (r1 §5.3, r5 §4). Secrets leak through `Config.Env`,
interpolated `docker compose config` output, image history and labels, and
need masking and must never sync (r5 §6).

### 3.9 Portability is the support cost

ServerBox's issue tracker clusters on hosts that are not mainstream Linux:
Synology, QNAP, Unraid and ASUSTOR NAS boxes, OpenWrt with procd and no
systemctl, BusyBox, snap-installed Docker, `DOCKER_HOST` confusion, Swarm
task names crashing the `ps` parser, and "Segments not match" parse failures
on routers (r4 §1.1). A ServerCat reviewer says stats do not work on anything
but Debian and Ubuntu; Termix documents Linux-only metrics and disk stats for
`/` only. ServerBox survives these cases with fixture tests per distribution in
its parser crate, including BusyBox `ps`, OrbStack `df` and hostile-input
cases (r4 §1.1, §4.3). r4 §3.5 has the full checklist: BusyBox applets
lacking options, NAS paths missing from the non-interactive `PATH`, LXC
virtualized `/proc`, macOS and FreeBSD equivalents, Windows OpenSSH with
PowerShell, systemd older than 251, and sudo-rs error strings.

### 3.10 UX patterns worth adopting

These recur across categories (r1 §5, r2 §5, r3 §5, r4 §2); 02-FEATURES.md
grades them:

- **Fleet and server.** Density modes with an automatic default and one
  pressure glyph per server (ServerBox); explicit staleness; attention-first
  sorting (k9s "faults only"); a health card (Cockpit); a "doctor" checklist
  (YunoHost); a bottom dock for terminal and logs (Lens).
- **Containers.** Compose-project grouping with project-level bulk actions;
  a persisted column chooser; prune previews; a heuristic "diagnose this"
  from restart count, exit code, OOM kill and health log (Docker Desktop).
- **Safety and transparency.** Typed confirmation for irreversible actions;
  the exact command shown before and after it runs (Kamal, Dockge); a
  read-only mode (k9s `--readonly`); full container IDs and a PID start-time
  check before killing (ServerBox).

## 4. Technical feasibility

### 4.1 The Docker Engine API over `forwardLocalUnix`

The app can speak the full Docker Engine API without installing anything:

- dartssh2 has had `SSHClient.forwardLocalUnix(path)` since 2.14.0, so the
  pinned 3.0.2 includes it. It opens an OpenSSH `direct-streamlocal@openssh.com`
  channel straight to `/var/run/docker.sock`, the equivalent of
  `ssh -L port:/var/run/docker.sock` (r5 §1.1, §1.2; c2 §3.2).
- OpenSSH supports Unix-socket forwarding since 6.7 and allows it by default.
  It is blocked by `AllowStreamLocalForwarding no` or `remote`, by
  `DisableForwarding yes`, and, per r5's reading of `serverloop.c`, by an
  authorized_keys `restrict` or `no-port-forwarding` option. `ForceCommand`
  does not block it. sshd opens the socket as the authenticated user, so the
  usual `root:docker 0660` permissions apply (r5 §1.1).
- Dropbear gained server-side Unix stream forwarding in 2024.84; older
  releases need the exec fallback, and 2024.84 to 2025.88 carry the CVE in
  section 3.8.
- Forwarding channels do not count against `MaxSessions` (section 4.5), so
  Docker streams do not consume the session budget.

Fallbacks, in order (r5 §1.1): `docker system dial-stdio` over exec, which is
exactly what `docker -H ssh://` runs and which also works through `sudo`;
`podman system dial-stdio`; `socat` or `nc -U` relays `[U]`; TCP 2375 or 2376
only for users who already expose it. Discovery tries `$DOCKER_HOST` if
configured, then `/var/run/docker.sock`, the rootless
`/run/user/<uid>/docker.sock`, and the Podman sockets. Because OpenSSH
answers every streamlocal refusal with the same connect-failed "open failed",
discovery tells forwarding disabled from a missing path or missing permission
with one exec probe (`test -S`, `test -w`): a socket that exists and is
writable but is refused means forwarding is disabled (or a stale socket with
no listener).

What must be built (r5 §1.2, §1.3; c2 §2, §9):

- dartssh2's bundled `SSHHttpClient` cannot be used: it dials TCP only,
  buffers, and has no upgrade or hijack support. A small pure-Dart HTTP/1.1
  client over the forwarded channel (about 500 to 800 lines, per r5) handles
  chunked bodies, NDJSON streams and the `101 UPGRADED` hijack used by exec
  and attach.
- Never bridge the socket through a local TCP listener: on desktop any local
  process could then reach a root-equivalent API.
- dartssh2 3.0.2 can stall a channel forever if data arrives before the first
  listener (fixed upstream in 4.0.1), and its keepalive never declares a
  peer dead. The rules are "listen before write" and an own ping timeout
  (c2 R2, R3).
- `seance_core` exposes no Unix-socket forwarding today; no `forwardLocalUnix`
  call exists in the repository (r5 §1.2).

### 4.2 API versions

- Docker Engine 29.0 to 29.2 raised the minimum client API version to 1.44;
  29.3.0 (2026-03-05) lowered it back to 1.40. The newest release on
  2026-10-10 is 29.9.0; the published spec is v1.55 (Docker 29.8) and moby
  master is at 1.56. Podman's compatibility layer reports a maximum of 1.44
  and a minimum of 1.24 (r5 §1.4, r1 §2).
- Clients must negotiate: `GET /_ping` returns `Api-Version`, `GET /version`
  returns `MinAPIVersion`, and unversioned paths are deprecated. r5 proposes a
  client baseline of v1.44 and a floor of 1.41 (Docker 20.10), with newer
  fields feature-gated.
- Shapes changed recently: v1.52 dropped legacy `/events` fields and
  top-level `NetworkSettings.IPAddress`, and v1.53 removed legacy
  `/system/df` fields (r5 §1.4).
- Log streams are multiplexed with 8-byte frame headers unless the container
  has a TTY. From API 1.42 the logs endpoint sets `Content-Type` to
  `application/vnd.docker.multiplexed-stream` or
  `application/vnd.docker.raw-stream`; older daemons do not, and a current
  daemon labels every response raw-stream below 1.42, so the container's
  `Config.Tty` remains the fallback. Timestamps make `since=` cursors for
  reconnects (r5 §1.6).
- A streaming stats connection per container emits about one object per
  second; one-shot polling of visible containers or cgroup v2 files are
  cheaper (r5 §1.7, cgroup paths `[U]`).
- Registry credentials go per request in `X-Registry-Auth`; the daemon never
  reads the remote user's `~/.docker/config.json`, while CLI pulls over exec
  use the server's credential helpers (r5 §1.10).

### 4.3 Compose through labels and the CLI

Compose has no Engine API; it is a client that turns YAML into API calls
(r5 §1.12):

- **Discovery** uses container labels from Compose's `pkg/api/labels.go`:
  `com.docker.compose.project`, `.service`, `.project.working_dir`,
  `.project.config_files`, `.project.environment_file`, `.config-hash` and
  others. Grouping by project and reading `config_files` finds stacks
  anywhere on disk, including ones no tool registered.
- **CLI output** (Compose v5.6.0, 2026-10-02): `docker compose ls --format
  json` prints a JSON array; `docker compose ps --format json` prints JSON
  Lines (older v2 releases printed an array `[U]`, so parse both);
  `docker compose config --format json` gives the interpolated model, which
  contains secrets and must never be logged or synced.
- **Editing.** Read and write the YAML and `.env` over SFTP with an atomic
  `posix-rename@openssh.com` replace and a backup copy; validate with
  `docker compose config -q`; run `up -d`, `pull`, `down` and `logs -f` over
  exec. The flags for parseable progress without a PTY vary by version
  `[U]`. Legacy `docker-compose` v1 stopped receiving updates in July 2023
  and is at most a read-only fallback.
- **Round-trip rules** from section 3.7: keep comments and key order, never
  drop unknown keys, show a diff before writing, and put app metadata in
  `x-<app>` keys (r2 §6.3).

### 4.4 Host metrics: sources and versions

Everything a dashboard needs is readable from `/proc`, `/sys` and standard
CLIs. The version floors matter because the fleet includes old distributions
(r5 §2, r3 §6):

| Source | Minimum or caveat |
|---|---|
| `/proc/stat` | Fields up to `guest_nice` (2.6.33), in USER_HZ; iowait is "not reliable" |
| `/proc/meminfo` | `MemAvailable` since 3.14 |
| `/proc/pressure/*` (PSI) | Kernel 4.20 or later with `CONFIG_PSI`; may be disabled at boot (`psi=1` needed with `CONFIG_PSI_DEFAULT_DISABLED`); system-level CPU `full` reported since 5.13; some enterprise kernels ship it off `[U]` |
| `/proc/diskstats` | Sectors are always 512 bytes; field count varies by kernel |
| `systemctl list-units`, `list-timers`, ... `--output=json` | systemd v246 or later, found in source but not documented; older hosts need `--plain --no-legend` text (RHEL 8 has 239 and Ubuntu 20.04 has 245 `[U]`) |
| `systemctl show` | No JSON; systemd issue #39081 is open |
| `systemctl --timestamp=unix` | systemd 251 or later; ServerBox reads timestamps with `TZ=UTC LC_ALL=C` instead |
| `journalctl -o json` | Documented format; non-UTF-8 values arrive as byte arrays; `--list-boots` JSON since 251 |
| `hostnamectl --json`, `systemd-analyze security --json`, `loginctl --output=json` | systemd 249, 250 and 240 (`loginctl -j` shorthand from 256) |
| `lsblk`, `findmnt --json` | util-linux 2.27 or later |
| `smartctl -j` | smartmontools 7.0 or later; needs root |
| `sensors -j` | lm-sensors 3.5.0 or later; 3.6.0 fixed a JSON bug |
| `ip -j` | Available; `ss` has no JSON |
| Package updates | `apt-get -s upgrade` (apt warns its CLI is unstable for scripts); `dnf check-update` exits 100 when updates exist; `dnf5 check-upgrade --json`; `checkupdates`; `apk version -l '<'` |

Collection pattern, agreed across r3, r4 and r5:

- **One script, many sections.** Checkmk's `<<<section>>>` blocks,
  ServerBox's segments and Cockpit's framed channels all send one program
  and parse delimited, independently failing sections. Markers must resist
  forgery by command output (ServerBox base64url-encodes them). Target `dash`
  and BusyBox `ash`; never assume bash or Python.
- **Run under `sh`, not the login shell.** fish and other non-POSIX login
  shells break `VAR=x cmd`, and `.bashrc` output corrupts parsing. Prefix
  `LC_ALL=C` inside the command: dartssh2 closes the channel when sshd
  refuses an environment request, and OpenSSH accepts none by default
  (r5 §1.2, c2 R7, R9).
- **Cadence and cost.** procfs reads each tick; SMART, packages and `du` on
  demand or on long intervals; processes only while visible. Shell builtins
  instead of per-row `awk` (ServerBox cut 800 spawns per poll on a
  400-process host). Rates are computed client-side from counter deltas. A
  filtered core sample is about 1.5 to 2.5 KB, about 1 KB/s per host at a
  2 s cadence, and dartssh2 offers no SSH compression (r4 §1.1, r5 §3.1,
  §3.3, measured on a 4-vCPU VM).
- **Existing recorders.** sysstat (`sadf -j`), PCP archives (Cockpit's
  history source), atop logs, Netdata, node_exporter and Glances give history
  or richer data when already installed (r3 §6).

### 4.5 `MaxSessions` and connection etiquette

- OpenSSH's `MaxSessions` (default 10) is per connection and counts shell,
  exec and subsystem (SFTP) sessions, not forwarding channels; setting it to
  0 "will prevent all shell, login and subsystem sessions while still
  permitting forwarding" (r5 §3.2, c2 R1). Poltergeist's pool caps itself at
  8 channels per transport for headroom (c2 §2.5).
- A realistic budget is one sampler, one journal follow, one action and one
  SFTP session, with Docker on forwarding channels (r5 §3.2).
- `MaxStartups` (default `10:30:100`) and fail2ban punish bursts of new
  connections, so one long-lived connection per server beats the Docker CLI's
  one `ssh` process per HTTP connection; reconnects need backoff and jitter
  (r5 §3.2, c2 R11). Séance's probe sweeps already cap at 6 concurrent
  probes with jitter.
- Servers with keyboard-interactive or 2FA authentication allow exactly one
  transport without a second prompt, so everything for that server shares 10
  session slots (c2 R10).
- Closing a non-PTY exec channel does not reliably kill the remote process; a
  silent `journalctl -f` lingers. Send `TERM` first: OpenSSH 7.9 and later
  deliver it to the session's process group, except for forced-command
  sessions (r5 §3.2, c2 R4).
- Host-key pins are keyed by `host:port` only, so two private hosts with the
  same address behind different jump routes collide (c2 R8).

### 4.6 Privilege

- **Unprivileged baseline.** `/proc`, `/sys`, `df`, `ps`, `ss` without other
  users' process names, the user's own crontab and journal, and unit status
  (r5 §4).
- **Journal.** The system journal needs root or the `systemd-journal`, `adm`
  or `wheel` group; without them the output silently contains only the user's
  own entries, which the app must detect and say (r5 §2.3).
- **sudo.** Try `sudo -n` first; feed a password to `sudo -S -p ''` on stdin,
  never in argv or environment requests; validate with `sudo -S -v` before
  running the command. `requiretty` is off by default but set on some old
  RHEL configurations `[U]` (r5 §4). The prelude the plan adopts was
  verified locally (04 Appendix A).
- **sudo-rs**, the default `sudo` on Ubuntu 25.10 and later (0.2.13 on
  Ubuntu 26.04), supports `-n` and `-S` (and `-A` only from 0.2.11,
  December 2025; Ubuntu 25.10 ships 0.2.8 without it), but has different
  error strings and no `-E`. Cockpit 355 (January 2026) added a polkit and
  systemd transient-unit fallback because sudo-rs broke its askpass use
  (r3 §1, r5 §4). ServerBox recognizes both sudo and sudo-rs rejection texts
  so a wrong password re-prompts instead of looking like a failed command
  (r4 §1.1).
- **polkit and run0.** Non-root `systemctl restart` asks polkit, which has no
  agent over non-interactive SSH; `run0` (systemd 256) is polkit-based and
  cannot take a password over a pipe `[U]`.
- **Scoping.** Narrow NOPASSWD rules for read-only collectors are reasonable;
  a rule for `docker *` or `systemctl *` is root-equivalent. A generated
  sudoers drop-in can be validated with `visudo -cf` (r5 §4).
- **UX model.** Cockpit's session starts unprivileged with an explicit,
  remembered "Administrative access" toggle; ServerBox never uses sudo for
  reads ("a password prompt belongs to an action the user took") (r3 §3.1,
  r4 §1.1).

### 4.7 Platform background limits

| Platform | Limit | Source |
|---|---|---|
| iOS refresh | `BGAppRefreshTask` runs when the system decides, with up to 30 s of runtime | r5 §5.4 |
| iOS silent push | Rate-limited; more than about three per hour are throttled | r5 §5.4 |
| iOS widgets | Typically 40 to 70 reloads per day; iOS 26 adds WidgetKit push as a reload signal | r4 §2.7 |
| iOS Live Activities | Updates for up to 8 h, plus up to 4 h stale on the Lock Screen; good for bounded tasks such as a redeploy | r4 §2.7 |
| iOS background SSH | Possible through location-based keepers (Blink `geo track`), at a cost in battery and App Review scrutiny; not a monitoring strategy | r4 §2.7 |
| APNs | Needs the publisher's key; ServerBox relays through its own server; Hauntware ships an unsigned IPA | r4 §2.7 |
| Android periodic work | WorkManager minimum period 15 min, subject to Doze | r5 §5.4 |
| Android foreground service | `dataSync` limited to 6 h per 24 h since Android 15, then `onTimeout` | r4 §2.7, r5 §5.4 |
| Android widgets | `updatePeriodMillis` minimum 30 min | r4 §2.7 |
| Desktop | A tray or menu-bar mode can poll while the machine is awake | r5 §5.4 |

None of these supports periodic SSH polling from a phone. Apps that alert
without a server component do so only while running (Meows, ServerGlance).

### 4.8 Why alerts need an always-on component

Every tool that alerts while its UI is closed has a resident part: the Beszel
hub and agent, the Netdata agent, the Zabbix and Checkmk servers, Uptime Kuma,
Gatus, Coolify's Sentinel, ServerBox Monitor, Termix's server (r3 §1, r4 §0).
Coolify's docs even say CPU and memory threshold alerts need an external
system (r2 §1.1). The needs split cleanly (r2 §3, r5 §5.1):

| Need | Agentless? |
|---|---|
| Live dashboards, logs, Docker operations | Yes, while the app is open |
| History beyond the session | Partly, by reading existing recorders; otherwise nothing before first connect |
| Alerts while every client is closed | No; something must evaluate rules continuously |
| Push notifications | No; needs a sender with provider credentials |
| Scheduled jobs (backups, prune, update checks) | Yes, by authoring the host's own systemd timers or cron entries |
| Host-down alerts | No; a host cannot report its own death, so a peer or external monitor must watch it |

The options the reports describe, from least to most resident:

1. **Read existing recorders and integrations** (sysstat, PCP, Netdata,
   node_exporter, Uptime Kuma, Healthchecks) (r3 §6, r5 §5.3).
2. **Host-native delegation** (r2 verdict H): removable systemd timers or
   cron entries plus a small notifier script (ntfy, Gotify, Telegram, Slack,
   email, webhooks), all listed in a manifest the client can show and
   uninstall. Dokku and Runtipi are precedents; the difference is an
   enumerable footprint. The host script holds the channel credentials, which
   the UI must disclose (r2 §3.11, §4).
3. **An optional agent** modelled on Beszel: no shell, no PTY, outbound for
   NAT, read-only collectors, a local ring buffer and rule evaluation.
   `dart compile exe` cross-compiles to Linux x64, arm64, arm and riscv64;
   whether the binary runs on musl (Alpine) is `[U]` (r5 §5.2).
4. **Push** needs a publisher-run relay. ntfy's `upstream-base-url` pattern
   forwards only a message ID, and the app fetches the content from the
   user's server (r5 §5.3).

The plan's tier model (T0 agentless, T1 host-native delegation, T2 an
optional always-on companion) is built from these options; see
[03-ARCHITECTURE.md](03-ARCHITECTURE.md) §9.

### 4.9 Why the sync server cannot be a watcher

The Hauntware sync server looks like the natural always-on component. The
reports agree it cannot be one:

- It is a kind-agnostic, breach-tolerant blob store that cannot read,
  filter, query or expire anything; every client receives every record
  (c1 §1.2, §2.4).
- Its documented trust model is that it "never sees a key"
  (`seance/AGENTS.md`, `seance/docs/INBOX.md`, cited in r5 §0). A watcher on
  that server holding SSH keys would give a breached sync server access to
  the whole fleet; r5 rejects it (r5 §5.3).
- A separate watcher daemon enrolled as a full client could poll with a
  dedicated restricted key, but `restrict` also blocks Unix-socket
  forwarding, so it would rely on a forced read-only script and lose the
  Docker API (r5 §5.3). r3 and r4 sketched variants of this (r3 §6, r4 §4.2).
- The model-preserving path r5 recommends is an on-host agent acting as a
  producer in the existing command-inbox pattern: it seals alerts with a
  per-agent key provisioned over SSH and deposits ciphertext; the server can
  see that an agent stopped depositing (a dead-man heartbeat) without
  decrypting anything. The inbox is shaped for command proposals (100
  pending items per app, 30 deposits per minute, 50 apps per account, no
  push), so reusing it for alerts needs a new sealed payload type, which is a
  design decision rather than a drop-in (c1 §2.4, r5 §5.3).
- Metrics and logs can never travel through sync: Séance pulls the entire
  account every round, every 5 minutes and after each edit, and the server
  caps a push at 1000 records and 8 MiB and a blob at 1 MiB (c1 §2.4).

## 5. The codebase starting point (c1 to c4)

### 5.1 What exists and can be reused

- **Connections.** `openAuthenticatedClient` in `seance_core` provides TOFU,
  ProxyJump (16 hops, cycle detection), ssh-agent, keyboard-interactive and
  2FA, and a redacted transcript (c2 §2.1).
- **Exec precedent.** `SshSession.runCommand` is a bounded one-shot exec, and
  `RemoteGit` shows the target shape: a runner-injected class with
  sentinel-separated output, `LC_ALL=C`, quoted arguments and failure
  classification, testable without a transport (c2 §2.2, §2.3).
- **Pool and probes.** Poltergeist's pool encodes the 8-of-10 channel
  headroom, a 30 s ping timeout and "an interactive server stays at one
  transport"; `ProbeService` gives three-state reachability; `quoteShellWord`
  is safe across sh, bash, zsh and fish (c2 §2.4, §2.5).
- **Shared UI.** `ghost_ui` (sidebar kit, menus, toasts, colour picker, file
  rows), `ghost_marks` (identical server badges and pickers), `ghost_desktop`
  (window lifecycle, Settings window), `planchette_editor` and
  `planchette_core` (syntax for YAML, dotenv, Dockerfile and INI, validation,
  unified diff, search) are consumable unchanged by relative path (c3 §1).
- **Sync.** A fourth app can add its own record kinds with no server change
  and no protocol version bump, using a unique `<app>:` id prefix and never a
  bare id, which Séance treats as a server (c1 §2.4).

### 5.2 What is missing or must move first

- **Server list.** There is no shared local list; the only path to "the same
  server list" is shared-account enrollment into the user's Séance account.
  The catalog sync rules exist twice (Séance's collect-everything
  coordinator and Poltergeist's change-driven one) and already diverge in
  observable ways (c1 §3.3 lists five); a third copy is ruled out by root
  `AGENTS.md` (c1 §0, §3).
- **SSH primitives.** No headless or streaming exec, no stdin, PTY or signal
  options, no Unix-socket stream, no HTTP client, no channel budget, no
  dead-peer detection in Séance's path, and channel-open failures collapsed
  into strings (c2 §8, gaps G1 to G7).
- **Terminal.** The concrete xterm engine lives inside the Séance app and
  must move to a shared package before a container shell can reuse it
  (c2 §5).
- **Guards.** The dartssh2 import guard, the license and local-dependency
  gate and the private-key scope check scan only `poltergeist/` (c2 §4,
  c4 §1.5).
- **UI gaps.** No chart, sparkline, generic table or virtualized log viewer
  exists in the repository or its lockfiles; no local-notification plugin
  resolves; the server editor, prompts and theme stack are duplicated per app
  (c3 §1.8, §5).
- **dartssh2 pin.** Exactly 3.0.2 everywhere, with Poltergeist's M0 evidence
  bound to it. Upstream is at 4.1.0. 3.0.2 still proposes SHA-1 key
  exchange, `ssh-rsa` and CBC by default, cannot connect to chacha20-only or
  ML-KEM-only servers, and can time out handshakes on memory-constrained
  Android devices. A re-pin is a separate suite-wide task (c2 §3, R12, R13).

### 5.3 Suite integration cost

The suite hard-codes its three products in about 15 places, and nothing
discovers products automatically. The release tool silently treats an
unregistered product directory as unmanaged, so registration must land in the
same PR as the first versioned pubspec. A fourth five-platform product grows
the release from 13 to 18 clients and from 25 to 33 manifest assets, adds
roughly 30 to 45 job-minutes to every CI run, and raises macOS jobs per run
from 7 to 9 or 10 against GitHub's cap of 5 concurrent macOS jobs. A
greenfield product needs no history-checker entry and must not get one
(c4 §0, §3, §5).

## 6. The market gap

Putting the categories side by side (r1 §5.2, r2 §2, §7, r3 §5.2, r4 §4):

1. **Deep management always costs a host footprint.** PaaS and home-server
   products take over the host; Docker managers and panels run a resident web
   UI or agent; Kamal is agentless but only deploys. The agentless native
   clients (ServerBox, ServerCat, NeoServer) monitor well and manage
   shallowly.
2. **No Docker manager speaks SSH.** The SSH mobile apps are shallow on
   streaming and compose. Stack lifecycle, update detection, volumes,
   networks, events and prune previews over plain SSH would reach Dockhand
   and Portainer territory with zero host footprint.
3. **Nobody combines an end-to-end encrypted, self-hosted synced server list
   with terminal, file transfer, monitoring and Docker across five platforms
   in open source.** ServerBox syncs through iCloud or WebDAV backups,
   XPipe through git on desktop only, Termius has no monitoring, and Termix's
   server holds credentials (r4 §4.1). Hauntware already has the server list,
   the vault, the sync server and the shared marks; Séance and Poltergeist
   cover terminal and files.
4. **Specific features nobody does well:** a unified scheduled-jobs view;
   host and container logs merged in one view; listening ports mapped to
   process, unit, container and firewall rules ("exposed to the internet?");
   a compose diff or dry-run before deploy; cross-host search for containers,
   images and ports; a one-tap forward to an unpublished container port;
   fleet compliance tables (kernel, pending updates, reboot needed,
   certificate expiry, hardening index); backup screens that state exactly
   what is covered; a network topology view.
5. **Android.** With JuiceSSH gone and ServerBox off Google Play, maintained
   Android options are few.
6. **Keyboard-first desktop and touch-first mobile from one codebase.** k9s
   proves power users want `:`, `/` and single-key actions; mobile apps prove
   others want cards and sheets; no native server tool does both well.

r2's positioning line summarizes the gap: "the control panel that isn't
installed on your server". Two constraints come with it. Anything that must
happen while the app is closed needs a consented host-side or always-on
component (section 4.8), and the support cost concentrates on hosts that are
not mainstream Linux (section 3.9).

## 7. Where the reports disagree or were later corrected

| Topic | Disagreement | Resolution |
|---|---|---|
| dartssh2 Unix-socket forwarding | r4 left 3.0.2 support unchecked and suggested a CLI-first hybrid | r1, r5 and c2 verified `forwardLocalUnix` in 3.0.2; the plan uses the Engine API over it with `dial-stdio` as fallback (03 §5) |
| `restrict` and streamlocal | r5 read `serverloop.c` as blocking; c2 called the same reading unverified | Treated as blocking: a streamlocal refusal on a socket the exec probe finds present and writable switches to the CLI relay (03 §5) |
| TCP fallback | r5 lists TCP 2375 or 2376 for users who already expose it | The plan never offers TCP (03 §5) |
| Password sudo and `dial-stdio` | c2 R5 expected `sudo -S` to conflict with stdin as the data stream | A local experiment showed the builtin `read` consumes one line and leaves the rest (04 Appendix A, C) |
| Sampler control channel | r5 suggested toggling collectors by writing control lines to the sampler's stdin | dash reads ahead from pipes, so a `read` loop can miss requests; each tick is a whole command line instead (04 Appendix A, C) |
| Detecting `MaxSessions` exhaustion | c2 (G1, R1) proposed classifying the channel-open error | sshd refuses with a generic connect-failed "open failed", so the error alone cannot identify it; the plan classifies by channel type and open count `[R]` (03 §1.4, §5) |
| Where the sampler lives | r4 favoured ServerBox's uploaded script, r3 a script sent per refresh, r5 a persistent inline sampler that leaves no files | Decided in 03 §6 |
| Alert evaluation | r3 option B (sync-server watcher with a restricted key), r4 (a watch node posting sealed records), r5 (on-host agent as inbox producer), r2 (host-native timers) | Decided as tiers in 03 §9 |
| Release manifest lines | c4 placed Poltergeist's manifest block at `scripts/release-manifest.txt:123-155` | The file has 54 lines; the block is at `:46-54` `[V]` (04 Appendix C) |
| Versions seen | Docker Desktop 4.94.0 (r1) and 4.85.0 "seen" (r4); Podman v6.0.x (r1) and v6.1.3 with v5.8.8 on 2026-09-29 (r5); Dockge 1.5.0 without a year (r1) and 2025-03-30 (r2) | The later, primary readings stand: Docker Desktop 4.94.0, Podman 6.1.3, Dockge 1.5.0 from 2025-03-30 |

## 8. Sources

The appendices carry every source with its access date and marker; this
chapter does not repeat them.

| Report | Source list | Main source types |
|---|---|---|
| r1 | [r1 §6](research/r1-docker-managers.md) and per-profile lists | Project sites, manuals, GitHub repositories and releases, App Store listings, Docker docs, a few marked blog comparisons |
| r2 | Per-profile lists in [r2 §1](research/r2-selfhost-platforms.md) | Raw LICENSE and README files, vendor manifests, Docker Hub tags, official docs |
| r3 | [r3 §7](research/r3-server-panels-monitoring.md) | Project docs, source files (Cockpit `beiboot.py`, Beszel `server.go`), release notes, security advisories |
| r4 | [r4 §5](research/r4-native-mobile-clients.md) | ServerBox source at `50e61ed`, App Store listings, GitHub issues, Apple and Android developer documentation |
| r5 | [r5 Sources](research/r5-technical-feasibility.md) | dartssh2 3.0.2 archive, OpenSSH and Dropbear sources and manuals, Docker Engine API spec and version history, moby, Compose and Podman sources, kernel and systemd docs, sudo and sudo-rs manuals |
| c1 to c4 | Inline `path:line` citations at `bf1da58` | The Hauntware repository; c2 also cites the dartssh2 3.0.2 and 4.1.0 archives and sshd_config(5); c3 cites pub.dev; c4 cites GitHub's live CI and limits data |

A few primary documents underpin most of the technical conclusions:

- OpenSSH [sshd_config(5)](https://man.openbsd.org/sshd_config)
  (`MaxSessions`, `MaxStartups`, `AllowStreamLocalForwarding`,
  `DisableForwarding`) and
  [`PROTOCOL`](https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL)
  section 2.4.
- The [dartssh2 changelog](https://pub.dev/packages/dartssh2/changelog)
  (`forwardLocalUnix` since 2.14.0).
- The Docker Engine API
  [reference](https://docs.docker.com/reference/api/engine/) and
  [version history](https://docs.docker.com/reference/api/engine/version-history/).
- Cockpit's [322 release notes](https://cockpit-project.org/blog/cockpit-322.html)
  on deprecating multi-host.
- Apple's
  [background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
  and Android's
  [foreground service timeout](https://developer.android.com/develop/background-work/services/fgs/timeout)
  documentation.
