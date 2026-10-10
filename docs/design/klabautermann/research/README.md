# Server app research appendices

These nine reports are the research input for the server app plan in
[../README.md](../README.md). Five survey the external landscape and the
technical ground (r1 to r5); four read the Hauntware codebase (c1 to c4).
[../01-RESEARCH.md](../01-RESEARCH.md) condenses them into one chapter.

The reports are imported as captured and are not maintained. Corrections and
decisions live in the plan chapters (01 to 05). Where a report disagrees with
another report or with a plan chapter, the plan chapter wins;
01-RESEARCH.md lists the disagreements that matter.

## Freshness caveat

- External facts (versions, release dates, prices, licenses, star counts,
  CVEs, platform limits) reflect what the sources said on **2026-10-10**.
- Codebase facts (paths, `file:line` citations, line counts, behaviour)
  reflect commit **`bf1da58`** on main. Line numbers drift as main moves;
  re-check a citation before relying on it.
- Claims a report marked as unverified, secondary or prior knowledge were not
  re-verified during import.

## Index

| Key | File | Scope | Description |
|---|---|---|---|
| r1 | [r1-docker-managers.md](r1-docker-managers.md) | External: Docker and container managers | Dockhand (owner's reference), Portainer, Dockge, Komodo, Arcane, Dozzle, lazydocker, ctop, Docker Desktop, OrbStack, Podman Desktop, Cockpit, update notifiers, mobile Docker clients. Connection taxonomy, consolidated feature matrix, table stakes versus differentiators, and what a client-only SSH app can and cannot do. |
| r2 | [r2-selfhost-platforms.md](r2-selfhost-platforms.md) | External: self-hosting platforms, PaaS, home-server OSes, NAS apps | Coolify, Dokploy, CapRover, Easypanel, Dokku, Kamal, Cosmos, CasaOS and ZimaOS, Umbrel, Runtipi, YunoHost, Cloudron, Unraid, TrueNAS, Synology, 1Panel. Footprint matrix, agentless verdicts per feature, tiering, UX lessons, pitfalls and catalog licensing. |
| r3 | [r3-server-panels-monitoring.md](r3-server-panels-monitoring.md) | External: server panels and monitoring | Cockpit deep dive, Webmin, Ajenti, 1Panel, aaPanel, CloudPanel, HestiaCP, Netdata, Glances, Beszel, Uptime Kuma, Gatus, Prometheus, Zabbix, Checkmk, Pulse, Scrutiny, Monit, job schedulers, log and security tools, native SSH monitors. Per-subsystem feature inventory with agentless data sources. |
| r4 | [r4-native-mobile-clients.md](r4-native-mobile-clients.md) | External: native desktop, mobile and TUI clients | ServerBox studied from source, ServerCat, NeoServer, ServerBuddy, XPipe, Termius and Termix, iOS terminal apps, Android options, iStat, Cockpit Client, k9s and other TUIs, Lens, local container desktops. UX patterns, mobile platform limits, agentless command catalog, market gaps. |
| r5 | [r5-technical-feasibility.md](r5-technical-feasibility.md) | Technical feasibility | Docker Engine API over SSH Unix-socket forwarding, dartssh2 3.0.2 capabilities, API version negotiation, compose, agentless Linux metric sources and tool versions, sampler and transport design, `MaxSessions`, privilege (sudo, sudo-rs, polkit), watcher options, mobile background limits, security. |
| c1 | [c1-catalog-sync.md](c1-catalog-sync.md) | Codebase: server catalog and sync | How Séance and Poltergeist store and sync `ServerConfig`, what a fourth app must reuse, adding record kinds without a protocol bump, the two diverging coordinators, the proposed catalog extraction, security constraints. |
| c2 | [c2-ssh-exec-terminal.md](c2-ssh-exec-terminal.md) | Codebase: SSH, exec and terminal | `openAuthenticatedClient`, `runCommand`, the RemoteGit precedent, Poltergeist's pool rules, terminal seams, the dartssh2 pin and its defects, the import guard, an sshd plus Docker fixture, gaps and risks. |
| c3 | [c3-shared-ui-app-shells.md](c3-shared-ui-app-shells.md) | Codebase: shared UI and app shells | The shared `ghost_*` and `planchette_*` packages, duplicated server-list pieces, state architectures, localization, theming, an app-shell skeleton, the extraction plan, chart, table and log-viewer gaps. |
| c4 | [c4-suite-infra.md](c4-suite-infra.md) | Codebase: suite infrastructure | Every root script, release-tool list, workflow, guard and platform identity a new product must touch, suite conventions, history-checker constraints, directory layout, CI and release cost. |

## Abbreviation key

- **r1 to r5** are the external and technical reports, **c1 to c4** the
  codebase reports, as in the index. The report titles use upper case (R1,
  C1); the plan uses lower case.
- In-text markers such as `[R: r5 §5.4]`, `r2 §6.4` or `c1 §2.3` point to a
  report and a section number inside it.
- Some reports number their own items, and those numbers reuse the same
  letters: c2 has gaps G1 to G16 and risks R1 to R18; c4 has checklist items
  S, R, W, C, D, P and G. The plan always qualifies them with the report,
  for example "c2 R3" or "c4 R1". A bare "r3" is always the report.
- c4 writes the new product's stem and display name as `<prod>` and
  `<Prod>`; the plan uses `<app>` and `<App>` for the same placeholders.

## Marker legend used in the reports

Each report kept its own conventions. All of them cite repository files as
`path:line` at `bf1da58` and name external sources inline or in a closing
source list.

| Report | Markers |
|---|---|
| r1 | Feature tables: **Y** has it, **P** partial or limited, **-** no or not found, **BE**, **Ent**, **Pro** paid tier only, **?** could not verify (not "absent"). "Not verified" or "from my knowledge" marks a lead, "(secondary)" a non-primary source. |
| r2 | **[verified]** read from a primary source, **[secondary]** third-party or vendor-marketing source, **[prior knowledge, unverified]** background knowledge not re-checked. Agentless verdicts: **A** agentless while the app is open, **H** host-native delegation (timers, cron, restart policies) with no daemon, **D** needs a resident component, **X** out of scope. Two-letter platform codes are defined in its section 1. |
| r3 | "(unverified)" marks a secondary source or a claim from product knowledge rather than a fetched page; some such claims say "(product knowledge)" instead. The Class column grades features as Table stakes, Differentiator, Nice to have, Expert or Niche. Tool codes are defined in its section 4. |
| r4 | Command catalog sources: **[SB]** ServerBox `sbm_parser` source, **[TX]** Termix docs, **[GEN]** common practice not verified in a surveyed tool's source. "(secondary)" and a closing list of unverified items. |
| r5 | **[V-src]** verified in source code, **[V-doc]** verified in official documentation or a spec, **[V-repo]** verified in the Hauntware repository, **[U]** unverified (a hypothesis for a spike), "measured" for figures from a 4-vCPU test VM, "[design choice]" for proposals. |
| c1 | Path abbreviations `SP`, `SC`, `SRV`, `SA`, `PC`, `PA` and `P04`, defined at its top. Every claim cites a file and line range; doc and code drift is listed in its section 5. |
| c2 | Home key for gaps: **SC** upstream into `seance_core`, **NC** new product core package, **UI** shared Flutter package, **APP** the app. "unverified" marks OpenSSH behaviour not checked against a man page. No Dart tooling was run. |
| c3 | Duplication counts come from `diff -w` and are approximate. No Flutter SDK was run. |
| c4 | Checklist IDs by area: **S** root scripts, **R** release tool, **W** release workflow, **C** repo config, **D** root docs, **P** packaging, **G** signing and identities. Live GitHub figures are dated 2026-10-10. |

The plan chapters use a smaller set, defined at the top of
[../03-ARCHITECTURE.md](../03-ARCHITECTURE.md): **[V]** verified in the
repository at `bf1da58`, **[L]** verified by a local experiment, **[R]**
taken from a research report or review without re-verification, **[U]**
unverified and settled by a named spike, **[E]** estimate or design value.
