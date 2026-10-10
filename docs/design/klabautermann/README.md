# Server app plan (name to be decided)

Status: proposal for owner review, 2026-10-10. Nothing here is implemented.

This directory plans the fourth Hauntware product, a server management and
observability app. This README summarizes the plan, the decisions that
shape it and the questions the owner is asked to settle, and points to the
chapters that hold the detail.

## The owner's brief

The owner asked for an app for server management and observability (logs,
cron jobs, disk space, RAM, CPU "and so on"), for Docker management like
Dockhand, and for the same server list as Séance and Poltergeist.
[02-FEATURES.md](02-FEATURES.md#what-the-owner-asked-for-and-where-it-lands)
maps each part of the brief to catalog rows and release tiers.

## Product summary and positioning

`<App>` is a native Flutter client for Linux, macOS, Windows, Android and
iOS that monitors and manages servers and their Docker or Podman workloads
over plain SSH. Host metrics come from `/proc`, `/sys` and standard CLIs
over one SSH connection per server; the Docker Engine API is reached
through an SSH `direct-streamlocal` channel to the engine socket, which no
mainstream Docker manager offers today (r1 §1, r5 §1). Actions are guarded
by observe-only defaults, an explicit admin mode, command previews,
protected targets and typed confirmations.

Positioning (r2 §7): **the control panel that is not installed on your
server.**

- **Agentless over SSH.** Nothing is installed on a host by default and no
  port is opened. Work that must continue while the app is closed (alerts,
  history, scheduled checks) uses consented host timer files (T1, v1.x) or,
  only after an owner decision, an opt-in companion (T2). The UI states what
  each tier can and cannot catch.
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
| 1 | This README | Summary, tiers, key decisions, MVP scope, milestones, names, top open questions |
| 2 | [01-RESEARCH.md](01-RESEARCH.md) | Landscape by category, cross-cutting lessons, technical feasibility, codebase starting point, market gap |
| 3 | [02-FEATURES.md](02-FEATURES.md) | Feature catalog: 491 rows in 40 areas with release tier, execution tier, privilege and data source; MVP, table stakes, differentiators |
| 4 | [03-ARCHITECTURE.md](03-ARCHITECTURE.md) | Sections 1 to 11: principles, decision log (D1 to D40), packages, catalog, transport, collection, subsystems, privilege and safety, tiers, UI, testing |
| 5 | [04-IMPLEMENTATION.md](04-IMPLEMENTATION.md) | Sections 12 to 15 and Appendices A to C: suite integration, milestones, risks, open questions, verification notes |
| 6 | [05-NAMES.md](05-NAMES.md) | Naming rules, recommendation, shortlist, collision screen |
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
[04 Appendix B](04-IMPLEMENTATION.md#appendix-b-review-must-address-items-and-where-they-are-resolved)
maps every review "must address" item to its resolution.

## Tiers

| Tier | Kind | Meaning | Rows |
|---|---|---|---|
| T0 | Execution | Agentless over SSH while the app is open; host writes limited to [03 §8.11](03-ARCHITECTURE.md#811-host-write-inventory-d27) | 317 |
| T1 | Execution | Consented host timer files and POSIX scripts in one footprint manifest, removable in one action; no daemon, no port | 16 |
| T2 | Execution | Optional always-on companion; no T0 or T1 feature depends on it | 7 |
| C | Execution | Client-only: no server access, or only data already fetched | 144 |
| MVP | Release | First preview worth using daily; T0 and client-only rows, no T1 or T2; pull-only server list | 110 |
| v1 | Release | First public release: every table-stakes item, server editing, read-write sync | 135 |
| v1.x | Release | Differentiators and T1: host checks with notifications, scheduled update checks, coarse history, fleet tables | 147 |
| Later | Release | Needs T2 or a large decision: companion, push relay, backup scope, templates | 92 |

Rows are catalog rows in 02; execution counts exclude the 7 non-goal rows
(484 of 491). A `+E` suffix marks an opt-in feature that contacts an
endpoint outside the user's servers and the suite. Definitions:
[02](02-FEATURES.md#tier-definitions),
[03 §1.3](03-ARCHITECTURE.md#13-release-scope-at-a-glance),
[03 §9.1](03-ARCHITECTURE.md#91-what-runs-where).

## Key decisions

The [decision log](03-ARCHITECTURE.md#2-decision-log) resolves every design
question once (D1 to D40); when a later section conflicts with it, the log
wins. The decisions that shape the product most:

- **[D1](03-ARCHITECTURE.md#shape-and-scope) Agentless first.** T0 delivers
  the MVP and v1. T1 is committed for v1.x because phones cannot poll in the
  background [R: r5 §5.4]. T2 is Later
  ([9](03-ARCHITECTURE.md#9-execution-tiers-t0-t1-and-t2)).
- **[D3](03-ARCHITECTURE.md#code-sharing) Move, switch, prove.** Each
  extraction starts with an owner-approved design doc and switches a shipped
  app in the same PR, with its suite and pixel baselines unchanged. A
  stalling extraction is narrowed, never copied
  ([3.5](03-ARCHITECTURE.md#35-prerequisite-extractions)).
- **[D4](03-ARCHITECTURE.md#code-sharing) No dartssh2 in the product.**
  `SshLink` in `seance_core` holds every dartssh2 3.0.2 workaround; a root
  import guard keeps dartssh2 out of `<app>/`
  ([5.1](03-ARCHITECTURE.md#51-sshlink-f2a)).
- **[D5](03-ARCHITECTURE.md#code-sharing) Four product packages.** Pure-Dart
  `<app>_host` and `<app>_docker` with no SSH dependency, `<app>_core`
  orchestrating over `SshLink`, and the Flutter `<app>_app`.
- **[D6](03-ARCHITECTURE.md#code-sharing) Catalog library in
  `seance_core`.** Poltergeist migrates first with byte-identical files;
  Séance follows after v1 (F7). Five divergences need owner decisions
  ([4.4](03-ARCHITECTURE.md#44-the-catalog-library)).
- **[D13](03-ARCHITECTURE.md#server-list-and-sync) Shared-account
  enrollment.** The shared list comes only from the user's Séance account,
  as in Poltergeist's shared mode; desktop local-only mode imports
  `~/.ssh/config`
  ([4.3](03-ARCHITECTURE.md#43-first-run-enrollment-and-batch-onboarding-fl-22)).
- **[D14](03-ARCHITECTURE.md#server-list-and-sync) Pull-only MVP.** The
  catalog applies pulled records and never pushes; writes arrive in v1 with
  the shared server editor.
- **[D15](03-ARCHITECTURE.md#server-list-and-sync) Host keys quarantined,
  never published** until Séance #56 is fixed or the user explicitly shares
  a pin.
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
  an integration test; backups go to central directories.
- **[D30 and D31](03-ARCHITECTURE.md#persistence-alerts-and-tiers) T1 and
  T2.** T1 in v1.x: consented scripts and timers, user scope by default, a
  checksummed manifest, one-action uninstall
  ([9.3](03-ARCHITECTURE.md#93-t1-host-checks-without-a-daemon-v1x-d30)).
  T2 only after an owner decision, as an inbox producer with no listener
  and no SSH or account keys
  ([9.4](03-ARCHITECTURE.md#94-t2-optional-companion-later-d31)).
- **[D38](03-ARCHITECTURE.md#platform-ui-and-delivery) Identities fixed
  before M1:** name, stem, app ids, Windows `CompanyName`, keystore prefix,
  host artifact names
  ([04 §12.3](04-IMPLEMENTATION.md#123-identities-placeholders-fixed-before-m1-d38)).

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

Not in the MVP: container exec, in-app server editing, config-file writes,
`docker compose down`, per-service actions, prune, image pull outside a
stack, volumes and networks, package updates, history beyond the session,
alerts, anything T1 or T2.

## What v1 adds

- Every table-stakes item of [02 §4](02-FEATURES.md#4-table-stakes): parity
  with ServerBox and ServerCat on the host side and Dockge-class compose
  management on the Docker side.
- In-app server editing with catalog writes and the app's own `RecordKind`.
- Container exec shells; host shells hand off to Séance.
- Config edits with diff, backup and validation.
- Volumes, networks, prune with preview, image pull and update detection.
- Packages read-only, hardware, triage, firewall view, port forwards.
- On-device history rollups and in-app alerts while the app is open.
- Command palette, tablet layout, app lock, theme editing, hand-offs to
  Séance and Poltergeist.

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
| F3 | Catalog, stores and keystore | L to XL, 7 to 10 | |
| F4 | `ghost_servers` part 1 and formatters (parallel with F2 and F3) | M, 3 to 4 | |
| M1 | Scaffold and suite registration | M, 2 to 3 | |
| M2 | Host read MVP | L, 5 to 6 | |
| M3 | Docker read MVP | L, 4 to 5 | |
| M4 | MVP actions and safety | L, 5 to 6 | **MVP preview** |
| F5 | v1 extractions (parallel with M5 and M6) | 13 to 22 (sum of F5a to F5f) | |
| M5 | v1 part 1: editing, shells and sync writes | L to XL, 7 to 9 | |
| M6 | v1 part 2: breadth | XL, 8 to 10 | |
| M7 | v1 hardening and release readiness | M, 3 | **v1 public** |
| M8 | v1.x | Increments, XL in total | v1.x |
| M9 | Later (owner decisions first) | Not estimated | Later |
| F7 | Séance on the catalog library | L, after v1 | |

The MVP path (M0 to M4, including F1 to F4) comes to about 39 to 52
engineer-weeks [E]; with two contributors in parallel tracks the preview is
roughly 6 to 7 months out [E]. v1 adds about 31 to 44 engineer-weeks [E].
Cutting a release is a separate explicit task.

## Name

The name is undecided; the chapters use `<App>` (display name) and `<app>`
(lowercase ASCII stem). [05-NAMES.md](05-NAMES.md#2-recommendation)
recommends:

| Choice | Name | Language | Function pun | Conflict risk |
|---|---|---|---|---|
| First | Hausgeist | German | House spirit that watches the house and does the chores | Low |
| Alternate 1 | Voyant | French | Seer, and a dashboard warning light | Medium (crowded name) |
| Alternate 2 | Klabautermann | German, Frisian, Dutch | Ship spirit that tends cargo and knocks to warn | Low (long, hard to spell) |

This is a collision screen, not trademark clearance: no EU, German or
French register query ran and no domain was checked
([05 §8](05-NAMES.md#8-checks-still-required-before-committing)).

## Open questions for the owner

The most important of the 20 in
[04 §15](04-IMPLEMENTATION.md#15-open-questions-for-the-owner), with their
numbers there:

- **Q1** Name and identities, including Windows `CompanyName`.
- **Q2** Accept F1 to F4 (about 18 to 25 engineer-weeks [E]) before the
  scaffold, in exchange for no third copies?
- **Q3** Approve the recommended catalog divergence resolutions (03 §4.4).
- **Q4** Accept a pull-only MVP that cannot edit servers (D14)?
- **Q6** Are operation records, central backups, the syslog line and the
  manifest acceptable host writes?
- **Q7** Approve T1 for v1.x, user scope by default?
- **Q8** Is an always-on companion (T2) wanted at all?
- **Q9** One record kind with typed sub-records and a 1 MiB prefix budget
  (D17)?
- **Q12** Keep host-key publication disabled until Séance #56 lands (D15)?
- **Q15** Path-filter the new client matrix on PRs; privileged DinD in CI?
- **Q16** Ship the MVP in suite releases labelled preview, or wait for v1?
- **Q17** Start the suite-wide dartssh2 4.x re-pin in parallel?

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
- **`<App>` and `<app>`** are placeholders until the name is chosen.
- Feature IDs such as STK-06 refer to 02; D1 to D40 and F1a to F7 to 03;
  spikes, milestones, risks and open questions to 04. Section numbers run
  on from 03 (1 to 11) into 04 (12 to 15, Appendices A to C).
