# Klabautermann plan

Status: plan with owner decisions of 2026-10-10. Nothing here is implemented.

This directory plans Klabautermann, the fourth Hauntware product: a server
management and observability app. This README summarizes the plan, the
decisions that shape it and the owner's answers of 2026-10-10 to the
proposal's 20 open questions, plus two later decisions of the same day on
alerts while the app is not running (21 and 22), and points to the
chapters that hold the detail.

## The owner's brief

The owner asked for an app for server management and observability (logs,
cron jobs, disk space, RAM, CPU "and so on"), for Docker management like
Dockhand, and for the same server list as Séance and Poltergeist.
[02-FEATURES.md](02-FEATURES.md#what-the-owner-asked-for-and-where-it-lands)
maps each part of the brief to catalog rows and release tiers.

## Product summary and positioning

Klabautermann is a native Flutter client for Linux, macOS, Windows, Android
and iOS that monitors and manages servers and their Docker or Podman
workloads over plain SSH. Host metrics come from `/proc`, `/sys` and
standard CLIs over one SSH connection per server; the Docker Engine API is
reached through an SSH `direct-streamlocal` channel to the engine socket,
which no mainstream Docker manager offers today (r1 §1, r5 §1). Actions are
guarded by observe-only defaults, an explicit admin mode, command previews,
protected targets and typed confirmations.

Positioning (r2 §7): **the control panel that is not installed on your
server.**

- **Agentless over SSH.** Nothing is installed on a host by default and no
  port is opened. Work that must continue while the app is closed (alerts,
  history, scheduled checks) uses consented host timer files with an
  optional hash-pinned alert helper (T1, v1.x) or a companion written in
  Rust that the user enables per server (T2, planned for M9 after v1.x).
  Alerts raised while the app is closed reach every device through the
  sync server's inbox (D42). The UI states what each tier can and cannot
  catch.
- **Five platforms from one codebase.** Keyboard-first desktop, touch-first
  phone.
- **One shared server list.** The same end-to-end encrypted, self-hostable
  list as Séance (terminal) and Poltergeist (files). No surveyed tool
  combines that with monitoring and Docker on five platforms in open source
  ([01 §6](01-RESEARCH.md#6-the-market-gap)).
- **Host files are the truth.** Compose files, `.env`, crontabs and units
  are re-read on open, never mirrored into a shadow database. Uninstalling
  the app leaves every workload running.

The differentiators are listed in [02 §5](02-FEATURES.md#5-differentiators).

## Reading order

| # | Document | What it holds |
|---|---|---|
| 1 | This README | Summary, tiers, key decisions, MVP scope, milestones, name, owner decisions, follow-up tasks |
| 2 | [01-RESEARCH.md](01-RESEARCH.md) | Landscape by category, cross-cutting lessons, technical feasibility, codebase starting point, market gap |
| 3 | [02-FEATURES.md](02-FEATURES.md) | Feature catalog: 494 rows in 40 areas with release tier, execution tier, privilege and data source; MVP, table stakes, differentiators |
| 4 | [03-ARCHITECTURE.md](03-ARCHITECTURE.md) | Sections 1 to 11: principles, decision log with the owner decisions, packages, catalog, transport, collection, subsystems, privilege and safety, tiers, UI, testing |
| 5 | [04-IMPLEMENTATION.md](04-IMPLEMENTATION.md) | Sections 12 to 15 and Appendices A to C: suite integration, milestones, risks, owner decisions, verification notes |
| 6 | [05-NAMES.md](05-NAMES.md) | Naming rules, the name decision, shortlist, collision screen |
| 7 | [research/README.md](research/README.md) | Index of the research appendices, freshness caveat, abbreviation key, marker legends |

The nine research appendices are imported as captured and not maintained;
where one disagrees with a chapter, the chapter wins.

| Key | Appendix | Scope |
|---|---|---|
| r1 | [r1-docker-managers.md](research/r1-docker-managers.md) | Docker managers, including Dockhand |
| r2 | [r2-selfhost-platforms.md](research/r2-selfhost-platforms.md) | Self-hosting platforms, PaaS, NAS |
| r3 | [r3-server-panels-monitoring.md](research/r3-server-panels-monitoring.md) | Server panels and monitoring |
| r4 | [r4-native-mobile-clients.md](research/r4-native-mobile-clients.md) | Native, mobile and TUI clients |
| r5 | [r5-technical-feasibility.md](research/r5-technical-feasibility.md) | Technical feasibility |
| c1 | [c1-catalog-sync.md](research/c1-catalog-sync.md) | Codebase: server catalog and sync |
| c2 | [c2-ssh-exec-terminal.md](research/c2-ssh-exec-terminal.md) | Codebase: SSH, exec and terminal |
| c3 | [c3-shared-ui-app-shells.md](research/c3-shared-ui-app-shells.md) | Codebase: shared UI and app shells |
| c4 | [c4-suite-infra.md](research/c4-suite-infra.md) | Codebase: suite infrastructure |

## How proposals A, B and C relate to this plan

The feature catalog went through a draft and a critique pass; 02 applies
every critique item the research supports and records the disposition in
its Appendix A. The architecture was written as three competing proposals,
**A** (agentless-first minimalist), **B** (capability-first with an
optional companion) and **C** (suite-integration-first), judged by an
engineering review and a product and security review.

[03-ARCHITECTURE.md](03-ARCHITECTURE.md) takes A as the base, which both
reviews recommended. From C it takes suite integration (`SshLink` in
`seance_core`, the elevation prelude, "move, switch, prove", the catalog
home, suite links, convergence tests); from B the host tiers (the T1
design, the footprint manifest, durable detached-operation results, the T2
prerequisites). The proposals, the catalog draft and the critique are not
kept; "A's", "B's" and "C's" in rejected alternatives refer to them.
The [owner decisions](#owner-decisions) of 2026-10-10 then changed some
choices in place, notably the theme timing (D9), host-key publication
(D15), the companion (D31) and alert delivery while the app is closed
(D42).
[04 Appendix B](04-IMPLEMENTATION.md#appendix-b-review-must-address-items-and-where-they-are-resolved)
maps every review "must address" item to its resolution.

## Tiers

| Tier | Kind | Meaning | Rows |
|---|---|---|---|
| T0 | Execution | Agentless over SSH while the app is open; host writes limited to [03 §8.11](03-ARCHITECTURE.md#811-host-write-inventory-d27) | 317 |
| T1 | Execution | Consented host timer files and POSIX scripts, plus the optional hash-pinned `klabautermann-notify` helper for sync-server delivery (owner decision 21), in one footprint manifest, removable in one action; no daemon, no port; user scope by default, system scope only in admin mode | 18 |
| T2 | Execution | Always-on companion written in Rust, opt-in per server, planned for M9 after v1.x; no T0 or T1 feature depends on it | 7 |
| C | Execution | Client-only: no server access, or only data already fetched | 145 |
| MVP | Release | First preview worth using daily, shipped in suite releases labelled preview from M4; T0 and client-only rows, no T1 or T2; pull-only server list; theme editing and presets | 110 |
| v1 | Release | First public release: every table-stakes item, server editing, read-write sync, hand-offs to Séance and Poltergeist | 136 |
| v1.x | Release | Differentiators and T1: host checks whose alerts reach every device through the sync server's inbox, with a "while you were away" list (D42), scheduled update checks, coarse history, fleet tables | 149 |
| Later | Release | T2 rows (four scheduled in M9; ALR-12, ALR-13 and X-09 wait on further decisions) and work after v1.x: push relay, backups inside Klabautermann, permissive template catalogs | 92 |

Rows are catalog rows in 02; execution counts exclude the 7 non-goal rows
(487 of 494). The counts are those of
[02 Feature counts](02-FEATURES.md#feature-counts), which wins if they
differ. T2 rows keep the release tier Later; ALR-11, ALR-14, ALR-15 and
HIS-08 are scheduled in M9, and ALR-12, ALR-13 and X-09 wait on further
decisions. A `+E` suffix marks an opt-in feature that contacts an endpoint
outside the user's servers and the suite. Definitions:
[02](02-FEATURES.md#tier-definitions),
[03 §1.3](03-ARCHITECTURE.md#13-release-scope-at-a-glance),
[03 §9.1](03-ARCHITECTURE.md#91-what-runs-where).

## Key decisions

The [decision log](03-ARCHITECTURE.md#2-decision-log) resolves every design
question once and records the owner decisions of 2026-10-10 in place; when
a later section conflicts with it, the log wins. The decisions that shape
the product most:

- **[D1](03-ARCHITECTURE.md#shape-and-scope) Agentless first.** T0 delivers
  the MVP and v1. T1 is committed for v1.x because phones cannot poll in the
  background [R: r5 §5.4]. T2 is planned for M9 after v1.x
  ([9](03-ARCHITECTURE.md#9-execution-tiers-t0-t1-and-t2)).
- **[D3](03-ARCHITECTURE.md#code-sharing) Move, switch, prove.** Each
  extraction starts with an owner-approved design doc and switches a shipped
  app in the same PR, with its suite and pixel baselines unchanged. A
  stalling extraction is narrowed, never copied
  ([3.5](03-ARCHITECTURE.md#35-prerequisite-extractions)).
- **[D4](03-ARCHITECTURE.md#code-sharing) No dartssh2 in the product.**
  `SshLink` in `seance_core` holds every dartssh2 workaround; a root
  import guard keeps dartssh2 out of `klabautermann/`
  ([5.1](03-ARCHITECTURE.md#51-sshlink-f2a)). The suite now pins dartssh2
  4.1.0 (PR #113), which removed some of them (D23).
- **[D5](03-ARCHITECTURE.md#code-sharing) Four product packages.** Pure-Dart
  `klabautermann_host` and `klabautermann_docker` with no SSH dependency,
  `klabautermann_core` orchestrating over `SshLink`, and the Flutter
  `klabautermann_app`.
- **[D6](03-ARCHITECTURE.md#code-sharing) Catalog library in
  `seance_core`.** Poltergeist migrates first with byte-identical files;
  Séance follows after v1 (F7). The owner approved all five recommended
  divergence resolutions; each lands as its own PR
  ([4.4](03-ARCHITECTURE.md#44-the-catalog-library)).
- **[D9](03-ARCHITECTURE.md#code-sharing) Theme editing in the MVP
  preview.** The `ghost_theme` extraction (F4b, Séance switched,
  Poltergeist as a follow-up) runs after or in parallel with F4, before M1
  where the critical path allows, so the MVP builds its themes through it,
  including theme editing and presets. Owner decision 2026-10-10; the plan
  had recommended a fixed brand preset with `ghost_theme` in v1.
- **[D13](03-ARCHITECTURE.md#server-list-and-sync) Shared-account
  enrollment.** The shared list comes only from the user's Séance account,
  as in Poltergeist's shared mode; desktop local-only mode imports
  `~/.ssh/config`
  ([4.3](03-ARCHITECTURE.md#43-first-run-enrollment-and-batch-onboarding-fl-22)).
- **[D14](03-ARCHITECTURE.md#server-list-and-sync) Pull-only MVP.** The
  catalog applies pulled records and never pushes; writes arrive in v1 with
  the shared server editor.
- **[D15](03-ARCHITECTURE.md#server-list-and-sync) Host keys quarantined;
  publication enabled once Séance #56 is fixed.** The fix (Séance's
  conflict check for pulled pins, adopting the quarantine handler) moves
  into F3, before the MVP preview. Because the MVP pushes nothing,
  Klabautermann publishes first-seen pins from v1, when catalog writes
  arrive. Owner decision 2026-10-10; the plan had kept publication disabled
  until #56 landed after v1. The `host:port` collision behind different
  jump routes stays a known limitation
  ([follow-up tasks](#follow-up-tasks-outside-this-plan)).
- **[D17](03-ARCHITECTURE.md#server-list-and-sync) One product
  `RecordKind`** with typed sub-records, sealed removal and a 1 MiB budget,
  confirmed by the owner.
- **[D41](03-ARCHITECTURE.md#privilege-and-safety) Remembered sudo
  password, optionally synced**
  ([4.5](03-ARCHITECTURE.md#45-credentials)). From v1.x a per-server
  opt-in remembers the sudo password in the vault (protected by the device
  keystore). A second opt-in syncs it, only while the device's suite-wide
  "sync passwords" switch is also on, as a sealed sub-record of
  Klabautermann's own kind (for example
  `klabautermann:sudo:<serverConfigId>`), never as a Séance `secret:`
  record, so Séance and Poltergeist never apply or store it (they skip the
  unknown kind or prefix, 03 §4.8); removal is a sealed `removed` record.
  Anyone holding the account key, and every device on the account, can
  obtain a password that grants root on that server; the switch subtitle
  and the threat model say so. Admin mode still expires; a remembered
  password only skips the prompt. Owner decision 2026-10-10; the plan had
  recommended device-only storage.
- **[D20](03-ARCHITECTURE.md#transport-and-collection) Docker over
  streamlocal** with an own pure-Dart HTTP/1.1 client and a fallback ladder;
  never a local TCP or Unix listener
  ([5.4](03-ARCHITECTURE.md#54-docker-engine-api-over-the-forwarded-socket)).
- **[D22](03-ARCHITECTURE.md#transport-and-collection) HWS/1 sampler.**
  Program and nonce on the stdin of `sh -s`, one command line per tick,
  length-prefixed and nonce-framed sections; verified on dash and bash [L]
  ([6.2](03-ARCHITECTURE.md#62-sampler-protocol-hws1-cn-03-d22)).
- **[D24](03-ARCHITECTURE.md#privilege-and-safety) Elevation prelude.** The
  builtin `read` takes the password line, `sudo -S -v` validates and
  `sudo -n -- "$@"` runs as a child of the same shell, then `exit $?`; A's
  `exec sudo -n` variant fails [L]
  ([8.3](03-ARCHITECTURE.md#83-the-elevation-prelude-d24)).
- **[D26](03-ARCHITECTURE.md#privilege-and-safety) Immutable operation
  plans.** One plan yields the preview and the executed steps; no mutation
  without at least a dialog naming the target
  ([8.5](03-ARCHITECTURE.md#85-operation-model)).
- **[D27](03-ARCHITECTURE.md#privilege-and-safety) Host write contract.**
  Every file the app can create on a host is listed in 8.11 and checked by
  an integration test; backups go to central directories. The owner
  accepted operation records and logs, central backups, the audit syslog
  line and the footprint manifest. When sysstat is missing, an "Enable
  sysstat" action (v1.x) shows the exact commands and runs them only after
  explicit confirmation in admin mode. Helper containers for volume
  browsing (VOL-03) and the debug shell (CTR-21) start only after explicit
  confirmation and are removed afterwards.
- **[D30 and D31](03-ARCHITECTURE.md#persistence-alerts-and-tiers) T1 and
  T2.** T1 in v1.x: consented scripts and timers, plus the optional
  hash-pinned `klabautermann-notify` helper for sync-server delivery
  (D42), user scope by default, system scope only in admin mode, a
  checksummed manifest, one-action uninstall
  ([9.3](03-ARCHITECTURE.md#93-t1-host-checks-without-a-daemon-v1x-d30)).
  T2 is milestone M9 after v1.x: a companion written in Rust, an explicit
  opt-in per server, an inbox producer with no listener, no inbound control
  and no SSH or account keys, installed, updated and removed only by the
  client over SSH and never self-updating
  ([9.4](03-ARCHITECTURE.md#94-t2-optional-rust-companion-m9-d31)). The
  client build of the same release pins SHA-256 hashes of the companion
  binaries; there is no signing key and no new CI secret. The 9.4
  prerequisites stay. The companion cannot be built from
  `klabautermann_host` and `klabautermann_docker`, so collectors, parsers
  and rules exist in Dart and in Rust, and CI runs parity tests over a
  shared fixture corpus; ServerBox's AGPL parser crate `sbm_parser` is
  neither used nor copied. The repository gains a Rust toolchain, static
  musl binaries for Linux x86_64 and aarch64, license and advisory checks
  and a release job that feeds the client build through a `needs:` edge.
  Owner decision 2026-10-10; the plan had left T2 open and recommended
  Dart. Owner decision 2026-10-10 (21/22): the Rust toolchain, the musl
  builds, the checks and the release job now arrive in v1.x (M8) with the
  `klabautermann-notify` helper, whose hashes the client build pins the
  same way, built from the same Rust workspace the companion will use
  (a shared crate for sealing and posting); the helper part of spike S10
  runs before M8 (its companion parity part before M9).
- **[D42](03-ARCHITECTURE.md#persistence-alerts-and-tiers) Alerts while
  closed through the sync server, one sender per server.** From v1.x, T1
  checks (and the companion from M9) deposit sealed alerts into the
  existing command inbox of the sync server (1.9.0 or later), only on
  state changes and as a digest when many fire at once, so the per-app
  limits hold. Every Klabautermann device fetches them at launch and on
  each sync round, shows a "while you were away" list per server, keeps a
  local history, syncs acknowledgement as a bounded sealed status
  sub-record of Klabautermann's own kind and deletes handled items.
  Alerts use a versioned JSON format, are validated after decryption and
  are shown as untrusted plain text. Plain shell cannot produce the
  inbox's XChaCha20-Poly1305 blobs and the `openssl` CLI has no AEAD mode
  in `enc`, so a small single-purpose Rust program, `klabautermann-notify`,
  seals each alert under Klabautermann's own associated-data domain (a
  blob can never be read as a Séance proposal) and posts it over HTTPS.
  It reads its token and key from a 0600 file, never argv or the
  environment, has no daemon and no listener, is installed only with
  consent and removed by the one-action uninstall. Each server gets its
  own sender (deposit-only token and key), so a compromised host can
  forge or flood alerts only for itself and can be revoked alone; sender
  keys are sealed sub-records of Klabautermann's kind, never Séance
  `inboxApp` records. A small sync server change gives marked
  Klabautermann senders their own per-account quota (for example 500)
  beside the shared limit of 50, with no protocol bump; on older servers
  the app explains the limit and lets the user choose which servers alert
  through the sync server. The sync server can drop or delay alerts but
  can neither read nor forge them, so ntfy, email and webhook notifiers
  stay optional parallel channels; without the helper or a reachable sync
  server, T1 keeps its host-side alert spool, read on the next connect.
  Optional peer reachability checks let server A report "B unreachable
  from A". A Séance release must first stop its inbox cursor stalling at
  marked Klabautermann app ids, without decrypting or deleting their
  items. Owner decisions 21 and 22 of 2026-10-10.
- **[D37](03-ARCHITECTURE.md#platform-ui-and-delivery) CI on every PR.**
  Klabautermann's client matrix builds on every PR like the siblings, with
  no path filter (about 30 to 45 extra runner-minutes per PR [E] and longer
  macOS queues, accepted). Privileged `docker:dind` runs on ephemeral
  GitHub-hosted Linux runners, pinned by digest, with loopback-only ports;
  other platforms use recorded fixtures. Owner decision 2026-10-10; the
  plan had recommended a path filter.
- **[D38](03-ARCHITECTURE.md#platform-ui-and-delivery) Identities fixed
  before M1:** display name Klabautermann, stem `klabautermann`, app ids
  under `ch.lkmc.klabautermann`, Windows `CompanyName` `ch.lkmc` (matching
  Séance, Planchette and the `ch.lkmc.*` ids; Poltergeist keeps `L-K-M`),
  keystore prefix, host artifact names
  ([04 §12.3](04-IMPLEMENTATION.md#123-identities-fixed-by-the-owner-on-2026-10-10-d38)).
  Owner decision 2026-10-10; the plan had recommended `L-K-M`.

## MVP scope at a glance

The MVP targets glibc Linux with systemd; other hosts follow with fixtures.
Detail: [02 §2](02-FEATURES.md#2-mvp-at-a-glance); deviations:
[03 §1.4](03-ARCHITECTURE.md#14-deviations-from-and-corrections-to-02-featuresmd).

- **Fleet:** the shared list through enrollment (pull-only) or a desktop
  local-only list; reachability dots, search, groups, pressure bars, jump
  hosts.
- **Overview:** live CPU, memory, swap, disk usage and inodes, network
  throughput, uptime, system identity, LXC awareness, Docker summary.
- **Processes and services:** process list with kill; systemd units,
  failed units, start, stop, restart, reload, unit logs.
- **Logs:** journal viewer, follow, kernel log, search, file tail.
- **Scheduled jobs:** one list of cron jobs and timers, schedules in words,
  next runs, other users' crontabs read-only, run a timer now.
- **Docker:** engine info, event-driven refresh, managed-by badges;
  container lifecycle, inspect with masking, health, logs, live stats;
  image list and removal; compose stack discovery, overview, file view,
  start, stop, restart, and pull and redeploy as a detached operation.
- **Safety:** observe-only default, admin mode, root badges, command
  previews, tiered confirmations, protected targets, endpoint confirmation,
  a device audit log.
- **Appearance:** shared marks, light and dark themes built through
  `ghost_theme` (F4b), theme editing and presets.

The MVP ships in suite releases labelled preview from M4.

Not in the MVP: container exec, in-app server editing, config-file writes,
`docker compose down`, per-service actions, prune, image pull outside a
stack, volumes and networks, package updates, history beyond the session,
alerts, anything T1 or T2.

## What v1 adds

- Every table-stakes item of [02 §4](02-FEATURES.md#4-table-stakes): parity
  with ServerBox and ServerCat on the host side and Dockge-class compose
  management on the Docker side.
- In-app server editing with catalog writes and the app's own `RecordKind`;
  first-seen host-key pins are published from here (D15).
- Container exec shells; host shells hand off to Séance.
- Config edits with diff, backup and validation.
- Volumes, networks, prune with preview, image pull and update detection.
- Packages read-only, hardware, triage, firewall view, port forwards.
- On-device history rollups and in-app alerts while the app is open, with
  local notifications through `flutter_local_notifications` (BSD-3);
  charts stay in-house (D10).
- Hand-offs (F5d): Séance link intake, which opens a known server and asks
  before connecting (links pick only a server and a starting folder and
  can never run commands), and Poltergeist link registration on Android
  and iOS; X-03 open terminal, X-04 open files and X-10 open terminal in
  this directory.
- Command palette, tablet layout, app lock.

After v1, M8 (v1.x) adds T1 with the optional `klabautermann-notify`
helper and the "Enable sysstat" action, the saved
sudo password with its optional sync, a time-limited Android watch mode
(an opt-in foreground service, off by default, started per session, that
stops automatically and says so) and volume browsing with a confirmed
helper container. Backups inside Klabautermann, built on T1, follow after
v1.x; until then the one-off database dump (BAK-01) and the status of
existing backup tools (BAK-02) stay v1.x. Alerts raised while the app is
closed reach every device through the sync server's inbox, one sender per
server, and appear at launch in a "while you were away" list per server;
optional peer reachability checks let one server report another as
unreachable, though a host still cannot report its own outage; ntfy,
email or webhook notifiers stay optional parallel channels (D42). The
companion follows in M9.

## Milestones

Sizes are engineer-weeks of focused work [E]: S up to 1, M 2 to 3, L 4 to
6, XL 7 to 10; M0 refines every estimate. F steps are shared-code
extractions, M steps product milestones. Exit criteria and critical path:
[04 §13](04-IMPLEMENTATION.md#13-milestones).

| Step | Scope | Size [E] | Release point |
|---|---|---|---|
| M0 | Spikes S1 to S9 | 5 to 7 in total, parallel; calendar 3 to 4 weeks | |
| F1 | Guards and shared tooling | M to L, 3 to 4 | |
| F2 | `seance_core` transport and safety | L, 5 to 7 | |
| F3 | Catalog, stores and keystore; Séance #56 fix (pulled-pin conflict check) | L to XL, 8 to 12 | |
| F4 | `ghost_servers` part 1 and formatters (parallel with F2 and F3) | M, 3 to 4 | |
| F4b | `ghost_theme` (Séance switched, Poltergeist follow-up; after or parallel with F4, preferably before M1) | L, 4 to 6 | |
| M1 | Scaffold and suite registration (build, check and CI legs and the release gate steps) | M, 2 to 3 | |
| M2 | Host read MVP | L, 5 to 6 | |
| M3 | Docker read MVP | L, 4 to 5 | |
| M4 | MVP actions and safety; release job, manifest entries and workflow contracts | L, 5 to 6 | **MVP preview**, in suite releases labelled preview |
| F5 | v1 extractions F5a and F5c to F5f (parallel with M5 and M6; F5b moved to F4b) | 9 to 16 (sum of F5a and F5c to F5f) | |
| M5 | v1 part 1: editing, shells and sync writes | L to XL, 7 to 9 | |
| M6 | v1 part 2: breadth | XL, 8 to 10 | |
| M7 | v1 hardening and release readiness | M, 3 | **v1 public** |
| M8 | v1.x, including T1 alert delivery through the sync server with the `klabautermann-notify` helper, which brings the Rust toolchain, musl builds, `cargo-deny` and the helper release job; the helper part of spike S10 before M8 (its companion parity part before M9); Séance inbox prerequisites and the sync server sender quota land in a Séance release first | Increments: XL, plus L to XL for alert delivery | v1.x |
| M9 | Companion (Rust), after M8, on the Rust workspace and release job of M8 | XL, estimated after S10 | After v1.x |
| Later | Other Later rows: push relay, heartbeat dead-man, companion items in Séance, backups on T1, permissive template catalogs, debug shell with a helper container, Séance metrics strip, macOS and FreeBSD hosts | Not estimated | Later |
| F7 | Séance on the catalog library | L, after v1 | |

F1 to F4 plus F4b come to about 23 to 33 engineer-weeks [E]. The MVP path
(M0 to M4, including F1 to F4 and F4b) comes to about 44 to 60
engineer-weeks [E]; with two contributors in parallel tracks the preview is
roughly 7 to 8 months out [E]. The v1 increment (F5 plus M5 to M7) adds
about 27 to 38 engineer-weeks [E]. The dartssh2 4.1.0 re-pin, already
landed, was outside these totals, and so is S10, whose helper part runs
before M8 and whose companion parity part runs before M9. M1 registers
build, check and CI legs and the release gate steps only; the
`client_klabautermann` release job, manifest entries and workflow contracts
land at M4, so the first suite release after M4 contains Klabautermann
labelled preview. Cutting a release is a separate explicit task.

## Name

The owner chose **Klabautermann**: display name Klabautermann, lowercase
ASCII stem `klabautermann`. In German, Frisian and Dutch seafaring lore it
is the ship spirit that tends the cargo and knocks to warn the crew, which
fits an app that looks after containers and raises alerts
([05 §5.3](05-NAMES.md#53-klabautermann)). It was the second alternate in
[05-NAMES.md](05-NAMES.md); the screen found no collision, and its costs
are length (13 letters) and spelling. The Windows `CompanyName` is
`ch.lkmc`, as for Séance and Planchette and matching the `ch.lkmc.*` ids;
Poltergeist stays the outlier with `L-K-M`.

The screen was a collision screen, not trademark clearance: no EU, German
or French register query ran and no domain was checked; those checks are
listed in
[05 §8](05-NAMES.md#8-checks-still-required-before-committing).

## Owner decisions

The owner answered all 20 open questions of the proposal on 2026-10-10
and made two further decisions the same day on alerts while the app is
not running (21 and 22).
[04 §15](04-IMPLEMENTATION.md#15-owner-decisions) holds the full table with
where each decision is applied and the new open items the decisions
create.

| Q | Topic | Decision |
|---|---|---|
| 1 | Name and identities | Klabautermann, stem `klabautermann`; Windows `CompanyName` `ch.lkmc` (not the recommended `L-K-M`) |
| 2 | Foundations before the scaffold | Accepted: F1 to F4, no third copies; F4b added by Q5 |
| 3 | Catalog divergences (03 §4.4) | All five recommended resolutions approved, each in its own PR |
| 4 | Pull-only MVP (D14) | Accepted |
| 5 | Theme (D9) | Theme editing and presets in the MVP preview through `ghost_theme`, extracted as F4b before the MVP |
| 6 | Host writes (03 §8.11) | All four accepted; "Enable sysstat" shows the commands and runs them only after confirmation in admin mode |
| 7 | T1 | Approved for v1.x: user scope by default, system scope only in admin mode; optional `klabautermann-notify` helper added by Q21 |
| 8 | T2 companion | Yes, milestone M9 after v1.x, in Rust; SHA-256 hashes pinned in the client build, no signing key; spike S10 first: its helper part before M8 since Q21, its parity part before M9 |
| 9 | Record kind (D17) | One kind with typed sub-records, 1 MiB budget |
| 10 | Audit log (D28) | Device-local plus a host syslog line, never synced |
| 11 | Saved sudo password | Optional from v1.x and syncable behind a second opt-in, as a sealed sub-record of Klabautermann's kind (not the recommended device-only) |
| 12 | Host keys (D15) | Séance #56 fixed first, in F3; publication from v1; `host:port` collision fixed suite-wide after v1 |
| 13 | Dependencies | `flutter_local_notifications` (BSD-3) for v1 alerts; charts stay in-house (D10) |
| 14 | Android watch mode | v1.x, a time-limited opt-in foreground service, off by default |
| 15 | CI (D37) | Client matrix on every PR, no path filter; privileged `docker:dind` on ephemeral GitHub-hosted Linux runners |
| 16 | Preview releases | MVP ships in suite releases labelled preview from M4 |
| 17 | dartssh2 4.x re-pin | Start now as a separate suite-wide task (landed as 4.1.0, PR #113) |
| 18 | Hand-offs | Séance link intake and Poltergeist mobile registration (F5d) in v1; starting folder accepted, X-10 moves to v1 |
| 19 | Backups and templates | Backups inside Klabautermann after v1.x, built on T1; only permissive (Apache-2.0, MIT) template catalogs, so no legal review |
| 20 | Helper containers | Allowed for VOL-03 and CTR-21 with explicit confirmation, a digest-pinned image and removal afterwards |
| 21 | Alerts while the app is closed | From v1.x through the sync server's command inbox: T1 checks (later the companion) deposit sealed alerts on state changes, every device lists them at launch and syncs acknowledgement; a consented, hash-pinned Rust helper `klabautermann-notify` seals and posts them, so the Rust toolchain and the helper part of spike S10 move before M8; optional peer reachability checks; Séance inbox prerequisites ship first (D42) |
| 22 | Alert senders | One sender (deposit token and key) per server; a small sync server change gives Klabautermann senders their own per-account quota beside the shared 50; older servers keep 50 in total and the user chooses which servers alert through the sync server (D42) |

## Follow-up tasks outside this plan

- **dartssh2 4.x re-pin.** Done: 4.1.0 landed suite-wide on 2026-10-10
  (PR #113), outside the estimates above (D23).
- **`host:port` pin collision.** Identical addresses behind different jump
  routes share one host-key pin. The fix changes the suite's pin locator
  convention and is a dedicated suite-wide task after v1, together with F7;
  until then it is documented as a known limitation.

## Markers and abbreviations

- **[V]** verified in the repository at `bf1da58`; **[L]** verified by a
  local experiment
  ([04 Appendix A](04-IMPLEMENTATION.md#appendix-a-verification-notes));
  **[R]** taken from a research report or review without re-verification;
  **[U]** unverified, settled by a named spike; **[E]** estimate or design
  value. Defined at the top of 03; each appendix keeps its own legend.
- **r1 to r5, c1 to c4** are the research appendices. Markers such as
  `[R: r5 §5.4]` or `c1 §2.3` name a report and a section in it
  ([abbreviation key](research/README.md#abbreviation-key)).
- **A, B and C** are the architecture proposals described above.
- Feature IDs such as STK-06 refer to 02; decision numbers (D1 onward) and
  extraction steps F1a to F7 (including F4b) to 03; spikes, milestones,
  risks and owner decisions to 04. Section numbers run on from 03 (1 to 11)
  into 04 (12 to 15, Appendices A to C).
