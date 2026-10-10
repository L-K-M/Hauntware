# R3: Server administration panels and monitoring/observability tools

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Research date: 2026-10-10. Versions and dates were taken from primary sources
(project sites, docs, READMEs, release pages, source code) at that date unless
noted. Where a source was secondary or a claim comes from product knowledge
rather than a fetched page, it is marked "(unverified)".

Purpose: feature inventory and design insights for a fourth Hauntware app, a
native, agentless-first (SSH via dartssh2) server management, observability
and Docker tool that shares the synced `ServerConfig` server list with Seance
and Poltergeist. Docker UIs are covered in R1; this report touches Docker only
where monitoring tools include it.

---

## 1. Executive summary

1. **Agentless over SSH is a proven model, and the best-known one bootstraps
   code over stdin.** Cockpit's "beiboot" runs `python3 -ic` on the remote host
   over OpenSSH and streams its bridge into it, so nothing has to be installed.
   The cost is a Python 3.6+ requirement, which rules out hosts like Fedora
   CoreOS. Checkmk's agent is a plain shell script that prints `<<<section>>>`
   blocks. ServerBox, the closest Flutter competitor and also built on dartssh2,
   generates a status script and parses it by section keys. **Recommendation:**
   use one POSIX `sh` probe script per refresh, sent over an exec channel, that
   prints delimited sections. Parse them in Dart and do not depend on Python.
2. **Cockpit deprecated its own multi-host feature in v322.** All hosts' code
   ran in one browser origin with no isolation, so connected hosts "can control
   each other" (v329 warning). A native client isolates each host by
   construction. A fleet view is a structural advantage over the reference
   agentless tool.
3. **Privilege handling is the hardest UX problem.** Cockpit's model is a
   normal session plus an explicit, remembered "Administrative access" toggle
   that elevates through `sudo` with an askpass helper. In v355 (Jan 2026) it
   added a polkit/systemd `StartTransientUnit` fallback (the run0 mechanism)
   because `sudo-rs`, the default on Ubuntu 25.10, was incompatible with its
   askpass usage. Plan for sudo, sudo-rs, doas and run0 from day one, and
   detect NOPASSWD.
