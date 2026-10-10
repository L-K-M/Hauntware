# 02. Feature catalog

Status: plan with owner decisions of 2026-10-10. Nothing here is implemented.

This chapter lists every feature considered for Klabautermann, the fourth
Hauntware app, with its release tier, execution tier, privilege and data
source. A critique pass reviewed an earlier version of the catalog; this
version applies every critique item that the research supports, and
Appendix A records how each item was handled. The display name is
Klabautermann and the ASCII stem in identifiers is `klabautermann`
([05-NAMES.md](05-NAMES.md)); prose also says "the app". The architecture
built on this catalog is in [03-ARCHITECTURE.md](03-ARCHITECTURE.md); its
section 1.4 lists where it deviates from or corrects rows of this catalog.
Milestones are in [04-IMPLEMENTATION.md](04-IMPLEMENTATION.md), and the
owner decisions of 2026-10-10 are in its
[section 15](04-IMPLEMENTATION.md#15-owner-decisions); rows changed by a
decision cite it as "owner decision Qn".

References such as "r5 §1.1" or "c1 §2.4" point to the research reports r1 to
r5 and the codebase reports c1 to c4, imported as appendices under
[research/](research/README.md):
[r1](research/r1-docker-managers.md) Docker managers,
[r2](research/r2-selfhost-platforms.md) self-host platforms,
[r3](research/r3-server-panels-monitoring.md) server panels and monitoring,
[r4](research/r4-native-mobile-clients.md) native and mobile clients,
[r5](research/r5-technical-feasibility.md) technical feasibility,
[c1](research/c1-catalog-sync.md) catalog and sync,
[c2](research/c2-ssh-exec-terminal.md) SSH, exec and terminal,
[c3](research/c3-shared-ui-app-shells.md) shared UI and app shells,
[c4](research/c4-suite-infra.md) suite infrastructure.

## Product summary

Klabautermann is the fourth Hauntware product: a native Flutter client for
Linux, macOS, Windows, Android and iOS that monitors and manages the user's
servers and their Docker or Podman workloads over plain SSH. It shows the same
end-to-end encrypted server list as Séance and Poltergeist, installs nothing
on the host by default and opens no ports: host metrics come from `/proc`,
`/sys` and standard CLIs over one SSH connection per server, and the Docker
Engine API is reached through an SSH stream-local channel to the engine
socket, which no mainstream Docker manager offers today (r1 §1, r5 §1). The
core loop is see, act and update: live CPU, memory, disk and network,
processes, systemd services, the journal and log files, cron jobs and timers,
and Docker containers, images, logs, stats and compose stacks, with actions
guarded by observe-only defaults, an explicit admin mode, command previews,
protected targets and typed confirmations. Work that must continue while the
app is closed (alerts, history, scheduled checks) uses optional host-side
timer files (T1, v1.x) or a Rust companion that is an explicit opt-in per
server (T2, planned for M9 after v1.x), and the UI states what each tier can
and cannot catch.

## What the owner asked for, and where it lands

| Owner asked for | MVP | v1 | v1.x and Later |
|---|---|---|---|
| Same server list as the other tools | FL-01 shared list, FL-22 enrollment, FL-04 to FL-07 status, search, groups and pressure bars, FL-17 jump hosts, SYN-01, SYN-02 | FL-03 add and edit servers in the app | FL-13 tags, FL-14 compliance tables, FL-15 cross-host search |
| Logs | LOG-01 journal, LOG-02 follow, LOG-03 kernel log, LOG-05 search, LOG-22 file tail, SVC-04 unit logs, CTX-01 and CTX-02 container logs | LOG-06 regex, LOG-08 `/var/log` browser, LOG-09 boots, LOG-10 export, CTX-04 stack logs | LOG-11 faceted explorer, LOG-12 unified host and container stream |
| Cron jobs | JOB-01 unified jobs list, JOB-02 schedule in words and next runs, JOB-03 other users' crontabs (read-only), JOB-08 run a timer now | JOB-05 last result, JOB-06 safe edit, JOB-07 pause, JOB-19 run a cron job now | JOB-11 output capture, JOB-12 dead-man pings, JOB-13 missed runs |
| Disk space | DSK-01 usage per mount, DSK-02 inodes, OV-05 Docker reclaimable space | DSK-03 I/O, DSK-07 disk space explorer, DKE-04 Docker disk usage, DKE-05 prune with preview | DSK-09 cleanup suggestions, DSK-10 fill forecast, DSK-11 ZFS |
| RAM | MEM-01 breakdown, MEM-02 swap | MEM-03 OOM kills, MEM-04 pressure | MEM-05 ZFS ARC, MEM-06 zram |
| CPU | CPU-01 total, CPU-02 per core, CPU-03 load | CPU-04 breakdown with hints, CPU-05 pressure, TRI-02 "why is it slow" | CPU-06 frequency, CPU-08 per cgroup |
| Docker management like Dockhand | DKE-01, DKE-02, DKE-10, CTR-01 to CTR-06, CTX-01, CTX-02, CST-01, IMG-01, IMG-02, STK-01 to STK-06, STK-10 | CTX-07 exec shell, IMG-03 pull, IMG-05 update indicator, STK-07 compose edit, STK-23 per-service actions, VOL and DNW | IMG-07 to IMG-11 safe update pipeline, STK-11 drift, STK-12 deploy history, TPL templates, BAK backups |
| "And so on" | processes (PRC), services (SVC), network throughput, uptime | packages and updates (PKG), hardware (HW), triage (TRI), firewall view (NET-06) | security posture (SEC), certificates (CRT), alerts (ALR), history (HIS) |

## Tier definitions

### Release tiers

| Tier | Meaning |
|---|---|
| MVP | First preview build worth using daily, for users enrolled in a Séance sync account, shipped in suite releases labelled "preview" from M4 (owner decision Q16). Reads the shared server list and never pushes to the sync account (pull-only, D14, owner decision Q4); shows live host health, processes, services, the journal, file tails, scheduled jobs and Docker containers, images, logs, stats and compose stacks; builds its themes through `ghost_theme`, with theme editing and presets (X-01, owner decision Q5). Mutations: single-target lifecycle actions on units, processes and containers, container and image removal, running a timer now, and pull-and-redeploy for unmanaged, verified stacks, all behind confirmations, protected-target guards and admin mode where root is needed. No config-file writes, no new vault secret kinds, no new synced record kinds, and no Séance app changes beyond the prerequisite work of 03, section 3.5: the extractions and the Séance #56 fix for pulled host-key pins in F3 (owner decision Q12). |
| v1 | First public release. Meets every table-stakes item in section 4 (parity with ServerBox and ServerCat on the host side and with Dockge-class compose management on the Docker side) plus the first differentiators that are cheap once the MVP plumbing exists. Adds in-app server editing, container exec shells and config-file editing with diff, backup and validation. Catalog writes start here, including publication of first-seen host-key pins (X-02), and so do the hand-offs to Séance and Poltergeist (X-03, X-04, X-10; owner decision Q18). |
| v1.x | Differentiators and host-side (T1) features: footprint-tracked host checks with notifications, scheduled update checks, coarse history, fleet tables. |
| Later | After v1.x. Rows that need the T2 companion are scheduled in milestone M9 (owner decision Q8; see T2 below). Restic-based backups are built into the app after v1.x on top of T1 (owner decision Q19). Other Later rows need a further design decision (for example the push relay, ALR-13) or have low value per effort. |
| Non-goal | Deliberately out of scope. Rows moved out of scope stay in their area table with this tier; cross-cutting non-goals are in section 3.41. |

### Execution tiers

| Tier | Meaning |
|---|---|
| T0 | Agentless over SSH while the app is open. Uses `/proc`, `/sys`, standard CLIs and the Docker Engine API over an SSH `direct-streamlocal` channel. Writes to the host only what the host write inventory in 03, section 8.11 lists, including explicit user edits (for example a crontab change) and their backups (SAF-12), transient units with operation records and logs for detached operations (SAF-23), the audit syslog line (SAF-13) and the footprint manifest (SAF-14), all accepted by owner decision Q6. Helper containers for volume browsing (VOL-03) and the debug shell (CTR-21) are engine changes, not host file writes: each use needs explicit confirmation, and the helper is removed afterwards (owner decision Q20). |
| T1 | Host-side plain files installed only with explicit consent: systemd timer and service pairs (cron fallback) plus small POSIX scripts and state files, all listed in one footprint manifest (SAF-14) and removable in one action. No daemon, no listening port. System timers run only root-owned scripts from root-owned directories (0755; state files 0640 or 0600); user timers run only user-scope checks; notifier secrets live in 0600 files owned by the timer user; per-file checksums in the manifest are verified on connect. Approved for v1.x with user scope by default and system scope only in admin mode (owner decision Q7). |
| T2 | Optional always-on companion written in Rust: nothing by default, an explicit opt-in per server (owner decision Q8). An inbox producer on the host with no listener, no inbound control and no SSH or account keys, installed, updated and removed only by the client over SSH, never self-updating; the client build pins the SHA-256 hashes of the companion binaries of the same release (no signing key). No T0 or T1 feature depends on it. T2 rows keep the release tier Later and are scheduled in milestone M9 after v1.x, except where their notes name a further decision (ALR-12, ALR-13, X-09). |
| C | Client-only. No server access, or only data the app already fetched. |
| +E | Suffix on any tier: the feature contacts an endpoint outside the user's servers and the suite (registry, code forge, notification service, LLM provider, RDAP, catalog URL). Notes say what data leaves. Device-side lookups of this kind are opt-in, because they disclose the device IP (and image names, for registries) and inherit third-party rate limits (Docker Hub counts pulls per IP, r5 §1.10). |

### Privilege

| Value | Meaning |
|---|---|
| none | No server access needed. |
| user | Plain SSH account. |
| user+ | Works unprivileged with partial results and is complete with sudo (for example process owners of other users in `ss -p`). |
| docker | Can connect to the Docker or Podman socket: `docker` group, a rootless socket, or `sudo -n docker system dial-stdio`. A rootful socket is root-equivalent per Docker's own documentation; a rootless socket is equivalent to its user. The UI says which applies (SAF-08). |
| journal | System journal readable: root or a member of `systemd-journal`, `adm` or `wheel`. Without it `journalctl` silently returns only the user's own entries. |
| sudo | Admin mode (SAF-02): sudo or sudo-rs with the password on stdin, or doas and run0 when they need no password. |
| polkit | Non-root `systemctl` action granted by a polkit rule. There is no polkit agent over SSH, so the app passes `--no-ask-password` and fails fast when no rule grants the action (r5 §4). A polkit rule is a narrower grant than sudo. |

### Columns and markers

| Column | Meaning |
|---|---|
| ID | Stable reference for the plan: area prefix plus number. |
| Feature | Short name. |
| Description | One line. |
| Inspiration | Tools from the research that do this, or "none found" when no surveyed tool does it well. |
| Rel | Release tier. |
| Exec | Execution tier, with the +E suffix where it applies. |
| Priv | Required privilege. |
| Data source | Exact command, file or Docker Engine API endpoint. API paths are relative to the negotiated `/v1.xx` prefix. |
| Notes | Caveats, portability, and mobile notes (prefixed "Mobile:"). |

Marker **[U]** means the research did not verify the fact. Treat it as a spike
item before relying on it. Inspiration names are written out. "Docker Manager
iOS" means the App Store app "Docker Manager: SSH & Compose". "WUD" is What's
Up Docker.

## Feature counts

Rows per area and release tier (counted from section 3):

| Area | MVP | v1 | v1.x | Later | Non-goal | Total |
|---|---|---|---|---|---|---|
| Fleet and server list (FL) | 9 | 6 | 4 | 2 | 1 | 22 |
| Connection, capability probe and transport (CN) | 15 | 5 | 2 | 2 | 1 | 25 |
| Server overview dashboard (OV) | 5 | 5 | 1 | 0 | 0 | 11 |
| CPU (CPU) | 3 | 3 | 2 | 1 | 0 | 9 |
| Memory (MEM) | 2 | 2 | 2 | 1 | 0 | 7 |
| Disks and storage (DSK) | 2 | 5 | 7 | 1 | 1 | 16 |
| Network (NET) | 1 | 5 | 7 | 1 | 2 | 16 |
| Processes (PRC) | 2 | 4 | 2 | 1 | 0 | 9 |
| Services (SVC) | 4 | 6 | 4 | 2 | 0 | 16 |
| Logs (LOG) | 6 | 5 | 8 | 3 | 1 | 23 |
| Scheduled jobs (JOB) | 4 | 6 | 5 | 4 | 0 | 19 |
| Packages and updates (PKG) | 0 | 6 | 5 | 3 | 0 | 14 |
| Users, SSH keys and access audit (ACC) | 0 | 2 | 5 | 3 | 0 | 10 |
| Security and hardening (SEC) | 0 | 1 | 8 | 1 | 0 | 10 |
| Certificates (CRT) | 0 | 1 | 4 | 1 | 0 | 6 |
| Hardware and sensors (HW) | 0 | 3 | 4 | 1 | 0 | 8 |
| System configuration and power (SYS) | 2 | 2 | 1 | 3 | 0 | 8 |
| Boot, uptime and reliability (BOOT) | 1 | 2 | 2 | 0 | 0 | 5 |
| Triage and diagnosis (TRI) | 0 | 4 | 2 | 0 | 0 | 6 |
| Docker engine and host (DKE) | 3 | 9 | 2 | 3 | 0 | 17 |
| Containers (CTR) | 6 | 5 | 8 | 3 | 0 | 22 |
| Container logs, exec and attach (CTX) | 2 | 6 | 3 | 0 | 0 | 11 |
| Container stats (CST) | 1 | 4 | 2 | 0 | 0 | 7 |
| Images and updates (IMG) | 2 | 4 | 6 | 8 | 0 | 20 |
| Volumes (VOL) | 0 | 2 | 1 | 2 | 0 | 5 |
| Networks (DNW) | 0 | 2 | 2 | 0 | 0 | 4 |
| Compose stacks (STK) | 7 | 4 | 8 | 6 | 0 | 25 |
| Registries (REG) | 0 | 1 | 2 | 1 | 0 | 4 |
| Templates and app catalog (TPL) | 0 | 0 | 1 | 6 | 0 | 7 |
| Backups (BAK) | 0 | 0 | 2 | 8 | 0 | 10 |
| Alerts and notifications (ALR) | 0 | 2 | 8 | 6 | 0 | 16 |
| History and trends (HIS) | 0 | 1 | 5 | 4 | 0 | 10 |
| Automation, runbooks and snippets (AUT) | 0 | 2 | 2 | 3 | 0 | 7 |
| Web and reverse proxy (WEB) | 0 | 0 | 3 | 2 | 0 | 5 |
| Cross-app integration (X) | 2 | 4 | 1 | 3 | 0 | 10 |
| Assistant (AI) | 1 | 0 | 5 | 3 | 0 | 9 |
| Settings, privilege and safety (SAF) | 12 | 6 | 4 | 1 | 0 | 23 |
| Sync and data (SYN) | 5 | 2 | 1 | 1 | 0 | 9 |
| Platform specifics (PLT) | 4 | 5 | 3 | 2 | 1 | 15 |
| Accessibility and localization (A11Y) | 9 | 4 | 2 | 0 | 0 | 15 |
| **All areas** | **110** | **136** | **146** | **92** | **7** | **491** |

Rows per execution tier and release tier (Non-goal rows excluded):

| Exec | MVP | v1 | v1.x | Later | Total | of which +E |
|---|---|---|---|---|---|---|
| T0 | 65 | 94 | 100 | 58 | 317 | 3 |
| T1 | 0 | 0 | 8 | 8 | 16 | 3 |
| T2 | 0 | 0 | 0 | 7 | 7 | 1 |
| C | 45 | 42 | 38 | 19 | 144 | 14 |
| **All** | **110** | **136** | **146** | **92** | **484** | **21** |

---

## 1. Tiering principles

1. **Observe first.** Every new server starts read-only. Management needs a
   per-server switch, and root needs admin mode (r2 §6.1, Cockpit's
   administrative access, k9s `--readonly`). Anything that can cut the user
   off (sshd, network, firewall, VPN, the engine itself) needs a second,
   typed confirmation (SAF-22).
2. **Agentless covers live management.** Coolify falls back to SSH when its
   Sentinel agent is stale, and ServerBox runs its whole status surface over
   SSH (r2 §0, r4 §1.1). Only history before first connect, alerts while the
   app is closed, and push need T1 or T2.
3. **Host files are the source of truth.** Compose files, `.env`, crontabs and
   unit files are re-read on every open, edited with diff and backup, and never
   mirrored into a shadow database (Dockge, Kamal, CapRover "no lock-in").
   A file is presented as a stack's source only after verification (STK-01).
   Uninstalling the app must leave every workload running.
4. **No listening ports and no setuid helpers in T0 or T1.** The Docker socket
   is never bridged to a local TCP port (r5 §1.3). Device-side port forwards
   bind loopback only, open on demand and close with their view (NET-11).
   Netdata's 2026 `ndsudo` CVE and Cockpit CVE-2026-4631 set the bar for
   quoting and helpers (r3 §1).
5. **Shared before copied.** Features that need a shared extraction (catalog
   and sync layer, prompts, theme, server editor, terminal engine, charts, log
   viewer) are tiered after that extraction (root `AGENTS.md`, c1 §3.4, c2 §8,
   c3 §4). This is why container exec and in-app server editing are v1, not
   MVP.
6. **Mobile cannot poll in the background.** iOS gives about 30 s at
   system-chosen times; Android WorkManager runs at most every 15 minutes and
   `dataSync` foreground services are capped at 6 h per 24 h (r4 §2.7, r5 §5.4).
   Widgets and while-closed alerts therefore wait for T1 or T2, and long
   mutations run detached on the host (SAF-23) so that suspension cannot cut
   them in half.
7. **Portability is a feature, budgeted per tier.** ServerBox's issue history is
   dominated by non-mainstream hosts (r4 §0). MVP targets glibc Linux with
   systemd; BusyBox, OpenWrt and NAS appliances follow with fixtures.
8. **Honest coverage.** The UI states what is and is not covered: alerts only
   while open, backups that exclude a mount, history gaps, values virtualized
   inside LXC. Unknown is shown as unknown, never as zero (Séance probe
   semantics, Cockpit degradation).
9. **Respect other owners.** Stacks and containers owned by another manager,
   by Swarm or by a systemd unit are badged and read-only by default (r2 §6.2).
   Acting on them needs an explicit step that names the owner.

---

## 2. MVP at a glance

The MVP has 110 rows. 62 are user-facing screens or actions in the host and
Docker areas; the other 48 sit in cross-cutting areas (transport, integration,
safety, sync, platform, accessibility, assistant rules) and are small
individually but must be right from the first build. Grouped by screen, the
MVP is: a fleet list, a server overview, processes, services, logs, scheduled
jobs, containers, images and stacks, plus first-run enrollment, an access
check and settings.

User-facing areas:

- **Fleet and server list (FL)**: FL-01 Shared server list; FL-02 Local-only
  mode; FL-04 Reachability dots; FL-05 Search; FL-06 Group sections; FL-07
  Fleet rows with pressure bar; FL-17 Jump hosts; FL-21 Fleet monitoring
  policy; FL-22 First-run enrollment.
- **Server overview dashboard (OV)**: OV-01 Live overview; OV-02 Health card;
  OV-03 Session sparklines and gauges; OV-04 Staleness indicator; OV-05 Docker
  summary card.
- **CPU (CPU)**: CPU-01 Total utilization; CPU-02 Per-core utilization; CPU-03
  Load with core context.
- **Memory (MEM)**: MEM-01 Memory breakdown; MEM-02 Swap.
- **Disks and storage (DSK)**: DSK-01 Usage per mount; DSK-02 Inodes.
- **Network (NET)**: NET-01 Total throughput.
- **Processes (PRC)**: PRC-01 Process list; PRC-02 Kill and signal.
- **Services (SVC)**: SVC-01 Unit list; SVC-02 Failed units; SVC-03 Start,
  stop, restart, reload; SVC-04 Unit logs inline.
- **Logs (LOG)**: LOG-01 Journal viewer; LOG-02 Live follow; LOG-03 Kernel
  log; LOG-04 Access-limits notice; LOG-05 Text search; LOG-22 Tail a file.
- **Scheduled jobs (JOB)**: JOB-01 Unified jobs list; JOB-02 Schedule in words
  and next runs; JOB-03 Other users' crontabs; JOB-08 Run timer now.
- **System configuration and power (SYS)**: SYS-01 System identity; SYS-04
  Container and LXC awareness.
- **Boot, uptime and reliability (BOOT)**: BOOT-01 Uptime and last boot.
- **Docker engine and host (DKE)**: DKE-01 Engine info; DKE-02 Event-driven
  refresh; DKE-10 Managed-by badges.
- **Containers (CTR)**: CTR-01 Container list; CTR-02 Start, stop, restart;
  CTR-03 Inspect; CTR-04 Health status; CTR-05 Pause, unpause, kill; CTR-06
  Remove.
- **Container logs, exec and attach (CTX)**: CTX-01 Follow logs; CTX-02 Search
  in logs.
- **Container stats (CST)**: CST-01 Live CPU and memory in list.
- **Images and updates (IMG)**: IMG-01 Image list; IMG-02 Remove.
- **Compose stacks (STK)**: STK-01 Stack discovery; STK-02 Stack overview;
  STK-03 Stack start, stop, restart; STK-04 View compose and .env; STK-05
  Compose CLI detection; STK-06 Pull and redeploy; STK-10 Managed stacks
  read-only.

Cross-cutting areas:

- **Connection, capability probe and transport (CN)**: CN-01 One connection
  per server; CN-02 Capability probe; CN-03 Sampler channel; CN-04 Client-side
  rates; CN-05 Pause, backoff, resume; CN-06 Dead-peer detection; CN-07 Docker
  endpoint discovery; CN-08 API version negotiation; CN-09 Runtime per host;
  CN-10 Old-systemd fallbacks; CN-11 Host tier A; CN-19 Off-UI parsing; CN-22
  Low-session degradation; CN-23 Client-limitation errors; CN-24 Access check.
- **Cross-app integration (X)**: X-01 Shared marks and theme; X-02 Shared host
  keys.
- **Assistant (AI)**: AI-01 Danger rules.
- **Settings, privilege and safety (SAF)**: SAF-01 Observe-only default;
  SAF-02 Admin mode; SAF-03 Root badges; SAF-04 Command preview; SAF-05 Tiered
  confirmations; SAF-06 Read-only mode; SAF-07 Secret masking; SAF-08
  Root-equivalence notice; SAF-09 Endpoint confirmation; SAF-10 Safe
  interpolation; SAF-22 Protected targets; SAF-23 Detached operations.
- **Sync and data (SYN)**: SYN-01 Server list sync; SYN-02 Credential reuse;
  SYN-03 Never-sync rule; SYN-07 No account deletion in shared mode; SYN-08
  Device data policy.
- **Platform specifics (PLT)**: PLT-01 Desktop layout; PLT-02 Phone layout;
  PLT-03 Touch safety; PLT-04 iOS background disclosure.
- **Accessibility and localization (A11Y)**: A11Y-01 Never colour alone;
  A11Y-02 Chart semantics; A11Y-03 Table semantics; A11Y-04 Safe palettes;
  A11Y-05 Localization pipeline; A11Y-06 Server units; A11Y-08
  Locale-independent parsing; A11Y-11 Reduced motion; A11Y-15 Live update
  announcements.

Deliberately not in the MVP: container exec shells (need the shared terminal
engine), in-app server editing (needs the shared server editor), any
config-file write (crontab, compose, `.env`, unit overrides), `docker compose
down` and per-service actions, prune, image pull outside a stack, volume and
network management, package updates, history beyond the session, alerts, any
push to the sync account (pull-only, D14), and anything T1 or T2.

MVP technical prerequisites (not features, listed because they drive the cut):

- the shared catalog and sync package with shared-account enrollment (c1 §3.4,
  §6);
- headless exec, streaming exec, exec stdin and a Unix-socket byte stream in
  `seance_core` (c2 G1 to G4);
- a pure-Dart HTTP/1.1 client with upgrade hijack and Docker stdcopy demux
  (c2 G5);
- session-channel budgeting and dead-peer detection (c2 G6, G7);
- shared UI extractions: TOFU, keyboard-interactive and missing-credential
  dialogs (`ghost_prompts`), the status-dot vocabulary and connection log view
  (`ghost_servers` part 1) and the theme stack with theme editing and presets
  (`ghost_theme`, F4b, Séance switched; owner decision Q5) (c3 §4);
- Séance's conflict check for pulled host-key pins (Séance #56, adopting the
  quarantine handler, in F3; owner decision Q12), so that pin publication can
  start with catalog writes in v1 (X-02);
- a shared `CredentialResolver` for identity files and vault lookups (c2 G9);
- the dartssh2 import guard generalized to root `tool/` and run per product
  (c2 G12, c4 §5.4);
- the isolate decision for parsing (CN-19, c2 G14);
- Docker, systemd, cron and firewall rules in `DangerLinter` (AI-01, c2 §6);
- small chart and virtualized log-viewer widgets (c3 §5);
- product registration in scripts, release tool and CI (c4 §1): the client
  matrix builds on every PR (owner decision Q15), and the release job and
  manifest entries land at M4 for the preview releases (owner decision Q16).

Where the plan accepts a temporary copy instead of an extraction, it records
the copy with a follow-up (c4 §5.5).

---

## 3. Feature catalog by area

### 3.1 Fleet and server list (FL)

The shared list is the owner's hard requirement, so its read path is MVP even
though it depends on the catalog extraction and shared-account enrollment (c1
§2.1). The MVP requires enrollment and says so on first run (FL-22): without
it, phones show no servers and desktops can import `~/.ssh/config`. In-app
editing waits for the shared server editor so that no third copy appears
(c3 §4). Fleet metrics cover only servers the user marks for monitoring
(FL-21), so launch never fans out to every host. Fleet-wide aggregation is
cheap once per-host collectors exist, so most of it lands in v1 and v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| FL-01 | Shared server list | The same `serverConfig` records as Séance and Poltergeist, with groups, marks and colours | Termius and XPipe (contrast); suite requirement | MVP | C | none | E2E sync account in shared-account mode; extracted catalog package | Requires shared-account enrollment (FL-22) and Séance >= v0.9.0 on every device (c1 §6). Without it the list is empty, except for desktop ssh_config import (FL-02). |
| FL-02 | Local-only mode | Use without a sync account by importing `~/.ssh/config` hosts | Séance import, c1 §6 | MVP | C | none | ssh_config parser | Desktop only in practice; phones have no ssh_config. |
| FL-03 | Add, edit, duplicate, delete servers | Full editor with Séance-identical LWW write semantics | Séance and Poltergeist editors | v1 | C | none | shared server editor package, `duplicateServerConfig` | Blocked on the shared server editor extraction (`ghost_servers`, c3 §4). The MVP tells the user to edit in Séance or Poltergeist. |
| FL-04 | Reachability dots | Online, offline or unknown, plus "last sample N s ago" | Séance ProbeService, ServerBox staleness | MVP | T0 | none | `ProbeService` / `TcpBannerProber` (45 s jittered, at most 6 concurrent) | Probe only endpoints confirmed on this device (c1 §4.1). Mobile: pause in background. |
| FL-05 | Search | Name, host, user and group search | Séance, k9s `/` | MVP | C | none | `serverSearchHaystack` | |
| FL-06 | Group sections | Collapsible sections from Séance groups | Séance, Beszel | MVP | C | none | `existingServerGroups` | |
| FL-07 | Fleet rows with pressure bar | Per-server CPU, memory and disk segments in fixed colours; grey when stale, warn colour over threshold | ServerBox, Beszel table | MVP | T0 | user | sampler, overview collector set | Mobile: fixed row height so unreachable hosts do not reflow the list. Only servers in the monitor set (FL-21). Values inside LXC without lxcfs show as unknown (SYS-04). |
| FL-08 | Density modes | Auto, cards, rows, grid | ServerBox | v1 | C | none | - | Grid targets 40+ servers on desktop. |
| FL-09 | Fleet summary strip | Online count, attention items, total CPU and RAM | ServerGlance, ServerBox | v1 | C | none | cached samples | |
| FL-10 | Attention-first sort and faults-only filter | Sort by problems; one toggle shows only hosts that need action | k9s ctrl-z, Pulse attention queue | v1 | C | none | cached probe results | |
| FL-11 | Connection tree | Fleet, host, stacks, containers as one navigable tree | XPipe, Lens catalog | v1 | C | none | - | Mobile: drill-down stack instead of a tree. |
| FL-12 | Bulk host selection | Select hosts to refresh, connect, disconnect or run a snippet | ServerBox bulk bar, NeoServer batch | v1.x | T0 | per action | - | |
| FL-13 | Tags | Key-value tags for filtering and bulk targeting | ServerBuddy, Dockhand tags | v1.x | C | none | own synced record kind `klabautermann:pref:<serverConfigId>` | Must not add fields to `ServerConfig`: older builds drop them on re-push (c1 §2.4). |
| FL-14 | Fleet compliance tables | Columns across hosts: OS, kernel, pending and security updates, reboot needed, Docker and Compose versions, cert expiry, hardening index, failed units | Checkmk and Zabbix inventories (partial) | v1.x | T0 | user+ | cached slow-tier collectors | Differentiator. |
| FL-15 | Cross-host search | Find containers, images, ports, units, cron jobs and SSH keys across the fleet | none found (r1 gap) | v1.x | T0 | docker, user | fan-out over cached data | Differentiator. Bounded concurrency (ServerBox caps at 4). |
| FL-16 | Per-server app settings | Cadence, Docker endpoint override, read-only flag, admin-mode memory, binary path overrides | ServerBox, k9s per-cluster readOnly | v1 | C | none | device-local; selected fields as own synced kind | Endpoint overrides stay device-local. |
| FL-17 | Jump hosts | Reach servers behind bastions | Séance ProxyJump, Docker Server Admin | MVP | T0 | user | `openAuthenticatedClient` (16 hops, cycle detection) | |
| FL-18 | Fleet bulk Docker actions | Update flagged images or prune across selected hosts | Dockhand "update all flagged", Coolify scheduled cleanup | Later | T0 | docker | per-host API calls | Typed confirmation per batch. |
| FL-19 | Status share card | Share a status image with host and IP hidden by default | ServerGlance | Non-goal | C | none | rendered locally | Non-goal: low value, and every share path would need redaction. |
| FL-20 | Import Docker contexts | Offer local `docker context` SSH endpoints as servers | Raycast Docker extension | Later | C | none | `docker context ls --format json` on the device | Desktop only. |
| FL-21 | Fleet monitoring policy | Fleet metrics only for servers the user marks for monitoring that have non-interactive credentials and a confirmed endpoint; other rows show reachability only | ServerBox refresh cap, Séance ProbeService | MVP | C | none | per-server setting, FL-04, SAF-09 | At most 4 concurrent connects with jitter (ServerBox); background refreshes never prompt (c2 §2.5); keyboard-interactive servers connect on demand only (c2 R10, R11). Mobile: paused in background. |
| FL-22 | First-run enrollment | Explains that the list comes from the shared Séance sync account, asks the user to assert Séance >= v0.9.0 on every device, and discloses that the account key decrypts every app's records | Poltergeist shared-mode gate | MVP | C | none | `SyncEnrollment`, fleet assertion (c1 §6) | Without enrollment phones show no servers; desktops can import ssh_config (FL-02). From v1, before Klabautermann publishes first-seen pins, the assertion also covers the first Séance release with the #56 fix on every device (X-02, owner decision Q12). |

### 3.2 Connection, capability probe and transport (CN)