4. **History and alerts need something that runs while the app is closed.**
   Every alerting tool has a resident component: Beszel hub plus agent, Netdata
   agent, Zabbix/Checkmk server, Uptime Kuma or Gatus server, ServerBox's
   optional "ServerBox Monitor" agent. Three agentless options:
   - Read the host's existing recorders: sysstat `sar` via `sadf -j`, PCP
     pmlogger archives (Cockpit's history source), atop logs, journald.
   - Offer an optional, non-interactive collector, like Beszel's agent, whose
     SSH server provides no shell or PTY.
   - Let a hub poll over SSH, as Beszel's SSH mode, Zabbix `ssh.run` and the
     Checkmk SSH datasource do. This is in tension with Seance's E2E-encrypted
     sync server: the hub would need credentials.
5. **Table stakes for a native SSH monitor**, set by ServerBox, ServerCat,
   Cockpit and Beszel:
   - live CPU (per core), memory/swap, disk usage and I/O, network, load and
     uptime
   - a process list with kill
   - systemd services with start/stop/restart and their logs
   - a journal viewer with filters and follow
   - SMART, temperatures and GPU
   - Docker container list, stats and logs
   - a terminal hand-off
6. **Differentiators are rare even in big tools:**
   - PSI pressure plus iowait/steal "why is it slow" triage
   - listening ports mapped to their owning process and to firewall rules
   - an ncdu-style largest-files explorer
   - a **unified scheduled-jobs view**: user crontabs, `/etc/cron.*`, systemd
     timers and anacron, with last/next run, captured output, human-readable
     schedules and dead-man monitoring
   - an update center with security updates, reboot-required and services
     needing restart
   - SSH login audit and authorized_keys inventory across the fleet
   - TLS expiry for endpoints *and* local certificate files
   - boot history with unclean-shutdown detection
   - fleet-wide compliance tables (kernel, pending updates, Lynis hardening
     index)
7. **Hosting panels are a different product.** 1Panel, aaPanel, CloudPanel and
   HestiaCP focus on websites, databases, mail, DNS, app stores and WAF. Do not
   compete there. Borrow their host-management sub-features: cron with run
   history, firewall, SSH config and login logs, process manager, Fail2ban and
   ClamAV toolbox.
8. **Security lessons from 2026:**
   - Cockpit CVE-2026-4631 (fixed in 360, Apr 2026): an unauthenticated RCE
     through SSH argument and `%r` token injection from unvalidated hostnames
     and usernames.
   - Netdata fixed a privilege escalation in its setuid `ndsudo` helper (2.10.4).
   - Lessons: shell-quote every interpolated unit name, path and user, and
     validate host and user strings. Never install setuid helpers. Any agent we
     ship must be non-interactive.

---

## 2. Architecture taxonomy

| Pattern | Examples | How data moves | Fit for Hauntware |
|---|---|---|---|
| Agentless, CLI over SSH, parse text/JSON | ServerBox, ServerCat, Zabbix `ssh.run`, Checkmk "individual program call" via ssh, Gatus `ssh://` checks, lazyjournal remote | Client opens SSH, runs commands, parses stdout | Primary model. Zero install, works with existing `ServerConfig`, jump hosts and keys |
| Agentless, code bootstrapped over SSH stdin | Cockpit beiboot (Python bridge), Cockpit Client flatpak | Ships an interpreter-hosted bridge per session; JSON channel protocol over stdin/stdout | Powerful but needs Python on host; Dart cannot be shipped this way. Could ship a static helper binary as an optional "turbo" mode |
| Installed web panel running as root | Webmin (Perl), Ajenti (Python), 1Panel (Go core+agent), aaPanel, CloudPanel, HestiaCP | Browser to panel on host | Not our model; feature reference only |
| Agent on host, central server pulls | Prometheus/node_exporter, Checkmk agent controller (TCP 6556, TLS), Zabbix passive agent, Beszel SSH mode (hub to agent:45876) | Server scrapes agent | Optional agent mode later; Beszel shows an agent can expose a *non-shell* SSH endpoint |
| Agent on host pushes to hub | Beszel WebSocket mode, Netdata streaming to parents, Checkmk push (Ultimate), Zabbix active, Dockhand Hawser, ServerBox Monitor, Pulse unified agent | Agent dials out (NAT friendly) | Needed for alerts/history when no client is open; could reuse sync server infrastructure |
| Heartbeat/push from jobs | Healthchecks, Uptime Kuma push monitors, Gatus external endpoints | Job pings URL on start/success/fail | Dead-man switch for cron; could be offered via sync server or third-party HC |

---

## 3. Tool profiles

### 3.1 Cockpit (deep dive)

- **What:** Red Hat-sponsored web console for Linux servers. Default on
  RHEL/Fedora and packaged widely.
  - Recent releases: 366 (2026-08-13), 363 (2026-06-04), 360 (2026-04-08,
    CVE-2026-4631 fix) and 358 (2026-03-18). In 358 Cockpit Client moved to
    GTK 4 and Networking gained Wi-Fi.
  - 355 (2026-01-29) added the polkit/transient-unit root bridge fallback.
- **License:** multi-licensed, primarily LGPL-2.1-or-later. The Python bridge
  files carry GPL-3.0-or-later.
- **Architecture:**
  - **cockpit-ws** is the web server and WebSocket endpoint. **cockpit-bridge**
    runs as the logged-in user and speaks a framed JSON protocol over
    stdin/stdout.
  - The protocol has a control channel (`init`, `open`, `close`, `ready`,
    `done`, `ping`, `authorize`, `kill`) and payload channels:
    - `stream` (spawn a process or connect a socket)
    - `dbus-json3` (D-Bus as JSON, used for systemd, NetworkManager, UDisks
      and PackageKit)
    - `http-stream2`, `websocket-stream1` and `packet`
    - `fsinfo`, `fsread1` and `fsreplace1` (file read and atomic replace with
      transaction tags)
    - `metrics1` (PCP metrics: live, `pmcd`, or pmlogger archives, sampled at a
      default 1000 ms)
  - `open` accepts `host` (route to another machine), `superuser`
    (`require`/`try`), flow control, and `send-acks`.
  - Most of the UI is thin JavaScript over D-Bus APIs. The services page talks
    to systemd over D-Bus; logs come from `journalctl` via `stream`.
- **Connecting to other hosts over SSH:**
  - Older versions used `cockpit-ssh` (libssh).
  - Since about 326/327, `python3 -m cockpit.beiboot` invokes the OpenSSH
    client. It sends a first-stage bootloader that either `exec`s an installed
    `cockpit-bridge` or receives the bridge code over the SSH stdin ("beipack")
    and runs it in `python3 -ic`. The `remote_bridge` modes are `auto`,
    `always`, `supported` and `never`.
  - Host-key and password prompts are relayed through a "ferny" askpass
    interaction agent. The beiboot source has explicit handling for the
    changed OpenSSH 10.2p1 host-key prompt text.
  - Requirements on the remote are SSH, a user account and Python ≥ 3.6. Sudo
    is needed only for privileged operations.
  - Cockpit Client (flatpak) bundles machines, podman, ostree, storaged,
    sosreport, selinux, packagekit, networkmanager and kdump. It cannot mix
    bundled pages with pages installed on the target.
- **Superuser handling:**
  - The session starts unprivileged with the same rights as SSH. An
    "Administrative access" indicator lets the user gain or drop root, and the
    choice is remembered for the next login.
  - The privileged bridge is a second bridge started through a configured
    superuser rule: `sudo` with `SUDO_ASKPASS` pointing at a ferny askpass
    helper, so prompts surface in the UI.
  - Sudo is validated for askpass support; an incompatible sudo such as
    sudo-rs is ignored. The fallback is polkit-guarded systemd
    `StartTransientUnit` running the bridge as root, the same mechanism as
    `run0`.
  - NOPASSWD sudo means no prompt. The login password can optionally be cached
    for escalation.
  - Fine-grained restriction is weak. Red Hat says granting the root bridge
    equals full root, though polkit rules (`manage-units` with unit/verb
    details) can scope service actions.
- **Modules:**
  - Overview: health, usage, system information and configuration. The
    configuration card covers hostname, time/NTP, domain join, crypto policy,
    SSH host keys and power.
  - Logs: the journal by priority, identifier, time and boot, with a text
    filter.
  - Storage: partitions, LVM, RAID, LUKS, NFS, iSCSI and Stratis.
  - Networking: interfaces, bonds, bridges, VLANs, firewalld zones and Wi-Fi.
  - Podman containers and Virtual Machines (libvirt).
  - Accounts: create, delete, lock, password, account/password expiry, groups,
    authorized SSH keys and terminating sessions.
  - Services: systemd services, targets, sockets, timers and paths for system
    and user units. Includes start/stop/restart/enable, unit relationships,
    per-unit logs and creating timers.
  - Software Updates: PackageKit for RPM/DEB and OSTree. Tracer, or
    `dnf needs-restarting`/`zypper ps`, suggests service restarts or a reboot.
  - Applications, Diagnostic Reports (sos), Kernel Dump (kdump) and SELinux
    (troubleshooting alerts and rule export).
  - Terminal and Files (a new file browser).
  - Metrics and history: PCP-backed. "Enable PCP metrics collector" starts
    `pmlogger`; without PCP there is live data only.
- **Third-party apps** (cockpit-project.org/applications):
  - monitoring and system: Sensors (lm-sensors), Cockpit Top (btop-style
    processes and container stats), ZFS Manager, Benchmark, SCAP Compliance
    (OpenSCAP)
  - packages and access: Package Manager, Pacman, Sudo Manager
  - containers: Docker Manager, Docker Compose, systemd-nspawn
  - networking: File Sharing, Port Forward Manager, Tailscale, Cloudflare
    Tunnels
  - backups: Hangar (restic and ReaR backups)
- **UX worth copying:**
  - The health card summarizes failed units, available updates and
    reboot-needed in one place.
  - Logs appear in context on service, storage and network pages.
  - Service detail shows relationships (Requires, Wants, After and so on) plus
    the unit's recent journal.
  - Timer creation uses a friendly calendar UI.
  - Administrative access is a visible, explicit, remembered mode.
  - Graceful degradation: a page is hidden when its backing package (such as
    libvirt-dbus) is missing.
- **Gaps:**
  - multi-host deprecated (322) for lack of isolation; a warning was added in
    329
  - Python required; no alerting or notifications
  - no listening-ports view; no cron (crontab) management, only timers
  - no disk usage explorer; no fleet dashboard (the old dashboard was removed)
  - no historical data without PCP

Sources:
- https://cockpit-project.org/applications
- https://raw.githubusercontent.com/cockpit-project/cockpit/main/doc/protocol.md
- https://github.com/cockpit-project/cockpit/blob/main/src/cockpit/beiboot.py
- https://github.com/cockpit-project/cockpit/blob/main/src/cockpit/superuser.py
- https://fedoramagazine.org/using-cockpit-to-graphically-manage-systems-without-installing-cockpit-on-them/ (2023-08-16)
- https://cockpit-project.org/blog/cockpit-295.html
- https://cockpit-project.org/blog/cockpit-355.html
- https://cockpit-project.org/blog/cockpit-329.html
- https://cockpit-project.org/blog/cockpit-238.html
- https://cockpit-project.org/blog/
- https://docs.cockpit-project.org/cockpit-guide/362/guide/privileges.html
- https://docs.cockpit-project.org/cockpit-guide/362/guide/feature-systemd.html
- https://docs.cockpit-project.org/cockpit-guide/362/guide/feature-pcp.html
- https://docs.cockpit-project.org/cockpit-guide/362/guide/multi-host.html
- https://seclists.org/oss-sec/2026/q2/88
- https://docs.oracle.com/en/operating-systems/oracle-linux/cockpit/cockpit-services.html
- https://docs.oracle.com/en/operating-systems/oracle-linux/cockpit/cockpit-usermanage.html

### 3.2 Webmin

- **What:** the veteran web admin panel for Unix. Webmin 2.670 and Usermin
  2.570 shipped 2026-09-20, Virtualmin 8.3.0 on 2026-09-29.
- **License:** BSD-3-Clause.
- **Architecture:** a Perl web server (`miniserv.pl`) running as root, default
  port 10000 (product knowledge). It has 116 standard modules and at least as
  many third-party ones.
  - Cluster modules for multiple servers: cluster-copy, cluster-cron,
    cluster-passwd, cluster-shell, cluster-software, cluster-useradmin,
    cluster-usermin, cluster-webmin.
  - Remote Webmin servers are reached via Webmin RPC.
- **Standout features:**
  - Breadth: Systemd Services and Units; Bootup and Shutdown; System Logs;
    Hardware Information; SMART Status.
  - Disk Quotas (incl. Btrfs) and ZFS usage.
  - Firewalls: nftables, firewalld, Linux iptables; plus Fail2Ban.
  - Package management: Software Packages, and Package Updates for APT/DNF
    with holds.
  - Users and Groups; Scheduled Cron Jobs; Running Processes; File Manager;
    Terminal; Let's Encrypt via Certbot.
  - Plus Apache/Nginx/BIND/MySQL/PostgreSQL/Postfix/Dovecot.
  - "System and Server Status" schedules monitors: services, free memory, load,
    disk space, remote TCP/HTTP/ping. They run from cron and alert by email or
    pager. Commands can run on down or up, either locally or on the remote
    host.
- **UX worth copying:**
  - The cron module lists every user's jobs and system jobs together.
  - Each job can be enabled or disabled without deleting it, with "run now"
    and a simple schedule picker (product knowledge).
  - Monitors offer "run command when down / when back up".
- **Gaps:** a dated interaction model, root web server exposure, no real-time
  charts or history, and form-heavy UX.

Sources:
- https://webmin.com/
- https://github.com/webmin/webmin
- https://webmin.com/docs/modules/system-and-server-status/

### 3.3 Ajenti

- **What:** a modular admin panel for Linux and BSD with a Python 3 backend and
  AngularJS frontend. Ajenti 3 work (Angular, socketio, REST) is in progress on
  the `ajenti-3-dev` branch. About 8k stars.
- **License:** MIT.
- **Architecture:** a pip-installable panel on the host with Python plugins.
- **Standout features:** it edits existing config non-destructively, keeping
  comments, and has a responsive mobile UI with a low footprint.
- **Gaps:** slow evolution, and the release cadence is unclear from the repo
  page.

Source: https://github.com/ajenti/ajenti

### 3.4 1Panel

- **What:** a "modern open-source Linux server management panel and lightweight
  AI management platform". v2.3.2 shipped 2026-09-24; about 37.1k stars.
- **License:** GPL-3.0.
- **Architecture:** repo split into `core` and `agent`. Apps are deployed as
  containers. Multi-node management is Pro/Ent; v2.2.4 to v2.3.0 added node
  health checks, version mismatch prompts and node auth hardening.
- **Feature areas:**
  - App Store; AI (agents, models, vLLM, AI gateway, MCP, GPU monitor);
    websites with OpenResty and SSL/ACME.
  - Runtimes (PHP, Node, Java, Go, Python, .NET); databases (MySQL,
    PostgreSQL, Redis).
  - Containers: containers, compose, images, networks, volumes, registries,
    templates.
  - **System:** files, monitor, firewall (rebuilt in v2.3.0), process manager
    (runtime diagnostics in v2.2.4) and SSH management.
  - Terminal with session preservation and recovery (v2.3.0).
  - **Cron jobs** with execution durations and run records, typed jobs such as
    script, backup and log cutting.
  - Toolbox (Supervisor, ClamAV virus scan, FTP, Fail2ban); WAF; anti-tamper.
  - **Log Audit**, including a host system log viewer (v2.2.4).
- **UX worth copying:**
  - Cron jobs are first-class objects with history and logs per run.
  - The SSH management page brings together port, root login, password/key
    auth and login logs.
  - Fail2ban and ClamAV appear as "toolbox" items.
- **Gaps:** a web panel on the host and hosting-centric. Multi-node is paid.

Sources:
- https://github.com/1Panel-dev/1Panel
- https://1panel.pro/docs/v2/
- https://1panel.pro/docs/v2/changelog/

### 3.5 aaPanel

- **What:** a free hosting control panel (BT Panel's international edition)
  claiming 3M+ installs. Pro adds WAF, multi-user and analytics. Supports
  Ubuntu, Debian, CentOS, Alma, Rocky and OpenEuler.
- **License:** described as free and open source, but no license is named on
  the site.
- **Features:**
  - real-time CPU/memory/disk/traffic/service status with alerts
  - scheduled tasks, including backups to FTP or cloud
  - firewall, malware scan and WAF
  - Docker manager (containers, images, compose)
  - 200+ one-click apps, file manager and an optional AI assistant
- **Gaps:** hosting-centric. Logs are not a standalone feature.

Source: https://www.aapanel.com/

### 3.6 CloudPanel

- **What:** a simple panel for PHP, Node.js, Python, static sites and reverse
  proxies, with Varnish integration and the `clpctl` CLI. v2.5.4 adds Ubuntu
  26.04 support; Debian 11 to 13 and Ubuntu 22.04 to 26.04 on x86 and ARM.
- **License:** free, but license terms are not clearly published; secondary
  sources call it open source.
- **Features:** sites, vhosts, databases, SSL, file manager, per-site cron
  jobs and logs, security (IP/bot blocking), and backups.
- **Gaps:** host monitoring is minimal. Single-purpose.

Sources:
- https://www.cloudpanel.io/docs/v2/introduction/
- https://www.cloudpanel.io/blog/cloudpanel-v2-5-4-release/

### 3.7 HestiaCP

- **What:** a VestaCP-derived hosting panel with both web UI and CLI. Latest
  stable is 1.10.5, on Debian 11 to 13 and Ubuntu 22.04 to 26.04.
- **License:** GPL-3.0, with trademark restrictions on the name.
- **Features:** Apache/NGINX with PHP-FPM 5.6 to 8.5, BIND clustering, mail
  (ClamAV/SpamAssassin/Roundcube), MariaDB/PostgreSQL, Let's Encrypt
  wildcard, and a firewall built on iptables, fail2ban and ipset.
- **Insight:** Everything is exposed as `v-*` CLI commands (product knowledge),
  which makes it scriptable over SSH. A native client could wrap them as an
  integration.

Source: https://github.com/hestiacp/hestiacp

### 3.8 Netdata

- **What:** a per-second, zero-config monitoring agent with ML anomaly
  detection, parents for centralization, and optional Netdata Cloud. The 2.x
  line is current: 2.9.0 (2026-02), 2.10.x mid-2026, and 2.11.0 released per
  Debian tracker.
- **License:** the Agent is GPL-3.0+. The dashboard UI is under the
  proprietary **NCUL1** license.
- **Architecture:**
  - The agent collects, stores, learns, alerts, streams and exports.
  - Tiered storage: tier 0 per-second, tier 1 per-minute, tier 2 per-hour, at
    about 0.5 bytes per sample with ZSTD.
  - It uses about 5% CPU and 150 MiB RAM by default.
- **Standout "Functions"** (live on-demand views):
  - Processes and Network-connections (per-process, Cloud-gated).
  - Systemd-list-units (Cloud-gated) and Systemd-services (cgroup resources).
  - Mount-points (space and inodes), Block-devices, Network-interfaces.
  - Containers-vms and Ipmi-sensors.
- **systemd journal explorer:**
  - facets with live counts and include/exclude
  - a timeline histogram plus per-field histograms
  - full-text search with `*`, `|` and `!`
  - PLAY mode, which is a live tail
  - sampling for large journals: the newest 500k entries are evaluated, with
    estimated buckets beyond that
  - a sidebar with all fields and click-to-filter
- **Security note:** CVEs fixed in 2.10.4 include an abusable setuid-root
  `ndsudo` helper.
- **UX worth copying:**
  - the faceted log explorer with a histogram
  - "Functions" as on-demand table views
  - hundreds of preconfigured alerts
  - zoom-aware tier selection
- **Gaps:** heavy, and the UI is not OSI-licensed. Several Functions require
  Cloud. It is an agent, not agentless.

Sources:
- https://github.com/netdata/netdata
- https://learn.netdata.cloud/docs/top-monitoring-netdata-functions
- https://learn.netdata.cloud/docs/logs/systemd-journal-logs/systemd-journal-plugin-reference
- https://tracker.debian.org/pkg/netdata-core
- https://fossies.org/linux/netdata/CHANGELOG.md

### 3.9 Glances

- **What:** a cross-platform top/htop alternative with TUI, Web UI, REST and
  XML-RPC APIs, and exporters (CSV, InfluxDB and more). Glances 4.5.7 shipped
  2026-09-26.
  - It includes an MCP server for AI assistants since 4.5.1.
  - 4.5.5 added GPU meters, container CPU limits, Jetson and Raspberry Pi GPU.
- **License:** LGPL-3.0.
- **Architecture:** a Python process on the host, with client/server mode and
  `--browser` discovery of other Glances servers.
  - Output modes include `--stdout`, `--stdout-csv`, `--stdout-json` and
    `--fetch`.
- **Standout features:**
  - plugins: per-core CPU (incl. iowait, steal, ctx switches), memory/swap,
    load, processes, disk I/O, filesystems, network, sensors, GPU, containers
    (Docker, Podman, LXD), RAID, IP and ports
  - threshold color states: careful, warning, critical
- **UX worth copying:** a single-screen dense summary with color-coded
  thresholds, plus "quicklook" bars.
- **Insight:** if Glances is already installed, `glances --stdout-json` gives a
  structured snapshot in one exec. It can serve as an optional data source.
- **Gaps:** no fleet storage or alerts beyond thresholds and actions.

Sources:
- https://github.com/nicolargo/glances
- https://github.com/nicolargo/glances/releases

### 3.10 Beszel (hub/agent, including an SSH design)

- **What:** a lightweight monitoring hub built on PocketBase, with agents.
  v0.21.0 shipped 2026-10-02:
  - systemd service logs in service details
  - TLS expiry checks in HTTPS network monitors
  - DNS server choice for DNS monitors
  - bandwidth alert units
  - an active-alerts banner
- **Earlier releases:**
  - v0.20.0 (2026-09-19): network monitoring from agents and a container image
    update flag.
  - v0.19.0 (2026-09-03): alerts for failed systemd services, container health
    (with log excerpts), CPU iowait/steal, and ZFS pools and datasets.
- **License:** MIT.
- **Architecture:**
  - **SSH mode (hub initiates):** the Go agent runs a gliderlabs/ssh server on
    `:45876` or a Unix socket. It accepts only the hub's ED25519 public key and
    rejects PTY requests. The agent "does not provide a pseudo-terminal or
    accept input", and idle connections close after 70 s.
  - The hub does *not* verify the agent host key; the docs recommend
    WebSocket mode on untrusted networks.
  - **WebSocket mode (agent initiates):** the agent calls
    `/api/beszel/agent-connect` with a per-system token. The hub proves its
    identity by signing the token, and the agent sends a machine fingerprint.
  - Payloads are CBOR. Metrics come via gopsutil; notifications via Shoutrrr.
  - History is rolled up through tiers 1m → 10m → 20m → 120m → 480m
    (`internal/records/records.go`).
- **Metrics:**
  - CPU, memory (incl. swap and ZFS ARC), disk usage and I/O per device,
    network, load, temperatures, fans
  - GPU (NVIDIA, AMD, Intel), battery, S.M.A.R.T. (incl. eMMC wear and mdraid
    health), ZFS
  - per-container CPU/memory/network history, systemd services, network
    probes
- **UX worth copying:**
  - a fleet dashboard table with inline usage bars and per-system detail pages
  - per-metric alerts with threshold plus duration
  - copying alerts between systems
  - multi-user sharing
- **Insight:** this is the best reference for a lightweight optional collector
  that can be reached *over SSH* without exposing a shell.
- **Gaps:** no management actions (read-only), no logs beyond systemd service
  logs, and no cron.

Sources:
- https://github.com/henrygd/beszel (README)
- https://beszel.dev/guide/security
- https://github.com/henrygd/beszel/releases
- https://github.com/henrygd/beszel/blob/main/agent/server.go
- https://github.com/henrygd/beszel/blob/main/internal/records/records.go

### 3.11 Uptime Kuma

- **What:** a self-hosted uptime monitor. 2.5.6 shipped 2026-10-09; 2.5.4
  (2026-09-11) added an SFTP monitor and new notification providers.
- **License:** MIT.
- **Architecture:** a Node.js server with SQLite/MariaDB.
- **Monitor types:** HTTP(s), keyword, JSON query, TCP, WebSocket, ping, DNS,
  Push, Docker container, game servers and SFTP.
- **Features:** 20 s intervals, 90+ notification services, multiple status
  pages (also on custom domains), certificate info, maintenance, proxies, 2FA.
- **UX worth copying:**
  - heartbeat bars (colored ticks per check)
  - status pages
  - the "Push" monitor as a dead-man switch for jobs
- **Gaps:** no host metrics.

Sources:
- https://github.com/louislam/uptime-kuma
- https://github.com/louislam/uptime-kuma/releases

### 3.12 Gatus

- **What:** a config-driven health and status page.
- **License:** Apache-2.0 (product knowledge).
- **Architecture:** a single Go binary with YAML config, in-memory or SQL
  storage. Supports:
  - **SSH tunnels** (jump hosts) for internal checks
  - `ssh://` endpoints
  - "external endpoints" that receive pushed results
  - experimental remote instances
- **Standout features:** the condition language, for example:
  - `[STATUS] == 200` and `[RESPONSE_TIME] < 500`
  - `[BODY].path == pat(...)`
  - `[CERTIFICATE_EXPIRATION] > 48h` and `[DOMAIN_EXPIRATION] > 720h`
  - `[DNS_RCODE]`
  - It also has maintenance windows (global and per-endpoint, with timezone
    and weekdays), many alert providers and badges.
- **UX worth copying:** declarative checks with readable conditions, and
  per-endpoint maintenance windows.

Source: https://github.com/TwiN/gatus

### 3.13 Prometheus + node_exporter + Grafana

- **What:** the de facto metrics stack. Prometheus 3.x (3.13.x current per
  secondary sources); node_exporter 1.10.2, with 1.11 and 1.12 seen; Grafana 13
  (GrafanaCON, Apr 2026: Git Sync GA, Grafana Advisor).
- **License:** Prometheus and node_exporter Apache-2.0; Grafana AGPL-3.0.
- **Architecture:** a pull-based TSDB scraping `/metrics` from exporters, with
  Alertmanager for routing.
- **node_exporter default collectors include:**
  - CPU and memory: cpu, cpufreq, loadavg, meminfo, vmstat, stat, schedstat,
    edac
  - storage: diskstats, filesystem, mdadm, nvme, btrfs, xfs, zfs, bcache
  - network: netdev, netstat, netclass, sockstat, softnet, conntrack, arp
  - **pressure** (PSI)
  - sensors and power: hwmon, thermal_zone, powersupplyclass, rapl
  - system: os, uname, time, timex, boottime, kernel_hung, selinux, watchdog,
    filefd, entropy
  - textfile (lets a cron job publish arbitrary metrics, e.g. apt updates)
- **Opt-in collectors:** systemd, processes, ethtool, interrupts, tcpstat,
  cgroups, drm, wifi, logind, perf, mountstats, cpu_vulnerabilities and more.
- **UX worth copying:** the "Node Exporter Full" style dashboard, with dense
  panels grouped by subsystem (product knowledge).
- **Insight:**
  - The collector list is a good checklist of Linux signals worth surfacing.
  - If node_exporter is already running, the client can read
    `curl -s localhost:9100/metrics` over SSH as a rich, cheap data source.
- **Gaps:** heavy to operate, with no management actions.

Sources:
- https://github.com/prometheus/node_exporter
- https://grafana.com/blog/grafana-13-release-all-the-latest-features/
- https://endoflife.ai/prometheus/3.0

### 3.14 Zabbix

- **What:** an enterprise monitoring server with agents and proxies. The
  current docs are 7.4. 8.0 LTS is targeted for Q3 2026 (beta 2 shipped
  2026-07-09); verify GA.
- **License:** AGPL-3.0 since 7.0; GPLv2 through 6.4.
- **Architecture:**
  - server, proxies and agent/agent2 (Go plugins), plus agentless SNMP, IPMI
    and HTTP checks
  - **SSH checks:** `ssh.run[description,<ip>,<port>,<encoding>,<ssh
    options>,<subsystem>]` with password or key auth
  - SSH check limits: libssh2 may truncate scripts to about 32 kB, and output
    is capped at 16 MB
- **Standout features:** templates (e.g. "Linux by Zabbix agent"), triggers
  with hysteresis, maintenance periods, problem acknowledgement and escalation,
  and `nodata()` triggers that act as dead-man switches (product knowledge).
- **UX worth copying:** problem lifecycle (open, acknowledged, resolved) and
  maintenance periods that suppress alerts.
- **Gaps:** complexity and dated UX.

Sources:
- https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/ssh_checks
- https://blog.zabbix.com/striking-the-right-balance-zabbix-7-0-to-be-released-under-agplv3-license/
- https://www.zabbix.com/life_cycle_and_release_policy

### 3.15 Checkmk

- **What:** a monitoring platform with auto-discovery of services. Current
  docs are for 2.5.0 (agent package 2.5.0p15). Editions in the docs are
  "Community" and "Ultimate".
- **License:** the Community edition is GPL (product knowledge); commercial
  editions are proprietary.
- **Architecture:**
  - `check_mk_agent` is a **shell script** run as root that prints
    `<<<section>>>` blocks, with 30+ sections by default.
  - `cmk-agent-ctl` handles transport: pull on TCP 6556 with TLS and
    registration, or push in Ultimate.
  - In legacy mode it is a plain script via xinetd.
  - Plugins are executable files in `/usr/lib/check_mk_agent/plugins`; a
    numeric subdirectory makes them async with caching.
  - Local checks live in `.../local`; Nagios plugins run via MRPE.
  - The community invokes the agent over SSH through an "individual program
    call" datasource (`ssh ... check_mk_agent`), often with a forced command
    in authorized_keys. The 2.0 docs documented this; current docs do not
    feature it.
- **Insight:** this is the strongest precedent for our design: **one script,
  one exec, many sections**. The forced-command trick can restrict a
  monitoring key to the probe script.
- **Gaps:** heavy server; the UX is for NOC teams.

Sources:
- https://docs.checkmk.com/latest/en/agent_linux.html
- https://forum.checkmk.com/t/access-agent-over-ssh/24650

### 3.16 Pulse (rcourtman)

- **What:** a self-hosted monitoring workspace for Proxmox VE/PBS/PMG, Docker
  and Podman, Kubernetes, TrueNAS, Linux/Windows/macOS machines, and vSphere
  (early access), using a "unified agent".
  - "Patrol" runs scheduled checks over current state and history: failed
    backups, capacity pressure, restart loops, unhealthy containers, clock
    drift.
  - Optional AI (local or bring-your-own provider) gives watch-only analysis.
    Pro adds policy-bound fixes with approval and an audit trail.
  - It includes an MCP adapter.
- **License:** MIT.
- **UX worth copying:**
  - an "attention queue" of problems instead of charts
  - agent commands disabled by default
  - governed actions with approval and audit
  - backups and recovery shown next to the resources they protect

Source: https://github.com/rcourtman/Pulse

### 3.17 Scrutiny

- **What:** a WebUI for smartd S.M.A.R.T. monitoring. A collector uses
  `smartctl --scan` and `smartctl` JSON; the web/API stores history in
  InfluxDB. It runs as an omnibus image or hub/spoke.
- **License:** MIT.
- **Standout features:**
  - focuses on *critical* attributes
  - custom thresholds based on real-world failure rates (Backblaze-style
    data), rather than only manufacturer thresholds
  - temperature history and webhook alerts
  - overrides for RAID controllers
- **UX worth copying:** a per-drive pass/warn/fail card with "why", and an
  attribute history sparkline.
- **Gaps:** needs SYS_RAWIO and device passthrough in Docker. Work in
  progress.

Source: https://github.com/AnalogJ/scrutiny

### 3.18 Monit

- **What:** a small Unix supervisor and monitor. 6.0.0 is current.
- **License:** AGPL. M/Monit (multi-host) is a separate commercial product.
- **Features:**
  - checks processes (CPU/memory), files (checksum, timestamp, size),
    filesystems, hosts (TCP/UDP/Unix with protocol tests), programs (exit
    codes) and system resources
  - automatic start/stop/restart and alerts
  - a built-in HTTP UI to start, stop, restart and toggle monitoring
- **UX worth copying:** "if X then restart" remediation rules.
- **Insight:** if Monit is present, its status (`monit status` or its XML
  status endpoint, product knowledge) is a cheap integration.

Source: https://mmonit.com/monit/

### 3.19 Cronicle and xyOps

- **What:** Cronicle is a multi-server job scheduler written in Node.js.
  - It supports a primary with failover, worker groups and timezones.
  - It has a live log viewer, per-job CPU/memory tracking, history graphs and
    plugins in any language.
  - The author announced **xyOps** v1.0 as its successor; Cronicle stays in
    maintenance mode.
  - xyOps combines scheduling, visual workflows, server monitoring, alerts
    with a server snapshot on alert, and tickets. Workers are "xySat"
    satellites.
- **License:** Cronicle MIT (product knowledge); xyOps BSD-3-Clause, with
  every feature free.
- **UX worth copying:**
  - a live log per job run with resource graphs
  - "snapshot the server when an alert fires"
  - "block unsafe launches"

Sources:
- https://github.com/jhuckaby/Cronicle
- https://github.com/pixlcore/xyops

### 3.20 crontab-ui

- **What:** a Node.js web editor for crontab. It can import an existing
  crontab, add, delete or pause jobs safely, back up and export crontabs, and
  keeps error logs with mail and hooks.
- **License:** MIT (product knowledge).
- **UX worth copying:**
  - pausing a job (comment it out) instead of deleting it
  - automatic backups before each save
  - import from and export to other machines
  - an explicit "save to crontab" step (autosave optional)

Source: https://github.com/alseambusher/crontab-ui

### 3.21 Healthchecks.io

- **What:** a cron and heartbeat monitoring service, hosted or self-hosted
  (Python 3.12+, Django 6.1).
- **License:** BSD-3-Clause.
- **Features:**
  - each check has a Period and Grace or a **cron expression**, evaluated with
    the cronsim library
  - ping endpoints: success, `/start`, `/fail`, `/log` and `/<exit-status>`
    (0 to 255)
  - `rid` pairs start and finish pings for accurate durations
  - POST bodies are stored (first 100 kB) as captured job output
  - slug URLs with auto-provisioning (`create=1`)
  - 25+ integrations, badges, monthly reports, teams
- **UX worth copying:**
  - the period/grace dialog
  - a cron dialog that previews the human-readable schedule and next runs
  - an event log per check
- **Insight:** our app could wrap cron lines to emit start/finish pings to
  the user's Healthchecks instance, or to a Hauntware endpoint.

Sources:
- https://github.com/healthchecks/healthchecks
- https://healthchecks.io/docs/http_api/
- https://healthchecks.io/docs/signaling_failures/

### 3.22 Dozzle, Logdy, lazyjournal (logs)

- **Dozzle** (MIT):
  - **What:** a real-time Docker log viewer. v11.3.0 shipped 2026-10-05:
    - safe container updates with rollback and auto-update modes
    - writable-layer and volume sizes
    - host reclaimable space
    v11.2.0 added host metrics and k8s rollout restarts. v11.1.3 added SQL
    analytics charts.
  - **Features:** fuzzy container search, regex search, **SQL queries over
    logs** (DuckDB), split screen, live stats, agent mode for multi-host,
    Swarm.
  - **Gaps:** no log persistence.
- **Logdy** (Apache-2.0):
  - **What:** a single-binary web log viewer for stdin, files, sockets and
    REST, with custom TypeScript parsers and columns. 0.17.0 is from
    2025-06-01.
  - **UX worth copying:** user-defined column extraction from unstructured
    lines.
- **lazyjournal** (MIT):
  - **What:** a TUI over journald (system and user), auditd, `/var/log` files
    (incl. rotated `.gz/.xz/.bz2`) and Docker/Podman/Compose/k8s logs, with
    remote access over SSH.
  - **Features:**
    - lists *all* systemd units (incl. disabled) to jump to their logs
    - a list of boots for kernel logs
    - four filter modes: exact, fuzzy, regex and date since/until
    - built-in highlighting of errors, warnings, IPs, URLs and numbers
  - **UX worth copying:** one searchable source list across journal units,
    files and containers.

Sources:
- https://github.com/amir20/dozzle
- https://github.com/amir20/dozzle/releases
- https://github.com/logdyhq/logdy-core
- https://github.com/Lifailon/lazyjournal

### 3.23 GoAccess (web logs)

- **What:** a real-time web log analyzer in C (ncurses TUI or a live HTML
  dashboard over its own WebSocket server). It updates every 200 ms in the
  terminal and every 1 s in HTML.
  - Formats: Apache, Nginx, S3, ELB, CloudFront and custom.
  - Incremental on-disk persistence, per-vhost panels, response-time
    tracking, JWT-authenticated WebSocket.
- **License:** MIT (product knowledge).
- **Insight:** an agentless client can run `goaccess --log-format=COMBINED -o
  json` over SSH when GoAccess is installed. Alternatively, parse access logs
  in Dart for top URLs, status codes, IPs and bandwidth.

Source: https://github.com/allinurl/goaccess

### 3.24 fail2ban, Fail2Ban UI, CrowdSec

- **fail2ban** (GPL-2.0, product knowledge):
  - no first-party UI; managed with `fail2ban-client status [jail]`,
    `set <jail> unbanip <ip>`
  - Webmin has a Fail2Ban module; 1Panel and HestiaCP integrate it
- **Fail2Ban UI** (Swissmakers, GPL-3.0):
  - a dashboard of jails and banned IPs with unban, config editing and filter
    testing via `fail2ban-regex`
  - management of local *and remote servers over SSH*
  - real-time ban activity and country-based email alerts
  - active in Feb 2026
- **CrowdSec** (MIT):
  - an IDS/IPS and WAF (Coraza-based AppSec) built on log parsing, with
    decoupled "bouncers" for remediation and a community blocklist
  - CLI `cscli` with JSON output for decisions, alerts and metrics (product
    knowledge); the web Console is SaaS
- **UX worth copying:** a banned-IP list with jail, time and country, plus
  one-tap unban.

Sources:
- https://code.swissmakers.ch/swissmakers_gmbh/fail2ban-ui (mirror of github.com/swissmakers/fail2ban-ui)
- https://github.com/crowdsecurity/crowdsec

### 3.25 Lynis (security audit)

- **What:** an on-host security auditing and hardening scanner (shell). It
  needs no install: `./lynis audit system`.
  - Output goes to `/var/log/lynis-report.dat` as flat `key=value`:
    - `warning[]=` and `suggestion[]=` lines with pipe-delimited
      `test-id|text|details|solution`
    - `hardening_index` (0 to 100)
  - It is used for compliance (ISO27001, PCI-DSS, HIPAA).
- **License:** GPL-3.0. The Enterprise edition adds a web UI.
- **Insight:** this is easy to run over SSH and parse. A fleet-wide hardening
  index table, with per-host findings and "solution" links, is a
  differentiator.

Sources:
- https://github.com/CISOfy/lynis
- https://docs.defectdojo.com/supported_tools/parsers/file/lynis/

### 3.26 Native SSH monitoring apps (direct competitors)

- **ServerBox (lollipopkit/flutter_server_box)** (AGPL-3.0, with a CLA for
  App Store builds):
  - Flutter on iOS, macOS, Android, Linux and Windows. It vendors **dartssh2**.
  - Features:
    - status charts for CPU, sensors and GPU
    - SSH terminal and SFTP; RDP/VNC through SSH
    - Docker/Podman, process and service management; S.M.A.R.T.
    - biometric lock, widgets, a watchOS app and 16 languages
  - **Status collection:**
    - typed command keys per OS (Linux: `echo, time, net, sys, cpu, uptime,
      conn, disk, mem, tempType, tempVal, host, diskio, battery, nvidia, gpu,
      amd, sensors, diskSmart, cpuBrand, ip`; also BSD and Windows/PowerShell
      sets)
    - script generation and parsing now live in a shared Rust library
      (`sbm_parser`)
    - the optional **ServerBox Monitor** agent is required for push
      notifications, widgets, the watch app, history from before first
      connection, and HTTP access without SSH
  - This is the clearest proof that a native agentless client hits a ceiling
    on alerts and history without an agent.
- **ServerCat** (iOS/macOS, commercial):
  - agentless ("will not install any tools")
  - free tier: per-core CPU, memory, network, disk I/O and Docker stats
  - paid tier: terminal, sync, container create/manage and background SSH

Sources:
- https://github.com/lollipopkit/flutter_server_box
- https://github.com/lollipopkit/flutter_server_box/blob/main/lib/data/model/app/scripts/cmd_types.dart
- https://apps.apple.com/us/app/servercat/id1501532023

(Dockhand, for reference: BSL-1.1 converting to Apache-2.0 after 4 years. It
has the Hawser outbound agent; host monitoring is limited to what Docker
reports. See R1. https://dockhand.pro/)

---

## 4. Consolidated feature inventory

Legend:

| Code | Tool | Code | Tool |
|---|---|---|---|
| CP | Cockpit | WM | Webmin |
| 1P | 1Panel | AA | aaPanel |
| HE | HestiaCP | CL | CloudPanel |
| ND | Netdata | GL | Glances |
| BZ | Beszel | PR | Prometheus/node_exporter/Grafana |
| ZB | Zabbix | CM | Checkmk |
| PU | Pulse | SC | Scrutiny |
| MO | Monit | UK | Uptime Kuma |
| GA | Gatus | HC | Healthchecks |
| CR | Cronicle/xyOps | CU | crontab-ui |
| DZ | Dozzle | LJ | lazyjournal |
| GO | GoAccess | LY | Lynis |
| F2B | fail2ban/Fail2Ban UI | CS | CrowdSec |
| SB | ServerBox | SCat | ServerCat |

The "Agentless source" column lists the commands or files a POSIX-shell probe
can use. Minimum versions are noted where verified.

### 4.1 CPU

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Total utilization, user/system/idle | all monitors, CP, WM, 1P, AA, SB, SCat | `/proc/stat` delta (two samples) | Table stakes |
| Per-core utilization | ND, GL, PR, ZB, CM, SB, SCat | `/proc/stat` cpuN lines | Table stakes |
| Load average 1/5/15 + core count | all | `/proc/loadavg`, `nproc` | Table stakes |
| iowait, steal, irq/softirq breakdown | ND, GL, PR, ZB, CM; BZ alerts on iowait/steal (v0.19) | `/proc/stat` fields | Differentiator for VPS users (steal = noisy neighbour) |
| PSI pressure (cpu/memory/io some/full avg10/60/300) | ND, PR (`pressure` collector) | `/proc/pressure/{cpu,memory,io}` (kernel ≥ 4.20, may be disabled by `psi=0`) | Differentiator; best "is it actually saturated" signal |
| Frequency / throttling | ND, GL, PR (cpufreq) | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` | Nice to have |
| CPU model/topology | CP, WM, SB (cpuBrand), GL | `lscpu -J` | Table stakes |
| Context switches, interrupts | GL, ND, PR | `/proc/stat` ctxt/intr | Expert |

### 4.2 Memory, swap, OOM

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Used/available/buffers/cache/shared | all | `/proc/meminfo` | Table stakes |
| Swap used, swap in/out rate | ND, GL, PR, BZ, ZB | `/proc/meminfo`, `/proc/vmstat` pswpin/pswpout | Table stakes |
| ZFS ARC as reclaimable | BZ, ND, PR | `/proc/spl/kstat/zfs/arcstats` | Nice to have |
| OOM-kill events with victim | ND (processes/OOM), PR (`vmstat` oom_kill count) | `/proc/vmstat` oom_kill; `journalctl -k -g 'Out of memory'` | Differentiator (link count to journal entries) |
| Memory pressure (PSI) | ND, PR | `/proc/pressure/memory` | Differentiator |
| Huge pages, slab, dirty/writeback | PR, ND | `/proc/meminfo` | Expert |

### 4.3 Processes

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Sortable list (CPU, mem, user, cmd) | WM, 1P, GL, ND (Function), SB, Cockpit Top (3rd-party), xyOps | `ps -eo pid,ppid,user,pcpu,pmem,rss,etimes,stat,comm,args --no-headers` or `/proc/[pid]/stat` | Table stakes |
| Tree view | GL (tree mode), WM, htop/btop | ppid from `ps` | Table stakes |
| Kill / signal | WM, 1P, GL, SB | `kill -s SIG pid` (sudo for others' processes) | Table stakes |
| Renice / ionice | WM, GL, htop | `renice`, `ionice` | Nice to have |
| Open files, cwd, environment | WM (process detail, unverified), htop (`lsof`) | `ls -l /proc/pid/fd`, `lsof -p` | Differentiator |
| Per-process network connections | ND (network-viewer), WM, 1P (unverified) | `ss -tupn` (root to see all owners) | Differentiator |
| Per-process disk I/O | ND, GL | `/proc/pid/io` (root) | Expert |
| cgroup/systemd unit attribution | ND (systemd-services) | `/proc/pid/cgroup` | Differentiator (process to service to logs) |
| Per-job resource tracking | CR | sample during run | Expert |

### 4.4 Disks and filesystems

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Usage per mount, % and bytes | all | `df -PB1 -x tmpfs -x devtmpfs`; `findmnt -J -b` | Table stakes |
| Inodes | ND (mount-points), PR, ZB, CM | `df -Pi` | Table stakes (often forgotten) |
| Mount table, fs type, options | CP, WM, ND | `findmnt -J`, `/proc/self/mountinfo` | Table stakes |
| Block devices, partitions, LVM/RAID/LUKS | CP (Storage), WM | `lsblk -J -b -o ...`, `pvs/vgs/lvs --reportformat json`, `/proc/mdstat` | Nice to have (read-only first) |
| I/O throughput, IOPS, await/latency, util | ND, GL, BZ, PR, ZB, CM, CP, SB | `/proc/diskstats` delta | Table stakes for throughput; latency is a differentiator |
| SMART health and attributes, NVMe wear | SC, BZ, ND, WM, CM, ZB, SB | `smartctl --scan -j`, `smartctl -a -j /dev/X` (smartmontools ≥ 7.0 JSON), sudo | Table stakes (health); differentiator (critical-attribute scoring à la Scrutiny) |
| ZFS pools, datasets, scrub state | BZ (v0.19), ND, CP (3rd-party ZFS Manager), PU (TrueNAS) | `zpool status -p`, `zpool list -Hp`, `zfs list -Hp` | Nice to have |
| mdraid health | BZ, ND, CP, WM | `/proc/mdstat`, `mdadm --detail` | Nice to have |
| Largest dirs/files explorer (ncdu-like) | rare: 1P file manager size-on-demand; ncdu/gdu TUIs | `ncdu -o -` JSON (format v1.x documented), `gdu -o-` JSON, fallback `du -x -B1 -d N` | **Differentiator** |
| Disk usage growth forecast ("full in N days") | ND (ML/alerts), PR (`predict_linear`) | needs history | Differentiator |
| Quotas | WM | `repquota` | Niche |

### 4.5 Network

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Interfaces, addresses, state, MTU, speed | CP, WM, ND, GL, SB (ip) | `ip -j addr`, `ip -j -s link`, `/sys/class/net/*/speed` | Table stakes |
| Throughput rx/tx, errors, drops | all monitors | `/proc/net/dev` delta | Table stakes |
| Connection counts by state | GL, SB (conn), PR (netstat/sockstat), ND | `ss -s`, `/proc/net/sockstat` | Table stakes |
| Live connection list | ND (Cloud-gated), GL, xyOps | `ss -tunp` | Differentiator |
| **Listening ports + owning process/unit/container** | ND network-viewer (partly), rare elsewhere | `ss -Htulpn` (root for all owners) + `/proc/pid/cgroup` + Docker port map | **Differentiator** (security and "what's on :8080") |
| Firewall rules view/edit (ufw, nftables, firewalld, iptables) | CP (firewalld), WM (all three), 1P (v2.3 rebuilt), AA, HE, CL | `ufw status verbose`, `nft -j list ruleset`, `firewall-cmd --list-all-zones`, `iptables-save` | Table stakes (view); edit is risky, needs a lockout guard |
| Ports vs firewall correlation ("exposed to internet?") | none found | combine the two above | **Differentiator** |
| Routes, DNS resolvers | CP, WM | `ip -j route`, `resolvectl status` / `/etc/resolv.conf` | Nice to have |
| Outbound probes (ping/TCP/HTTP/DNS from host) | BZ (v0.20/0.21), UK, GA, ZB, CM, WM | `ping -c`, `curl -w`, `getent hosts`/`dig` run on host | Differentiator (test from server perspective) |
| Per-process bandwidth | ND (eBPF), nethogs | `nethogs -t` if installed | Expert |
| WireGuard/Tailscale status | CP 3rd-party (Tailscale), product knowledge | `wg show all dump`, `tailscale status --json` | Nice to have |

### 4.6 Services (systemd)

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| List units with load/active/sub state, filter by type | CP, WM, ND (Function), BZ, SB, LJ, CM, ZB | `systemctl list-units --all -o json` (JSON table output on modern systemd, verify per distro; fallback plain `--plain --no-legend`) | Table stakes |
| Start/stop/restart/reload/enable/disable/mask | CP, WM, SB, MO (own checks), 1P/AA (own apps) | `systemctl <verb> <unit>` via sudo | Table stakes |
| Failed units summary | CP (health), BZ (alerts v0.19), CM, ND | `systemctl --failed -o json` | Table stakes |
| Unit file view (with drop-ins) | CP, WM | `systemctl cat <unit>` | Table stakes |
| Unit file edit / override | WM (edit), product knowledge | `systemctl edit` equivalent: write `/etc/systemd/system/<u>.d/override.conf` + `daemon-reload` | Differentiator |
| Dependencies/relationships | CP | `systemctl show -p Requires,Wants,After,Before,...`, `systemctl list-dependencies` | Nice to have |
| Per-unit resource usage (CPU, mem, tasks) | ND (systemd-services), CP (service detail memory) | `systemctl show -p MemoryCurrent,CPUUsageNSec,TasksCurrent` | Differentiator |
| Per-unit logs inline | CP, BZ (v0.21), LJ | `journalctl -u <unit> -o json -n N` | Table stakes |
| User units (`--user`) | CP | `systemctl --user` (needs user session/linger) | Nice to have |
| Boot performance (`systemd-analyze blame`, critical chain) | none found among surveyed | `systemd-analyze`, `systemd-analyze blame`, `critical-chain` | **Differentiator** |
| Security exposure score per service | none in UI | `systemd-analyze security --json=short` (systemd ≥ 250) | Differentiator |
| Supervisor / OpenRC / runit / s6 fallback | 1P/AA (Supervisor), PR (runit, supervisord collectors) | `supervisorctl status`, `rc-status` (Alpine) | Nice to have |

### 4.7 Logs

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Journal query by unit/identifier/priority/time | CP, ND, LJ, WM, 1P (v2.2.4) | `journalctl -o json --since --until -p -u -t -n --no-pager` (`-o json` is long-standing) | Table stakes |
| Boot selection, list boots | CP, LJ | `journalctl --list-boots` (JSON since systemd 251), `-b -1` | Table stakes |
| Follow / live tail | CP, ND (PLAY), LJ, DZ, Logdy | `journalctl -f -o json` on a dedicated channel; `tail -F` | Table stakes |
| Faceted filters with counts, histogram | ND | compute client-side over fetched window or `journalctl -F FIELD` for values | **Differentiator** |
| Regex / fuzzy / exact search | DZ (regex, SQL), LJ (4 modes), ND (patterns) | `journalctl -g` (PCRE2) server-side or client filter | Table stakes (text); fuzzy/regex differentiator |
| /var/log file browser incl. rotated .gz | WM, LJ, 1P | `ls /var/log`, `zcat`, `tail -n` | Table stakes |
| Kernel log (dmesg) | CP (priority/kernel), LJ | `journalctl -k`, `dmesg --json` (util-linux) | Table stakes |
| auditd logs | LJ | `ausearch -i` | Niche |
| Highlighting (levels, IPs, URLs) | LJ, DZ (ANSI) | client-side | Nice to have |
| Structured parsing / custom columns | Logdy (TS parsers), DZ (JSON fields) | client-side | Differentiator |
| Export / share | ND (copy), DZ (download) | client-side save | Table stakes |
| Logrotate config | WM (Log File Rotation) | `/etc/logrotate.d/*` | Niche |
| Web access log analytics | GO, 1P (WAF/site logs), AA Pro | `goaccess -o json` if installed, or Dart parser | Differentiator |
| Container logs | DZ, LJ, BZ (health alert excerpts), PU | `docker logs --timestamps --since` | Table stakes (shared with Docker section) |

### 4.8 Scheduled jobs

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| User crontabs list/edit | WM, CU, 1P (own jobs), AA, CL, HE | `crontab -l -u <user>` (root), `/var/spool/cron/crontabs/*` (Debian) or `/var/spool/cron/*` (RHEL) | Table stakes |
| System cron (`/etc/crontab`, `/etc/cron.d`, `cron.{hourly,daily,weekly,monthly}`) | WM | read files; `run-parts --test /etc/cron.daily` | Table stakes (rarely done well) |
| systemd timers with last/next run | CP (list + create) | `systemctl list-timers --all` (JSON on modern systemd), `systemctl show <timer> -p LastTriggerUSec,NextElapseUSecRealtime` | Table stakes |
| anacron | WM (unverified) | `/etc/anacrontab`, `/var/spool/anacron/*` timestamps | Nice to have |
| **Unified jobs view** (cron + timers + anacron in one list) | none found | merge of above | **Differentiator** |
| Human-readable schedule and next N runs | HC (cron dialog), CR (picker), WM (simple schedule) | Dart cron parser (port of cronsim semantics) + `systemd-analyze calendar --iterations=N` for OnCalendar | Differentiator |
| Last run time and exit status for cron | CR, 1P (records), HC (via pings) | `journalctl -t CRON -t cron` / `_COMM=cron` (Debian logs "CMD"), syslog `/var/log/cron` (RHEL); exit status not logged by default | Differentiator |
| Output capture | CR (live log), CU (error log), 1P, HC (100 kB body) | wrap job: `cmd 2>&1 \| logger -t hw-job-<id>` or systemd-cat, or timer's journal | Differentiator |
| Pause/enable without deleting | CU, WM | comment out line with marker | Table stakes |
| Run now | WM, CU, CR, 1P | `sh -c "<cmd>"` as job user / `systemctl start <svc>` | Table stakes |
| Backup before edit, diff, validate syntax | CU (backups) | keep previous text, validate with Dart parser before `crontab -` | Differentiator (safety) |
| Dead-man switch / missed-run alerts | HC, UK (push), GA (external), ZB (`nodata`), CM (freshness) | ping wrapper + resident checker (sync server or third-party HC) | Differentiator (needs resident component) |
| Convert cron to timer | none found | generate `.timer` + `.service` | Expert |

### 4.9 Packages and updates

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Pending updates list | CP (PackageKit), WM (APT/DNF), CM (apt check), PR (textfile) | `apt list --upgradable` (after `apt-get update` or read cache age), `dnf check-update -q` / `dnf updateinfo list`, `pacman -Qu` / `checkupdates`, `apk version -l '<'`, `zypper -q lu` | Table stakes |
| Security updates flagged | CP, CM | `dnf updateinfo list --security`; Debian/Ubuntu: origin `-security` in `apt list --upgradable`; `zypper lp -g security` | Differentiator |
| Apply updates with streaming output | CP, WM | `sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade` on PTY channel | Table stakes |
| Package holds | WM | `apt-mark showhold`, `dnf versionlock list` | Nice to have |
| Reboot required | CP (post-update) | `/var/run/reboot-required(.pkgs)` (Debian/Ubuntu), `needs-restarting -r` (RHEL), running vs installed kernel compare | Differentiator |
| Services needing restart | CP (tracer / `dnf needs-restarting` / `zypper ps`) | `needrestart -b` (Debian), `needs-restarting -s`, `zypper ps -s` | Differentiator |
| Unattended-upgrades / dnf-automatic status | CP (dnf-automatic, unverified) | `/etc/apt/apt.conf.d/20auto-upgrades`, `systemctl status dnf-automatic.timer`, last run in `/var/log/unattended-upgrades/` | Differentiator |
| Live patch status | none in UI | `canonical-livepatch status`, `kpatch list` | Niche |
| Container image updates | BZ (v0.20 flag), DZ (v11.3 updates), PU | registry digest compare | See R1 |

### 4.10 Users, groups, sudoers, SSH keys

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Users/groups list, create, lock, delete, password, expiry | CP, WM, HE | `getent passwd/group`, `chage -l`, `passwd -S`, `useradd/usermod/userdel` | Nice to have |
| Logged-in sessions, terminate | CP | `loginctl list-sessions -j` (systemd ≥ 256 `-j`), `who`, `loginctl terminate-session` | Nice to have |
| Login history incl. failures with source IP | 1P (SSH login logs), CS/F2B (indirect) | `last -F -w`, `lastb` (root), `journalctl _COMM=sshd -o json` / `/var/log/auth.log`, `/var/log/secure` | **Differentiator** |
| authorized_keys inventory (all users) with fingerprints/comments | CP (per user add/remove), cockpit-identities | read `~/.ssh/authorized_keys` (root), `ssh-keygen -lf` | **Differentiator** (fleet-wide "where is this key") |
| sudoers view / audit | Cockpit 3rd-party Sudo Manager | `sudo -l -U user`, `/etc/sudoers.d/*` (validate with `visudo -c`) | Differentiator |
| sshd config audit (root login, password auth, port) | 1P (SSH mgmt), LY | `sshd -T` (root) | Differentiator |

### 4.11 Certificates

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Endpoint TLS expiry | UK, GA (`[CERTIFICATE_EXPIRATION]`), BZ (v0.21), ZB, CM | client-side TLS handshake from app, or `openssl s_client` from host | Table stakes in monitors |
| Local certificate file inventory and expiry | rare (1P/WM/HE/CL manage their own certs) | `certbot certificates`, scan `/etc/letsencrypt/live/*/cert.pem`, `/etc/ssl`, paths referenced in nginx/apache/haproxy configs; `openssl x509 -noout -enddate -subject -ext subjectAltName` | **Differentiator** |
| ACME renewal status | 1P, HE, CL, WM (certbot) | `systemctl list-timers certbot*`, `/var/log/letsencrypt/` | Nice to have |
| Domain expiry | GA (`[DOMAIN_EXPIRATION]`) | RDAP/WHOIS from client | Nice to have |

### 4.12 Hardware, sensors, GPU, kernel/OS, uptime

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Temperatures, fans, voltages | BZ, GL, ND, SB, PR (hwmon), CP 3rd-party | `sensors -j` (lm-sensors), `/sys/class/hwmon`, `/sys/class/thermal` | Table stakes |
| GPU utilization/memory/power/temp | BZ (NVIDIA/AMD/Intel), GL, ND, 1P (GPU monitor), SB | `nvidia-smi --query-gpu=... --format=csv,noheader,nounits`, `rocm-smi --json`, `intel_gpu_top -J` | Table stakes for GPU hosts |
| IPMI/BMC sensors, EDAC memory errors | ND, PR (edac) | `ipmitool sdr`, `/sys/devices/system/edac` | Expert |
| Battery/UPS | BZ, SB | `/sys/class/power_supply`, `upsc` | Niche |
| Hardware inventory (DMI, CPU, RAM slots, PCI) | WM (Hardware Information), CP (hardware page), PR (dmi) | `/sys/class/dmi/id/*`, `lspci -mm`, `dmidecode` (root) | Nice to have |
| OS/kernel/virtualization info | all | `/etc/os-release`, `uname -a`, `systemd-detect-virt`, `hostnamectl --json=short` (systemd ≥ 249) | Table stakes |
| Uptime | all | `/proc/uptime` | Table stakes |
| Reboot history, unclean shutdowns | CP (boot selection), LJ (boot list) | `journalctl --list-boots`, `last -x reboot shutdown` | **Differentiator** (timeline with "crashed" markers) |
| Kernel vulnerabilities/mitigations | PR (cpu_vulnerabilities) | `/sys/devices/system/cpu/vulnerabilities/*` | Nice to have |
| Time sync status | CP (NTP config) | `timedatectl show`, `chronyc tracking` | Nice to have (Pulse flags clock drift) |

### 4.13 Security posture

| Feature | Tools | Agentless source | Class |
|---|---|---|---|
| Hardening audit score and findings | LY, Cockpit 3rd-party SCAP, Lynis Enterprise UI | `lynis audit system --quick --no-colors` then parse `/var/log/lynis-report.dat` | **Differentiator** (fleet table) |
| Fail2ban jails and bans, unban | F2B UI, WM, 1P, HE | `fail2ban-client status`, `fail2ban-client status <jail>`, `set <jail> unbanip` | Differentiator |
| CrowdSec decisions/alerts | CS (cscli, Console) | `cscli decisions list -o json`, `cscli alerts list -o json` | Differentiator |
| Malware scan | 1P (ClamAV), AA | `clamscan` | Niche |
| SELinux/AppArmor status and denials | CP (SELinux) | `getenforce`, `sestatus`, `ausearch -m AVC`, `aa-status --json` | Nice to have |
| World-exposed listening services | none as a feature | ports and firewall correlation (4.5) | Differentiator |

### 4.14 Alerts, history, fleet, maintenance, automation

| Feature | Tools | Notes for Hauntware | Class |
|---|---|---|---|
| Threshold alerts with duration ("CPU > 90% for 5 min") | BZ, ND, ZB, CM, AA, WM, GL (colors only) | Needs resident evaluator (agent, hub, or sync server) | Table stakes for monitors; hard for pure client |
| Status/availability alerts | BZ, UK, GA, ZB, CM, MO | Seance already has TCP banner `ProbeService` with online/offline/unknown | Table stakes |
| Notification channels (ntfy, Telegram, Slack, email, webhook...) | UK (90+), GA, BZ (Shoutrrr), ND, HC (25+) | ntfy/webhook first; OS push via own server | Table stakes once alerts exist |
| Historical charts | ND (tiers), BZ (rollups), PR, ZB, CM, CP (PCP), SC | Agentless: read sysstat `sadf -j`, PCP archives, atop logs; or local client cache while connected; or optional collector | Table stakes (at least 24 h) |
| Retention tiers / downsampling | ND (s/min/h), BZ (1m to 480m) | Copy BZ's rollup scheme for local cache | Implementation detail |
| Anomaly detection | ND (ML per metric), PU (AI Patrol) | Later; LLM summaries exist in Seance (`llm/`) | Differentiator |
| Fleet overview table/grid | BZ, ND Cloud, PU, UK, ZB, CM, 1P (Pro), WM (cluster), SB, SCat | Native per-host isolation; use shared `ServerConfig` groups/colors/icons | Table stakes |
| Fleet compliance views (kernel versions, pending updates, reboot-needed, cert expiry, Lynis index) | partial in CM/ZB inventories | Cross-host tables from cached probe results | **Differentiator** |
| Maintenance windows / silencing | GA, UK, ZB, CM, HC (pause), ND (silence) | Store per server/group; suppress alerts | Nice to have |
| Problem lifecycle (ack, resolve, notes) | ZB, CM, PU (attention queue), xyOps (tickets) | Light "attention queue" | Differentiator |
| Remediation rules (if down then restart) | MO, WM (command on down), xyOps | Only with resident component; require explicit opt-in | Expert |
| Runbooks / saved scripts / multi-host run | WM (custom commands, cluster-shell), CR/xyOps (workflows), SB (snippets), 1P (cron scripts) | Reuse Seance snippets/LLM; Seance has a `danger_linter` for risky commands | Differentiator |
| Incident snapshot on alert (ps, df, journal tail) | xyOps | Cheap to do agentlessly when user opens alert | **Differentiator** |
| Audit trail of actions taken | PU (Pro), Dockhand (paid) | Local + synced action log | Differentiator |
| Status pages / badges | UK, GA, HC | Out of scope initially | Out of scope |

---

## 5. Table stakes vs differentiators for a native, agentless-first SSH client

### 5.1 Table stakes (users will expect these on day one)

The baseline comes from ServerBox, ServerCat, Cockpit, Beszel and Glances:

1. **Shared synced server list** with groups, colors and online status, plus
   a quick terminal hand-off to Seance and file hand-off to Poltergeist.
2. **Live overview per host:**
   - CPU total and per-core, load, memory and swap, disk usage per mount
     (with inodes), disk I/O, network throughput
   - uptime, OS and kernel, temperatures, GPU if present
3. **Processes:** a sortable list and tree, search, kill/signal.
4. **systemd services:** list and filter, failed units, start/stop/restart,
   enable/disable, unit file view, per-unit logs.
5. **Journal viewer:** unit, priority, boot and time filters, text search,
   live follow, and a kernel log.
6. **SMART health summary.**
7. **Docker:** containers, stats, logs and lifecycle actions (see R1).
8. **Privilege elevation that works:** sudo password, NOPASSWD, sudo-rs and
   doas. Elevation must be explicit, visible and remembered per server.
9. **Fleet grid/table** with the key gauges for all servers.

### 5.2 Differentiators (few or no surveyed tools do these well)

1. **Unified scheduled-jobs center:**
   - covers user crontabs, system cron dirs, systemd timers and anacron
   - human-readable schedule and next runs
   - last run and output from the journal or syslog
   - safe edit with validation, backup and diff; pause/resume; run now
   - optional Healthchecks-style dead-man pings
2. **"Why is it slow?" triage:**
   - PSI pressure, iowait, steal, top processes, recent OOM kills and disk
     latency on one screen
   - plain-language hints, for example: "steal 25%: noisy neighbour on your
     VPS host"
3. **Exposure map:** listening ports mapped to process, unit or container,
   and to firewall rules, with a "reachable from outside?" check run from the
   client.
4. **Disk space explorer:** an ncdu-like tree using `ncdu -o -` or `gdu -o-`
   when present, otherwise `du`. Includes cleanup suggestions: journal vacuum,
   apt cache, docker prune and old kernels, each run as an explicit command
   preview.
5. **Update center:** security updates, reboot-required, services needing
   restart, and unattended-upgrades status, viewable fleet-wide.
6. **Access audit:** SSH login history including failures by IP,
   authorized_keys inventory across the fleet ("where is this key?"), sudoers
   overview, and the `sshd -T` posture.
7. **Certificate inventory:** local cert files and endpoint expiry,
   fleet-wide.
8. **Boot and reliability timeline:** list of boots, unclean shutdowns, the
   last kernel panic or OOM, and `systemd-analyze blame`.
9. **Fleet compliance tables:** kernel and OS versions, pending updates,
   reboot-needed, Lynis hardening index, failed units.
10. **Faceted journal explorer** in Netdata style, computed client-side. It is
    free, while Netdata gates parts of this behind Cloud.
11. **Incident snapshot:** capture ps, df, the journal tail and `ss` when a
    problem is seen, and save it as a shareable bundle.
12. **Runbooks** with dry-run preview and Seance's danger linter, executable
    across a server group.
13. **Per-host isolation and offline-first caching** of the last snapshot.
    This is a structural advantage over Cockpit, whose multi-host is
    deprecated.

### 5.3 Explicit non-goals (from panel analysis)

- website/vhost hosting, mail servers, DNS servers, database admin
- app stores and WAF
- VM management
- status pages

These belong to 1Panel, aaPanel, CloudPanel, HestiaCP and Virtualmin. At most,
integrate with them, for example by detecting HestiaCP and offering its `v-*`
commands.

---

## 6. Implementation insights for an agentless Dart/dartssh2 client

1. **Probe script pattern** (Checkmk sections, ServerBox command keys,
   Cockpit beiboot):
   - Send one POSIX `sh` script per refresh over a single exec channel on the
     shared multiplexed connection. Keep a separate channel for follows
     (`journalctl -f`, `docker logs -f`).
   - Emit sections like `@@hw:cpu@@` with a sentinel nonce to resist output
     injection. Each section is independent and failure-tolerant (`command -v
     X >/dev/null || echo "@@hw:x:missing@@"`).
   - Target `dash` and BusyBox `ash` (Alpine); never assume bash or Python.
   - Two-sample rates (CPU, disk, net): either `sleep 1` inside the script, or
     diff consecutive snapshots in Dart. The second is cheaper; ServerBox
     appears to do this.
   - Version the probe and make sections opt-in per screen to limit cost. A
     slow tier (SMART, updates, Lynis, `du`) runs on demand or on long
     intervals.
2. **Prefer JSON-emitting tools when present**, falling back to `/proc`
   parsing:

   | Tool | JSON flag | Availability |
   |---|---|---|
   | `lsblk`, `findmnt` | `-J` | |
   | `ip` | `-j` | |
   | `smartctl` | `-j` | smartmontools ≥ 7 |
   | `sensors` | `-j` | |
   | `journalctl` | `-o json` | `--list-boots` JSON from systemd 251 |
   | `systemctl` | `-o json` | modern systemd |
   | `hostnamectl` | `--json` | systemd 249 |
   | `loginctl` | `-j` | systemd 256 |
   | `systemd-analyze security` | `--json` | systemd 250 |
   | `nft` | `-j` | |
   | `docker` | `--format '{{json .}}'` | |
   | `cscli` | `-o json` | |
   | `sadf` | `-j` | |
   | `ncdu`/`gdu` | `-o -` | |
   | `glances` | `--stdout-json` | |

   Probe capabilities once per host per session, using `command -v` and
   `systemctl --version`, then cache them.
3. **Privilege model:**
   - Default to an unprivileged read-only session. Offer an explicit "Admin
     mode" per server, Cockpit-style, remembered per server.
   - Detect `sudo -n true` (NOPASSWD), else prompt and feed the password via
     `sudo -S -p ''` on stdin, never on the command line.
   - Support `doas`, `run0` (systemd ≥ 256) and sudo-rs. Cockpit 355 shows
     sudo-rs breaks some askpass assumptions, so test `-S` with sudo-rs.
   - Store the elevation secret using the existing Seance `secretRef`
     keychain approach, opt-in only.
   - Show which actions need root (badge) and the exact command to be run
     (preview), as Cockpit and Webmin hint.
4. **Quoting and injection:**
   - CVE-2026-4631 came from unvalidated hostnames and usernames reaching
     `ssh`. dartssh2 avoids the CLI, but every unit name, path, user, container
     name or package name interpolated into probe or action scripts must go
     through one well-tested POSIX single-quote escaper.
   - Validate systemd unit names against the systemd unit name grammar before
     use.
5. **History without agents:**
   - Detect and read existing recorders: sysstat (`sadf -j` over
     `/var/log/sysstat` or `/var/log/sa`, default 10-min samples, HISTORY
     days) and PCP pmlogger archives (Cockpit's source; `pmrep`/`pmlogdump`).
     atop raw logs and journald also have history (product knowledge).
   - Offer "enable sysstat" as a one-tap setup action.
   - The client keeps its own rollup cache while connected, using Beszel-like
     tiers (1m → 10m → 2h → 8h).
6. **Alerts and background work:**
   - Mobile OS background limits make a pure-client poller unreliable.
     ServerBox concluded an optional agent is required for push, widgets and
     watch.
   - **Option A:** an optional tiny collector, modelled on Beszel: no shell,
     no PTY, a key-pinned SSH or WebSocket endpoint, CBOR/JSON payloads,
     outbound mode for NAT.
   - **Option B:** extend the self-hosted Seance sync server with an opt-in
     "watcher" role that polls via SSH, as Beszel SSH mode, Zabbix `ssh.run`
     and Checkmk do. This breaks the E2E-only property for those servers,
     because the watcher needs a key. Mitigate with a dedicated low-privilege
     monitoring key restricted by an authorized_keys forced command to the
     probe script (the Checkmk community pattern).
   - **Option C:** integrate with existing Uptime Kuma, Healthchecks, Netdata
     or Prometheus if present, reading their APIs over SSH tunnels.
7. **Never install privileged helpers.** Netdata's 2026 `ndsudo` CVEs show
   the risk. Any setup action, such as installing sysstat or smartmontools,
   should be a transparent, previewed package-manager command.
8. **Respect sshd logs and rate limits.** Seance's `ProbeService` already
   jitters and pauses when invisible. Reuse one long-lived SSH connection per
   host with multiple channels rather than reconnecting per refresh. Many
   connections trip fail2ban and MaxStartups.
9. **Graceful degradation, as Cockpit does:**
   - hide or grey out features whose backing tool is missing
   - offer "install X" with a preview
   - mark data as "unknown" rather than zero, matching the Seance probe's
     online/offline/unknown philosophy
10. **Edit safety for config mutations** (crontab, unit overrides, firewall):
    - read the current text and keep a backup copy on host
      (`/var/backups/hauntware/...`) or in the client
    - show a diff, validate (`visudo -c`, `systemd-analyze verify`,
      `nginx -t`, cron parser), then apply atomically (write temp and `mv`)
    - for firewall changes, offer an auto-revert timer (apply, then roll back
      in 60 s unless confirmed), the classic lockout guard (product knowledge)

---

## 7. Source index

Panels:
- Cockpit:
  - https://cockpit-project.org/applications
  - https://cockpit-project.org/blog/
  - https://raw.githubusercontent.com/cockpit-project/cockpit/main/doc/protocol.md
  - https://github.com/cockpit-project/cockpit/blob/main/src/cockpit/beiboot.py
  - https://github.com/cockpit-project/cockpit/blob/main/src/cockpit/superuser.py
  - https://docs.cockpit-project.org/cockpit-guide/362/guide/privileges.html
  - https://docs.cockpit-project.org/cockpit-guide/362/guide/feature-systemd.html
  - https://docs.cockpit-project.org/cockpit-guide/362/guide/feature-pcp.html
  - https://docs.cockpit-project.org/cockpit-guide/362/guide/multi-host.html
  - https://cockpit-project.org/blog/cockpit-355.html
  - https://cockpit-project.org/blog/cockpit-329.html
  - https://cockpit-project.org/blog/cockpit-295.html
  - https://cockpit-project.org/blog/cockpit-238.html
  - https://seclists.org/oss-sec/2026/q2/88
  - https://fedoramagazine.org/using-cockpit-to-graphically-manage-systems-without-installing-cockpit-on-them/
  - https://docs.oracle.com/en/operating-systems/oracle-linux/cockpit/cockpit-services.html
  - https://docs.oracle.com/en/operating-systems/oracle-linux/cockpit/cockpit-usermanage.html
- Webmin:
  - https://webmin.com/
  - https://github.com/webmin/webmin
  - https://webmin.com/docs/modules/system-and-server-status/
- Ajenti: https://github.com/ajenti/ajenti
- 1Panel:
  - https://github.com/1Panel-dev/1Panel
  - https://1panel.pro/docs/v2/
  - https://1panel.pro/docs/v2/changelog/
- aaPanel: https://www.aapanel.com/
- CloudPanel:
  - https://www.cloudpanel.io/docs/v2/introduction/
  - https://www.cloudpanel.io/blog/cloudpanel-v2-5-4-release/
- HestiaCP: https://github.com/hestiacp/hestiacp

Monitoring:
- Netdata:
  - https://github.com/netdata/netdata
  - https://learn.netdata.cloud/docs/top-monitoring-netdata-functions
  - https://learn.netdata.cloud/docs/logs/systemd-journal-logs/systemd-journal-plugin-reference
  - https://tracker.debian.org/pkg/netdata-core
- Glances:
  - https://github.com/nicolargo/glances
  - https://github.com/nicolargo/glances/releases
- Beszel:
  - https://github.com/henrygd/beszel
  - https://beszel.dev/guide/security
  - https://github.com/henrygd/beszel/releases
  - https://github.com/henrygd/beszel/blob/main/agent/server.go
  - https://github.com/henrygd/beszel/blob/main/internal/records/records.go
- Uptime Kuma:
  - https://github.com/louislam/uptime-kuma
  - https://github.com/louislam/uptime-kuma/releases
- Gatus: https://github.com/TwiN/gatus
- Prometheus and Grafana:
  - https://github.com/prometheus/node_exporter
  - https://grafana.com/blog/grafana-13-release-all-the-latest-features/
- Zabbix:
  - https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/ssh_checks
  - https://blog.zabbix.com/striking-the-right-balance-zabbix-7-0-to-be-released-under-agplv3-license/
  - https://www.zabbix.com/life_cycle_and_release_policy
- Checkmk:
  - https://docs.checkmk.com/latest/en/agent_linux.html
  - https://forum.checkmk.com/t/access-agent-over-ssh/24650
- Pulse: https://github.com/rcourtman/Pulse
- Scrutiny: https://github.com/AnalogJ/scrutiny
- Monit: https://mmonit.com/monit/

Jobs, logs, security:
- Cronicle and xyOps:
  - https://github.com/jhuckaby/Cronicle
  - https://github.com/pixlcore/xyops
- crontab-ui: https://github.com/alseambusher/crontab-ui
- Healthchecks:
  - https://github.com/healthchecks/healthchecks
  - https://healthchecks.io/docs/http_api/
  - https://healthchecks.io/docs/signaling_failures/
- Dozzle:
  - https://github.com/amir20/dozzle
  - https://github.com/amir20/dozzle/releases
- Logdy: https://github.com/logdyhq/logdy-core
- lazyjournal: https://github.com/Lifailon/lazyjournal
- GoAccess: https://github.com/allinurl/goaccess
- Fail2Ban UI: https://code.swissmakers.ch/swissmakers_gmbh/fail2ban-ui
- CrowdSec: https://github.com/crowdsecurity/crowdsec
- Lynis:
  - https://github.com/CISOfy/lynis
  - https://docs.defectdojo.com/supported_tools/parsers/file/lynis/

Native competitors and Docker:
- ServerBox:
  - https://github.com/lollipopkit/flutter_server_box
  - https://github.com/lollipopkit/flutter_server_box/blob/main/lib/data/model/app/scripts/cmd_types.dart
- ServerCat: https://apps.apple.com/us/app/servercat/id1501532023
- Dockhand: https://dockhand.pro/

Command and format references:
- systemd NEWS (JSON output versions): https://github.com/systemd/systemd/blob/main/NEWS
- sysstat:
  - https://www.mankier.com/5/sysstat
  - https://man.he.net/man1/sadf
- ncdu:
  - https://www.mankier.com/1/ncdu
  - https://dev.yorhel.nl/ncdu/jsonfmt
- gdu: https://github.com/dundee/gdu