These are the user-visible behaviours of the transport. Most are MVP because
every other feature depends on them. Host support tiers follow the ServerBox
issue history (r4 §1.1): glibc plus systemd first, then BusyBox, OpenWrt and
NAS appliances with per-distro fixtures.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CN-01 | One connection per server | All features share one authenticated SSH connection; session channels budgeted at 8 or fewer; Docker traffic on forwarding channels | Poltergeist pool policy, OpenSSH `MaxSessions` | MVP | T0 | user | dartssh2 3.0.2 through `seance_core` | Forwarding channels do not count against `MaxSessions` (r5 §3.2). Avoids `MaxStartups` and fail2ban trips from reconnect bursts. Hosts with a `MaxSessions` below the budget degrade (CN-22). |
| CN-02 | Capability probe | Classify OS family, init system, container runtimes, sudo flavour, systemd version, tools present, journal access, Docker socket access, server time zone and UTC offset; cache per session | Cockpit graceful degradation, ServerBox detection | MVP | T0 | user | `uname`, `/etc/os-release`, `/proc/1/comm`, `systemctl --version`, `command -v`, `id -u`, `id -nG`, `sudo -V`, `test -S`, `date +%s %z`, `timedatectl show -p Timezone` or `/etc/timezone` | Panels that cannot work are hidden with a reason, never shown as zero. |
| CN-03 | Sampler channel | Persistent non-PTY `sh` exec emitting nonce-framed sections; collectors switched per visible screen; fast (1 to 5 s) and slow (30 s to hourly) cadences | ServerBox, Checkmk sections, Cockpit bridge | MVP | T0 | user | POSIX sh (dash, BusyBox ash); `LC_ALL=C.UTF-8` (or `C` when `locale -a` lacks it) and `TZ=UTC` prefixed in the command | No bash or Python dependency. SSH `env` requests are avoided because dartssh2 closes the channel when one is rejected. |
| CN-04 | Client-side rates | CPU %, throughput and IOPS from counter deltas with wrap and reboot detection | ServerBox | MVP | C | none | raw counters plus `btime` | |
| CN-05 | Pause, backoff, resume | Stop sampling when a screen is hidden or the app is backgrounded; reconnect with backoff; resume journal `__CURSOR` and Docker `since=` | Séance prober, ServerBox | MVP | C | none | - | Mobile: iOS suspends sessions; reconnect on return. |
| CN-06 | Dead-peer detection | Notice silently dropped links quickly | Poltergeist connection manager | MVP | T0 | user | `ping()` with a 30 s timeout | dartssh2 3.0.2 keepalive never times out (c2 R3). |
| CN-07 | Docker endpoint discovery | Try streamlocal to a configured `DOCKER_HOST`, `/var/run/docker.sock`, `/run/user/<uid>/docker.sock`, `/run/podman/podman.sock`, `/run/user/<uid>/podman/podman.sock`; fall back to `docker system dial-stdio` (or `sudo -n`) | Docker CLI `ssh://`, VS Code contexts | MVP | T0 | docker | `forwardLocalUnix`, exec | OpenSSH refuses every streamlocal open with the same connect-failed "open failed" [R: openssh-portable `serverloop.c`, reported by review], so an exec `test -S`/`test -w` check decides between a missing socket, no permission, and forwarding disabled (socket present and writable); say which. Generic relays (`socat`, `nc -U`) when no CLI exists (r5 §1.1 option C). Snap Docker is off the non-login PATH (ServerBox #969, c2 R7). |
| CN-08 | API version negotiation | Read max and min API version; client floor 1.41, baseline 1.44; feature-gate newer fields | r5 §1.4 | MVP | T0 | docker | `GET /_ping` (`Api-Version`), `GET /version` (`MinAPIVersion`) | Docker 29.0 to 29.2 rejected clients below 1.44; Podman compat reports max 1.44. |
| CN-09 | Runtime per host | Docker or Podman, rootful or rootless, auto-detected with manual override | ServerBox, Podman Desktop | MVP | T0 | docker | socket paths above, `Libpod-API-Version` header | Podman's compat API reports max 1.44, and `podman-docker` may symlink `/run/docker.sock` to Podman (r5 §1.11). Rootless engines are user-equivalent (SAF-08). The enable-socket offer is CN-25. |
| CN-10 | Old-systemd fallbacks | Text parsing where JSON output is missing (systemd < 246, for example RHEL 8 [U]) | ServerBox | MVP | T0 | user | `systemctl --plain --no-legend`, `env TZ=UTC LC_ALL=C systemctl show` | `--timestamp=unix` needs systemd 251. |
| CN-11 | Host tier A | Debian, Ubuntu, RHEL family, Fedora and Arch with systemd | ServerCat complaint, Termix Linux-only | MVP | T0 | user | - | Fixture tests per distro. |
| CN-12 | Host tier B | Alpine and BusyBox, OpenRC, OpenWrt (procd, `logread`), Dropbear | ServerBox issues #167, #1363 | v1.x | T0 | user | `ps w`, `df -k`, `rc-status`, `logread` | Needs per-distro fixtures. |
| CN-13 | NAS hosts | Synology, QNAP, Unraid, TrueNAS: docker off PATH, custom `df`, restricted shells | ServerBox issues #27, #86, #100 | v1.x | T0 | user | per-server binary path overrides | |
| CN-14 | macOS and FreeBSD hosts | Core metrics on non-Linux hosts; Linux panels hidden | ServerBox, btop | Later | T0 | user | `sysctl`, `vm_stat`, `top -l`, `netstat -ibn` | |
| CN-15 | Dropbear compatibility | Exec fallback below 2024.84; warn on 2024.84 to 2025.88 (CVE-2025-14282) | r5 §1.1 | v1 | T0 | user | SSH server banner | |
| CN-16 | Per-server overrides | Binary paths (`docker`, `journalctl`), `DOCKER_HOST`, elevation command | ServerBox | v1 | C | none | settings | |
| CN-17 | Clock skew display | Server time against device time; durations computed on the server clock | ServerBox, Pulse clock drift | v1 | T0 | user | `date +%s` | Time zone and offset are probed from the MVP (CN-02); this row adds the skew display. |
| CN-18 | Diagnostic bundle | Export raw collector output with secrets redacted, for parser bug reports | r4 §4.3 | v1 | C | none | sampler raw text, `SecretRedactor` | Redacted by default with an explicit include-secrets toggle (SAF-07). |
| CN-19 | Off-UI parsing | Parse samples and log floods outside the UI isolate | Poltergeist engine isolate | MVP | C | none | - | c2 G14. Shapes every API, so it is decided first. |
| CN-20 | Transient helper binary | Optional static helper uploaded per session for richer structured data | Cockpit beiboot | Later | T0 | user | per-arch binary over SFTP | Adds per-arch builds and review burden. |
| CN-21 | Windows hosts | PowerShell-based metrics | ServerBox | Non-goal | - | - | - | Separate parser stack; revisit after v1. |
| CN-22 | Low-session degradation | Detect a small `MaxSessions` or the `dial-stdio` fallback and degrade: cap concurrent streams, poll stats, merge stack logs through one `docker compose logs -f`, and say which mode is active | OpenSSH `MaxSessions`, Poltergeist pool policy | MVP | T0 | user | classified `SSHChannelOpenError` (c2 G1) | Under `dial-stdio` every Docker stream is an exec session (r5 §1.1 option B, §3.2). |
| CN-23 | Client-limitation errors | Report failures caused by dartssh2 3.0.2 limits (no chacha20-poly1305, no ML-KEM, handshake timeouts on low-memory Android) as client limitations, not server faults | c2 R12, R13 | MVP | C | none | connect error classification in `seance_core` | Hardened hosts are core users. The fix is the suite-wide dartssh2 re-pin (section 6). |
| CN-24 | Access check | Per-server screen: sudo NOPASSWD, journal group, Docker socket rights, streamlocal allowed, compose plugin, systemd version, each with a copyable fix command | Cockpit degradation, r5 §1.1 detection | MVP | T0 | user | view over CN-02, CN-07, LOG-04 | Fix commands are shown, never run implicitly. Docker-group advice carries the SAF-08 notice. |
| CN-25 | Enable Podman socket | Previewed command when the Podman socket is off | Podman Desktop, r5 §1.11 | v1 | T0 | sudo, user | `systemctl [--user] enable --now podman.socket` | System socket behind admin mode. |

### 3.3 Server overview dashboard (OV)

The overview is where users land, so a fixed, useful default is MVP and
customisation is v1. Cards read from the shared sampler, so they cost almost
nothing extra.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| OV-01 | Live overview | CPU (total and per core), load, memory and swap, disk per mount, network throughput, uptime, OS and kernel | ServerBox, ServerCat, Cockpit | MVP | T0 | user | `/proc/stat`, `/proc/loadavg`, `/proc/meminfo`, `df -PT`, `/proc/net/dev`, `/proc/uptime`, `/etc/os-release` | Mobile: single column. Values inside LXC without lxcfs are marked unknown (SYS-04). |
| OV-02 | Health card | Failed units, disks over threshold, unhealthy containers | Cockpit health card | MVP | T0 | user | `systemctl --failed`, `df`, container `State.Health` | Updates and reboot-required items join at v1 (PKG). |
| OV-03 | Session sparklines and gauges | Rolling history since connect | Meows, Glances quicklook | MVP | C | none | client ring buffer | Needs a small in-house chart package (c3 §5.1). |
| OV-04 | Staleness indicator | "Last sample N s ago"; grey when stale | ServerBox | MVP | C | none | - | |
| OV-05 | Docker summary card | Running, stopped and unhealthy counts, images, reclaimable space | ServerBox `system df` summary, Dockhand tiles | MVP | T0 | docker | `/containers/json`, `/system/df` on demand | `system df` is slow on large hosts; fetch separately. |
| OV-06 | Configurable cards | Reorder, hide and add cards; unsupported cards hidden | ServerBox, Dockhand tiles | v1 | C | none | - | Layout syncs as an own record kind in v1.x. |
| OV-07 | Top lists | Top processes and containers by CPU and memory | Dockhand tile, Glances | v1 | T0 | user, docker | `/proc`, container stats | |
| OV-08 | Quick actions | Terminal, files, restart a pinned service, reboot | ServerBox, Cockpit | v1 | T0 | per action | - | |
| OV-09 | Custom cards | Output of user-defined probes on the overview | ServerBox `server_card_top_right` | v1.x | T0 | user | AUT-03 | |
| OV-10 | Bottom dock | Persistent panel for logs, command output and terminal under the dashboard | Lens dock | v1 | C | none | - | Mobile: bottom sheet. |
| OV-11 | Threshold bands | OK, careful, warning, critical bands per metric with user thresholds | Glances, Beszel | v1 | C | none | settings | Never colour alone (A11Y-01). |

### 3.4 CPU (CPU)

Total, per-core and load come from the same `/proc/stat` read and are MVP.
Breakdowns and pressure are v1 because they need explanation copy to be useful.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CPU-01 | Total utilization | User, system, idle | every monitor | MVP | T0 | user | `/proc/stat` deltas | |
| CPU-02 | Per-core utilization | Bars or heatmap per core | ServerCat, ServerKeep heatmap | MVP | T0 | user | `/proc/stat` `cpuN` lines | Mobile: heatmap compacts many cores. |
| CPU-03 | Load with core context | 1, 5, 15 minute load and load per core | every monitor | MVP | T0 | user | `/proc/loadavg`, `nproc` | |
| CPU-04 | Breakdown with hints | iowait, steal, irq, softirq, with plain-language hints such as "steal 25%: noisy neighbour on your VPS host" | Glances, Netdata, Beszel iowait/steal alerts | v1 | T0 | user | `/proc/stat` fields | The man page calls iowait unreliable; say so. |
| CPU-05 | Pressure (PSI) | cpu, memory and io `some`/`full` averages | Netdata, node_exporter | v1 | T0 | user | `/proc/pressure/{cpu,memory,io}` | Kernel 4.20+; may be disabled (`psi=0`, some enterprise kernels [U]). Absence is normal. |
| CPU-06 | Frequency and throttling | Current frequency and governor per core | Netdata, Glances | v1.x | T0 | user | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` | |
| CPU-07 | Model and topology | Model, sockets, cores, threads | Cockpit, ServerBox | v1 | T0 | user | `lscpu -J`, `/proc/cpuinfo` | arm64 often lacks `model name`. |
| CPU-08 | Per-cgroup CPU | CPU by systemd unit and container | Netdata systemd-services | v1.x | T0 | user | `/sys/fs/cgroup/**/cpu.stat` | Paths differ per cgroup driver [U]. |
| CPU-09 | Context switches and interrupts | Rates | Glances, Netdata | Later | T0 | user | `/proc/stat` `ctxt`, `intr` | The `intr` line can be large; read only when shown. |

### 3.5 Memory (MEM)

The memory breakdown is table stakes. OOM correlation is a cheap
differentiator because the kernel already counts kills.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| MEM-01 | Memory breakdown | Used, available, buffers, cache, shared as a stacked bar | every monitor, ServerKeep | MVP | T0 | user | `/proc/meminfo` (`MemAvailable`) | On hosts with `/proc/spl/kstat/zfs/arcstats` the bar says "ZFS ARC counted as used" until MEM-05 arrives. |
| MEM-02 | Swap | Swap used; swap-in and swap-out rates | Netdata, Beszel | MVP | T0 | user | `/proc/meminfo`, `/proc/vmstat` `pswpin`/`pswpout` | Rates arrive in v1. |
| MEM-03 | OOM kills | Kill count with victims linked to journal entries | Netdata, node_exporter | v1 | T0 | journal | `/proc/vmstat` `oom_kill`, `journalctl -k -g 'Out of memory'` | Differentiator. |
| MEM-04 | Memory pressure | PSI memory | Netdata | v1 | T0 | user | `/proc/pressure/memory` | |
| MEM-05 | ZFS ARC as reclaimable | Count ARC as cache, not used | Beszel, Komodo 2.3 | v1.x | T0 | user | `/proc/spl/kstat/zfs/arcstats` | |
| MEM-06 | zram and zswap | Compression ratio and usage | none found | v1.x | T0 | user | `zramctl`, `/sys/module/zswap/parameters/*` [U] | |
| MEM-07 | Expert memory fields | Huge pages, slab, dirty and writeback | node_exporter | Later | T0 | user | `/proc/meminfo` | |

### 3.6 Disks and storage (DSK)

Disk space was an explicit owner ask, so usage and inodes are MVP; I/O rates
follow in v1. The
disk explorer is v1 because it is the most-requested storage feature that
almost no GUI does well (r3 §4.4); deleting files from it is handed to
Poltergeist (r4 §4.3). Layout, ZFS and RAID are read-only v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| DSK-01 | Usage per mount | Bytes and percent, pseudo filesystems filtered by type | every panel | MVP | T0 | user | `df -PT -B1`, `findmnt -J -b` | Filter tmpfs, devtmpfs, overlay, squashfs, erofs by type, not device name. Wrap in a timeout: stale NFS mounts hang `df`. |
| DSK-02 | Inodes | Inode use per mount | Netdata, Checkmk | MVP | T0 | user | `df -Pi` | Often forgotten; a full inode table looks like a full disk. |
| DSK-03 | I/O throughput and IOPS | Read and write rates per device | every monitor | v1 | T0 | user | `/proc/diskstats` deltas (512-byte sectors) | Skip loop and ram devices. |
| DSK-04 | Latency and utilization | Await and busy percent per device | Netdata, Glances | v1 | T0 | user | `/proc/diskstats` `io_ticks`, weighted ms | |
| DSK-05 | Mount details | Source, type and options | Cockpit | v1 | T0 | user | `findmnt -J` (util-linux 2.27+) | |
| DSK-06 | Block device layout | Partitions, LVM, RAID, LUKS, read-only | Cockpit Storage, Webmin | v1.x | T0 | user+ | `lsblk -J -b -o ...`, `pvs`/`vgs`/`lvs --reportformat json`, `/proc/mdstat` | LVM reports need sudo. |
| DSK-07 | Disk space explorer | ncdu-style drill-down of the largest directories and files, streamed | ncdu, gdu, 1Panel (partial) | v1 | T0 | user+ | `ncdu -x -o -` or `gdu -o-` when installed, else incremental `du -x -B1 -d1` | Differentiator. sudo for a complete tree. Mobile: drill-down list. |
| DSK-08 | Open in Poltergeist | Hand a directory or file from the explorer to Poltergeist for browsing and deletion | Poltergeist | v1.x | C | none | `poltergeist://browse` deep link (X-04) | File operations stay in Poltergeist (r4 §4.3). |
| DSK-09 | Cleanup suggestions | Journal vacuum, package caches, Docker prune, old kernels, core dumps, rotated logs; each with size and command preview | none found as one screen | v1.x | T0 | sudo | `journalctl --disk-usage`, `du` on caches, `/system/df`, package queries | Differentiator. |
| DSK-10 | Fill forecast | "Full in N days" per mount | Netdata, Prometheus `predict_linear` | v1.x | C | none | HIS data | Needs history (HIS-02, HIS-05). |
| DSK-11 | ZFS | Pools, datasets, scrub state | Beszel 0.19, Cockpit ZFS Manager | v1.x | T0 | user | `zpool status -p`, `zpool list -Hp`, `zfs list -Hp` | |
| DSK-12 | mdraid health | Array state and degraded members | Beszel, Webmin | v1.x | T0 | user, sudo | `/proc/mdstat`, `mdadm --detail` | |
| DSK-13 | Btrfs health | Device error stats and scrub | node_exporter btrfs | Later | T0 | sudo | `btrfs device stats`, `btrfs scrub status` [U flags] | |
| DSK-14 | Swap devices | Swap files and partitions with priority | none found | v1 | T0 | user | `swapon --show`, `/proc/swaps` | |
| DSK-15 | Network mounts | NFS and SMB mounts with stale-mount detection | none found | v1.x | T0 | user | `findmnt -t nfs,nfs4,cifs`, `timeout 5 stat <mount>` | |
| DSK-16 | Quotas | User and group quotas | Webmin | Non-goal | T0 | sudo | `repquota` | Non-goal: niche (r3 §4.4). |

### 3.7 Network (NET)

Throughput is MVP. Listening ports mapped to their owner and the firewall view
are v1 because they answer the two most common questions ("what is on :8080",
"is it exposed"). Firewall editing is Later because a mistake locks the user
out.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| NET-01 | Total throughput | Receive and transmit rates | every monitor | MVP | T0 | user | `/proc/net/dev` | |
| NET-02 | Interfaces | Addresses, state, MTU, speed, rates, errors, drops per interface | Cockpit, ServerBox | v1 | T0 | user | `ip -j addr`, `ip -j -s link`, `/sys/class/net/*/speed` | |
| NET-03 | Connection counts | Sockets by state | Glances, ServerBox | v1 | T0 | user | `ss -s`, `/proc/net/sockstat`, `/proc/net/snmp` | |
| NET-04 | Listening ports map | Port to process to systemd unit or container | Netdata network viewer (partial) | v1 | T0 | user+ | `ss -Htulpn`, `/proc/<pid>/cgroup`, container `Ports` | Differentiator. `ss` has no JSON. Owners of other users' sockets need sudo. Docker port bindings are merged in too: with `userland-proxy: false` published ports have no listening socket [U]. |
| NET-05 | Live connections | Remote peers per process | Netdata (Cloud-gated), Glances | v1.x | T0 | user+ | `ss -Htunp` | |
| NET-06 | Firewall view | ufw, nftables, firewalld, iptables rules | Cockpit, Webmin, 1Panel | v1 | T0 | sudo | `ufw status verbose`, `nft -j list ruleset`, `firewall-cmd --list-all-zones`, `iptables-save` | |
| NET-07 | Exposure map | Listening ports crossed with firewall rules and a reachability probe from the device | none found | v1.x | T0 | sudo | NET-04, NET-06, client TCP connect | Differentiator. Mobile: label the vantage point; a phone on Wi-Fi is not the public internet. Docker-published ports bypass ufw and firewalld INPUT rules unless `DOCKER-USER` rules restrict them [U: current Docker documentation wording]; such ports are marked. The device-side probe is the ground truth. |
| NET-08 | Firewall edit with lockout guard | Add or remove rules; automatic revert unless confirmed within 60 s | Cloudron, YunoHost; classic pattern | Later | T0 | sudo | `ufw`, `firewall-cmd`, `nft`; revert scheduled with `systemd-run --on-active=60` | The revert is a transient unit, not an installed file. |
| NET-09 | Routes and DNS | Routing table and resolvers | Cockpit, Webmin | v1.x | T0 | user | `ip -j route`, `resolvectl status`, `/etc/resolv.conf` | |
| NET-10 | Probes from the server | Ping, TCP, HTTP timing, DNS and traceroute from the host's vantage point | Beszel 0.20 and 0.21, Uptime Kuma, Gatus | v1.x | T0 | user | `ping -c`, `curl -w`, `getent hosts`, `dig`, `traceroute`, `mtr --json` [U] | |
| NET-11 | Local port forward | Forward a host or container port to 127.0.0.1 on the device and open it in a browser | Dockpeek idea, OrbStack | v1 | T0 | user | `forwardLocal` (`direct-tcpip`) | Needs `AllowTcpForwarding` (default yes) and a new `seance_core` API (c2 G16). Prefer an in-app web view fed through the SSH channel with no listening socket [U feasibility]; otherwise a random loopback port, explicit start and stop, auto-close with the view. Mobile: any Android app can reach loopback ports [U]; warn. |
| NET-12 | VPN status | WireGuard peers and handshakes, Tailscale state | Cockpit Tailscale plugin | v1.x | T0 | sudo, user | `wg show all dump`, `tailscale status --json` | |
| NET-13 | Traffic totals | Daily and monthly volume for VPS quotas | vnStat (not in research) | v1.x | T0 | user | `vnstat --json` when installed [U] | |
| NET-14 | conntrack usage | Connection-tracking table fill against its maximum | node_exporter conntrack | v1.x | T0 | user | `/proc/sys/net/netfilter/nf_conntrack_count`, `nf_conntrack_max` | A full table silently drops connections. |
| NET-15 | Public IP and reverse DNS | The address the internet sees, with rDNS | YunoHost diagnosis | Non-goal | T0 | user | `curl` to a user-chosen echo service; rDNS lookup from the device | Non-goal: contacts a third party for little value. |
| NET-16 | Per-process bandwidth | Bandwidth by process | nethogs, Netdata eBPF | Non-goal | T0 | sudo | `nethogs -t` when installed | Non-goal: needs an extra tool installed with sudo for an expert view. |

### 3.8 Processes (PRC)

A sortable list with kill is table stakes everywhere, so both are MVP, with
ServerBox's PID-reuse guard. Process-to-unit and process-to-container
attribution is v1 because it links three screens together.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| PRC-01 | Process list | Sort by CPU, memory, user, start time, command; search | htop, ServerBox, Webmin | MVP | T0 | user | `/proc/<pid>/stat` read with shell builtins; `ps -eo ...`; BusyBox `ps w` | Current CPU from utime plus stime deltas, not the lifetime `pcpu`. Sampled only while visible. Command lines masked per SAF-07. |
| PRC-02 | Kill and signal | TERM, KILL, HUP and others, guarded against PID reuse | ServerBox start-time check, htop | MVP | T0 | user, sudo | `kill -s <SIG> <pid>` after comparing start time | sudo only for other users' processes. Dialog names the target. Protected targets (SAF-22): PID 1, sshd, dockerd and the sampler need typed confirmation. |
| PRC-03 | Tree view | Parent and child hierarchy | htop, btop, Glances | v1 | T0 | user | `ppid` field | |
| PRC-04 | Process detail | Command line, cwd, environment (masked), limits, open files, sockets | htop, Webmin | v1 | T0 | user+ | `/proc/<pid>/{cmdline,cwd,environ,limits,fd}`, `ss -p` | Environment values masked by default. |
| PRC-05 | Unit and container attribution | Which systemd unit or container owns a process; jump to its logs | Netdata systemd-services | v1 | T0 | user | `/proc/<pid>/cgroup` | Differentiator. |
| PRC-06 | State highlighting | Zombies, uninterruptible sleep, runaway thread counts | htop | v1 | T0 | user | `stat` state field | |
| PRC-07 | Renice and ionice | Change priority | htop, Webmin | v1.x | T0 | user, sudo | `renice`, `ionice` | Raising priority needs sudo. |
| PRC-08 | Per-process I/O | Read and write bytes per process | Netdata, Glances | v1.x | T0 | sudo | `/proc/<pid>/io` | |
| PRC-09 | Follow a process | Pin a PID and chart it over the session | btop | Later | T0 | user | - | |

### 3.9 Services (SVC)

The unit list, failed units, start, stop, restart and per-unit logs are MVP:
they are the core of Cockpit's value and need no file writes. Enable, disable
and unit file views follow in v1. Override editing waits for the shared
edit-safety machinery (v1.x). Reading never uses sudo; actions do, except for
user units (ServerBox rule).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| SVC-01 | Unit list | System services with load, active and sub state; filter by type and state | Cockpit, ServerBox | MVP | T0 | user | `systemctl list-units --all --output=json` (systemd 246+), else `--plain --no-legend` | |
| SVC-02 | Failed units | Summary and per-unit result | Cockpit, Beszel | MVP | T0 | user | `systemctl --failed` | |
| SVC-03 | Start, stop, restart, reload | Unit actions with command preview | Cockpit, ServerBox | MVP | T0 | sudo, polkit | `sudo -n systemctl <verb> -- '<unit>'` | Unit names validated against the systemd grammar and quoted (Cockpit CVE-2026-4631 lesson). Protected targets (SAF-22). |
| SVC-04 | Unit logs inline | Recent journal lines on the unit page | Cockpit, Beszel 0.21 | MVP | T0 | journal | `journalctl -u <unit> -o json -n N` | |
| SVC-05 | Enable and disable | Boot-time enablement | Cockpit | v1 | T0 | sudo, polkit | `systemctl enable`, `systemctl disable` |  |
| SVC-06 | Mask, unmask, reset-failed |  | Cockpit | v1 | T0 | sudo, polkit | `systemctl mask`, `unmask`, `reset-failed` |  |
| SVC-07 | Unit file view | Unit file with drop-ins | Cockpit | v1 | T0 | user | `systemctl cat <unit>` | |
| SVC-08 | Per-unit resources | Memory, CPU time, tasks, restart count, main PID, active since | Netdata, Cockpit | v1 | T0 | user | `systemctl show -p MemoryCurrent,CPUUsageNSec,TasksCurrent,NRestarts,MainPID,ActiveEnterTimestamp` | `systemctl show` has no JSON (systemd issue #39081). |
| SVC-09 | User units | Units of the SSH user's own manager | Cockpit | v1 | T0 | user | `systemctl --user ...` | Never `sudo systemctl --user`: it talks to root's manager. Needs a user session or linger. May need `XDG_RUNTIME_DIR=/run/user/<uid>` set in the command [U]. |
| SVC-10 | Timers, sockets, mounts, paths | Tabs per unit type | Cockpit | v1 | T0 | user | `systemctl list-timers --all`, `list-sockets` (JSON) | |
| SVC-11 | Override editor | Edit a drop-in, validate, reload the manager | Webmin, `systemctl edit` | v1.x | T0 | sudo | drop-in written through the privileged path (SAF-12), `systemd-analyze verify`, `systemctl daemon-reload` | Backup and diff first (SAF-12). |
| SVC-12 | Make resilient | Suggest a `Restart=on-failure` drop-in for units that keep failing | Monit restart rules (host-native alternative) | v1.x | T0 | sudo | drop-in file | Host-native remediation with no agent. |
| SVC-13 | Dependencies | Requires, Wants, After as a graph | Cockpit | v1.x | T0 | user | `systemctl list-dependencies`, `systemctl show -p Requires,Wants,After` | |
| SVC-14 | OpenRC and procd | Service list and actions on Alpine and OpenWrt | ServerBox | v1.x | T0 | user, sudo | `rc-status`, `rc-service`, `rc-update show`; `/etc/init.d` plus `ubus` | Enable on OpenRC is `rc-update`, not `rc-service`. |
| SVC-15 | runit, s6, supervisord | | node_exporter collectors, 1Panel Supervisor | Later | T0 | user, sudo | `sv status`, `supervisorctl status` | |
| SVC-16 | New service from a command | Wizard that writes a unit and an optional timer | Cockpit timer creation | Later | T0 | sudo | unit files, `daemon-reload` | |

### 3.10 Logs (LOG)

A journal viewer with filters, follow and the current boot's kernel log is
MVP, together with a single-file tail for logs outside the journal (LOG-22):
both are table stakes and need only read access. Regex, the `/var/log` browser
with archives, boot selection and export are v1. The faceted explorer and the
unified host-plus-container stream are the headline differentiators and land
in v1.x once the log viewer widget is mature.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| LOG-01 | Journal viewer | Filter by unit, identifier, priority, boot and time range; newest first; load older | Cockpit, lazyjournal | MVP | T0 | journal | `journalctl -o json --no-pager -u -t -p -b --since --until -n`; paging with `--after-cursor` | Non-UTF-8 values arrive as byte arrays; handle them. |
| LOG-02 | Live follow | Tail with pause on scroll and cursor resume | Cockpit, Netdata PLAY mode | MVP | T0 | journal | `journalctl -f -o json --after-cursor=<c>` on its own channel | Stop with TERM, then close the channel (r5 §3.2). Per-view ring buffer by lines and bytes with a line-length cap; backpressure pauses the subscription and shows "dropped N lines"; Live, Connecting, Disconnected and Paused chip (Dockhand, c2 R17). |
| LOG-03 | Kernel log | Kernel messages for the current boot; past boots arrive with LOG-09 | Cockpit, lazyjournal | MVP | T0 | journal | `journalctl -k`; `dmesg --json` only as a fallback | `dmesg` needs CAP_SYSLOG when `kernel.dmesg_restrict=1` [U distro defaults]. |
| LOG-04 | Access-limits notice | Explain when only the user's own entries are visible | r5 §2.3 | MVP | T0 | user | `id -nG` | Otherwise the truncation is silent. |
| LOG-05 | Text search | Plain text with case toggle and match stepping | Docker Desktop | MVP | C | none | loaded window | |
| LOG-06 | Regex and fuzzy search | Visible invalid-regex state; server-side matching for large ranges | lazyjournal, Dozzle | v1 | T0 | journal | `journalctl -g` (PCRE2) | |
| LOG-07 | Highlighting | Levels, IPs, URLs, HTTP codes, ANSI SGR colours | lazyjournal, Dozzle | v1 | C | none | - | |
| LOG-08 | Files under /var/log | Browse including rotated `.gz` and `.xz`; tail and follow | Webmin, lazyjournal | v1 | T0 | user+ | `ls /var/log`, `tail -n`, `tail -F`, `zcat` | Many files need `adm` or root. Single-file tail is LOG-22 (MVP). |
| LOG-09 | Boot picker | Choose a boot to inspect | Cockpit | v1 | T0 | journal | `journalctl --list-boots` (JSON since systemd 251) | |
| LOG-10 | Export and share | Copy, save or share, with optional redaction | Dozzle, Docker Desktop | v1 | C | none | `SecretRedactor` | Redacted by default with an explicit include-secrets toggle (SAF-07). Mobile: share sheet. |
| LOG-11 | Faceted explorer | Field values with counts, include and exclude, timeline histogram | Netdata journal explorer | v1.x | T0 | journal | client-side over the loaded window; `journalctl -F <FIELD>` for value lists | Differentiator: Netdata gates parts of this behind its Cloud. |
| LOG-12 | Unified stream | Journal units, container logs and files merged by timestamp | lazyjournal (TUI only); r1 gap | v1.x | T0 | journal, docker | LOG-01, CTX-01, LOG-08 | Differentiator. |
| LOG-13 | Structured fields | JSON detection, expandable rows, custom columns | Dozzle, Logdy | v1.x | C | none | - | |
| LOG-14 | Saved queries | Named filters synced across devices | Docker Desktop presets | v1.x | C | none | own record kind `klabautermann:query:<uuid>` | No host names or queries in record ids: they are plaintext (c1 §2.4). |
| LOG-15 | Journal size and vacuum | Disk used by the journal; vacuum by size or age | none found as a UI | v1.x | T0 | sudo | `journalctl --disk-usage`, `--vacuum-size=`, `--vacuum-time=` | Also offered by DSK-09. |
| LOG-16 | Log rate view | Lines and errors per minute | Netdata histogram, Dozzle SQL charts | v1.x | C | none | loaded window | |
| LOG-17 | Syslog-only hosts | Logs on OpenWrt and Alpine without journald | ServerBox, lazyjournal | v1.x | T0 | user | `logread`, `/var/log/messages` | |
| LOG-18 | logrotate view | Rotation policies per file | Webmin | Later | T0 | user | `/etc/logrotate.conf`, `/etc/logrotate.d/*` | |
| LOG-19 | auditd | Audit records | lazyjournal | Later | T0 | sudo | `ausearch -i` | |
| LOG-20 | Cross-host log search | One query across a server group | none found | Later | T0 | journal | fan-out `journalctl -g` | |
| LOG-21 | Picture-in-picture tail | Keep a tail visible while using other apps | Secure ShellFish | Non-goal | C | none | - | Non-goal: iPad-only nicety with low value. |
| LOG-22 | Tail a file | Tail and follow one file chosen from common paths or typed; no archives | Webmin, lazyjournal | MVP | T0 | user+ | `tail -n`, `tail -F` with a quoted path | nginx, Apache, rsyslog and application logs. Same ring buffer as LOG-02. Many files need `adm` or root (admin mode). |
| LOG-23 | Split and pinned log panes | Several streams side by side | Dozzle, Docker Desktop | v1.x | C | none | - | Desktop only. |

### 3.11 Scheduled jobs (JOB)

A unified jobs list with human-readable schedules is MVP because no surveyed
tool does it and it needs no writes (r3 §5.2). In admin mode it includes other
users' crontabs read-only, and a timer can be run now through the same
mechanism as a service start. Editing, pausing and running cron commands are
v1 with edit safety. Output capture and dead-man pings modify job
lines and depend on external services, so they are v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| JOB-01 | Unified jobs list | Own crontab, `/etc/crontab`, `/etc/cron.d`, `cron.{hourly,daily,weekly,monthly}` and systemd timers in one list | none found (r3 gap) | MVP | T0 | user | `crontab -l`, read the files, `systemctl list-timers --all --output=json` | Differentiator. Other users' crontabs via JOB-03 (admin mode). |
| JOB-02 | Schedule in words and next runs | Human-readable schedule and the next N run times | Healthchecks cron dialog, Cronicle picker | MVP | C | none | Dart cron parser (5 fields, macros, `CRON_TZ`); `systemd-analyze calendar --iterations=N` for `OnCalendar` | Uses the server time zone and offset from CN-02; DST changes and `RandomizedDelaySec` are noted next to next-run times. Localized ARB templates, not English concatenation (A11Y-05). |
| JOB-03 | Other users' crontabs | Read the crontabs of every user, without editing, in admin mode | Webmin | MVP | T0 | sudo | `crontab -l -u <user>`; spool `/var/spool/cron/crontabs/` (Debian) or `/var/spool/cron/` (RHEL) | Editing arrives with JOB-06 (v1). |
| JOB-04 | anacron | Periodic anacron jobs and last-run stamps | Webmin [U] | v1 | T0 | user | `/etc/anacrontab`, `/var/spool/anacron/*` | |
| JOB-05 | Last run and result | Native for timers; from journal or syslog for cron | Cronicle, 1Panel run records | v1 | T0 | journal | `systemctl show <timer> -p LastTriggerUSec` plus service `Result`; `journalctl -t CRON` or `_COMM=cron`; `/var/log/cron` | Cron does not log exit status by default; say so. |
| JOB-06 | Safe crontab edit | Validate, diff, back up, keep comments and env lines | crontab-ui | v1 | T0 | user, sudo | `crontab -` from stdin, run under `sh` with `LC_ALL=C` | fish login shells reject POSIX syntax; always run under `sh`. |
| JOB-07 | Pause and resume | Comment a job out with a marker instead of deleting it | crontab-ui, Webmin | v1 | T0 | user, sudo | crontab edit | |
| JOB-08 | Run timer now | Start a timer's service immediately and stream its journal output | Cockpit, Webmin | MVP | T0 | sudo, polkit, user | `systemctl start <service>`; `systemctl --user start` for user units | Same mechanism and guards as SVC-03 (SAF-22). |
| JOB-09 | Managed-crontab detection | Jobs owned by Dokku, Coolify, Dokploy or Runtipi shown read-only | Dokku docs ("reserved") | v1 | T0 | user | crontab owner and markers | |
| JOB-10 | Timer creator | Calendar UI that writes a `.timer` and `.service` | Cockpit | v1.x | T0 | sudo | unit files, `daemon-reload` | User units need no sudo. |
| JOB-11 | Output capture | Wrap a job so its output reaches the journal | Cronicle live log, Healthchecks body capture | v1.x | T0 | user, sudo | `cmd 2>&1 \| logger -t klabautermann-job-<id>` or `systemd-cat` | Visible, reversible edit of the job line. T1 only if a wrapper script is installed. |
| JOB-12 | Dead-man pings | Start, success and fail pings to the user's Healthchecks or Uptime Kuma push URL | Healthchecks, Uptime Kuma push monitors | v1.x | T1+E | user | `curl` wrapper around the job | Alerting lives in that external service. Sends job timing and status to the chosen service. |
| JOB-13 | Missed-run detection | Compare expected runs with observed runs | Checkmk freshness, Zabbix `nodata()` | v1.x | T0 | journal | schedule plus journal history | |
| JOB-14 | Fleet jobs overview | All jobs across servers | none found | v1.x | T0 | user | fan-out | |
| JOB-15 | Collision heatmap | Jobs per minute across a host or the fleet, to spot pile-ups at the same time | none found | Later | C | none | parsed schedules | |
| JOB-16 | Convert cron to timer | Generate an equivalent timer and service | none found | Later | T0 | sudo | generated unit files | |
| JOB-17 | Typed job presets | Backup, log rotation, cache cleanup, URL ping, time sync | 1Panel cron types | Later | T1 | sudo | timers plus scripts | |
| JOB-18 | Container jobs | `docker compose exec` or `run --rm` on a schedule | Dokploy schedule jobs, Dokku cron | Later | T1 | docker | systemd timer | |
| JOB-19 | Run cron job now | Run a cron command immediately as its user with streamed output | Webmin, Cronicle | v1 | T0 | user, sudo | `sh -c '<cmd>'` as the job user | Danger rules (AI-01) on the command; long runs detached (SAF-23). |

### 3.12 Packages and updates (PKG)

Update status is read-only and cheap, so the fleet update center is v1.
Applying updates is v1.x because it is long-running and privileged: it runs as
a detached operation (SAF-23) with typed confirmation. Scheduled checks are T1.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| PKG-01 | Pending updates | List per distro, with package-list age | Cockpit, Webmin | v1 | T0 | user | `apt-get -s upgrade` (parse `Inst`), `dnf check-update` (exit 100), `dnf5 check-upgrade --json`, `checkupdates`, `apk version -l '<'`, `zypper -q lu` | `apt` warns that its CLI is unstable for scripts; use `apt-get`. Unprivileged checks use cached metadata only (`--cacheonly` for dnf, the same rule for zypper and `checkupdates`) and show the cache age; refresh is PKG-05 [U unprivileged dnf cache behaviour]. |
| PKG-02 | Security updates | Flag security fixes | Cockpit, Checkmk | v1 | T0 | user | `dnf updateinfo list --security`, Debian `-security` origin, `zypper lp -g security`, Ubuntu `apt-check` [U] | |
| PKG-03 | Reboot required | | Cockpit | v1 | T0 | user | `/var/run/reboot-required(.pkgs)`, `needs-restarting -r` (exit 1 = reboot), running against installed kernel | |
| PKG-04 | Services needing restart | Daemons still running old libraries | Cockpit tracer | v1 | T0 | user, sudo | `needrestart -b`, `needs-restarting -s`, `zypper ps -s` | |
| PKG-05 | Refresh package lists | | Webmin | v1 | T0 | sudo | `apt-get update`, `dnf makecache` | |
| PKG-06 | Fleet update center | All servers with counts, security counts, reboot flags | none found fleet-wide | v1 | T0 | user | cached PKG-01 to PKG-04 | Differentiator. |
| PKG-07 | Apply updates | Streamed output with typed confirmation | Cockpit, Webmin | v1.x | T0 | sudo | `DEBIAN_FRONTEND=noninteractive apt-get -y upgrade`, `dnf -y upgrade`, run as a detached operation (SAF-23) | Never in a client-held channel: a hangup mid-dpkg can leave a half-configured system [U]. Mobile: Live Activity later (PLT-13). |
| PKG-08 | Holds | Held and version-locked packages | Webmin | v1.x | T0 | user, sudo | `apt-mark showhold`, `dnf versionlock list` | |
| PKG-09 | Automatic updates status | unattended-upgrades or dnf-automatic config and last run | Cockpit [U] | v1.x | T0 | user | `/etc/apt/apt.conf.d/20auto-upgrades`, `/var/log/unattended-upgrades/`, `systemctl status dnf-automatic.timer` | |
| PKG-10 | Old kernels | Installed kernels that can be removed | none found | v1.x | T0 | user | `dpkg -l 'linux-image*'`, `rpm -q kernel` | Feeds DSK-09. |
| PKG-11 | Scheduled update check | Daily check on the host writing a state file the app reads on connect | Coolify patch notifications | v1.x | T1 | sudo | timer plus script writing JSON | Notifications through ALR-05. |
| PKG-12 | Install, remove, search | Package management | Cockpit Applications, Webmin | Later | T0 | sudo | `apt-get install`, `dnf install` | |
| PKG-13 | Livepatch status | | none found | Later | T0 | user | `canonical-livepatch status`, `kpatch list` | |
| PKG-14 | Snap and Flatpak updates | | none found | Later | T0 | user | `snap refresh --list`, `flatpak remote-ls --updates` [U] | |

### 3.13 Users, SSH keys and access audit (ACC)

Listing users and sessions is v1. The access audit (login history, key
inventory, "where is this key") is a differentiator that needs sudo on every
host, so it is v1.x. Fleet key rotation is valuable but can lock the user out
and changes credentials that Séance owns, so it is Later and Séance-led.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| ACC-01 | Users and groups | UID, shell, groups; members of sudo, wheel and docker flagged as root-equivalent | Cockpit Accounts | v1 | T0 | user | `getent passwd`, `getent group` | |
| ACC-02 | Logged-in sessions | Who is logged in, from where | Cockpit | v1 | T0 | user | `who`, `loginctl list-sessions --output=json` (systemd 240+; `-j` shorthand only from 256; before 243 an empty list prints nothing, read as no sessions) | |
| ACC-03 | Terminate session | | Cockpit | v1.x | T0 | sudo | `loginctl terminate-session <id>` | |
| ACC-04 | Login history | Successes and failures with source IPs, per user | 1Panel SSH login logs | v1.x | T0 | sudo, journal | `last -F -w`, `lastb`, `journalctl _COMM=sshd -o json`, `/var/log/auth.log`, `/var/log/secure` | Differentiator. Distros moving to wtmpdb and lastlog2 change sources [U]. |
| ACC-05 | authorized_keys inventory | Fingerprints, comments and options per user | Cockpit per-user keys | v1.x | T0 | sudo | `~/.ssh/authorized_keys`, `ssh-keygen -lf` | |
| ACC-06 | Where is this key | Search a fingerprint across the fleet | none found | v1.x | T0 | sudo | fan-out ACC-05 | Differentiator. |
| ACC-07 | Fleet key rotation | Add a new key, verify login with it, then remove the old one | none found | Later | T0 | sudo | atomic authorized_keys edit; test connection before removal | Differentiator; typed confirmation; never removes the key in use without a verified alternative. Séance-led design: it needs a new key in the vault and updated credentials on `ServerConfig`, which Séance owns. |
| ACC-08 | sudoers overview | Who may run what | Cockpit Sudo Manager plugin | v1.x | T0 | sudo | `sudo -l -U <user>`, `/etc/sudoers.d/*`, `visudo -c` | |
| ACC-09 | User management | Create, lock, delete, password, expiry | Cockpit, Webmin, ServerBox | Later | T0 | sudo | `useradd`, `usermod`, `userdel`, `chpasswd` on stdin, `chage -l` | Use flags BusyBox also accepts. |
| ACC-10 | Stale accounts | No login in N days, expired passwords | Lynis findings | Later | T0 | sudo | `lastlog`, `chage -l` | |

### 3.14 Security and hardening (SEC)

`sshd -T` is v1 because it also explains whether Docker streamlocal can work.
The rest depends on optional tools (Lynis, fail2ban, CrowdSec) or produces
long result lists, so it is v1.x or Later. The container security review lives
in DKE-06.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| SEC-01 | sshd posture | Root login, password auth, port, key types, forwarding settings | 1Panel SSH management, Lynis | v1 | T0 | sudo | `sshd -T -C user=<u>,host=<h>,addr=<addr from $SSH_CONNECTION>` | Shows whether `AllowStreamLocalForwarding` blocks the Docker transport. Without `-C`, `Match` blocks are ignored [U, standard OpenSSH behaviour]. |
| SEC-02 | Hardening audit | Lynis hardening index and findings with solutions | Lynis, Cockpit SCAP plugin | v1.x | T0 | sudo | `lynis audit system --quick --no-colors`, parse `/var/log/lynis-report.dat` | Lynis must be present or installed with a previewed command. |
| SEC-03 | Fleet hardening table | Index per host with trend | none found | v1.x | C | none | cached SEC-02 | Differentiator. |
| SEC-04 | fail2ban | Jails, banned IPs, unban | Fail2Ban UI, Webmin | v1.x | T0 | sudo | `fail2ban-client status`, `fail2ban-client status <jail>`, `fail2ban-client set <jail> unbanip <ip>` | |
| SEC-05 | CrowdSec | Decisions and alerts | CrowdSec | Later | T0 | sudo | `cscli decisions list -o json`, `cscli alerts list -o json` | |
| SEC-06 | SELinux and AppArmor | Mode and recent denials | Cockpit SELinux page | v1.x | T0 | sudo | `getenforce`, `sestatus`, `ausearch -m AVC`, `aa-status --json` | |
| SEC-07 | Service exposure scores | systemd sandboxing score per service | none in a UI | v1.x | T0 | user | `systemd-analyze security --json=short` (systemd 250+) | |
| SEC-08 | Kernel mitigations | CPU vulnerability status | node_exporter cpu_vulnerabilities | v1.x | T0 | user | `/sys/devices/system/cpu/vulnerabilities/*` | |
| SEC-09 | Root-equivalent access summary | Everyone who can become root: sudo rules, docker group, wheel | none found | v1.x | T0 | sudo | ACC-01 plus ACC-08 | Differentiator. |
| SEC-10 | Host key cross-check | Show the host's key fingerprints next to the TOFU pin | Cockpit configuration card | v1.x | T0 | user | `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` | Arrives over the same connection, so it is not independent verification; it records every key type and spots pin mismatches. |

### 3.15 Certificates (CRT)

Endpoint expiry needs no SSH at all, so it is v1. The local certificate
inventory (files on disk, proxy stores) is a differentiator but needs sudo and
path discovery, so it is v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CRT-01 | Endpoint TLS expiry | TLS handshake from the device to user-listed host and port pairs | Uptime Kuma, Gatus, Beszel 0.21 | v1 | C | none | Dart `SecureSocket` | Vantage point is the device. |
| CRT-02 | Local certificate inventory | Subject, SANs, issuer and expiry for certificate files on the host | none found | v1.x | T0 | sudo | `certbot certificates`, `/etc/letsencrypt/live/*/cert.pem`, `/etc/ssl`, paths referenced in nginx, Apache and HAProxy configs, Traefik `acme.json`, Caddy storage; `openssl x509 -noout -enddate -subject -ext subjectAltName` | Differentiator. |
| CRT-03 | Renewal status | ACME timer or cron present, last run | 1Panel, Webmin | v1.x | T0 | user | `systemctl list-timers 'certbot*'`, `/var/log/letsencrypt/` | |
| CRT-04 | Fleet expiry table | All certificates across servers, soonest first | none found fleet-wide | v1.x | C | none | cached CRT-01 and CRT-02 | |
| CRT-05 | TLS from the server | Check upstream endpoints from the host's vantage point | Gatus | v1.x | T0 | user | `openssl s_client -servername <host> -connect <host>:<port>` | |
| CRT-06 | Domain expiry | Registration expiry | Gatus | Later | C+E | none | RDAP from the device | Queries an RDAP service from the device; opt-in. |

### 3.16 Hardware and sensors (HW)

Temperatures, GPU and SMART summary are table stakes for home-lab users and are
v1. SMART runs on a slow cadence with `-n standby` so it never wakes spun-down
disks (ServerBox rationale).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| HW-01 | Temperatures | CPU, board and drive temperatures | Beszel, Glances, ServerBox | v1 | T0 | user | `/sys/class/thermal/thermal_zone*`, `/sys/class/hwmon/*`, `sensors -j` (lm-sensors 3.5+) | VMs and LXC usually have none; hide the card. |
| HW-02 | Fans and voltages | | Beszel | v1.x | T0 | user | hwmon files, `sensors -j` | |
| HW-03 | GPU | Utilization, memory, temperature, power | Beszel, btop, ServerBox | v1 | T0 | user | `nvidia-smi --query-gpu=... --format=csv,noheader,nounits`, amdgpu `gpu_busy_percent` sysfs, `intel_gpu_top -J` | Forking tools run on the slow cadence. |
| HW-04 | SMART summary | Pass, warn or fail per disk, NVMe wear, temperature | Scrutiny, Beszel | v1 | T0 | sudo | `smartctl --scan-open`, `smartctl -n standby -a -j /dev/<disk>` (smartmontools 7.0+) | sudo only when the device node is unreadable. Minutes-scale cadence. |
| HW-05 | Critical attribute scoring | Failure-rate-based thresholds with a "why" | Scrutiny | v1.x | C | none | HW-04 data | |
| HW-06 | Battery and UPS | | Beszel, ServerBox | v1.x | T0 | user | `/sys/class/power_supply/*`, `upsc` | |
| HW-07 | Hardware inventory | DMI, PCI devices, memory slots | Webmin, Cockpit | v1.x | T0 | user+ | `/sys/class/dmi/id/*`, `lspci -mm`, `dmidecode` (sudo) | |
| HW-08 | IPMI, BMC and EDAC | Out-of-band sensors and memory error counters | Netdata, node_exporter edac, ServerBox Redfish | Later | T0 | sudo | `ipmitool sdr`, `/sys/devices/system/edac` | |

### 3.17 System configuration and power (SYS)

System identity and container or LXC detection are MVP: the overview needs
both to show correct values. Reboot with reboot-and-wait is v1. Changing
system settings is Later: low frequency, high blast radius.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| SYS-01 | System identity | OS, kernel, architecture, virtualization, hostname | every panel | MVP | T0 | user | `/etc/os-release`, `uname -a`, `systemd-detect-virt`, `hostnamectl --json=short` (systemd 249+) | |
| SYS-02 | Time and NTP | Time zone and sync status | Cockpit, Pulse clock drift | v1 | T0 | user | `timedatectl show`, `chronyc tracking` | |
| SYS-03 | Reboot and shutdown | Typed confirmation; reboot-and-wait progress until SSH answers again | ServerBox, NeoServer | v1 | T0 | sudo | `systemctl reboot`, `systemctl poweroff` | Mobile: Live Activity later (PLT-13). |
| SYS-04 | Container and LXC awareness | Detect virtualized `/proc` (lxcfs) and mark affected metrics unknown | r5 §2.6 | MVP | T0 | user | `systemd-detect-virt -c` | Marks affected metrics unknown in OV-01, FL-07 and the CPU and memory views (r5 §2.6). |
| SYS-05 | sysctl and kernel command line | Searchable values | none found | v1.x | T0 | user | `sysctl -a`, `/proc/cmdline` | |
| SYS-06 | Kernel modules | Loaded modules | Webmin | Later | T0 | user | `lsmod` | |
| SYS-07 | Change hostname and time zone | | Cockpit | Later | T0 | sudo | `hostnamectl set-hostname`, `timedatectl set-timezone` | |
| SYS-08 | Wake-on-LAN | From the device on the same LAN, or relayed through another server in the list | NeoServer | Later | C | none | magic packet; `wakeonlan` or `etherwake` on a relay host | Relay variant is T0 on the relay. |

### 3.18 Boot, uptime and reliability (BOOT)

Uptime is MVP. The boot timeline with unclean-shutdown markers is a cheap
differentiator (journal plus wtmp) and lands in v1.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| BOOT-01 | Uptime and last boot | | every monitor | MVP | T0 | user | `/proc/uptime`, `btime` in `/proc/stat` | |
| BOOT-02 | Boot timeline | Boots with duration; unclean shutdowns marked | Cockpit boot selector, lazyjournal | v1 | T0 | journal | `journalctl --list-boots`, `last -x reboot shutdown` | Differentiator. |
| BOOT-03 | Running against installed kernel | Flag a pending kernel | Cockpit | v1 | T0 | user | `uname -r` against the package database or `/boot` | |
| BOOT-04 | Crash markers | Kernel panics, OOM kills and watchdog resets on the timeline | none found | v1.x | T0 | journal | `journalctl -k -b -1 -p err`, `/sys/fs/pstore` [U] | |
| BOOT-05 | Boot performance | Total boot time, slowest units, critical chain | none in surveyed GUIs | v1.x | T0 | user | `systemd-analyze`, `systemd-analyze blame`, `systemd-analyze critical-chain` | Differentiator. |

### 3.19 Triage and diagnosis (TRI)

These screens combine collectors from other areas into answers. They are v1
because they need the collectors first, and they are a large part of what
separates the app from Docker-only tools.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| TRI-01 | Doctor checklist | Read-only checks with fix hints: disk over 90%, inodes, failed units, pending security updates, reboot required, time sync, cert expiry, open ports, Docker disk use, dangling images, unrotated container logs | YunoHost diagnosis, Cockpit health card | v1 | T0 | user+ | aggregates other collectors | Differentiator. |
| TRI-02 | Why is it slow | One screen: pressure, iowait, steal, top processes, recent OOM kills, disk latency, swap activity, with plain-language hints | none found | v1 | T0 | user | CPU-04, CPU-05, MEM-03, DSK-04, PRC-01 | Differentiator. |
| TRI-03 | Attention queue | Fleet list of problems with acknowledge and note | Pulse attention queue, Zabbix problem lifecycle | v1 | C | none | cached results | Ack state device-local first; syncing is a later decision. |
| TRI-04 | Container diagnose | Heuristics from restart count, exit code, OOMKilled, health log and last log lines | Docker Desktop Gordon (AI) | v1 | T0 | docker | `State` from inspect, logs tail | Works without an LLM. |
| TRI-05 | Incident snapshot | Capture processes, disks, memory, sockets, journal tail and containers at one moment; save or share redacted | xyOps server snapshot on alert | v1.x | T0 | user+ | bundle of collectors | Differentiator. Saved or shared redacted by default (SAF-07). |
| TRI-06 | Pre-flight checks | Before a deploy: missing bind-mount sources, port conflicts, wrong architecture, low disk | Synology and Coolify pitfalls (r2 §5.6) | v1.x | T0 | user, docker | `test -e`, `ss -ltn`, `uname -m`, `df` | Missing bind sources otherwise become empty directories. |

### 3.20 Docker engine and host (DKE)

The Engine API over an SSH `direct-streamlocal` channel gives full API
fidelity with nothing installed and no `MaxSessions` cost (r5 §1.1). Read-only
views, event-driven refresh and managed-by detection are MVP, because
ownership must be known before the first lifecycle action (r2 §6.2).
Destructive engine-wide operations (prune) need a dry-run preview first and
come in v1. Topology and daemon config are v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| DKE-01 | Engine info | Version, API version, storage, cgroup and logging drivers, rootless flag, daemon warnings | Portainer, Docker Desktop | MVP | T0 | docker | `GET /version`, `GET /info` | |
| DKE-02 | Event-driven refresh | Lists update from engine events instead of polling | r5 §1.9 | MVP | T0 | docker | `GET /events?since=` | Parse `Type`, `Action` and `Actor`; API 1.52 removed the legacy `status`, `id` and `from` fields, so accept both shapes. Resume with `since=` after reconnects. |
| DKE-03 | Events timeline | create, start, die, oom, health_status and more, filterable, while the app is open | Dockhand activity log, Portainer events | v1 | T0 | docker | `GET /events?since=&filters=` | Docker keeps only a bounded buffer: gaps while disconnected. A persistent log needs T2 (ALR-14). |
| DKE-04 | Disk usage | Images, containers, volumes, build cache, reclaimable space | Dockhand, ServerBox, Dozzle 11.3 | v1 | T0 | docker | `GET /system/df` (shape changed in API 1.52 and 1.53) | On demand only; slow on large hosts. |
| DKE-05 | Prune with preview | List exactly what would be removed, with sizes and exemption labels, then prune | Docker Manager iOS delete preview, Dockhand | v1 | T0 | docker | list with the same filters, then `POST /containers/prune`, `/images/prune`, `/volumes/prune`, `/networks/prune`, `/build/prune` | Typed confirmation for volumes and for `-a`. |
| DKE-06 | Security review | Privileged containers, socket mounts, host network or PID, added capabilities, root user, databases on 0.0.0.0, `latest` tags, no healthcheck, no restart policy | Docker Manager iOS, Dockhand validate, Arcane risk view, Cosmos orange ports | v1 | T0 | docker | inspect of every container | Differentiator. |
| DKE-07 | Log rotation lint | Flag containers on `json-file` without `max-size` whose log file is growing | none found | v1 | T0 | docker | `HostConfig.LogConfig`, `LogPath` size (sudo for the size) | `json-file` does not rotate by default (r5 §1.6). |
| DKE-08 | Apps and ports view | Every published port and proxy URL label with "open in browser" | Dockpeek, Docker Desktop | v1 | T0 | docker | container `Ports`, Traefik and Caddy labels, `dockhand.url`, `dev.dozzle.url` | |
| DKE-09 | Unexposed port access | One-tap SSH forward to a container IP and port that is not published | none found | v1 | T0 | docker | container IP from inspect plus `forwardLocal` (NET-11) | Differentiator. Same exposure rules as NET-11. |
| DKE-10 | Managed-by badges | Detect stacks owned by Coolify, Runtipi, Umbrel, CasaOS, Swarm, TrueNAS, Dockhand or Portainer; default to read-only | r2 §6.2 | MVP | T0 | docker | labels `coolify.managed`, `runtipi.managed`, `com.docker.stack.namespace`, `com.docker.swarm.*`; Podman systemd unit label [U name]; Umbrel, CasaOS and TrueNAS conventions [U] | Editing behind another manager's back gets overwritten or desynchronizes it. Containers owned by systemd units (quadlets, `docker run` units with `Restart=always`) and Swarm tasks count as owned. Actions on owned targets need an explicit "act anyway" step that names the owner. |
| DKE-11 | Rootless linger warning | Flag a rootless engine whose user has linger disabled | r5 §1.11 | v1 | T0 | user | `loginctl show-user <user> -p Linger` | Rootless containers stop at logout without linger [U]. |
| DKE-12 | Daemon config | View and validate `/etc/docker/daemon.json`; restart is a separate typed action | none found | v1.x | T0 | sudo | privileged read (SAF-12); `dockerd --validate --config-file` [U] |  |
| DKE-13 | Network topology graph | Containers, networks, published ports and proxies as a graph | Dockhand (compose dependency graph only); r1 gap | v1.x | C | none | `/networks`, `/containers/json` | Differentiator. Mobile: list fallback. |
| DKE-14 | Swarm read-only | Services, tasks and nodes | Portainer | Later | T0 | docker | `/services`, `/tasks`, `/nodes` | Orchestration is a non-goal. |
| DKE-15 | Podman pods and quadlets | | cockpit-podman, Podman Desktop | Later | T0 | docker | `/libpod/pods/json`, `/libpod/quadlets` | |
| DKE-16 | Engine restart | Restart dockerd with an impact list and typed confirmation | Coolify warns about this | Later | T0 | sudo | `systemctl restart docker` | Never implicit (r2 §6.1). |
| DKE-17 | Other tools on this host | Detect Portainer, Dockhand, Dockge, Dozzle, Beszel, Uptime Kuma, Netdata or WUD and offer a link or a port forward | r1 §5.3 option (d) | v1 | T0 | docker, user | container images and names, unit names | Pairs with DKE-10. |

### 3.21 Containers (CTR)

The list, inspect and single-container lifecycle (start, stop, restart, pause,
kill, remove) are MVP: they map one-to-one onto Engine API calls and are what
every tool, native or web, offers first (r1 §5.2). Bulk actions and the column
chooser are v1. Create, edit and file browsing
need more UI and are v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CTR-01 | Container list | Name, state, health, uptime, image, ports, stack; grouped by compose project; running-only toggle; search by name, image or ID | Docker Desktop, Dockhand, ServerBox | MVP | T0 | docker | `GET /containers/json?all=1` | Parse Swarm task names (long and dotted; ServerBox #1226). `size=1` is expensive; load sizes lazily. |
| CTR-02 | Start, stop, restart | Single container, addressed by full ID | every tool | MVP | T0 | docker | `POST /containers/{id}/start`, `/stop?t=`, `/restart?t=` | Ownership (DKE-10) and protected targets (SAF-22) are checked first. |
| CTR-03 | Inspect | Env (secrets masked), labels, mounts, ports, networks, restart policy, command, raw JSON | Portainer, Dockhand | MVP | T0 | docker | `GET /containers/{id}/json` | Inspect output is never synced or sent to an LLM without consent. |
| CTR-04 | Health status | Health badge; last health-check outputs | Dockhand, Arcane | MVP | T0 | docker | `State.Health` | Health-check log view in v1. |
| CTR-05 | Pause, unpause, kill | Kill with a chosen signal | Portainer, lazydocker | MVP | T0 | docker | `POST /containers/{id}/pause`, `/unpause`, `/kill?signal=` | Same guards as CTR-02. |
| CTR-06 | Remove | Optionally with anonymous volumes | every tool | MVP | T0 | docker | `DELETE /containers/{id}?v=&force=` | Typed confirmation when `v=1`; same guards as CTR-02. |
| CTR-07 | Bulk actions | Checkbox selection; selecting a project selects its containers | Docker Desktop, Dockhand | v1 | T0 | docker | per-container calls | |
| CTR-08 | Column chooser | Show, hide and reorder columns (CPU, memory, network, block I/O, PIDs, IP, last started), persisted | Docker Desktop, Dockhand | v1 | C | none | settings | |
| CTR-09 | Restart-loop and exit flags | Restart count, last exit code, OOMKilled | Docker Desktop, Coolify notifications | v1 | T0 | docker | `RestartCount`, `State.ExitCode`, `State.OOMKilled` | |
| CTR-10 | Processes tab | Processes inside the container | Portainer, Arcane 2.14 | v1 | T0 | docker | `GET /containers/{id}/top?ps_args=` | |
| CTR-11 | Label links | Open `dockhand.url`, `dev.dozzle.url` or proxy hosts; honour mute labels | Dockhand, Dozzle | v1 | T0 | docker | container labels | |
| CTR-12 | Interop labels | Honour `wud.tag.include`/`exclude` and `dockhand.*` labels | Dockhand, WUD | v1.x | C | none | container labels | Cheap interoperability with existing setups. |
| CTR-13 | Copy as docker run | Reconstruct a `docker run` command | Docker Desktop | v1.x | C | none | inspect | |
| CTR-14 | Generate compose service | From a running container; save as a new stack or append to one | Dockhand, Arcane compose generator, Dockge converter | v1.x | T0 | docker | inspect converted to YAML | On-ramp from CLI-created containers to stacks. |
| CTR-15 | Rename | | Portainer, Docker Manager iOS | v1.x | T0 | docker | `POST /containers/{id}/rename?name=` | |
| CTR-16 | Update limits in place | CPU, memory and restart policy without recreating | Dockhand, Docker Manager iOS | v1.x | T0 | docker | `POST /containers/{id}/update` | Image, env and port changes need a recreate. |
| CTR-17 | Create from form | Image, ports, env, mounts, network, restart policy, limits | Portainer, Dockhand | v1.x | T0 | docker | `POST /containers/create` | |
| CTR-18 | Filesystem changes | Files added, changed or deleted against the image | Docker Desktop | v1.x | T0 | docker | `GET /containers/{id}/changes` | |
| CTR-19 | Container file browser | Browse, download, upload and edit small files | Docker Desktop, Dockhand, Docker Manager iOS | v1.x | T0 | docker | `GET`, `PUT`, `HEAD /containers/{id}/archive?path=` (tar) | Mobile: download through the share sheet. |
| CTR-20 | Recreate with changes | Duplicate and edit, applied as a recreate | Portainer | Later | T0 | docker | create plus remove | |
| CTR-21 | Debug shell | Tool-equipped helper container sharing the target's PID and network namespaces, for distroless images | Docker Debug, OrbStack Debug Shell | Later | T0 | docker | helper created with `PidMode=container:<id>` [U design] | Explicit confirmation on each use (owner decision Q20): shows what will start and whether an image must be downloaded; helper image pinned by digest, preferring one already present; helper removed afterwards; clear failure on air-gapped hosts. |
| CTR-22 | App icons | Icons for well-known images | Dockhand (selfh.st icons) | Later | C | none | icon set | Blocked until the icon licence is checked [U]. |

### 3.22 Container logs, exec and attach (CTX)

Following logs is MVP: it is the most-used Docker feature and the stdcopy
demuxer is part of the MVP HTTP client anyway. Exec shells are v1 because they
need the terminal engine moved into a shared package first (c2 G10). Merged
stack logs and parsing are v1.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CTX-01 | Follow logs | Tail N, follow, timestamps, stdout and stderr marked, ANSI colours, pause on scroll; works for stopped containers | Dozzle, Dockhand, Docker Desktop | MVP | T0 | docker | `GET /containers/{id}/logs?follow=1&tail=N&timestamps=1&stdout=1&stderr=1`; stdcopy demux unless `Config.Tty` | Reconnect with `since=` the last timestamp as Unix `seconds.nanoseconds`, dropping the duplicated boundary line (the bound is inclusive). Mobile: bottom sheet. Same bounded ring buffer and connection chip as LOG-02. When the logging driver keeps no readable logs, say so ("driver X, cache disabled", r5 §1.6). |
| CTX-02 | Search in logs | Text search with match stepping | Docker Desktop | MVP | C | none | loaded buffer | |
| CTX-03 | Time range | Since and until | Dozzle 11.2, Portainer | v1 | T0 | docker | `since=`, `until=` | |
| CTX-04 | Stack logs | All services of a stack merged by time, one colour per container, per-service filter | Dozzle, Docker Desktop, Dockge | v1 | T0 | docker | parallel log streams, one forwarding channel each | |
| CTX-05 | JSON and level parsing | Expandable JSON, level colours, multi-line stack traces grouped | Dozzle | v1 | C | none | - | |
| CTX-06 | Download and share logs |  | Dozzle zip, Docker Desktop export | v1 | C | none | `SecretRedactor` | Redacted by default with an explicit include-secrets toggle (SAF-07). |
| CTX-07 | Exec shell | Choose shell and user; TTY resize | every tool | v1 | T0 | docker | `POST /containers/{id}/exec`, `POST /exec/{id}/start` (hijacked with `Upgrade: tcp`), `POST /exec/{id}/resize?h=&w=`, `GET /exec/{id}/json` | Needs the shared terminal engine (c2 G10). Watch the rows and columns order. |
| CTX-08 | One-off command | Run a non-interactive command; show output and exit code | Portainer console | v1 | T0 | docker | exec without TTY | |
| CTX-09 | Attach | Attach to PID 1 | Portainer, Dozzle, lazydocker | v1.x | T0 | docker | `POST /containers/{id}/attach?stream=1&stdin=1&stdout=1&stderr=1` | Never send the detach keys (Ctrl-P Ctrl-Q) by accident. |
| CTX-10 | Global logs view | One stream across all containers of a host, with saved presets | Docker Desktop global Logs | v1.x | T0 | docker | parallel streams; presets as own record kind | |
| CTX-11 | Pattern highlights | User regexes highlighted in live streams | Dozzle alert expressions (used as filters) | v1.x | C | none | - | |

### 3.23 Container stats (CST)

Live CPU and memory in the list are MVP, polled one-shot only for visible
containers to keep daemon load low (r5 §1.7). Detail charts and sorting are v1.
Reading cgroup files in the sampler is cheaper for many containers but needs
per-driver path verification, so it is v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| CST-01 | Live CPU and memory in list | For visible containers | Dockhand, Docker Desktop, ServerBox | MVP | T0 | docker | `GET /containers/{id}/stats?stream=false&one-shot=true` at list cadence; deltas client-side | One streaming connection per container is costly on large hosts. |
| CST-02 | Sort by live usage | | Arcane 2.13, Dockhand | v1 | C | none | CST-01 | |
| CST-03 | Detail charts | CPU, memory against limit, network, block I/O, PIDs since connect | Docker Desktop, Dozzle | v1 | T0 | docker | `stats?stream=1` for the open container | cgroup v2 omits some fields (`percpu_usage`, most `blkio_stats`). |
| CST-04 | Memory limit risk | Percent of limit with OOM-risk highlight | none found | v1 | C | none | stats | |
| CST-05 | Top containers table | Dense ctop-style table | ctop, lazydocker | v1 | C | none | CST-01 | |
| CST-06 | cgroup sampler | CPU and memory for all containers from cgroup files in the host sampler | r5 §1.7 | v1.x | T0 | user | `/sys/fs/cgroup/system.slice/docker-<id>.scope/` or `/sys/fs/cgroup/docker/<id>/` [U paths] | |
| CST-07 | Per-stack totals | Sum of a stack's services | none found | v1.x | C | none | - | |

### 3.24 Images and updates (IMG)

The image list with an unused flag and image removal are MVP. Pull, history
and digest update detection are v1 table stakes. The Dockhand-style update
pipeline (semver advisories, release notes, cooldown, safe update with
rollback) is the largest Docker differentiator and lands in v1.x. Scanning is
Later because it runs third-party tools on the host and Trivy had a
supply-chain compromise in 2026 (r5 §6).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| IMG-01 | Image list | Tags, size, created, in use, unused, dangling | every tool | MVP | T0 | docker | `GET /images/json` (`Containers` is a real count since API 1.51) | |
| IMG-02 | Remove | With force option | every tool | MVP | T0 | docker | `DELETE /images/{name}?force=&noprune=` | Typed confirmation when forcing; images in use are flagged. |
| IMG-03 | Pull with progress | Per-layer progress and error detail | Dockhand, Docker Desktop | v1 | T0 | docker | `POST /images/create?fromImage=&tag=` with `X-Registry-Auth`; or `docker pull` over exec to use the host's credential helpers | Read `progressDetail` and `errorDetail` (legacy fields deprecated in 1.48). |
| IMG-04 | History and layers | | Portainer, lazydocker | v1 | T0 | docker | `GET /images/{name}/history` | `CreatedBy` can reveal build arguments; mask. |
| IMG-05 | Update detection | Local `RepoDigests` against the registry digest; amber indicator; cached | Dockhand, WUD, Diun, Cup | v1 | T0+E | docker | registry `HEAD /v2/<repo>/manifests/<tag>` (`Docker-Content-Digest`) from the device or `curl -I` on the host; `GET /distribution/{name}/json` as fallback | HEAD does not count against Docker Hub pull limits; GET does. Compare index digests on the containerd image store [U]. Device-side registry lookups are opt-in: they disclose the device IP and image names. |
| IMG-06 | Prune unused | With preview and exemption label | Dockhand | v1 | T0 | docker | DKE-05 | |
| IMG-07 | Update shelf | All flagged images across the fleet in one place | Umbrel 2.0 update shelf, Dockhand "update all flagged" | v1.x | C | none | IMG-05 cache | |
| IMG-08 | Safe update | Pull first, record previous digests, recreate, wait for health, roll back automatically, report what changed | Runtipi 4.10.2, WUD 9.3, Dozzle 11.3, Dockhand safe-pull | v1.x | T0 | docker | pull, then `docker compose up -d` or recreate; poll `State.Health`; recreate from the recorded digest on failure | Differentiator. Writes host-side deploy history (STK-12). |
| IMG-09 | Semver tag advisory | Newer tags within a maximum bump, flavour matching (`-alpine`), prerelease toggle | Dockhand, WUD | v1.x | C+E | none | registry tag list API | Advisory only; never edits compose silently. |
| IMG-10 | Release notes | Rendered from the forge linked in `org.opencontainers.image.source` | Dockhand | v1.x | C+E | none | GitHub, Gitea or Forgejo release APIs from the device |  |
| IMG-11 | Minimum age cooldown | Hide updates younger than N hours | Dockhand `MINIMUM_RELEASE_AGE_HOURS` | v1.x | C+E | none | registry created date | Guards against freshly published compromised images. |
| IMG-12 | Scheduled update check | Daily digest check on the host writing a state file | Diun, WUD | v1.x | T1+E | docker | timer plus script (`docker image inspect`, `curl -I`) | Notifies through ALR-05. |
| IMG-13 | Tag and push | | Portainer, Dockhand | Later | T0 | docker | `POST /images/{name}/tag`, `POST /images/{name}/push` | |
| IMG-14 | Vulnerability scan | Ephemeral Grype or Trivy container pinned by digest; results by severity; export | Dockhand, Arcane, Docker Manager iOS | Later | T0 | docker | `grype docker:<image> -o json`, `trivy image --format json` | Trivy v0.69.4 and the Docker Hub images 0.69.5 and 0.69.6 (and `latest` during the March 2026 exposure window) were backdoored (CVE-2026-33634, GHSA-69fq-xp46-6x23): pin a verified digest, never a tag. |
| IMG-15 | SBOM and attestations | In-toto statements attached at build time | Docker Engine API 1.55 | Later | T0 | docker | `GET /images/{name}/attestations` | Offline OSV matching feasibility [U]. |
| IMG-16 | Signature policy | Deploy only images signed by chosen identities | none in GUIs | Later | T0 | docker | `cosign verify` on the host | |
| IMG-17 | Move images between servers | Export from one host, load on another | Dockhand, Portainer | Later | T0 | docker | `GET /images/{name}/get`, `POST /images/load`, streamed through the app | |
| IMG-18 | Build | Build from a Dockerfile or compose `build:` | Portainer, Komodo | Later | T0 | docker | `docker build`, `docker compose build` over exec | |
| IMG-19 | Auto-update | Scheduled safe update per container or stack | Watchtower fork, Tugtainer, Dockhand | Later | T1 | docker | timer running the IMG-08 flow | Discouraged for stateful apps; needs a pre-update backup (BAK-08). |
| IMG-20 | Save and load on the device | Save an image to a tar on the device and load it on a host, for air-gapped hosts | Dockhand load from tar | Later | T0 | docker | `GET /images/{name}/get`, `POST /images/load` | Large transfers; mobile storage limits. |

### 3.25 Volumes (VOL)

Volume and network CRUD are table stakes but not first-day needs, so they are
v1. Browsing volume contents uses a privileged read or a helper container and
is v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| VOL-01 | Volume list | Driver, mountpoint, labels, users, size | Dockhand, Docker Desktop | v1 | T0 | docker | `GET /volumes`; sizes from `GET /system/df?verbose=1` | |
| VOL-02 | Create and remove | | every tool | v1 | T0 | docker | `POST /volumes/create`, `DELETE /volumes/{name}` | Typed confirmation on remove. |
| VOL-03 | Browse volume files | SFTP to the mountpoint when readable, else a helper container (read-only while in use) | Dockhand busybox helper, Docker Desktop | v1.x | T0 | docker, sudo | `Mountpoint` read through the privileged path (SAF-12), or a helper container with the volume mounted | Offers "open in Poltergeist". The helper container needs explicit confirmation on each use (owner decision Q20): it shows what will start and whether an image must be downloaded, pins the image by digest, prefers an image already present and removes the helper afterwards; clear failure on air-gapped hosts. |
| VOL-04 | Clone | | Dockhand, Docker Desktop | Later | T0 | docker | helper container copy | Keep driver, options and labels. |
| VOL-05 | Export and import | Volume to tar and back | Dockhand, Docker Desktop | Later | T0 | docker | helper container `tar`, streamed | See also BAK-03. |

### 3.26 Networks (DNW)

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| DNW-01 | Network list | Driver, subnet, gateway, attached containers; built-in networks protected | Dockhand, Portainer | v1 | T0 | docker | `GET /networks`, `GET /networks/{id}` | |
| DNW-02 | Remove and prune | | every tool | v1 | T0 | docker | `DELETE /networks/{id}`, DKE-05 | |
| DNW-03 | Create with IPAM | Subnet, gateway, range, driver options | Dockhand | v1.x | T0 | docker | `POST /networks/create` | |
| DNW-04 | Connect and disconnect | With aliases and static IP | Dockhand, Docker Manager iOS | v1.x | T0 | docker | `POST /networks/{id}/connect`, `/disconnect` | |

### 3.27 Compose stacks (STK)

Compose has no Engine API: stacks are discovered from container labels, files
are read over SFTP (or a privileged read) and commands run over exec
(r5 §1.12). The MVP verifies each stack's source files and shows them
read-only, starts, stops and restarts whole stacks in dependency order, and
runs pull and redeploy (`pull`, `up -d`) as a detached operation for
unmanaged, verified stacks. Writing files, `down` and per-service actions
arrive in v1 with diff, backup and validation. Drift
detection, deploy preview, lint and host-side history are v1.x differentiators.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| STK-01 | Stack discovery | Group containers by `com.docker.compose.project`; resolve `working_dir` and `config_files` and verify them before use | Dockhand adopt, Dockge (stacks folder only); r2 gap | MVP | T0 | docker | compose labels from `GET /containers/json` | Finds hand-written stacks with no registration step. A file counts as the stack source only if it exists and its `com.docker.compose.config-hash` label matches `docker compose config --hash` (when the CLI exists); otherwise it is labelled "unverified source", or "source not on host (deployed by X)" when missing. Containerized managers record paths inside their own container (Dockge's path rule, r1 §3.3). |
| STK-02 | Stack overview | Services, containers, state, health, ports, images | Dockhand, Dockge | MVP | T0 | docker | labels plus `/containers/json` | |
| STK-03 | Stack start, stop, restart | Act on the project's existing containers in dependency order | Docker Desktop, ServerKeep | MVP | T0 | docker | per-container API calls | Start in `com.docker.compose.depends_on` order and stop in reverse; one-off containers (`com.docker.compose.oneoff`) are skipped. Existing containers only: STK-06 creates missing services. Guarded by DKE-10 and SAF-22. |
| STK-04 | View compose and .env | Read-only, highlighted | ServerKeep, Dockhand read-only view | MVP | T0 | user, sudo | SFTP read when the login user can read the files; `sudo -n cat` in admin mode otherwise | Verified sources only (STK-01). `.env` values masked by default. |
| STK-05 | Compose CLI detection | Compose plugin version; legacy `docker-compose` treated read-only | r5 §1.12 | MVP | T0 | user | `docker compose version`, `docker-compose version` | v1 Python Compose stopped receiving updates in 2023. Needed in the MVP for source verification and STK-06. |
| STK-06 | Pull and redeploy | `pull` then `up -d` for unmanaged, verified stacks, with streamed output and exit status | Dockge, Dockhand deploy console | MVP | T0 | docker | `docker compose -p <p> --project-directory <d> -f <files> [--env-file <f>] pull` and `up -d` over exec, rebuilt from compose labels; `--progress plain`, `--ansi never` [U flags] | Runs as a detached operation (SAF-23). No `--remove-orphans` by default: orphans are listed in the preview with an explicit option. Warns when running services are gated by a profile (active profiles are not recorded in labels [U]). Shows the STK-13 preview where supported. Uses the host's registry credentials (REG-01). `down` and per-service actions are STK-23. |
| STK-07 | Edit compose and .env | Planchette editor, diff before write, timestamped backup, validation, atomic replace | Dockhand, Dockge, Docker Manager iOS auto-backup | v1 | T0 | user, sudo | SAF-12 file paths (SFTP or the privileged path); `docker compose config -q` | Comment- and order-preserving; never drop unknown keys (r2 §6.3). Verified sources only (STK-01). |
| STK-08 | Folder scan | Find stacks with no running containers in user-chosen directories such as `/opt/stacks` | Dockge, Dockhand | v1 | T0 | user | `find <dir> -maxdepth 2` for `compose*.y*ml` and `docker-compose*.y*ml` | |
| STK-09 | Overrides and profiles | Multiple compose files, overrides, profiles | Komodo, Arcane | v1 | T0 | docker | `config_files` label, `--profile` | |
| STK-10 | Managed stacks read-only | Stacks owned by other managers shown with a badge, edits off by default | r2 §6.2 | MVP | C | none | DKE-10 | Actions need an explicit "act anyway" step that names the owner. |
| STK-11 | Drift detection | Running config against the file on disk; running image digest against the current tag | Sencho | v1.x | T0 | docker | `com.docker.compose.config-hash` label against `docker compose config --hash '*'`; `com.docker.compose.image` label | Differentiator. Same source verification as STK-01. |
| STK-12 | Deploy history and rollback | Host-side append-only history with previous digests and file backups; one-tap rollback | Dockhand deploys tab, Kamal audit and rollback | v1.x | T0 | docker | history file next to the stack or under `~/.local/state/klabautermann/` [design choice] | On the host so every device sees it. |
| STK-13 | Deploy preview | What `up` would create, recreate or remove | Komodo sync diff (partial); r1 gap | v1.x | T0 | docker | `docker compose up --dry-run` where supported [U] plus STK-11 | Differentiator. |
| STK-14 | Compose lint | Duplicate host ports, cross-stack port collisions, hard-coded secrets, socket mounts, privileged, `latest`, missing restart or healthcheck; gutter markers; conservative fixes | Dockhand validate, Cosmos warnings | v1.x | T0 | user | parsed YAML plus `docker compose config` | Never blocks a deploy. |
| STK-15 | Required variables | Block apply while a `${VAR:?}` is unset | Coolify | v1.x | T0 | user | `docker compose config --variables` | |
| STK-16 | Dependency graph | `depends_on` and shared networks | Dockhand | v1.x | C | none | parsed YAML | |
| STK-17 | Create stack | New directory and compose from scratch, a template or a generated service | Dockge, Dockhand | v1.x | T0 | user, docker | SFTP plus exec | |
| STK-18 | Start order across stacks | Boot order and delays between stacks | Unraid start order | Later | T1 | sudo | one systemd unit per stack with `After=` | Within a stack, `depends_on: condition: service_healthy` covers it. |
| STK-19 | Git-backed stacks | Pull the stack's Git repository and redeploy on demand | Dockhand, Komodo, Portainer | Later | T0 | docker | `git pull`, `docker compose up -d` | Pull-and-redeploy button only; polling timers and webhooks fall under NG-03. Warn when the repository is not trusted (Dokploy previews lesson). |
| STK-20 | Migrate stack | Copy files and volumes to another server in the list, then deploy | Cloudron clone and migrate | Later | T0 | docker | SFTP plus VOL-05 or BAK-03 | Uses the Poltergeist transfer engine. |
| STK-21 | Secrets from the vault | Resolve values from the Hauntware vault at deploy and write `.env` with mode 0600 | Kamal secret adapters | Later | T0 | user | vault plus SFTP | Disclose that values land on the host disk. |
| STK-22 | Podman compose | | Podman Desktop | Later | T0 | user | `podman compose` | |
| STK-23 | Per-service and teardown actions | Restart, stop, pull, recreate or scale one service; `down` for the whole stack | lazydocker, Docker Desktop, Docker Manager iOS | v1 | T0 | docker | `docker compose` with `restart`, `stop`, `pull`, `up -d --force-recreate`, `up -d --scale` or `down` over exec | Typed confirmation for `down`; never `-v` by default. Same verification, ownership and detached-run rules as STK-06. |
| STK-24 | Compose completion and validation | Schema-aware completion and inline validation in the compose editor | VS Code Container Tools | v1.x | C | none | Compose specification schema | No compose schema model exists in the repo (c3 §5.4). |
| STK-25 | Health-gated cutover | Zero-downtime switch for proxied HTTP services: start the new container, wait for health, retire the old one | Kamal, Dokku | Later | T0 | docker | scale up, `State.Health`, scale down through the user's existing proxy | Only with a proxy that can swap upstreams; never installs or takes over a proxy (NG-04). r2 §4 places proxy-based zero-downtime in Tier 2. |

### 3.28 Registries (REG)

Pulling with the host's own credentials needs no new secret storage, so it is
v1. Keeping registry credentials in the vault needs a new record kind in
`seance_protocol` (no protocol bump or server change), so it is v1.x.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| REG-01 | Host credentials | Use the server's own `docker login` and credential helpers | Docker CLI | v1 | T0 | docker | `docker pull`, `docker compose pull` over exec | The daemon does not read `~/.docker/config.json`; only the CLI does. |
| REG-02 | Vault credentials | Registry credentials in the E2E vault, sent per request | Portainer, Dockhand | v1.x | T0 | docker | `X-Registry-Auth` header | A sealed sub-record type of the product record kind behind an opt-in (D17, owner decision Q9), never a `secret:` record. The secret stays inside the sealed payload. Never written to the host unless asked. |
| REG-03 | Rate-limit display | Docker Hub pulls remaining | none found | v1.x | C+E | none | `ratelimit-remaining` response header [U behaviour on HEAD] |  |
| REG-04 | Registry browser | Search, tags, manifests | Dockhand, Arcane 2.15 | Later | C+E | none | registry v2 API |  |

### 3.29 Templates and app catalog (TPL)

A one-click catalog is what home-server users expect from panels, but it brings
licensing questions (r2 §6.7) and post-install UX work. The run-to-compose
converter is cheap and lands in v1.x. The catalog is Later and limited to
sources the user adds (Dockhand reads Portainer v2 JSON catalogs, r1 §3.1)
under permissive licences (Apache-2.0, MIT); GPL and unlicensed catalogs are
not fetched, so no legal review is needed (owner decision Q19). Curating or
hosting an app store is a non-goal (NG-19).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| TPL-01 | docker run to compose | Paste a `docker run` command, get a compose service | Dockge | v1.x | C | none | local parser | |
| TPL-02 | Template catalog | Compose plus `x-klabautermann` metadata rendered as a form; "view raw compose" always available | CapRover, Runtipi, CasaOS, Coolify, Umbrel | Later | T0+E | docker | catalog fetched by the device; SFTP plus `docker compose up` | User-added sources only, for example Portainer v2 JSON catalogs as Dockhand reads them (r1 §3.1); no curated or hosted store (NG-19). Only permissively licensed catalogs are fetched (TPL-04). Fetching a catalog discloses the device IP to its host. |
| TPL-03 | Generated secrets | Random passwords and keys written to the host `.env` | Coolify magic variables, CapRover `$$cap_gen_random_hex` | Later | C | none | device RNG | |
| TPL-04 | Third-party catalogs | Permissively licensed catalogs only: CapRover, CasaOS and Coolify (Apache-2.0), Dokploy (MIT), and Portainer v2 JSON catalogs where their licence permits | Dockhand, Yacht | Later | C+E | none | catalog URLs | Owner decision Q19: GPL catalogs (Runtipi, 1Panel) and unlicensed ones (umbrel-apps) are not fetched, so no legal review is needed. |
| TPL-05 | Compatibility checks | Architecture, free ports, disk | Runtipi, Umbrel 2.0 | Later | T0 | user | `uname -m`, `ss -ltn`, `df` | |
| TPL-06 | Post-install card | URL, generated credentials and a health indicator that turns green | Umbrel App Store Standard | Later | T0 | docker | `State.Health` | |
| TPL-07 | Personal templates | Save a stack as a reusable template, synced | Portainer custom templates, Dockhand config sets | Later | C | none | device-local, or a file on the host | Not synced: whole-account pulls and a 1 MiB blob cap (c1 §2.4). |

### 3.30 Backups (BAK)

Scheduled backups are T1 by nature (systemd timer plus restic), and r2 shows
this is where platforms disappoint most: CapRover skips volumes, Dokploy skips
bind mounts, Coolify skips Redis-family databases. A one-shot database dump is
cheap T0 and comes first (v1.x). Restic-based backups with a coverage report and
test restores are Later because they need restic on the host and careful,
honest UX. The owner placed them inside the app, after v1.x and built on T1
(owner decision Q19); until then the one-shot dump (BAK-01) and the rows'
existing tiers apply. Dockhand, the owner's reference, ships restic backups
(r1 §3.1).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| BAK-01 | Database dump | One-shot dump from a database container using its own env credentials; keep on host or download | Coolify, Dokploy | v1.x | T0 | docker | `docker exec <c> pg_dump`, `mysqldump`, `mongodump`, `sqlite3 <db> .backup` | Credentials are read from container env and never displayed. |
| BAK-02 | Existing backup status | Detect restic, borg or kopia timers and show the last success | Cockpit Hangar plugin (partial) | v1.x | T0 | user, sudo | `systemctl list-timers`, `journalctl -u <unit>`, `restic snapshots --json` when repo credentials are available [U] | |
| BAK-03 | Volume and bind-mount backup | restic snapshot of chosen paths, with a stop-for-consistency option | Dockhand restic, Cosmos, Dokploy (named volumes only) | Later | T0 | sudo, docker | `restic backup <paths>` | Inside the app after v1.x (owner decision Q19). Covers bind mounts too (Dokploy gap). Explain the stop trade-off (Cosmos guidance). |
| BAK-04 | Coverage report | Per stack, every mount classified as backed up, excluded or unsupported | none found; Cloudron and TrueNAS honesty | Later | C | none | inspect mounts plus backup configuration | Differentiator. |
| BAK-05 | Scheduled backups and retention | Timer plus restic retention policy explained in words | Cloudron, Cosmos, Dockhand | Later | T1 | sudo | systemd timer and script; `restic forget --keep-daily N ...` | Inside the app after v1.x (owner decision Q19). |
| BAK-06 | Integrity check |  | Cloudron, Dockhand | Later | T0 | sudo | `restic check` | Inside the app after v1.x (owner decision Q19). Scheduled variant is T1. |
| BAK-07 | Verify by test restore | Restore to a scratch directory or a disposable database container and report | Coolify advice, Cloudron dry-run restore | Later | T0 | sudo, docker | `restic restore --target <tmp>`, temporary container | Inside the app after v1.x (owner decision Q19). Differentiator. |
| BAK-08 | Pre-update backup | Automatic dump or snapshot before a safe update | Cloudron (kept 3 weeks) | Later | T0 | docker | BAK-01, BAK-03 | Tied to IMG-08. |
| BAK-09 | Backup targets | Local disk, another server in the list over SFTP, S3-compatible, B2 | Cloudron, Dockhand | Later | T1 | sudo | restic repositories | Inside the app after v1.x (owner decision Q19). The SFTP target reuses the shared server list. |
| BAK-10 | Download and upload backups | Move dumps and archives between host and device by handing off to Poltergeist | Docker Manager iOS | Later | T0 | user | Poltergeist deep link and transfer engine (X-04, X-08) | No transfer code in this app. |

### 3.31 Alerts and notifications (ALR)

An agentless client can only alert while it runs (r1 §5.3, r4 §2.7). In-app
alerts with local notifications are v1 and desktop tray monitoring is v1.x.
Host-side checks with a notifier script (T1) give while-closed alerts without
a daemon (v1.x), and the opt-in Rust companion (T2) follows in M9. A host
cannot report its own death, so host-down detection needs a peer or an external
monitor. Native push needs a publisher-run relay and conflicts with today's
unsigned iOS distribution, so it is Later and uncertain.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| ALR-01 | In-app threshold alerts | Threshold plus duration rules evaluated on live samples | Beszel, Glances colours | v1 | C | none | sampler data | Labelled "only while the app is open". System notifications through `flutter_local_notifications` (BSD-3, owner decision Q13). |
| ALR-02 | Attention badges | Counts on fleet rows and on the app icon where supported | ServerGlance | v1 | C | none | TRI-03 | |
| ALR-03 | Desktop background monitoring | Tray or menu-bar mode keeps polling while the machine is awake, with local notifications | OrbStack menu bar; r5 §5.4 | v1.x | T0 | per collector | the same sampler | Desktop only. Local notifications through `flutter_local_notifications` (BSD-3, owner decision Q13; none in the repo today, c3 §5.4). |
| ALR-04 | Host-side checks | Timer script for disk, inodes, failed units, dead or restart-looping containers, cert expiry, pending security updates, reboot required | Coolify notification events, Webmin monitors | v1.x | T1 | user, sudo, docker (per check) | systemd timer (cron fallback), POSIX script, JSON state file | Listed in the footprint manifest (SAF-14). |
| ALR-05 | Notifier script | ntfy, Gotify, Telegram, Discord, Slack, Pushover, email, generic webhook; optional Apprise | Coolify, Dokploy, Dockhand | v1.x | T1+E | user | `curl` from the host | Channel secrets live on the host and the UI says so. ntfy and Gotify have their own mobile apps, which avoids APNs. |
| ALR-06 | Channel and event matrix | Per channel, per event toggles; failures on and successes off by default; test send | Coolify | v1.x | C | none | configuration written to the host | |
| ALR-07 | Maintenance windows | Silence per server or group, with time zone | Gatus, Zabbix | v1.x | T1 | none | configuration written to the host; synced as own kind | |
| ALR-08 | Peer watcher | One server in the list checks the reachability of others on a timer | Coolify "unreachable after two consecutive checks" | v1.x | T1 | user | timer on the peer with `nc -z` or `curl` | The peer needs network reach only, no credentials for targets. |
| ALR-09 | Alert snapshot | Capture an incident snapshot when the user opens an alert | xyOps | v1.x | T0 | user+ | TRI-05 | |
| ALR-10 | External monitor integration | Create or read Uptime Kuma or Healthchecks checks | Uptime Kuma, Healthchecks | Later | C+E | none | their HTTP APIs | Alerts then leave the suite. |
| ALR-11 | Agent alerts through the inbox | Optional agent evaluates rules on the host and deposits sealed alerts and heartbeats through the Séance inbox producer pattern | r5 §5.3 recommendation | Later | T2 | docker (container rules) | sync server inbox with a new sealed alert type | Rust companion in M9 (owner decision Q8). Rules then exist in Dart and in Rust, so parity tests over a shared fixture corpus run in CI. Trust model unchanged: the agent holds no SSH keys. Inbox limits: 100 pending items and 30 deposits per minute per app, at most 50 apps per account, so one app per host caps agent fleets at 50 hosts (c1 §2.4). |
| ALR-12 | Heartbeat dead-man | Sync server flags "agent silent for N minutes" without decrypting anything | r5 §5.3 | Later | T2 | none | inbox deposit timestamps | Not scheduled by M9: needs a sync server change [design decision]. |
| ALR-13 | Native push | APNs and FCM through a publisher relay with content-free payloads | ServerBox relay, ntfy upstream relay | Later | T2+E | none | relay service | Not scheduled by M9: conflicts with the unsigned IPA; the push relay remains an open decision. |
| ALR-14 | Docker event alerts | Real-time die, oom, health_status | Dozzle alerts | Later | T2 | docker | `GET /events` stream in the agent | Companion in M9 (owner decision Q8). ALR-04 approximates by polling. |
| ALR-15 | Log pattern alerts | | Dozzle | Later | T2 | journal, docker | agent | Companion in M9 (owner decision Q8). |
| ALR-16 | Hysteresis and flap suppression | Separate raise and clear thresholds, minimum duration and flap damping | Zabbix, Checkmk | v1.x | C | none | rule configuration | Applies to ALR-01 and to host-side checks (ALR-04). |

### 3.32 History and trends (HIS)

Session history is v1 and lives only on the device. Reading the host's
existing recorders (sysstat, exporters) and a T1 ring file give longer history
without a daemon (v1.x). Fine-grained history needs the T2 companion (M9).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| HIS-01 | Session history | Charts since connect, rolled up in a local cache | Meows, Beszel rollup tiers | v1 | C | none | device-local cache | Never synced (c1 §2.4). |
| HIS-02 | sysstat history | Read existing `sar` data | Cockpit (via PCP), r3 §6.5 | v1.x | T0 | user | `sadf -j` over `/var/log/sysstat` or `/var/log/sa` | 10-minute samples by default. |
| HIS-03 | Enable sysstat | When sysstat is missing, an "Enable sysstat" action shows the exact commands (package install plus enabling its timer) and runs them only after explicit confirmation in admin mode | Cockpit "enable PCP metrics collector" | v1.x | T0 | sudo | `apt-get install sysstat` or equivalent, then `systemctl enable --now` on the sysstat unit or timer [U: names per distro] | Owner decision Q6: consistent with "nothing installed without your consent". |
| HIS-04 | Existing exporters | node_exporter, Netdata, Glances as data sources | r3 §3.9, §3.13 | v1.x | T0 | user | `curl -s localhost:9100/metrics`, Netdata local API, `glances --stdout-json` | Read over SSH; opens no ports. |
| HIS-05 | Host ring file | Coarse 1-minute samples appended to a capped file by a timer; read on connect | r2 Tier 1 | v1.x | T1 | user | timer plus script | Fills gaps without a daemon. |
| HIS-06 | Forecasts | Disk full and memory growth trends | Netdata, Prometheus | v1.x | C | none | HIS data | |
| HIS-07 | PCP archives | | Cockpit | Later | T0 | user | `pmrep`, `pmlogdump` [U usage] | |
| HIS-08 | Agent history | Fine-grained history with rollups | ServerBox Monitor, Beszel | Later | T2 | user | agent ring buffer | Companion in M9 (owner decision Q8). |
| HIS-09 | Compare and overlay | Servers or periods side by side | Grafana | Later | C | none | - | |
| HIS-10 | Export CSV | | Glances exporters | Later | C | none | - | |

### 3.33 Automation, runbooks and snippets (AUT)

Running existing Séance snippets with preview and danger lint is v1 because
the record kind, linter and placeholder fill already exist. Fan-out and custom
probes are v1.x. Multi-step runbooks are Later.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| AUT-01 | Snippets | Run Séance snippets (with placeholders) on a server, with command preview and danger lint | Séance snippets, Prompt Clips, ServerBox | v1 | T0 | per command | Séance `Snippet` records, `DangerLinter` | Shared synced kind, no new record type. |
| AUT-02 | Copy as commands | Every action exposes the exact commands or API calls it runs | Kamal "just basic Docker commands", Cockpit | v1 | C | none | - | Teaches and enables scripting. |
| AUT-03 | Custom probes | User commands with timeout and output cap, shown as cards or fleet columns | ServerBox custom commands, node_exporter textfile | v1.x | T0 | user | `sh -c` with `timeout` and `ulimit -f` | |
| AUT-04 | Run on many | Fan a command out to a group with per-host results, concurrency cap and stop on error | Webmin cluster-shell, NeoServer batch scripts | v1.x | T0 | per command | parallel exec | Typed confirmation for mutating commands. |
| AUT-05 | Runbooks | Ordered steps with checks, dry run, stop on failure and a run log | xyOps workflows, Komodo procedures | Later | T0 | per step | exec | |
| AUT-06 | Scheduled runbooks | | 1Panel, Dokploy schedule jobs | Later | T1 | per step | timers | |
| AUT-07 | Remediation rules | "If X fails, restart" using host-native mechanisms | Monit, Webmin monitors | Later | T1 | sudo | systemd `Restart=` and `OnFailure=` | Prefer SVC-12. |

### 3.34 Web and reverse proxy (WEB)

Not in the owner's list, but r2 and r3 show most self-hosters run a reverse
proxy in front of their containers. Detection and the route map are read-only
and v1.x; config changes and access-log analytics are Later.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| WEB-01 | Proxy detection | Traefik, Caddy, nginx, Apache, HAProxy as host service or container | r2 §3.4 | v1.x | T0 | user, docker | process, unit and container names | |
| WEB-02 | Route map | Domain to proxy to service or container | Dockpeek, Coolify | v1.x | T0 | user, docker | Traefik and Caddy labels; `nginx -T` (sudo) for `server_name` and `proxy_pass` | Differentiator. |
| WEB-03 | HTTP checks | Status, latency and keyword from the device and from the server | Uptime Kuma, Gatus | v1.x | T0 | user | device HTTP client; `curl -w` on the host | |
| WEB-04 | Validate and safe reload | Test proxy config, reload, revert on failure | Coolify proxy validation | Later | T0 | sudo | `nginx -t`, `caddy validate`, `apachectl configtest` | "An invalid proxy configuration can make every application unreachable" (Coolify docs). |
| WEB-05 | Access log analytics | Top paths, status codes, client IPs, bandwidth | GoAccess, 1Panel | Later | T0 | user+ | `goaccess -o json` when installed, else a Dart parser over `tail` | |

### 3.35 Cross-app integration (X)

Shared marks, themes built through `ghost_theme` and pulled host-key pins
are MVP. Séance #56 is fixed before the MVP preview (owner decision Q12), so
first-seen pins are published from v1, when catalog writes arrive; the MVP
pushes nothing (D14). The terminal and file hand-offs depend on URL schemes
(Séance registers none today, c1 §4.7) and the editor hand-off on the
remote-edit extraction, so they are v1, including "open terminal in this
directory" (owner decision Q18). The app does not embed a host terminal:
that stays in Séance (r4 §4.3).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| X-01 | Shared marks and theme | Identical badges, colours, icons and light and dark themes across the suite's apps, with theme editing and presets | ghost_marks, Séance and Poltergeist appearance settings | MVP | C | none | `ghost_marks`, `ghost_theme`, `ghost_ui` | Owner decision Q5: the MVP builds its themes through `ghost_theme` (F4b, extracted before the MVP with Séance switched, c3 §4), including theme editing and presets. Pasting a theme from a sibling app is v1. |
| X-02 | Shared host keys | Pull TOFU pins through `hostkey:` records under Poltergeist's quarantine model; publish first-seen pins from v1, when catalog writes arrive | Poltergeist quarantine model | MVP | C | none | catalog package | Owner decision Q12: Séance #56 (pulled pins applied without a conflict check, so a pushed pin silently replaced trust on Séance devices, c1 §2.3) is fixed before the MVP preview by Séance adopting the quarantine handler (F3). The pull-only MVP publishes nothing (D14); publication also needs every device to run a Séance release with the fix (an extended FL-22 assertion). The pin locator uses `ServerConfig.host` verbatim. Pins are keyed by `host:port` only, so identical addresses behind different jump routes collide (c2 R8): a known limitation until a suite-wide task after v1. |
| X-03 | Open terminal | Hand the selected server to Séance | Séance; Poltergeist `seance://connect` precedent | v1 | C | none | `seance://` link | Séance link intake lands in v1 (F5d, owner decision Q18): it opens a known server and asks before connecting; a link never runs a command and only picks a server and a starting folder. Séance registers no URL scheme today (c1 §4.7). No embedded host terminal (r4 §4.3). |
| X-04 | Open files | Open a stack directory, volume mountpoint or log file in Poltergeist | Poltergeist | v1 | C | none | `poltergeist://browse` deep link | Poltergeist validates this intake (`deep_links.dart`) and declares the scheme on macOS, Linux and Windows (03, D12); Android and iOS registration lands in v1 (F5d, owner decision Q18). |
| X-05 | Edit in the editor | Edit compose, `.env`, unit overrides, crontab and proxy config with `planchette_editor` and remote conflict detection | Planchette, Poltergeist checkout | v1 | T0 | user, sudo | `planchette_editor` plus SFTP | Remote-edit logic exists twice today (c3 §5.4); extract, do not copy. |
| X-06 | Open in this app | "Open dashboard" from server menus in Séance and Poltergeist | none | v1.x | C | none | URL scheme in this app | Requires changes in both apps. |
| X-07 | Metrics strip in Séance | CPU, memory and disk above a terminal session | Termix | Later | T0 | user | shared sampler package | Séance-side work. |
| X-08 | Transfers through Poltergeist | Volume, backup and image moves between servers | Poltergeist | Later | T0 | user | Poltergeist core | |
| X-09 | Inbox items | Agent-produced alerts and proposals appear in the Séance inbox | Séance inbox | Later | T2 | none | inbox | Needs a design decision beyond the M9 companion: the planned Séance inbox change makes Séance skip companion items (03, section 9.4). |
| X-10 | Open terminal in this directory | Hand a stack folder or log directory to Séance | r2 §5 item 13 | v1 | C | none | `seance://` link with a directory | Owner decision Q18: moved to v1 with Séance link intake (F5d, c1 §4.7); the starting-folder (`cwd`) parameter is accepted, never a command parameter. |

### 3.36 Assistant (AI)

Reuses the `seance_core` LLM pieces. The Séance invariant "no execution tools
in chat" stays: the model explains and proposes, the user reviews and runs
(c2 §6). New Docker, systemd, cron and firewall danger rules are MVP because
command previews and protected targets use them. The chat features need
`ChatController` parameterized upstream, so they are v1.x. Every model call
sends data to the user's chosen provider (+E).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| AI-01 | Danger rules | Lint rules for `system prune -a --volumes`, `volume rm`, `compose down -v`, stopping or masking sshd, `crontab -r`, `ufw reset`, `nft flush ruleset`, `userdel` | c2 §6 | MVP | C | none | `DangerLinter` (upstream in `seance_core`) | Upstream in `seance_core` (c2 §6); Séance benefits too. Feeds SAF-04 previews and SAF-22. |
| AI-02 | Explain log excerpt | Selected lines explained; excerpt redacted and wrapped as untrusted context | Docker Desktop Gordon, Pulse | v1.x | C+E | none | `LlmProvider.streamChat`, `SecretRedactor` | Bring-your-own provider key. |
| AI-03 | Suggest a fix | Staged command with danger rating; never run automatically | Séance reviewed commands, ServerBox agent review | v1.x | C+E | none | `generateCommand`, `CommandSuggestion.effectiveDanger` |  |
| AI-04 | Diagnostic attachments | Fixed, read-only, app-defined diagnostics whose output the user chooses to attach | c2 §6 middle ground | v1.x | T0+E | user+ | app-defined commands | The model never chooses commands. |
| AI-05 | Explain a container or stack | Plain-language summary of inspect and compose | Docker Desktop | v1.x | C+E | none | redacted inspect | Consent before env values leave the device. |
| AI-06 | Compose assistant | Draft or explain compose; output opens in the editor with a diff | Arcane compose generator | Later | C+E | none | - |  |
| AI-07 | Audit summaries | Prioritized summary of doctor and Lynis findings | Pulse AI patrol | Later | C+E | none | - |  |
| AI-08 | Natural-language log filter | Turn a question into journal filters shown for review | none found | Later | C+E | none | - |  |
| AI-09 | Reuse Séance assistant settings | Read Séance's synced `assistant:settings` record for provider configuration | c1 §1.1 | v1.x | C | none | `assistant:settings` record | Read-only. Provider keys stay inside the sealed payload behind Séance's opt-in. |

### 3.37 Settings, privilege and safety (SAF)

Safety features are MVP whenever MVP has a mutation they guard. Audit logging,
edit safety and sudo password storage arrive with the features that need them.
RBAC is impossible to enforce from a client (docker group equals root), so
these are guardrails and transparency, not security boundaries, and the UI says
so.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| SAF-01 | Observe-only default | New servers start read-only until management is enabled | r2 §6.1, k9s `--readonly` | MVP | C | none | per-server setting | |
| SAF-02 | Admin mode | Explicit per-server elevation with a visible indicator and expiry | Cockpit administrative access | MVP | T0 | sudo | `sudo -n true`; else `sudo -S -p '' -v && sudo -n -- <cmd>` in one shell with the password on stdin (sudo and sudo-rs); doas and run0 only when they need no password | The password is held in memory for the admin window only and cleared on expiry, on app background (mobile) and on server switch; never in argv or env. Do not rely on `-v` in one channel and `-n` in another: without a terminal sudo may key its cached credential by parent PID [U: sudoers `timestamp_type`]. doas and run0 password prompts need a PTY spike; run0 cannot read a password from a pipe [U]. Recognize sudo-rs messages and "you must have a tty". |
| SAF-03 | Root badges | Mark actions that need root | Cockpit, Webmin | MVP | C | none | - | |
| SAF-04 | Command preview | Show the exact command or API call before any mutation | k9s plugin confirm, Kamal, Cockpit | MVP | C | none | - | Danger rules from AI-01 annotate the preview. |
| SAF-05 | Tiered confirmations | None for refresh; a dialog naming the target for stop and kill; typed name for irreversible or fleet-wide actions | k9s Tab-then-Enter, ServerGlance | MVP | C | none | - | Confirmation dialogs are fully keyboard-operable from the MVP. |
| SAF-06 | Read-only mode | Per server and global; hides every mutation | k9s | MVP | C | none | - | Safe for screen sharing. |
| SAF-07 | Secret masking | Env, labels, `.env`, inspect values, process arguments (`-p<secret>`, `--password=`) and URL credentials (`scheme://user:pass@`) masked with reveal on tap; every share or export path redacts by default | r5 §6 | MVP | C | none | key regex such as PASS, SECRET, TOKEN, KEY, CREDENTIAL, DSN | Exports offer an explicit include-secrets toggle (LOG-10, CTX-06, TRI-05, CN-18). Copied secrets are marked sensitive on the clipboard where supported [U: Flutter plugin support]. |
| SAF-08 | Root-equivalence notice | Explain at onboarding that rootful Docker socket access and broad NOPASSWD rules equal root, that rootless engines are user-equivalent, and that Docker behind password-only sudo needs the docker group, a rootless socket or NOPASSWD | Docker documentation | MVP | C | none | - | Do not suggest adding users to the docker group casually. `sudo -S` cannot feed a password to `docker system dial-stdio`, whose stdin is the API stream (c2 R5). |
| SAF-09 | Endpoint confirmation | Connect and poll only endpoints confirmed on this device; prompt when a synced host or port changes | c1 §4.1 (per-device endpoint pins) | MVP | C | none | device-local pins | Any device can rewrite a server's host through LWW. |
| SAF-10 | Safe interpolation | One POSIX quoting function for every interpolated name, path and user; unit-name grammar validation | Cockpit CVE-2026-4631 lesson | MVP | C | none | - | A safety property, not a screen. |
| SAF-11 | Local audit log | Every mutation recorded with device, server, target, command and result | Pulse Pro, Dockhand Enterprise (paid there) | v1 | C | none | device-local store | Never synced (D28, owner decision Q10): Séance pulls whole accounts and records are never garbage-collected (c1). |
| SAF-12 | Edit safety | Backup, diff, validation and atomic write for every config file | r3 §6.10 | v1 | T0 | per file | SFTP for files the login user owns; otherwise a privileged exec path: `sudo -n cat`, temp file in the same directory via `sudo -n tee`, `chown --reference` and `chmod --reference`, `restorecon` when SELinux is enforcing, content-hash compare before `sudo -n mv`; validators `visudo -c`, `systemd-analyze verify`, `nginx -t`, cron parser, `docker compose config -q` | SFTP cannot elevate (c2 §2.4). Atomic rename creates a new inode, so owner, mode, ACLs and the SELinux label are restored [U relabel details]. Spike: an elevated SFTP channel through `sudo -n` and `sftp-server` over exec [U]. |
| SAF-13 | Host-side audit trail | One syslog line per mutation | Kamal audit on servers | v1 | T0 | user | `logger -t klabautermann '<action>'` | Corroborated by Docker events and sudo logs. |
| SAF-14 | Footprint manifest | List, diff and remove every T1 file the app installed, in one action | r2 Tier 1 | v1 | T0 | per file | manifest under `/etc/klabautermann/` or `~/.config/klabautermann/` | Prerequisite for every T1 feature. Tracks app state files on the host (backups, deploy history, locks) from v1. Ownership, mode and checksum rules are in the T1 definition. |
| SAF-15 | Multi-device lock | Lock file with owner, device and TTL around deploys and edits | Kamal lock | v1.x | T0 | user | lock file on the host | Five platforms can act on one host at once. |
| SAF-16 | Saved sudo password | Per-server opt-in "remember sudo password" in the vault; a second opt-in syncs it to the user's other devices | Cockpit cached login password | v1.x | C | none | vault behind the device keystore; synced as the sealed sub-record `klabautermann:sudo:<serverConfigId>` | Owner decision Q11. Syncing also needs the device's suite-wide "sync passwords" switch (the existing credential-sync opt-in, SYN-02). It travels as a sub-record of the product record kind (D17), never as a Séance `secret:` record, so Séance and Poltergeist never apply or store it (they skip the unknown kind or prefix, c1 §2.4); removal is a sealed `removed` record and unsealed tombstones are ignored. The switch subtitle and the threat model disclose that anyone holding the account key, and every device on the account, obtains a password that grants root on that server. Admin mode still expires; a remembered password only skips the prompt. |
| SAF-17 | Sudoers drop-in generator | Narrow NOPASSWD rules for read-only collectors, validated before install | r5 §4 | v1.x | T0 | sudo | `visudo -cf <file>` | Prefer group membership (`systemd-journal`) for journal reads. Pin exact argument vectors; never grant pager-capable binaries (`journalctl`, `systemctl`) without `--no-pager` pinned and `env_reset` (known sudo escapes, GTFOBins [U]). Validate with `visudo -cf`. Wildcard rules for `docker` or `systemctl` equal root (r5 §4). |
| SAF-18 | Privacy mode | Hide host names and IPs in the UI for screenshots and demos | ServerGlance | v1.x | C | none | - | |
| SAF-19 | Polling budget | Cadence presets, cellular saver, per-server caps | ServerCat configurable refresh | v1 | C | none | settings | |
| SAF-20 | App lock | Biometric or OS authentication on open | Docker Manager iOS Face ID, NeoServer | v1 | C | none | OS APIs | Séance has an app-local app lock (`seance/app/seance_app/lib/services/app_lock.dart`); extract it to a shared package rather than copy it. |
| SAF-21 | Restricted monitoring key | Key limited by a forced command, for T2 or watcher use | Checkmk forced-command pattern | Later | T0 | sudo | authorized_keys `command=`, `restrict`, `from=` | `restrict` also blocks streamlocal, so no Docker API with that key. |
| SAF-22 | Protected targets | Built-in list (sshd and ssh.socket, network managers, firewall units, tailscaled, wg-quick@*, docker, containerd and podman units, PID 1, the sampler's own PIDs), connection-path detection and user-marked targets; typed confirmation with an impact line such as "drops your session" or "stops 23 running containers" | r2 §6.1, c2 §6 danger rules | MVP | T0 | user | `$SSH_CONNECTION`, the sshd parent of the session, containers publishing the SSH or VPN port, AI-01 rules | Guards SVC-03, PRC-02, JOB-08, CTR-02, CTR-05, CTR-06, STK-03 and STK-06. Users mark extra targets such as a self-hosted Séance sync server container or the proxy on a jump route. |
| SAF-23 | Detached operations | State-changing operations that can exceed a few seconds run as a transient unit on the host, survive app suspension and are re-attached after reconnect; per-server list of running operations | r5 §5.4, r4 §2.7 (mobile limits) | MVP | T0 | per operation | `systemd-run --unit=klabautermann-op-<id> --collect` (or `--user`), followed with `journalctl -u`; `setsid nohup ... > <log>` fallback without systemd | A transient unit is not an installed file. Used by STK-06 in the MVP and later by PKG-07, IMG-08 (whose rollback logic must run host-side) and STK-23. `systemd-run --user` needs a user manager (session or linger) [U]. |

### 3.38 Sync and data (SYN)

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| SYN-01 | Server list sync | Existing `serverConfig` records with Séance-identical write semantics | Séance, Poltergeist | MVP | C | none | shared catalog package | The MVP pulls only and never pushes (D14, owner decision Q4); writes start in v1 with FL-03 and SYN-04. |
| SYN-02 | Credential reuse | Honour the device `syncSecrets` switch and per-server `syncSecret`; otherwise prompt and store locally under the same `secretRef` | Poltergeist | MVP | C | none | vault | |
| SYN-03 | Never-sync rule | Metrics, logs, inspect output, `compose config` output and snapshots never enter sync | c1 §2.4, r5 §6 | MVP | C | none | - | Server caps: 1 MiB per blob, 1000 records and 8 MiB per push. |
| SYN-04 | Own record kinds | Per-server preferences and tags, dashboard layouts, saved queries, alert rules, maintenance windows | c1 §2.4 | v1 | C | none | one product `RecordKind` with typed sub-records, ids `klabautermann:<type>:<id>` (D17, owner decision Q9) | No new `ServerConfig` fields; no bare ids; per-type count and byte budgets and at most 1 MiB for the prefix. Per-server records of excluded servers are skipped and retracted; payload id must equal envelope id on apply. Templates and audit logs stay out of sync (c1 §2.4). |
| SYN-05 | Sealed removal for rules | Safety-relevant records use a sealed `removed` flag, not unsealed tombstones | inbox apps precedent | v1.x | C | none | - | The server can forge unsealed deletes. |
| SYN-06 | Settings export and import | | none | Later | C | none | file | |
| SYN-07 | No account deletion in shared mode | The app never exposes `DELETE /v1/account`, which deletes every app's data | c1 §4.1 | MVP | C | none | - | Account deletion stays in Séance. |
| SYN-08 | Device data policy | Persist only metric rollups and settings; logs, inspect output and snapshots touch disk only by explicit export (share sheet or encrypted file); purge per-server caches and stop polling on remote delete, exclusion or endpoint change | c1 §4.1, §2.4 | MVP | C | none | device-local store | Ties to SAF-09 and SAF-20. |
| SYN-09 | Account size view | Record counts and bytes by id prefix after a pull | c1 §2.4 | v1 | C | none | pulled records | Séance pulls the whole account every 5 minutes, and records are never garbage-collected. |

### 3.39 Platform specifics (PLT)

One Flutter codebase serves both a keyboard-first desktop and a touch-first
phone; both layouts are MVP. Anything that must run while the app is closed
(widgets with fresh data, push) is Later.

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| PLT-01 | Desktop layout | Fleet rail, server dashboard, later a bottom dock | Lens, Docker Desktop | MVP | C | none | `ghost_desktop`, `ghost_ui` | Dock in v1 (OV-10). |
| PLT-02 | Phone layout | Master-detail stack, bottom sheets for logs and actions, pull to refresh | ServerBox | MVP | C | none | - | |
| PLT-03 | Touch safety | Swipe only for non-destructive actions; long-press menus; large targets | r4 §2.6 | MVP | C | none | - | |
| PLT-04 | iOS background disclosure | No background polling; sessions suspended and reconnected on return; said plainly in the UI | r4 §2.7 | MVP | C | none | - | |
| PLT-05 | Tablet split view | | none | v1 | C | none | - | |
| PLT-06 | Keyboard model | `/` filter, single-key row actions, `?` help, Cmd or Ctrl plus 1 to 9 for tabs | k9s, lazydocker, ServerBox macOS | v1 | C | none | - | |
| PLT-07 | Command palette | Jump to a server, container, unit or action | Dockhand Ctrl+K, k9s `:` | v1 | C | none | - | The repo already has two palettes (c3 §5.4); extract rather than add a third. |
| PLT-08 | Share sheet | Export logs, snapshots and status cards | none | v1 | C | none | - | |
| PLT-09 | Flatpak permissions | Product-specific `finish-args`, not copied from Poltergeist | c4 §5.7 | v1 | C | none | - | |
| PLT-10 | Tray and menu bar | Fleet status and quick actions | OrbStack, ServerBox | v1.x | T0 | user | - | Desktop only; pairs with ALR-03. |
| PLT-11 | Android foreground service | Opt-in watch mode: a time-limited foreground service keeps sessions alive; off by default, started per session, stops automatically and says so | Séance keepalive | v1.x | C | none | native channel | Owner decision Q14. `dataSync` is limited to 6 h per 24 h on Android 15+. |
| PLT-12 | Home-screen widgets | Last-known values with timestamps; refreshed when the app runs | ServerCat widgets, ServerBox (agent-backed) | Later | C | none | WidgetKit, Android AppWidget | iOS budget is roughly 40 to 70 reloads per day; Android minimum period 30 min. Fresh data needs T2. Whether widget extensions survive re-signing of the unsigned IPA is [U]. |
| PLT-13 | Live Activities and ongoing notifications | Bounded operations: compose pull and up, package upgrade, reboot-and-wait | ServerBox, Secure ShellFish | Later | C | none | ActivityKit, Android ongoing notification | iOS limit about 8 h; push updates need a signed build [U]. Whether Live Activity extensions survive re-signing is [U]. |
| PLT-14 | Watch app | | ServerBox | Non-goal | - | - | - | Low value relative to effort (r4). |
| PLT-15 | Android background reachability | TCP banner probe every 15 minutes or more with no credentials; local notification on change | r4 §2.7 | v1.x | C | none | `TcpBannerProber` in a WorkManager job | Reachability only. Local notifications through `flutter_local_notifications` (owner decision Q13; none in the repo today, c3 §5.4). Subject to Doze. |

### 3.40 Accessibility and localization (A11Y)

Accessibility basics and the localization pipeline are MVP because retrofitting
them later is expensive (Poltergeist's contract test shows the cost of the
string-bag migration, c3 §4.5).

| ID | Feature | Description | Inspiration | Rel | Exec | Priv | Data source | Notes |
|---|---|---|---|---|---|---|---|---|
| A11Y-01 | Never colour alone | Every status colour paired with an icon and text | Glances four-level states | MVP | C | none | - | |
| A11Y-02 | Chart semantics | Screen-reader summary of each series: current, min, max, trend | c3 D20 | MVP | C | none | chart package | |
| A11Y-03 | Table semantics | Announced column names and row actions | c3 D20 | MVP | C | none | - | |
| A11Y-04 | Safe palettes | Colour-blind-safe severity and series palettes, contrast-checked | `contrastRatio` in shared UI | MVP | C | none | - | |
| A11Y-05 | Localization pipeline | ARB and gen-l10n with a localization contract test from day one | Poltergeist | MVP | C | none | - | English first. |
| A11Y-06 | Server units | IEC binary units for server figures, locale number formats, a rate formatter | c3 §5.4 | MVP | C | none | new formatter | `ghostFormatFileSize` uses decimal units on macOS and Linux. |
| A11Y-07 | Time display | Toggle server time or device time; relative times | ServerBox | v1 | C | none | - | |
| A11Y-08 | Locale-independent parsing | Every server command runs with `LC_ALL=C.UTF-8` (or `C` when unavailable) and `TZ=UTC`; the UI locale is separate | ServerBox | MVP | T0 | user | - | Plain `C` escapes or replaces non-ASCII in paths, unit descriptions and process names in some tools [U per tool]. |
| A11Y-09 | Text scaling | OS text scale up to 200% without truncating key values | none | v1 | C | none | - | |
| A11Y-10 | Keyboard reachability | Every action reachable by keyboard with visible focus | k9s | v1 | C | none | - | |
| A11Y-11 | Reduced motion | No animated charts when the OS asks | none | MVP | C | none | - | The MVP ships animated sparklines (OV-03). |
| A11Y-12 | Log readability | Font size 10 to 18 px, wrap toggle, line-by-line navigation for screen readers | Dockhand log font sizes | v1 | C | none | - | |
| A11Y-13 | More languages | | ServerBox (16 languages) | v1.x | C | none | - | |
| A11Y-14 | Right-to-left layout | | none | v1.x | C | none | - | |
| A11Y-15 | Live update announcements | Screen readers hear state and threshold-band changes only, configurable; values refreshing every 1 to 5 s are not live regions | none found | MVP | C | none | - | Chart summaries (A11Y-02) stay available on demand. |

### 3.41 Non-goals (NG)

Cross-cutting non-goals. Rows moved out of scope inside an area keep their ID
and carry the Non-goal tier there: Windows server hosts (CN-21), the Apple
Watch app (PLT-14), the status share card (FL-19), public IP and reverse DNS
(NET-15), per-process bandwidth (NET-16), quotas (DSK-16) and the
picture-in-picture tail (LOG-21).

| ID | Non-goal | Why | Who does it instead |
|---|---|---|---|
| NG-01 | Website and vhost hosting, PHP runtimes, mail servers, DNS servers | Hosting-panel product, host takeover | 1Panel, HestiaCP, CloudPanel, aaPanel |
| NG-02 | Database administration GUI beyond dumps | Different product | Adminer, pgAdmin |
| NG-03 | PaaS features: git-push builds, buildpacks, PR previews, webhook or polling redeploys | Needs a resident control plane | Coolify, Dokploy, Dokku |
| NG-04 | Host takeover: owning ports 80/443, installing a proxy, initializing Swarm, restarting dockerd implicitly | Violates the observe-first rule (r2 §6.1) | Coolify, CapRover, Easypanel |
| NG-05 | Kubernetes management | Mature dedicated tools | k9s, Lens, Freelens |
| NG-06 | VM and system-container management (Proxmox, libvirt, Incus, LXD) | Scope creep; ServerBox crashes coincide with such additions (r4 §4.3) | Proxmox UI, Cockpit Machines, Incus UI |
| NG-07 | Swarm orchestration beyond read-only | Low demand, high complexity | Portainer |
| NG-08 | Teams, RBAC, SSO | Access is the SSH account; a client cannot enforce RBAC over a root-equivalent socket | Portainer BE, Dockhand Enterprise |
| NG-09 | Status pages and badges | Needs a public server | Uptime Kuma, Gatus |
| NG-10 | Log aggregation and forwarding pipelines | Needs resident infrastructure | Loki, Vector |
| NG-11 | WAF, VPN servers, lazy-start proxies, disk pooling and NAS shares | Out of scope | 1Panel, Cosmos, Unraid |
| NG-12 | Cloud server provisioning | Out of scope for v1; revisit Later at most | Coolify |
| NG-13 | Malware scanning | Low value over SSH | 1Panel ClamAV toolbox |
| NG-14 | RDP and VNC | Remote desktop is a different product | ServerBox, Termix |
| NG-15 | Map or globe view | Privacy-sensitive, low value | ServerBox |
| NG-16 | Telemetry | Suite stance | (Termix enables it by default) |
| NG-17 | Any listening port or web panel on the host in T0 and T1 | Attack surface; core selling point | Dockge, Dockhand, 1Panel |
| NG-18 | MCP server (initially) | Expands attack surface; revisit after v1 | Glances, Arcane, Dozzle, Umbrel |
| NG-19 | Curating or hosting an app store | Licensing burden (r2 §6.7) and panel territory (r3 §5.3); user-added template sources (TPL-02, TPL-04) stay in scope | CapRover, Runtipi, Umbrel |
| NG-20 | Network interface configuration (netplan, NetworkManager, ifupdown) | A mistake locks the user out of the host | Cockpit, Webmin |
| NG-21 | Storage mutations: partition, format, LVM resize, RAID rebuild, ZFS create or destroy | Data-loss risk; storage views stay read-only (DSK-06, DSK-11, DSK-12) | Cockpit Storage, TrueNAS |
| NG-22 | containerd, nerdctl and k3s containers outside Docker and Podman | Separate runtimes and APIs; the UI states that such containers are not shown | nerdctl, k9s |

---

## 4. Table stakes

Users will compare the app against ServerBox and ServerCat on the host side and
against Dockhand, Portainer and Dockge on the Docker side (r1 §5.2, r3 §5.1,
r4 §0). Missing any of these at v1 reads as unfinished:

- Shared server list with groups, search and reachability, plus in-app editing
  (FL-01, FL-03 to FL-06).
- Live CPU (total and per core), load, memory and swap, disk usage with
  inodes, disk I/O, network throughput, uptime, OS and kernel (OV-01, CPU-01
  to CPU-03, MEM-01, MEM-02, DSK-01 to DSK-03, NET-01).
- Process list with sort, search and kill (PRC-01, PRC-02).
- systemd services with failed units, start, stop, restart, enable, disable
  and per-unit logs (SVC-01 to SVC-05).
- Journal viewer with unit, priority, boot and time filters, follow and
  kernel log, plus log files under `/var/log` (LOG-01 to LOG-03, LOG-08,
  LOG-09, LOG-22).
- Cron and timers with next-run times, safe edits and run now (JOB-01 to
  JOB-03, JOB-06 to JOB-08, JOB-19).
- SMART summary, temperatures, GPU where present (HW-01, HW-03, HW-04).
- Pending updates and reboot required (PKG-01, PKG-03).
- Containers with lifecycle, bulk actions, inspect, health, followed logs,
  exec shell and live CPU and memory (CTR-01 to CTR-07, CTX-01, CTX-07,
  CST-01).
- Images with pull, remove, prune and an unused flag; update-available
  indicator (IMG-01 to IMG-06).
- Volume and network list, create and remove (VOL-01, VOL-02, DNW-01,
  DNW-02).
- Compose stacks: list, edit, up, down, pull and redeploy with streamed output
  (STK-01 to STK-07, STK-23).
- Privilege elevation that works with sudo and sudo-rs passwords, NOPASSWD,
  and passwordless doas and run0; confirmations for destructive actions; dark
  mode (SAF-02, SAF-05, X-01).
- Phone and desktop layouts, biometric lock, shareable logs (PLT-01, PLT-02,
  SAF-20, LOG-10).

## 5. Differentiators

What no surveyed tool does well, and this app can:

1. **Native, agentless, zero-port Docker plus host management over SSH with
   full Engine API fidelity.** No mainstream Docker manager speaks SSH; Dockhand
   documents an external `ssh -L` tunnel as the workaround. dartssh2's
   `forwardLocalUnix` gives streaming logs, stats, events and exec without
   installing anything (r1 §1, r5 §1). Cockpit deprecated its own multi-host
   mode for lack of isolation; a native client isolates hosts by construction.
2. **One E2E-encrypted server list shared with a terminal and a file app**,
   self-hostable and open source (r4 §4.1).
3. **Unified scheduled-jobs center**: user and system crontabs, cron
   directories, systemd timers and anacron in one list with schedules in words,
   next runs, last results, safe edits and dead-man pings (JOB-01 to JOB-13).
4. **Unified logs**: journald, container logs and files merged by time, with
   a faceted explorer that Netdata partly gates behind its Cloud (LOG-11,
   LOG-12).
5. **Exposure map**: listening ports mapped to process, unit or container,
   crossed with firewall rules (including Docker's ufw bypass) and an outside
   reachability probe (NET-04, NET-07).
6. **Compose that respects files on disk**: discovery anywhere with source
   verification, drift detection from compose labels, deploy preview,
   host-side deploy history with rollback, and "managed by another tool"
   detection (STK-01, STK-10 to STK-13, DKE-10).
7. **Safe update pipeline**: digest detection with HEAD requests, cooldown,
   semver advisories, release notes, and a pull-first, health-gated update with
   automatic rollback that runs host-side (IMG-05, IMG-07 to IMG-11, SAF-23).
8. **Fleet triage**: attention queue, compliance tables, update center,
   certificate inventory, cross-host search, "where is this key" (TRI-03,
   FL-14, FL-15, PKG-06, CRT-02, ACC-06).
9. **Answers instead of charts**: doctor checklist, "why is it slow",
   container diagnose without AI, incident snapshots (TRI-01 to TRI-05).
10. **Transparency and safety by default**: observe-only start, explicit admin
    mode, command preview, protected targets, typed confirmations, detached
    operations, host-side audit trail, a footprint manifest, and all durable
    state on the host in standard formats, so uninstalling the app leaves
    everything running (SAF section).
11. **Honest alerting tiers**: alerts while open (T0), host-side checks without
    a daemon (T1), an opt-in Rust companion (T2, M9), each labelled in the UI
    with what it can and cannot catch (ALR section).
12. **Keyboard-first desktop and touch-first mobile from one codebase**, with
    portability (BusyBox, OpenWrt, NAS) treated as a feature backed by fixtures
    (PLT-06, CN-11 to CN-13).

---

## 6. Open questions and unverified items

The owner decisions of 2026-10-10 answer the questions this section used to
list. Section 15 of
[04-IMPLEMENTATION.md](04-IMPLEMENTATION.md#15-owner-decisions) records every
decision, and the decision log in [03-ARCHITECTURE.md](03-ARCHITECTURE.md)
section 2 carries the design consequences. Where the decisions land in this
catalog:

- Audit log (SAF-11): device-local plus the host syslog line, never synced
  (Q10). Attention acknowledgements (TRI-03) stay device-local, because no
  synced record class may grow with events (03, section 4.8).
- Record kinds (SYN-04): one product `RecordKind` with typed sub-records and
  a 1 MiB budget (Q9). Registry credentials (REG-02) and the synced sudo
  password (SAF-16) are sealed sub-records of it, never `secret:` records.
- Saved sudo password (SAF-16): per-server opt-in in the vault from v1.x,
  with a second opt-in that syncs it as
  `klabautermann:sudo:<serverConfigId>` only while the device's "sync
  passwords" switch is on (Q11).
- T2 companion (ALR-11, ALR-14, ALR-15, HIS-08): Rust, an explicit opt-in per
  server, binaries pinned by SHA-256 hashes in the client build of the same
  release, scheduled as milestone M9 after v1.x (Q8). It deposits through the
  existing inbox (50 apps per account, 30 deposits per minute, 100 pending
  items). Collectors, parsers and rules then exist in Dart and in Rust, so CI
  runs parity tests over a shared fixture corpus; ServerBox's AGPL Rust parser
  crate (`sbm_parser`) is not used or copied.
- URL schemes and hand-offs (X-03, X-04, X-10): Séance link intake and
  Poltergeist Android and iOS registration land in v1 with F5d, and X-10
  moves to v1 (Q18).
- T1 install location: user scope (`~/.config/klabautermann/`) by default,
  system scope (`/etc/klabautermann/`) only in admin mode (Q7).
- Template catalogs (TPL-02, TPL-04): permissively licensed catalogs only; GPL
  and unlicensed catalogs are not fetched, so no legal review is needed (Q19).
- Backups (BAK-03, BAK-05 to BAK-07, BAK-09): inside the app, after v1.x and
  built on T1 (Q19).
- The suite-wide dartssh2 re-pin to 4.x (CN-23) starts now as a separate task
  with its own PR across all apps (Q17). It touches M0 evidence, pin audits
  and the `redactConnectionTrace` audit and is not folded into the app work
  (c2 §3.3).
- Séance #56 is fixed in F3 before the MVP preview; first-seen pins are
  published from v1 (X-02, Q12). The `host:port` collision behind different
  jump routes stays a known limitation until a suite-wide task after v1.
- Server editing: the pull-only MVP points users to Séance or Poltergeist,
  and FL-03 arrives in v1 with `ghost_servers` part 2 (Q4).
- Theme editing and presets ship in the MVP through `ghost_theme` (X-01, Q5);
  local notifications use `flutter_local_notifications` (ALR-01, ALR-03,
  PLT-15, Q13); Android watch mode is a v1.x opt-in (PLT-11, Q14); helper
  containers need explicit confirmation (VOL-03, CTR-21, Q20); "Enable
  sysstat" runs only after confirmation in admin mode (HIS-03, Q6).

Still open in this catalog:

- Whether to operate a push relay (ALR-13) given unsigned iOS distribution,
  and the sync server change behind the heartbeat dead-man (ALR-12).
- How companion items could appear in Séance (X-09), given that Séance's
  planned inbox change skips them (03, section 9.4).
- The outcome of spike S10 and the Rust toolchain policy for the companion
  (04, section 15).

Spikes before relying on the design:

- **Transport** (r5 §7 spike A; 04 S1): streamlocal, the HTTP/1.1 client,
  hijacked exec and resize against Docker 29.9 and Podman 6.1, rootful and
  rootless.
- **Sampler** (spike B; 04 S2): the POSIX sampler on Debian 12, Ubuntu 24.04,
  RHEL 9, Alpine and a BusyBox NAS; `--output=json` on systemd 239, 245, 252
  and 257.
- **Elevation** (spike C; 04 S3): `sudo -S -p '' -v && sudo -n -- cmd` in one
  shell; whether cached credentials cross exec channels; sudo-rs strings; doas
  and run0 prompts on a PTY.
- **Update checks** (spike D; 04 S8): DistributionInspect against registry
  HEAD and `ratelimit-remaining` on Docker Hub.
- **Privileged files** (spike E; 04 S6): an SFTP channel over `sudo -n` and
  `sftp-server`; owner, mode, ACL and SELinux label restore after an atomic
  replace.
- **Detached operations** (spike F; 04 S4): `systemd-run --user` over
  non-interactive SSH (linger, `XDG_RUNTIME_DIR`), re-attach after reconnect,
  and cleanup of the `setsid nohup` fallback.
- **Port access** (spike G; 04 S7): an in-app web view fed through an SSH
  channel without a loopback listener (NET-11, DKE-09).
- **Companion** (04 S10): the Rust build of static musl binaries for Linux
  x86_64 and aarch64, and the parity harness that runs one fixture corpus
  through the Dart and Rust collectors, parsers and rules (ALR-11, HIS-08).

Facts marked [U] above, to confirm in spikes: systemd version on RHEL 8 and
JSON keys of `systemctl list-*`; PSI default on enterprise kernels; cgroup v2
paths per driver (CPU-08, CST-06); `zramctl` and zswap fields (MEM-06); btrfs
flags (DSK-13); `mtr --json` (NET-10); `vnstat --json` (NET-13); Docker's ufw
bypass wording and `userland-proxy: false` sockets (NET-04, NET-07); Android
loopback exposure (NET-11); Ubuntu `apt-check`, dnf-automatic detection,
Flatpak update listing, unprivileged dnf cache (PKG-01, PKG-02, PKG-09,
PKG-14); a hangup mid-dpkg (PKG-07); wtmpdb and lastlog2 migration (ACC-04);
`sshd -T` without `-C` (SEC-01); pstore crash records (BOOT-04); `dmesg`
restrictions (LOG-03); label conventions for Podman systemd units, Umbrel,
CasaOS and TrueNAS (DKE-10); linger behaviour over SSH (DKE-11, SVC-09,
SAF-23); `dockerd --validate` (DKE-12); debug helper design (CTR-21); icon
licence (CTR-22); sysstat unit and timer names per distro (HIS-03);
containerd image-store digest comparison and offline SBOM matching (IMG-05,
IMG-15); compose `--dry-run`, `--progress` and `--ansi` flags in Compose v5
and active profiles in labels (STK-06, STK-13);
`ratelimit-remaining` on HEAD (REG-03); restic access to existing
repositories (BAK-02); PCP tooling (HIS-07); sudo `timestamp_type` and run0
password input (SAF-02); SELinux relabel after replace (SAF-12); GTFOBins
pager escapes (SAF-17); clipboard sensitivity flags (SAF-07); `LC_ALL=C`
behaviour per tool (A11Y-08); widget and Live Activity extensions on re-signed
IPAs (PLT-12, PLT-13).

---

## Appendix A. Review disposition

A critique pass reviewed the earlier version of this catalog against the
research and raised 36 numbered items, C-01 to C-36, prioritized from P0
(safety, data-loss or correctness defects in MVP rows, or an owner
requirement the MVP did not meet) to P3 (consistency and wording). The
critique is not part of this plan; its applied items are reflected in the
rows above, and this appendix records the disposition of each item number
and the reasoning behind every choice and rejection.

Applied in full: C-01 to C-06, C-08 to C-10, C-12 to C-21, C-23 to C-32, C-34
and C-36. Where the critique rests on facts the research does not verify, the
rows carry [U]: C-06 (doas, run0, sudo caching), C-17, C-24, C-25, C-28
(`dmesg`), C-29, C-30 and C-31. C-20 and the logging-driver item of C-33 are
applied as MVP notes on LOG-02 and CTX-01 instead of separate rows. C-05
applies to state-changing operations only: reboot (SYS-03) returns at once
and the disk explorer (DSK-07) is read-only, so neither needs SAF-23.

Applied with a choice between the critique's options:

- **C-07**: option (a). The MVP requires shared-account enrollment and says so
  on first run (FL-22); in-app editing (FL-03) stays v1 behind the shared
  editor extraction. This keeps the MVP small and still meets the "same server
  list" requirement for every enrolled user.
- **C-11**: CTR-05, CTR-06, IMG-02, STK-05 and a restricted STK-06 (pull and
  `up -d` only, unmanaged and verified stacks, detached) move to the MVP, and
  v1 is defined as the first public release. DKE-05 (prune) and CTX-08
  (one-off exec) stay v1: prune is engine-wide and destructive, and one-off
  exec runs arbitrary commands and belongs with the exec shell.
- **C-22**: JOB-03 (read-only, admin mode) and running a timer now (JOB-08)
  move to the MVP. Editing the own crontab (JOB-06, JOB-07) stays v1, to keep
  the MVP rule "no config-file writes" and to ship it with SAF-12 edit safety.
  Running a cron command now is split out as JOB-19 (v1).
- **C-33**: all proposed rows added (CN-24, DKE-17, STK-23, STK-24, LOG-23,
  PLT-15, ALR-16, AI-09, X-10, IMG-20). Health-gated cutover is Later
  (STK-25), not Non-goal, because r2 §4 places proxy-based zero-downtime in
  Tier 2. The critique's citation of r3 §3.18 (Monit) does not support
  "detect other managers"; DKE-17 rests on r1 §5.3 option (d).

Rejected or partly rejected (C-35):

- **Non-goal for TPL-02, TPL-03, TPL-04, TPL-06, IMG-13, IMG-18 and STK-19:
  rejected.** Dockhand, the owner's named reference, ships templates from
  Portainer v2 JSON catalogs, image tag and push, and Git-backed stacks with
  builds (r1 §3.1, §4.5, §4.8); r1 §5.2 ranks template catalogs as a
  differentiator and r2 §3.1 rates them agentless. The rows stay Later. The
  valid part of the critique is kept as NG-19 (no curated or hosted store,
  user-added sources only) and STK-19 is limited to the T0 button.
- **Removing BAK-03, BAK-05, BAK-06, BAK-07 and BAK-09 from the catalog:
  rejected.** Dockhand ships restic backups and r1 §5.2 and r2 §6.5 name
  honest backups as a gap. The rows stay Later; their "Decision: backup
  scope" flag is resolved by owner decision Q19 (inside the app, after v1.x).
- **Non-goal for ACC-09, SYS-07, PKG-12, SVC-16, WEB-04, HW-08, SEC-05, CRT-06
  and CTR-22: rejected.** The research classes them as nice to have, as a
  differentiator (CrowdSec, r3 §4.13) or as a UX lesson worth adopting (safe
  proxy reload, r2 §5 item 5), and none appears in a research non-goal list.
  They stay Later; CTR-22 is blocked on its unverified icon licence and
  CRT-06 is marked +E.
- **Accepted from C-35:** Non-goal for NET-15, NET-16, DSK-16, LOG-21 and
  FL-19; hand-offs for DSK-08 and BAK-10 (Poltergeist) and X-03 (Séance, no
  embedded host terminal, per r4 §4.3); ACC-07 as Séance-led; the new
  non-goals NG-20 to NG-22 and Incus and LXD in NG-06; removal of the
  duplicate non-goal rows (the former NG-19 and NG-20 repeated CN-21 and
  PLT-14, and their numbers are reused for new entries).
