# R4: Native desktop, mobile and TUI clients for server and container management

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Research date: 2026-10-10. Scope: native (not browser-first) apps and TUIs that
monitor or manage servers and containers, with emphasis on (a) UX for
multi-platform native apps and (b) how agentless collection over SSH is done
in practice. Feeds the product plan for a fourth Hauntware app that shares
Seance/Poltergeist's synced `ServerConfig` list.

Method: primary sources wherever possible. ServerBox was studied from its
source tree (shallow clone of `lollipopkit/flutter_server_box` at commit
`50e61ed`, 2026-10-10, app version `1.0.1719+1719`), not just its README. Other
tools from official sites, App Store listings, GitHub READMEs/release pages and
official docs. Where only secondary sources existed, that is stated.
App Store pages often omit the year on dates; years are inferred from context
and marked "(2026)" only when the page or release page made it clear.

---

## 0. Most important findings

1. **ServerBox is the reference implementation for agentless SSH collection,
   and it has matured a lot.** It uploads one POSIX `sh` script per server
   (by default a `server_box` directory in the host's temporary directory,
   falling back to `~/.config/server_box/` when that is unwritable or
   `noexec`), then calls shell functions by flag
   (`sh script.sh -s` status, `-e` extended, `-p` processes, `-sd/-r/-sp`
   power). One call returns every metric as segments separated by
   base64-encoded markers. Status runs every **3 s by default** over a
   **persistent shell channel** (falls back to one exec channel per poll on
   timeout); slow/expensive probes (SMART, AMD on Windows, IP addresses) run on
   a **5-minute "extended" cadence**. At most **4 servers refresh
   concurrently**. Since 2026 all commands and parsers live in a Rust crate
   (`sbm_parser`) shared by the app (via FFI) and an optional agent.
2. **Agentless hits a hard wall on mobile.** Every app that offers widgets,
   push alerts or watch complications that update while the app is closed
   either needs a server-side component (ServerBox Monitor agent, iStat Server,
   Beszel hub, Secure ShellFish's `widget` shell command) or only alerts while
   the app is running in the foreground (Meows, ServerGlance). iOS budgets
   widgets at roughly 40-70 reloads/day; Android periodic work is limited to
   15-minute intervals and `dataSync` foreground services to 6 h per 24 h
   (Android 15+).
3. **The common complaint is portability, not features.** ServerBox issues
   cluster on Synology/QNAP/Unraid NAS, OpenWrt/procd, BusyBox, snap-installed
   Docker, `DOCKER_HOST` confusion, Swarm task names and parse failures on odd
   hosts. A ServerCat reviewer: the dashboard "doesn't work for any systems
   other than Debian / Ubuntu servers." Termix documents Linux-only metrics and
   root-filesystem-only disk stats.
4. **Docker support in native apps is shallow.** Mobile apps typically offer
   list, start/stop/restart, logs and maybe exec. ServerBox deliberately never
   runs `docker compose` subcommands (it only groups by compose labels).
   ServerKeep and NeoServer go a bit further. Nobody native matches
   Portainer/Dockhand-class stack management (compose edit/redeploy, image
   update detection, volumes/networks, events) over plain SSH.
5. **Nobody combines an E2E-encrypted, self-hosted synced server list with
   terminal + SFTP + monitoring + Docker across five platforms in open
   source.** ServerBox is close on features (AGPLv3, 5 platforms + watch), but
   syncs via iCloud/WebDAV backups. XPipe syncs via git and is desktop-only.
   Termix is self-hosted but Electron/web with a central server that holds
   credentials. Termius (subscription) has no monitoring at all.
6. **UX patterns worth copying**: ServerBox's density modes (auto / cards /
   rows / grid) and single "pressure bar"; k9s's `:` command mode, `/` filter
   with label/fuzzy/inverse variants, `--readonly`, Tab+Enter delete
   confirmation and XRay drill-down; Docker Desktop's column chooser, bulk
   selection by compose project and log search with regex; ServerGlance's
   "share a status card with host/IP hidden by default"; Secure ShellFish's
   server-driven widgets via one shell command.
7. **Android has a vacuum.** JuiceSSH (with its 2016 performance plugin) was
   unpublished from Google Play on 2025-12-11 (secondary sources). Android
   options are now ServerBox (F-Droid/GitHub only, not on Play), DaRemote,
   Meows (Android 14+, US$4.99) and Termix's client.

---

## 1. Tool-by-tool survey

### 1.1 ServerBox (lollipopkit/flutter_server_box), deep dive

**Facts.** Flutter + Rust, AGPLv3 with a CLA so the author can ship App Store
builds. Platforms: iOS, iPadOS, macOS (App Store build is Apple-silicon-only
and sandboxed, so no local terminal; DMG build has one), Android (GitHub,
F-Droid, OpenAPK; not Google Play), Linux, Windows, plus a watchOS app
(watchOS 10+) and iOS/Android home widgets. App v1.0.1719 released
2026-10-01 on GitHub (App Store shows Oct 2); it added RDP/VNC tunnelled over
SSH or the agent, Proxmox VE and libvirt/KVM management, a theme store and
agent-based port forwarding. Monitor agent v0.2.0 (2026-10-01) added accounts,
roles and permissions. App Store: free, 4.9/5 from 91 ratings. 16 languages.
Uses forks of dartssh2 and xterm.dart as git submodules.

**Architecture (2026).** "Rust owns what is said to a server; each client
owns its state and UI." Every command, parser and model lives in
`crates/sbm_parser` (about 19k lines of Rust plus fixture tests, including
`alpine_e2e.rs`, `hostile_input.rs`, fixtures for BusyBox `ps`, OrbStack `df`,
ImmortalWrt `df`, btrfs/nested `lsblk`, macOS `smartctl`). The Flutter app
calls it through `flutter_rust_bridge`; the agent links it directly; the
agent's Svelte web panel goes through the agent. Dart never builds a command
or parses output. A server can be reached over SSH, the Monitor agent's HTTP
API, both (SSH leads, agent is fallback), or "this device". One function,
`ServerNotifier.ensureExec()`, is the only place a command reaches a server.

**Collection mechanics (status).**
- The app generates a script from a command manifest
  (`crates/sbm_parser/src/commands.rs`), installs it with
  `mkdir -p DIR; cat > PATH; chmod 755 PATH` (payload on stdin), then runs
  `sh PATH -s`. On Windows the same is done through an encoded PowerShell
  command. A new SSH connection marks the script as unwritten, because a
  reboot may have cleared the host's temporary directory.
- Script header: `export LANG=en_US.UTF-8`; detects Darwin/BSD via
  `uname -a | grep`; detects BusyBox via `ls -l /bin/sh | grep busybox`;
  records `id -u`; `exec 2>/dev/null` for its own probes. The status functions
  then switch to `exec 2>&1` so each failing command's error text lands inside
  its own segment ("attribution by construction"); routinely failing probes
  (thermal zones, power supplies) keep their own `2>/dev/null` so absence
  draws as absence, not as an error.
- Segments: `echo SrvBoxSep.<key>` before each command. Marker names are
  base64url-encoded (`SrvBoxSep.b64.<...>`) so command output that happens to
  print a marker cannot open a fake section. Output order is wire format.
- Each function ends with `:` so a final `grep` that matched nothing (e.g.
  `model name` absent on arm64) does not make a healthy run look failed.
- Poll interval: `Defaults.updateInterval = 3` seconds (user-configurable).
  Extended function (`SbStatusExt`: SMART, AMD on Windows, IP list) every
  5 minutes, because polling `smartctl` every few seconds keeps spun-down disks
  awake and increments `Load_Cycle_Count`. `smartctl -n standby` is used so a
  standby disk is not woken.
- Transport: a persistent interactive shell channel per server for status;
  on timeout it falls back to one exec channel per command for that
  connection. Windows always uses exec. A global `ServerRefreshScheduler` caps
  concurrent refreshes at 4 and deduplicates overlapping requests from timer,
  lifecycle and user actions.
- Rates (CPU %, network/disk throughput) are computed client-side from raw
  counters across samples; parsers stay pure.
- Custom commands are files in `$HOME/.config/server_box/custom_cmds/`
  (`NNNNN_<base64url name>`, sparse order step 100), each run with
  `sh "$f"` under a 5 s timeout (with a `setsid`/kill-tree fallback where
  `timeout` is missing), output capped at 64 KiB via `ulimit -f` and returned
  base64-encoded. A command named `server_card_top_right` renders on the
  server card itself. App and agent share the same files.

**Processes.** One shell function prints a header plus one row per process
using only shell builtins (`read`, `set --`, parameter expansion), because
the previous version spawned two `awk`s per process (800 spawns per poll on a
400-process box). Reads `/proc/<pid>/stat` for PPID, nice, threads and
`starttime`, and `/proc/<pid>/io` for read/write bytes. It asks `ps` itself
whether it supports `-o %cpu=`; if not (BusyBox), it parses `ps w`. This
matters on Alpine with procps installed, where the shell is BusyBox but `ps`
is procps. `START_ID` (Linux `starttime`, BSD `lstart`, Windows creation
ticks) is checked before a kill, so a recycled PID is refused rather than
killed. Load average comes first as `SrvBoxProc.Load 1m 5m 15m`.

**Services.** A detection script identifies the manager from PID 1
(`/proc/1/comm`), `/run/systemd/system`, `procd`+`ubus`, `rc-status`/
`rc-service`, then s6, runit, upstart, launchd, sysvinit. Supported backends:
systemd (four calls: `list-units --all --no-legend --no-pager --plain
--type=service,socket,mount,timer` and one bulk `systemctl show
--property=Id,UnitFileState,SubState,Result,ExecMainStatus,MemoryCurrent,
...Timestamps,NextElapseUSecRealtime` per scope, system and `--user`),
procd (walk `/etc/init.d` + `ubus` dump) and OpenRC (catalog + `rc-status` +
`rc-update show`). Timestamps are read with `env TZ=UTC LC_ALL=C` (because
`--timestamp=unix` needs systemd 251, newer than Debian 11/RHEL 8) together
with the server's `date +%s`, so durations are computed on the server's clock.
Recent logs: `journalctl --no-pager --output=short-iso -n N -u UNIT`, or
`logread -e NAME | tail` on OpenWrt; none for OpenRC. Reading never uses sudo
("a password prompt belongs to an action the user took"); actions do, except
systemd user units, where `sudo systemctl --user` would talk to root's
manager.

**Cron.** Only the logged-in account's crontab: `crontab -l` (not the spool
file, whose path varies and needs root) and `crontab -` to save. No `-u`, no
`/etc/cron.d`, no systemd timers in the cron page (timers do appear in the
services list with their next-elapse time). Schedule expansion is returned as
numbers in the server's wall clock; wording is localized client-side.

**Docker and Podman.** One feature, two dialects. Commands:
`docker ps -a --format "{{.ID}}\t{{.Status}}\t{{.Names}}\t{{.Image}}\t
{{.Label "com.docker.compose.project"}}\t{{.Label
"com.docker.compose.project.working_dir"}}\t{{.Ports}}"`,
`podman ps -a --format "{{json .}}\t{{.Status}}"`,
`stats --no-stream --format "{{json .}}"`, `image ls --digests`,
`system df` (fetched separately because it is slow on hosts with many
images), `version`. Several are batched into one `sh -c` with a fresh
per-refresh separator so a late answer cannot be mistaken for the current
one. Host override via `DOCKER_HOST` / `CONTAINER_HOST`; under sudo it travels
as `sudo -S env LANG=... DOCKER_HOST=... docker ...` because
`sudo -S export ...` would be lost. Detects "not installed" (exit 127 or
messages) and Podman's Docker emulation ("Emulate Docker CLI using podman")
before parsing. Stats rows are matched to containers by exact ID, not short
substring. Actions: start/stop/restart/rm/rm -f, container/volume/image/system
prune (including `system prune -a --volumes -f`), pull, `rmi`, `run -itd`
with every user-typed argument shell-quoted, `logs -f --tail 100` and
`exec -it ... sh -c "bash || ash || sh"` in the terminal. **No compose
subcommands**; compose shows up only as grouping labels.

**Other modules** (all agentless over SSH unless noted): users (`getent`,
`useradd/usermod/userdel` restricted to flags BusyBox also accepts; password
via `chpasswd` on stdin), firewall (ufw and firewalld parsers and change
builders), SMART, GPU (NVIDIA `nvidia-smi -q -x`, AMD via DRM sysfs, Intel via
`intel_gpu_top -J`), iperf/benchmarks, tmux control mode, BMC via Redfish,
Proxmox VE API and libvirt, RDP (IronRDP) and VNC through SSH tunnels, a
"globe" view that geolocates servers from an on-device city dataset, an LLM
agent that proposes actions for review, and "program status" (reads OSC 7501,
OSC 9;4 and OSC 133 from terminal output to show waiting/finished/failed dots,
notifications and an iOS Live Activity).

**Privilege.** Passwords never go on the command line: `sudo -S` reads them
from stdin. `sudo_password_rejected()` recognizes both classic sudo and
sudo-rs phrasings (Ubuntu ships sudo-rs as `sudo` since 25.10) so a wrong
password can be re-prompted instead of looking like a failed command.
SMART uses `sudo -n` only when the device node is not readable, so it fails
fast without prompting.

**Mobile specifics.** Widgets, push and the watch app all **require the
Monitor agent** (Rust, port 3770, SQLite history, 7 s sampling by default,
example alert rules in `config.example.toml`: CPU >= 77 %, memory >= 85 %,
disk >= 90 %, default rate limit 1 per minute). Widgets and the watch read the agent's `/api/v1/metrics` directly
with a scoped read-only token minted per device (90-day lifetime). iOS widget
needs iOS 17 (for `AppIntentConfiguration` server picking); two fixed sizes
(small = text readings, medium = one chart per metric), deliberately not
configurable beyond server and leading metric. Push channels: webhook,
ServerChan, Bark and "ios", the last via the author's relay at
`push.lolli.tech`, because only the app publisher holds the APNs key. Android
keeps SSH alive in the background with a foreground service and persistent
notification; iOS sessions are suspended and reconnect on return.

**UX patterns.** Server list density enum: `auto` (default, whatever fits),
`cards` (one reading drawn in full, rest as rows), `rows` (fixed-height line
with name, two bars and a rate, so an unreachable machine does not push others
down), `grid` ("what a wall of forty is for"). A segmented "pressure bar"
shows CPU/mem/disk in fixed colors and order, used on tiles, rows and a strip
summarizing the whole list; over-threshold segments turn warn-colored, stale
data turns grey. Bulk selection bar (connect/disconnect/refresh selected).
Detail page is a configurable, reorderable list of cards (about, CPU, RAM,
swap, GPU, disk, SMART, net, sensors, temperature, battery, PVE, BMC, custom).
macOS menu bar with Cmd-1..9 tab switching. Destructive container actions go
through confirmation dialogs.

**Complaints** (GitHub issues by reactions/comments; App Store reviews):
- NAS and appliance hosts: Synology DSM 7 (#27), QNAP (#100), Unraid and
  ASUSTOR (#86), OpenWrt/Alpine containers (#167), OpenWrt 25.12/iStoreOS
  with procd and no systemctl (#1363, 2026-08).
- Docker discovery: "echo $DOCKER_HOST is empty" confusion (#162, #100),
  snap-installed Docker unreadable (#969), Swarm task names crashing the `ps`
  parser (#1226, 2026-07), blank Docker page after an update (#883).
- Parser fragility on unusual systems: "Segments not match: 12" on Padavan
  routers and PVE (#184), `/dev/mapper` disk names breaking the agent (#75).
- Stability after updates: crashes on SSH open (#616, #623), "unable to run
  after last update" (#912), crash viewing logs (#1008), crashes when terminal
  and AI agent are open together (#1372, 2026-08).
- Other: private key import (#432), iCloud sync bug (#698), WebDAV backup
  (#667), Android widget not connecting (#951), Flatpak request (#490),
  historical data request (#620).
- App Store: "probably the best iOS SSH and sftp monitoring app"; one
  reviewer says monitoring "mostly works on macOS hosts" (quoted as written).

**Takeaways for Hauntware.** (a) The script-upload + segmented-output model
works and survives edge cases when backed by fixture tests per distro. (b) A
single canonical command/parse layer shared by the app and any optional agent
avoids two implementations drifting. (c) Most bug reports are about hosts that
are not mainstream Linux; budget for that. (d) Anything that must work while
the app is closed needs a server-side or always-on component.

Sources: https://github.com/lollipopkit/flutter_server_box (README,
CLAUDE.md, `crates/sbm_parser/src/{commands,script,container,service,cron,
users}.rs`, `lib/data/provider/server/{single,all,refresh_scheduler}.dart`,
`lib/core/service/CLAUDE.md`, `monitor/README.md`,
`monitor/config.example.toml`, `docs/src/content/docs/**`);
https://github.com/lollipopkit/flutter_server_box/releases;
https://apps.apple.com/us/app/server-box/id1586449703;
GitHub issues #27, #75, #86, #100, #162, #167, #184, #432, #490, #616, #620,
#623, #667, #698, #883, #912, #951, #969, #1008, #1226, #1363, #1372.

### 1.2 ServerCat (Early Moon, LLC)

- Platforms: iPhone, iPad, Mac, Apple Vision (iOS 17+, macOS 14.1+). No
  Android, no Watch listed.
- Price: free; Premium US$5.99/year or US$18.99 lifetime.
- Collection: agentless; "only needs an SSH account ... will not install any
  tools to your system."
- Free: per-core CPU, GPU usage and processes, memory, network speed and TCP
  stats, Docker containers and stats, disk blocks and IOPS. Premium: terminal,
  iCloud sync, create/manage containers, background SSH.
- Recent (v26.7.x to 26.9.2, Sep 29, 2026): configurable refresh interval,
  per-server startup command, SSH keepalive, home-screen widgets for network
  traffic, disk and container counts, real-time sync.
- Rating 4.6 (about 1K). Complaints: stats "doesn't work for any systems other
  than Debian / Ubuntu servers"; container management "has also not worked for
  me"; sync "so slow it may as well not exist"; poor handling of dropped VPN
  connections.

Source: https://apps.apple.com/us/app/servercat-ssh-terminal/id1501532023

### 1.3 NeoServer (MakerNeo)

- Platforms: iPhone, iPad, Mac, Vision (iOS 16.4+, macOS 13.3+). No Android.
- Price: free with IAP (US$1.99/week, 3.99/month, 24.99/year, 59.99
  lifetime). Rating 4.8 (295).
- Agentless ("No Agent installation required"). Monitoring: uptime, load,
  CPU, memory, GPU, disk I/O, network. Widgets for key metrics; a push
  notification widget and notification center for custom pushes.
- Processes with column sort and signals. Docker **and Podman**: status,
  logs, inspect, create/start/stop/restart/pause/delete, images and resources
  (no compose mentioned). Batch scripts across server groups with execution
  history. Wake-on-LAN and remote shutdown. Mosh, tmux/zellij integration,
  ZMODEM, jump hosts, SOCKS5, ML-KEM post-quantum KEX. BYO-LLM assistant.
  iCloud sync, Face ID lock.
- Reviewer: "the best interface for server monitoring in my 25 years of
  servitude."

Source: https://apps.apple.com/us/app/neoserver-docker-ssh-sftp/id6448362669

### 1.4 ServerBuddy (macOS)

- Native Swift/SwiftUI macOS app managing Linux servers over SSH; "no
  agents/scripts to install." Free for one server, US$59 one-time for
  unlimited (one year of updates).
- Real-time CPU/memory graphs, disk, uptime; **sortable/filterable tables**
  for processes, Docker containers, systemd services, network ports and logs;
  file browser; terminal; key-value tags for search. A directory listing also
  claims user, package, cron and log management (single source).
- Show HN discussion: skeptics prefer Ansible; supporters answered "Tell me
  how you use Ansible to check cron jobs, docker container states and read
  logs." One user prefers it to installing Cockpit on servers "which I then
  tend to forget about." Linux-only because Packages/systemd tabs are
  distro-specific. Requests: GPU monitoring, file browser sorting.

Sources: https://hn.svelte.dev/item/44867184 ;
https://taoofmac.com/space/apps/serverbuddy

### 1.5 XPipe (connection hub, desktop)

- Windows, macOS, Linux (many package formats) plus a Docker "webtop" image.
  Open core: Apache-2.0 community edition; closed homelab/professional
  extensions. Pricing: Homelab US$5/month or 40/year, Professional US$10/month
  or 80/year, Enterprise quote. Latest seen: 24.5 (Oct 4, 2026).
- Mechanism: runs on top of locally installed CLIs (ssh, docker, kubectl,
  etc.) and opens shell sessions; nothing installed remotely.
- Integrations: SSH config and tunnels, Docker and Compose, Podman, LXD,
  Incus, Proxmox, Hyper-V, KVM, VMware, Tailscale, Netbird, Teleport, AWS,
  Hetzner, Kubernetes, RDP, VNC, WSL, PowerShell remoting, network switches.
- Hierarchical connection tree; encrypted vault synced and shared via a
  self-hosted **git repository**; password manager integration; remote file
  browser with mid-session sudo elevation; one-click terminal launch into the
  user's preferred terminal; reusable scripts placed on remote PATH; built-in
  MCP server.
- UX lesson: a connection tree where containers and VMs appear as children of
  their host, so "fleet -> host -> container -> shell" is one tree.

Sources: https://github.com/xpipe-io/xpipe ;
https://github.com/xpipe-io/xpipe/releases ; https://xpipe.io/pricing

### 1.6 Termius, and Termix as the self-hosted counterpart

**Termius**: desktop 10.1.x, iOS 7.9.0, Android 7.11.0 (Sep 2026). The
official changelog has no monitoring, metrics, Docker or container entries.
Focus is terminal, SFTP, sync, AI command generation/autocomplete, SSH ID
(passkey-style auth), post-quantum crypto; in Sep 2026 proxy, agent
forwarding, host chains and serial became free. Relevant mainly as the
benchmark for a polished synced host list and team vaults.
Source: https://docs.termius.com/changelog

**Termix** (Apache-2.0, "self-hosted alternative to Termius"): server in
Docker (SQLite/Postgres/MySQL) with web/PWA, Electron desktop and iOS/Android
clients. Features: SSH with split panes and a live CPU/mem/disk toolbar above
each session, RDP/VNC via guacd, tunnels, SFTP, Docker/Podman management (not
meant to replace Portainer), host metrics with history (7 days default,
configurable 1-90), alerts via ntfy/Discord/webhook, automations, RBAC, OIDC/
LDAP/passkeys. Metrics are collected over SSH from `/proc/stat`,
`/proc/meminfo`, `df`, `ip`, `ps`, `ss`/`netstat`, `iptables`/`nft`;
**Linux only**, **disk metrics only for `/`**, firewall needs root.
Anonymous telemetry on by default. Architecture difference that matters: the
central server stores credentials and does the polling, so alerts work with
clients closed, but the server is a high-value target.
Sources: https://github.com/Termix-SSH/Termix ;
https://docs.termix.site/features/networking/host-metrics

### 1.7 Terminal-first iOS clients (no fleet monitoring)

- **Secure ShellFish**: server-driven widgets. With Shell Integration
  installed, `widget cpu.fill 23% CPU drive 68% HDD` (runnable from cron)
  defines Home Screen, Lock Screen, StandBy widgets and Apple Watch
  complications; Live Activities for long-running tasks; Files/Finder
  provider for server directories; Shortcuts actions; tail logs in
  Picture-in-Picture. Freemium. This is the cleanest "agentless-ish widget"
  pattern: the server pushes a tiny payload when the user decides.
  Sources: https://secureshellfish.app/help/ ;
  https://secureshellfish.app/help/widgets
- **Prompt 3 (Panic)**: SSH, Mosh, Eternal Terminal, Telnet; Clips (snippets
  global or per server on the keyboard bar); Panic Sync for servers, keys and
  clips. Jump hosts. Source: https://apps.apple.com/app/id1594420480
- **Blink Shell**: Mosh/SSH, Secure Enclave keys, `geo track` uses location
  services to keep SSH alive in the background (Termius and Prompt use similar
  location-based keepers). Source: https://docs.blink.sh/basics/notifications
- **WebSSH** (v33.0, Sep 30, 2026; iOS 26+; US$15 Pro): SSH/Mosh/SFTP/serial,
  network tools, and a **Proxmox client** (node CPU/mem/storage, VM/LXC
  start/stop/migrate). General server-health monitoring was removed in 31.0.
  Source: https://apps.apple.com/us/app/webssh-ssh-client/id497714887

### 1.8 Newer small SSH-monitor apps and Android options

| App | Platforms | Price | Notes |
|---|---|---|---|
| ServerGlance | iPhone | Free, Pro US$4.99 | Fleet overview aggregating CPU/RAM/net; threshold alerts; Docker start/stop/restart with confirmation prompts; **share a status card with host/IP hidden by default**; host key change warning; auto-reconnect. https://apps.apple.com/app/id6758614736 |
| ServerKeep | iPhone (Mac unverified) | US$9.99 IAP | Memory split into used/page cache/available; CPU breakdown heatmap; **Docker Compose grouping, lifecycle, view/save compose config**; snippets. v3.0.0 Jul 2026. https://apps.apple.com/sb/app/serverkeep/id6759196608 |
| DaRemote | Android (Flutter) | Free for 3 servers, ~US$8 one-time | Agentless; Linux, FreeBSD, macOS (Windows claimed); CPU/proc/mem/disk per mount with R/W speed; Docker start/restart/pause/stop; SFTP; proxies. https://alternativeto.net/software/daremote/about |
| Meows | Android 14+ | US$4.99 one-time | Agentless; 1/2/5-min history; alerts for thresholds and disconnects **only while monitoring runs on device**; Docker controls and live logs over SSH; credentials in Android Keystore. https://lowendspirit.com/discussion/11336/ |
| JuiceSSH | Android | (gone) | Unpublished from Google Play 2025-12-11; Pro licences broke; its Performance Monitor plugin (last 2016) ran periodic commands over a background session. Secondary sources: https://termai.sh/blog/juicessh-removed-play-store , https://hn.nuxt.dev/item/46768909 |
| Beszel Companion | iOS | Free | Client for the Beszel hub (agent-based); charts and per-container usage. https://apps.apple.com/py/app/beszel/id6747600765 |
| Portainer clients | iOS/Android | various | No official Portainer mobile app found. Third-party: Kontainer (iOS), Pourtainer (iOS), "Portainer - Docker Manager" (Android, API token), Portarius (Flutter, inactive since 2023). All need a Portainer server. |

### 1.9 iStat View + iStat Server (Bjango)

Agent model: iStat Server (open-source daemon for Linux, BSDs, AIX, Solaris;
plus Mac and Windows builds) transmits CPU, memory, disk, network,
temperatures and fans to iStat View on iOS/Mac, over the internet or Bonjour,
protected by a 5-digit passcode. It installs no boot scripts by itself. Shows
the long-standing trade: polished native charts and low-overhead streaming
in exchange for a daemon on every host.
Sources: https://bjango.com/istatserver/ ;
https://git.unsupervised.ca/GitHub/istatserverlinux/src/branch/master/README

### 1.10 Cockpit Client (Flathub): "beam the bridge"

Cockpit Client connects over SSH and runs Cockpit's **Python bridge** on the
target, so the host needs only SSH, Python 3.6+ and sudo for privileged
pages; no Cockpit packages, web server or open port. Pages appear only when
the host has the backing feature (e.g. libvirt-dbus for VMs). This is a third
option between pure shell commands and a resident agent: a **transient
helper** shipped per session. Source:
https://fedoramagazine.org/using-cockpit-to-graphically-manage-systems-without-installing-cockpit-on-them/
(2023-08-16)

### 1.11 TUIs

**k9s** (v0.51.0, 2026-06-06). The keyboard model to emulate:
- `:` command mode with resource name/alias, optional namespace, filter,
  labels or context (`:pod ns-x`, `:pod /fred`, `:pod app=fred`,
  `:pod @ctx1`); `:ctx`, `:ns`; `-` last command; `[`/`]` history; `esc`
  back; `?` contextual help; `ctrl-a` all aliases.
- `/` filter: regex, `/!` inverse, `/-l` labels, `/-f` fuzzy.
- `d` describe, `y` YAML, `l` logs (`p` previous), `s` shell, `a` attach,
  `e` edit, `shift-f` port-forward, `space`/`ctrl-space` mark rows for bulk.
- **Destructive**: `ctrl-d` delete requires Tab then Enter to confirm;
  `ctrl-k` kill has no confirmation. Plugins can declare `confirm: true` and
  `dangerous: true` (disabled in read-only mode). Since v0.51 plugins with
  inputs default to confirm.
- `--readonly` or per-cluster `readOnly: true` disables all mutations.
- `:pulses` dashboard, `:xray` dependency tree, `:popeye` sanitizer
  (health lint), `shift-j` jump to owner, `ctrl-w` wide columns, `ctrl-z`
  faults-only toggle.
- `hotkeys.yaml`, `plugins.yaml`, `aliases.yaml`, skins.
Sources: https://github.com/derailed/k9s ; https://k9scli.io/ ;
https://github.com/derailed/k9s/releases

**btop++** (config references v1.4.5): Linux, macOS, FreeBSD, NetBSD,
OpenBSD; CPU/mem/net/proc boxes plus up to 6 GPU boxes (NVIDIA NVML, AMD ROCm
SMI, Intel sysfs, Apple Silicon); 9 layout presets; process tree with
aggregation; send any signal; follow a process; braille/block/TTY graph
modes; every highlighted key is also a clickable button.
Source: https://github.com/aristocratos/btop

**htop**: `/` search, `\` filter, `t` tree, `.` sort, `k` kill, F2 setup;
platforms Linux, macOS, BSDs, Solaris; optional PCP backend.
Source: https://github.com/htop-dev/htop

**Glances**: psutil-based; TUI, web UI (`-w`, port 61208), REST API,
client/server, network discovery (`--browser`), **MCP server** (4.5.1+,
`--enable-mcp`); plugins include containers (Docker, Podman, LXC), GPU, RAID,
SMART, sensors, ports, SNMP; exports to InfluxDB, Prometheus, Elasticsearch,
Kafka, etc. Four-level color model: OK (green), CAREFUL (blue), WARNING
(magenta), CRITICAL (red); an alert view lists only stats with colored
backgrounds. Sources: https://github.com/nicolargo/glances ;
https://glances.readthedocs.io/en/latest/aoa/index.html

**ctop**: grid view of container metrics plus single-container view (`o`);
sort, filter, column config, logs, exec; connectors Docker and runC. Last
tagged v0.7.7 (no newer release visible); effectively unmaintained.
Source: https://github.com/bcicen/ctop

**lazydocker**: panels for project, containers/services, images, volumes;
logs (last hour by default), ASCII metric graphs, attach, restart/remove/
rebuild, image layer ancestry, prune, custom commands, mouse. Talks to the
local Docker socket/context. Source: https://github.com/jesseduffield/lazydocker

**lazyjournal** (MIT, Go): one TUI for journald (system/user/kernel per
boot), `/var/log` files including gz/xz/bz2 archives, Docker/Swarm/Compose
(stacks merged and time-sorted), Podman, k8s/k3s; **`--ssh user@host`** with
a host switcher (F2); filter modes exact, fuzzy, regex (input turns red on
syntax error) and date range; built-in highlighting groups for errors,
warnings, IPs, HTTP codes, etc. Strong evidence of demand for a unified
log explorer. Source: https://github.com/Lifailon/lazyjournal

### 1.12 Lens / OpenLens / Freelens

- **Lens** (Mirantis, now lenshq.io): Personal free for small orgs (under
  US$10M revenue/funding); Plus US$25-30/month, Pro US$25-30/seat/month,
  Enterprise US$50-60/seat/month; AI ("Ask AI", built-in MCP server, cost
  optimization) in paid tiers. Source: https://lenshq.io/pricing
- **Freelens**: MIT fork of OpenLens (copyright 2024-2026), macOS 12+,
  Windows 10+, Linux (glibc 2.34+; deb/rpm/AppImage/Flatpak/Snap); uses
  kubeconfig; OpenLens extensions ported. Source:
  https://github.com/freelensapp/freelens
- UX lessons: a left "catalog/hotbar" of clusters, overview page with
  workload status rings, resource tables with a slide-in detail drawer, and a
  bottom dock that hosts terminals and log tabs. The dock pattern is directly
  reusable for "server dashboard + persistent bottom panel with terminal,
  logs and command output."

### 1.13 Local container desktops

**Docker Desktop** (4.85.0 seen, 2026-08-03; Gordon AI GA in 4.74.0,
2026-05-19; Extensions off by default since 4.74.0). Containers view: search,
"only running" toggle, **Columns chooser** (CPU %, memory usage/limit and %,
disk R/W, network I/O, PIDs, last started) persisted across sessions, compose
apps grouped with expand/collapse, **checkbox bulk actions; selecting a
compose project selects all its containers**. Row actions include open
terminal, open exposed port in browser, copy `docker run` command, Docker
Debug, view image CVEs. Detail tabs: Logs (Ctrl/Cmd-F search with match
stepping, regex or exact match, timestamps, clickable links, per-container
filter in compose apps, export since 4.77.0), Inspect, Bind mounts, Exec,
Files (browse, edit, drag-drop, diff of changed files), Stats charts.
Sources: https://docs.docker.com/desktop/use-desktop/container/ ;
https://docs.docker.com/desktop/release-notes/

**OrbStack** (macOS): free for personal use; Pro US$8/user/month or 96/year
(adds Debug Shell); Enterprise with SAML. Native Swift UI, menu-bar
management, low background CPU, local domain names, Linux machines.
Sources: https://orbstack.dev/ ; https://orbstack.dev/pricing

### 1.14 Launcher extension

**Raycast "Docker"** (Priit Haamer, about 53K installs, macOS and Windows):
Manage Containers, Manage Compose Projects, Manage Images. Connects via a
socket preference (`unix://`, `npipe://`, `tcp://`, `http(s)://`) or the
current `docker context`, honoring `DOCKER_HOST`/TLS variables. Lesson:
`docker context` is the user's existing source of truth for runtime
endpoints; a desktop app can import contexts the way Seance imports
`~/.ssh/config`. Source: https://www.raycast.com/priithaamer/docker

### 1.15 Summary matrix

| Tool | Desktop | Mobile | Collection | Docker depth | Background alerts | License/price |
|---|---|---|---|---|---|---|
| ServerBox | mac/Win/Linux | iOS/Android/watch | SSH script; optional agent | list/stats/actions/logs/exec, no compose ops | agent only | AGPLv3, free |
| ServerCat | macOS | iOS | SSH | list/stats; create/manage (Premium) | no | US$6/yr or 19 |
| NeoServer | macOS | iOS | SSH | Docker+Podman CRUD, logs | custom push | subs/59 lifetime |
| ServerBuddy | macOS | - | SSH | table + actions | no | US$59 |
| XPipe | all 3 | - | local CLIs | shells/lifecycle | no | open core |
| Termix | Electron/web | iOS/Android | server polls via SSH | basic | yes (server) | Apache-2.0 |
| ServerGlance/ServerKeep | - | iOS | SSH | start/stop; compose (ServerKeep) | in-app only | IAP |
| DaRemote/Meows | - | Android | SSH | start/stop/logs | in-app only | one-time |
| iStat View | macOS | iOS | agent | - | - | paid |
| Docker Desktop/OrbStack | local only | - | Engine API | full, local | n/a | commercial |
| k9s/lazydocker/btop | TUI | - | API / procfs | k8s / full Docker | no | OSS |

---

## 2. Best-in-class UX patterns

### 2.1 Fleet overview

- **Density as a first-class control, with an automatic default** (ServerBox):
  cards for a handful of servers, fixed-height rows for dozens (unreachable
  hosts must not change row height), a grid of tiles for 40+, and `auto`
  choosing by count and window size.
- **One composite "pressure" glyph per server** (ServerBox): CPU, memory and
  disk in fixed order and colors, with a strip summarizing the whole filtered
  list. Readable at a glance on a phone; color means "which metric", a warn
  color means "over threshold", grey means "stale".
- **Explicit staleness and three-state reachability.** Seance already has
  `ProbeStatus { online, offline, unknown }` (unknown = filtered/behind a
  bastion). Combine with "last sample N s ago" per row.
- **Aggregate header** (ServerGlance): total CPU/RAM/network across the fleet
  and counts of servers needing attention.
- **Attention-first sorting/filters**: offline, failed units, restarting or
  unhealthy containers, disks above threshold, pending updates. k9s's
  `ctrl-z` "faults only" toggle is the keyboard equivalent.
- **Groups and tags** (ServerBuddy key-value tags; Seance groups; XPipe
  hierarchy), plus bulk selection for refresh/connect/run-snippet across a
  selection (ServerBox bulk bar, NeoServer batch scripts with history).
- **Map view** is a nice-to-have (ServerBox globe) and privacy-sensitive; do
  local geolocation only.

### 2.2 Single-server dashboard

- Configurable, reorderable cards (ServerBox) with sensible defaults; hide
  cards the host cannot answer (Cockpit shows pages only if backing features
  exist) rather than drawing empty or error cards.
- Per-core CPU (ServerCat, ServerKeep heatmap), memory split into
  used/cache/available (ServerKeep), load average with core count context,
  per-mount disk with I/O rates (DaRemote), network per interface, temps.
- Short rolling history on the client (Meows 1/2/5 min) plus longer history
  only where an agent or always-on node records it (ServerBox Monitor 30 days,
  Termix 7 days default).
- A persistent **bottom dock** (Lens) for terminal, logs and command output so
  the dashboard stays visible; on phones this becomes a bottom sheet.
- Live mini-toolbar of CPU/mem/disk above terminal sessions (Termix): cheap
  cross-app integration with Seance.

### 2.3 Logs

- Live tail with pause-on-scroll, search with match stepping (Docker Desktop
  Cmd/Ctrl-F, Enter/Shift-Enter), regex vs exact toggle, case-sensitivity
  toggle (Docker Desktop 4.77), timestamps toggle, clickable links, export.
- Filter modes exact/fuzzy/regex with a visible invalid-regex state, and a
  time range (lazyjournal).
- Severity highlighting with fixed color groups (lazyjournal); journald
  priority filter; boot selector.
- Merge multiple sources by timestamp (lazyjournal for Compose stacks).
- Sources: journald units (`journalctl -u`, `--user`), container logs, files
  under `/var/log` (including rotated `.gz`), `logread` on OpenWrt.
- Picture-in-Picture tail on iPad (Secure ShellFish) for watching a deploy.

### 2.4 Container lists

- Group by compose project (label `com.docker.compose.project`) with
  expand/collapse and project-level bulk actions (Docker Desktop, ServerBox,
  ServerKeep).
- Column chooser with persisted choices (Docker Desktop), "only running"
  toggle, search by name/image/ID (Raycast).
- Row quick actions: logs, shell, restart; overflow menu for the rest; copy
  `docker run` equivalent; open published port in browser.
- Show health status and restart counts; flag crash loops (Docker Desktop
  Gordon suggestions flag repeated restarts).
- Prune flows that show reclaimable space first (ServerBox reads
  `docker system df` separately for this).
- Detect runtime dialects honestly: Podman pretending to be Docker, rootless
  sockets, snap Docker, Swarm tasks.

### 2.5 Destructive-action confirmation

- Tiered: no confirmation for safe/reversible (restart a container, refresh);
  a dialog naming the target for stop/kill; **two-step or typed confirmation**
  for irreversible or fleet-wide actions (k9s Tab+Enter for delete; type the
  server or container name for `system prune -a --volumes`, reboot, user
  deletion).
- Show the exact command that will run (k9s plugin `confirm` shows the
  command; ServerBox agent "review each action before it runs"; Seance's
  review-before-run gate and danger linter).
- Per-server and global **read-only mode** (k9s `--readonly`) that hides or
  disables every mutation, useful for production hosts and for sharing
  screens.
- Guard against stale targets: ServerBox's `START_ID` check before killing a
  PID is the model; for containers, act on full IDs, not names.
- Never put sudo passwords on the command line; feed `sudo -S` via stdin and
  detect rejection text (ServerBox, including sudo-rs messages).
- ServerGlance confirms critical Docker actions; on touch, prefer a
  confirmation sheet with a destructive-styled button over swipe-to-delete for
  anything irreversible.

### 2.6 Touch vs desktop

- Desktop: keyboard-first. A command palette (`Cmd/Ctrl-K` or k9s-style `:`)
  that jumps to `server/resource` with a filter; `/` to filter any list;
  single-key actions on the focused row (`l` logs, `s` shell, `r` restart,
  `ctrl-d` delete with confirm); `?` for contextual keymap; Cmd-1..9 for tabs
  (ServerBox macOS). Multi-pane: fleet list | server dashboard | dock.
- Mobile: master-detail stack, pull-to-refresh (ServerBox), swipe actions only
  for non-destructive ops, long-press for context menu, large tap targets,
  bottom sheets for logs/terminal, landscape for terminal, a terminal key bar
  (Esc/Tab/Ctrl/arrows) and snippets on the key bar (Prompt Clips).
- Shared: same information architecture so a user can move between Seance,
  Poltergeist and the new app with identical server marks/colors.

### 2.7 Mobile platform capabilities and constraints

| Capability | Constraint (primary source) | Implication |
|---|---|---|
| iOS widgets | Daily budget typically 40-70 reloads for a frequently viewed widget (about every 15-60 min); per-widget budgets; reloads while the app is foreground or via App Intents are free. iOS 26 adds WidgetKit push (`WidgetPushHandler`, APNs push type `widgets`) as a reload signal. https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date | Agentless widgets can only show the last value the app fetched; fresher data needs a server/relay. |
| iOS background refresh | `BGAppRefreshTask` is opportunistic and system-scheduled. https://developer.apple.com/documentation/backgroundtasks | Cannot poll servers reliably in the background. |
| iOS background SSH | Apps use location background modes as a keeper (Blink `geo track`, Termius, Prompt Connection Keeper). | Possible but costs battery and App Review scrutiny; not a monitoring strategy. |
| Live Activities | Updates for up to 8 h; Lock Screen can keep a stale one up to 4 more hours; push budget is dynamic, raised by `NSSupportsLiveActivitiesFrequentUpdates`. https://developer.apple.com/forums/thread/797676 ; https://wwdcnotes.com/documentation/wwdc23-10185-update-live-activities-with-push-notifications/ | Good for bounded tasks: a deploy, `docker compose pull && up`, a reboot-and-wait. |
| APNs push | Requires the publisher's APNs key; ServerBox relays through `push.lolli.tech`. | Hauntware ships an unsigned IPA today; push on iOS needs a signed build and a relay, or a third party like ntfy. |
| Android periodic work | `PeriodicWorkRequest` minimum 15 min. https://developer.android.com/reference/androidx/work/PeriodicWorkRequest | Coarse background checks are possible without an agent, but drain battery and require keys on device. |
| Android FGS | Android 15+: `dataSync`/`mediaProcessing` FGS limited to 6 h per 24 h, then `onTimeout`; must `stopSelf()` or crash. https://developer.android.com/develop/background-work/services/fgs/timeout | Long-lived SSH monitoring in background is time-boxed. |
| Android widgets | `updatePeriodMillis` minimum 30 min; apps can push updates when running. https://developer.android.com/develop/ui/views/appwidgets | Same as iOS: last-known value unless something pushes. |
| Apple Watch | ServerBox needs watchOS 10 and the agent; ShellFish complications via `widget`. | Defer; low value relative to effort. |

---

## 3. Catalog of agentless commands and files

Notation: [SB] = ServerBox `sbm_parser` manifest or module; [TX] = Termix
docs; [GEN] = common practice not verified in a surveyed tool's source.

### 3.1 Core metrics

| Metric | Linux (glibc and BusyBox) | macOS | FreeBSD | Windows (PowerShell) |
|---|---|---|---|---|
| OS detect | `echo __linux` segment; header uses `uname -a` grep for Darwin/BSD [SB] | `echo __bsd` | same | `echo __windows` |
| Time | `date +%s` [SB] | same | same | `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()` |
| OS name | `cat /etc/os-release /usr/lib/os-release \| grep -E '^(ID\|ID_LIKE\|PRETTY_NAME)='` fallback `/etc/*-release` [SB] | `uname -or` | `uname -or` | `(Get-CimInstance Win32_OperatingSystem).Caption` (not `Get-ComputerInfo`, which emits CLIXML progress through OpenSSH) |
| Hostname | `grep '[^[:space:]]' /etc/hostname \|\| uname -n` (OpenWrt/Termux lack the file; BusyBox has `uname -n` not always `hostname`) [SB] | `hostname` | `hostname` | `$env:COMPUTERNAME` |
| CPU usage | `cat /proc/stat \| grep cpu`; client computes deltas [SB][TX] | `top -l 1 \| grep "CPU usage"; sysctl -n hw.ncpu` (aggregate only) | `top -b -d 1 -P \| grep "^CPU"` (per core) | `Win32_Processor` LoadPercentage via `Get-WmiObject` |
| CPU model | `/proc/cpuinfo` `model name` (absent on many arm64) [SB] | `sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu` | same | `(Get-WmiObject Win32_Processor).Name` |
| Load | `/proc/loadavg` [SB] | `sysctl -n vm.loadavg` (`{ 1.4 0.9 0.7 }`) | same | n/a |
| Uptime | `uptime` [SB] (or `/proc/uptime` [GEN]) | `uptime` | `uptime` | `LastBootUpTime` |
| Memory | `/proc/meminfo` Mem*/Swap* using `MemAvailable` [SB][TX] | `top -l 1 \| grep PhysMem; vm_stat` (exclude cache/inactive) | `top -b -d 1 \| grep "^Mem:"` | `Win32_OperatingSystem` TotalVisibleMemorySize/FreePhysicalMemory |
| Disk usage | `lsblk --bytes --json --output FSTYPE,PATH,NAME,KNAME,MOUNTPOINT,FSSIZE,FSUSED,FSAVAIL,FSUSE%,UUID` else `df -k` (BusyBox/old util-linux lack lsblk JSON) [SB]; Termix reads `/` only | `df -k; mount` (mount types tell APFS container volumes apart) | same | `Win32_LogicalDisk` |
| Disk I/O | `/proc/diskstats` (skip loop) [SB] | n/a in SB | n/a | `Win32_PerfRawData_PerfDisk_LogicalDisk` (cumulative despite "Persec") |
| Network | `/proc/net/dev` [SB][TX] | `netstat -ibn` | same | two `Win32_PerfRawData_Tcpip_NetworkInterface` samples 1 s apart |
| TCP stats | `/proc/net/snmp` `Tcp:` line [SB] | n/a | n/a | `netstat -an \| findstr ESTABLISHED` count |
| Addresses | `ip -o addr show scope global \|\| ifconfig \|\| hostname -I` (slow cadence) [SB]; `ip` [TX] | `ifconfig` | `ifconfig` | `Get-NetIPAddress` |
| Temperatures | `cat /sys/class/thermal/thermal_zone*/{type,temp}` (millidegrees; pair counts must match) [SB]; `sensors` (lm-sensors, optional) [SB] | n/a | n/a | `MSAcpi_ThermalZoneTemperature` (often empty), `Win32_TemperatureProbe` |
| Battery | `/sys/class/power_supply/*/uevent` [SB] | n/a | n/a | `Win32_Battery` |
| GPU | `nvidia-smi -q -x` (also `/usr/lib/wsl/lib/nvidia-smi` on WSL); AMD from DRM sysfs `gpu_busy_percent`, hwmon temp/power/fan, VRAM; Intel `timeout 3s intel_gpu_top -J -s 500` [SB] | n/a | n/a | `nvidia-smi`, `amd-smi list --json` (slow, extended) |
| SMART | `lsblk -dn -o KNAME,TYPE` disks only (skip zram/loop), `smartctl -n standby -a -j /dev/X`, `sudo -n` if not readable; extended cadence [SB] | `diskutil list` physical only, `smartctl -n standby -a -j` (no sudo needed) | same | `Get-PhysicalDisk \| Get-StorageReliabilityCounter` |

### 3.2 Management surfaces

| Area | Commands | Portability notes |
|---|---|---|
| Processes | `ps -axo pid=,user=,%cpu=,%mem=,vsz=,rss=,tty=,stat=,time=,etime=,args=` plus `/proc/<pid>/stat` and `/proc/<pid>/io` via shell builtins; BusyBox: `ps w` (no %cpu) [SB]. Kill: verify start time first. | Probe `ps -o %cpu= -p $$` rather than `/bin/sh`. macOS/BSD: `ps -axo ...,lstart=,command=`. Windows: `Win32_Process` + `Win32_PerfFormattedData_PerfProc_Process`. |
| Service manager detection | PID 1 comm, `/run/systemd/system`, procd+ubus, OpenRC, s6, runit, upstart, launchd, sysvinit [SB] | Check procd before generic `/etc/init.d`. |
| systemd list | `systemctl [--user] list-units --all --no-legend --no-pager --plain --type=service,socket,mount,timer`; `env TZ=UTC LC_ALL=C systemctl show --property=... -- '*.service' ...` [SB] | `--timestamp=unix` needs systemd 251+. Failed units: `systemctl --failed` [GEN]. |
| Unit logs | `journalctl [--user] --no-pager --output=short-iso -n N -u UNIT`; OpenWrt `logread -e NAME` [SB] | `journalctl -o json` gives structured fields and `__REALTIME_TIMESTAMP` [GEN]; reading system journal may need `systemd-journal`/`adm` group. |
| Unit actions | `systemctl start/stop/restart/enable/disable UNIT` (sudo except `--user`); `rc-service NAME ACTION`; `/etc/init.d/NAME ACTION` [SB] | OpenRC enable/disable is `rc-update`, not `rc-service`. |
| Cron | `crontab -l`, `crontab -` with `LC_ALL=C`, run under `sh` (fish login shells reject POSIX syntax) [SB] | System cron: `/etc/crontab`, `/etc/cron.d/*`, `/etc/cron.{hourly,daily,...}` (root) [GEN]; timers: `systemctl list-timers --all` [GEN]. |
| Users | `getent passwd/group`, `getent shadow`, `passwd -S`, `sudo -nlU`; `useradd/usermod/userdel` with BusyBox-compatible flags; `chpasswd` on stdin [SB] | Linux only; macOS uses `dscl`. |
| Firewall | ufw and firewalld status/change builders [SB]; `iptables`/`nft` (root) [TX] | Read needs root on most systems. |
| Ports/connections | `ss -tulpn` / `netstat` [TX] | Process names need root. |
| Logins | system log files [TX]; `last`, `who` [GEN] | Access often restricted. |
| Updates | `apt list --upgradable`, `dnf check-update`, `apk version -l '<'`, `pacman -Qu`; `/var/run/reboot-required` (Debian/Ubuntu), `needs-restarting -r` (RHEL) [GEN] | Not in ServerBox; ServerBuddy claims package management. Keep read-only by default. |
| Power | `shutdown -h now`, `reboot`, `systemctl suspend`, each with `sudo -S` unless uid 0 [SB] | |

### 3.3 Containers

| Purpose | Docker | Podman | Notes |
|---|---|---|---|
| Detect | `docker version --format "{{json .}}"`; exit 127 / "not found" | `podman version` | Detect Podman emulation from stderr "Emulate Docker CLI using podman" [SB]. Snap Docker can break non-interactive access (#969). |
| List | `ps -a --format` with ID, Status, Names, Image, compose labels, Ports | `ps -a --format "{{json .}}\t{{.Status}}"` | Podman 4 vs 5 differ in `Names` shape [SB]. Swarm task names are long and dotted (#1226). |
| Stats | `stats --no-stream --format "{{json .}}"` | same (different fields per version) | Match by full ID [SB]. Takes about 1-2 s per call [GEN]; batch with `ps`. |
| Images | `image ls --digests --format "{{json .}}"` | same | |
| Disk use | `system df --format "{{json .}}"` | same | Slow on large hosts; fetch separately [SB]. |
| Logs | `logs -f --tail 100 ID` | same | Add `--timestamps`, `--since` for range [GEN]. |
| Exec | `exec -it ID sh -c "bash \|\| ash \|\| sh"` | same | |
| Lifecycle | `start/stop/restart/rm [-f]`, prune variants, `pull`, `rmi`, `run -itd` with quoted args | same | |
| Endpoint | `DOCKER_HOST` | `CONTAINER_HOST` | Under sudo pass via `sudo -S env VAR=...` [SB]. Rootless Docker socket `$XDG_RUNTIME_DIR/docker.sock`; rootless Podman needs no daemon. |
| Compose | not used by ServerBox (labels only) | `podman compose` / `podman-compose` | Gap: `docker compose ls --format json`, `-p NAME ps/pull/up -d/down/logs` [GEN]. |
| Events | not used | | Gap: `docker events --format "{{json .}}"` stream for live updates instead of polling [GEN]. |
| Alternative | Docker Engine API over the SSH-forwarded unix socket (`direct-streamlocal@openssh.com`) [GEN] | Podman REST API socket | Structured JSON, streaming logs/stats/events; requires socket access and dartssh2 support for streamlocal forwarding (verify). |

### 3.4 Transport techniques that matter

1. **Upload once, call by flag** (ServerBox): fewer bytes per poll, one
   round-trip, versioned script (`ScriptConstants.version` embedded in the
   file name). Reinstall on reconnect and when the version changes. Fallback
   directory when the temporary directory is read-only or `noexec`; run
   with `sh FILE` so the execute bit and `noexec` do not matter.
2. **Persistent shell channel for polling**, exec channel as fallback
   (ServerBox). Avoids per-poll channel setup; must handle prompt noise and
   timeouts.
3. **Segment markers that output cannot forge** (base64url names) and
   **per-refresh separators** for batched container calls.
4. **Locale and time hygiene**: `LANG`/`LC_ALL=C` for parseable output,
   `TZ=UTC` for timestamps, server `date +%s` alongside for skew.
5. **Run under `sh`, not the login shell**: fish and other non-POSIX shells
   break `VAR=x cmd` and `|| { }` (ServerBox cron and systemd notes).
6. **Errors inside segments** (`exec 2>&1` within status) so the UI can say
   *why* a reading is missing; routinely absent sources stay quiet.
7. **Cheap vs expensive cadence**: fast poll for procfs reads; slow cadence
   for SMART (avoid waking disks), GPU tools that fork, IP discovery.
8. **Spawn budget**: shell builtins over per-row `awk`; one script per poll.
9. **Bounded custom commands**: timeout, output cap, base64 output.
10. **Concurrency cap and dedup** across timer, lifecycle and user refreshes.
11. **Privilege**: `sudo -S` with password on stdin; `sudo -n` for
    opportunistic reads; recognize sudo and sudo-rs rejection strings; never
    sudo for `systemctl --user`; docker group vs sudo detection.
12. **Transient helper** alternative (Cockpit Client beams a Python bridge;
    VS Code Remote uploads a server [GEN]): richer structured output and
    streaming, but needs Python or a per-arch static binary, and raises review
    and trust questions.

### 3.5 Portability checklist

- **BusyBox/Alpine/OpenWrt**: `ps` lacks `%cpu`; `useradd` lacks `-M`;
  `hostname` may be missing; `lsblk` JSON missing (fall back to `df -k`);
  procd + `logread` instead of systemd/journald; `timeout`, `mktemp`, `setsid`
  may be absent.
- **NAS appliances** (Synology, QNAP, Unraid, ASUSTOR): nonstandard paths for
  `docker` (often not on non-interactive PATH), restricted shells, custom
  `df` output, Docker socket permissions. Allow per-server overrides for
  binary paths and `DOCKER_HOST`.
- **Containers/LXC**: `/etc/hostname` vs kernel hostname; overlay and
  fuse-overlayfs mounts to filter from disk lists; no thermal zones.
- **Disk lists**: filter `tmpfs`, `devtmpfs`, `overlay`, `squashfs`/snap
  loops, `erofs`, `iso9660` by filesystem type, not by device name (ServerBox
  `types.rs`); handle wrapped `df` lines for long device names; LVM
  `/dev/mapper/...`.
- **arm64**: `/proc/cpuinfo` may lack `model name`.
- **macOS hosts**: `top -l 1`, `vm_stat`, `netstat -ibn`, `sysctl`; APFS
  volumes share container numbers (dedupe by container); no per-core CPU
  without extra tools.
- **FreeBSD**: `top -b -d 1 -P`; no `vm_stat`; `sysctl vm.loadavg`.
- **Windows OpenSSH**: PowerShell, encoded commands, CLIXML progress noise,
  CRLF output.
- **Old systemd** (Debian 11, RHEL 8): no `--timestamp=unix`.
- **sudo-rs** (Ubuntu 25.10+): different error strings.

---

## 4. Market gaps a Hauntware app could fill

### 4.1 Positioning gaps

1. **One synced server list across terminal, files and operations, with E2E
   encryption on a self-hosted server.** ServerBox syncs via iCloud/WebDAV
   backups and is one monolith; XPipe uses git and is desktop-only; Termius is
   SaaS without monitoring; Termix's server holds credentials in the clear for
   polling. Hauntware already has `ServerConfig`, the vault, the E2E sync
   server and shared marks/colors. A fourth app that reads the same records
   (and can deep-link "open terminal in Seance" / "browse files in
   Poltergeist") is distinctive.
2. **Docker depth over plain SSH.** Native apps stop at start/stop/logs.
   Compose stack lifecycle (ls, ps, pull, up -d, down, logs merged, config
   view/edit with diff, restart one service), image update detection (local
   digest vs registry), volumes and networks, prune with preview, `docker
   events` streaming, healthcheck and restart-loop detection, and
   multi-host container search would put it in Dockhand/Portainer territory
   without installing anything on the host.
3. **systemd and logs as first-class.** Failed-unit triage, timers next to
   cron (user and system, `/etc/cron.d`), journal explorer with priority,
   boot and time range, unit file view with a reviewed edit and
   `daemon-reload`, and a unified log view across journald, containers and
   `/var/log` (lazyjournal proves demand, but no native GUI does it well).
4. **Fleet triage ("what needs me?")** across servers: offline, failed units,
   unhealthy/restarting containers, disks over threshold, pending updates,
   reboot required, TLS certificate expiry, SMART warnings. Most tools only
   show per-server meters.
5. **Keyboard-first desktop plus touch-first mobile from one codebase.** k9s
   proves power users want `:`, `/` and single-key actions; mobile apps prove
   others want cards and sheets. Flutter can do both; nobody native does both
   well for servers.
6. **Portability as a feature.** Explicit support tiers and fixture tests for
   Debian/Ubuntu, RHEL family, Alpine/BusyBox, OpenWrt, Synology/QNAP/Unraid,
   macOS and FreeBSD hosts, with a per-host "capabilities" probe that hides
   unsupported panels and explains why.
7. **Safety and auditability**: per-server read-only mode, typed
   confirmations, command preview, and a local (optionally synced, sealed)
   audit log of every mutating command run. Reuse Seance's danger linter.
8. **Android**: JuiceSSH's removal leaves Play Store users with few
   trustworthy, maintained options; ServerBox is not on Play.

### 4.2 Architecture implications

- **Agentless first.** Adopt ServerBox's proven model: versioned POSIX
  script uploaded per host, segmented output, persistent shell channel,
  fast/slow cadences, client-side rate computation, concurrency cap. Keep the
  command manifest and parsers in a pure-Dart package with per-distro fixture
  tests (Hauntware's pure-Dart convention), consumed through Poltergeist's
  and Seance's shared core rather than copied.
- **Do not depend on ServerBox code.** It is AGPLv3 with a CLA; Hauntware's
  license and the shared-library rule mean reimplementing from documented
  behavior and public command semantics, not porting source.
- **Docker transport choice.** CLI with `--format "{{json .}}"` is the most
  portable (works wherever `docker` works for the SSH user, including
  `sudo -S env DOCKER_HOST=...`). Engine API via SSH-forwarded unix socket is
  more structured and streams logs/stats/events, but needs socket permission
  and streamlocal forwarding support in dartssh2 3.0.2 (verify before
  committing to it). A hybrid is reasonable: CLI for discovery and actions,
  `docker events`/`logs -f`/`stats` streams over long-lived exec channels.
- **Background alerts need an always-on component; make it optional and
  E2E.** Options, in order of fit with Hauntware's security model:
  1. A headless "watch node" the user runs on a home server/NAS (Dart AOT,
     reusing the same core) that holds keys for chosen servers, polls
     agentlessly and posts **sealed** alert records to the existing sync
     server, using the same pattern as Seance's command inbox (producer seals,
     server stores opaque blobs). Clients show them; push delivery goes
     through ntfy/UnifiedPush/webhooks/email chosen by the user.
  2. A tiny optional per-host sentinel (cron job or systemd timer running the
     same script and posting sealed results), similar in spirit to
     ShellFish's `widget` command.
  3. iOS APNs requires a signed build plus a publisher-operated relay
     (ServerBox's `push.lolli.tech` pattern); not compatible with today's
     unsigned-IPA distribution.
- **Widgets**: show last-known values with timestamps; refresh in-app and
  through the watch node when available. Live Activities fit bounded
  operations (compose redeploy, reboot-and-wait).

### 4.3 Risks surfaced by the survey

- Parser breakage on unusual hosts is the top support cost (ServerBox issue
  history). Budget for fixtures and a "send diagnostic bundle" flow that
  captures raw segment output with secrets redacted.
- Feature sprawl: ServerBox now includes RDP, PVE, BMC, AI, themes; several of
  its 2026 crash reports coincide with big releases. Keep the fourth app
  focused on observability, services, logs, cron and containers; leave
  terminal and files to Seance and Poltergeist via deep links.
- Polling cost on servers: 3 s polls across many hosts and devices multiply.
  Pause when not visible (Seance's prober already does), back off on
  failures, and let the watch node be the single poller when present.
- Docker CLI output differs across Docker, Podman 4/5, snap Docker and Swarm.
- Privilege prompts: avoid sudo for reads; make elevation explicit and
  per-action.

---

## 5. Source list

ServerBox
- https://github.com/lollipopkit/flutter_server_box (source at `50e61ed`,
  2026-10-10)
- https://github.com/lollipopkit/flutter_server_box/releases
- https://apps.apple.com/us/app/server-box/id1586449703
- https://serverbox.lolli.tech/docs/ (same content as `docs/` in repo)
- Issues cited in 1.1

Commercial and indie apps
- https://apps.apple.com/us/app/servercat-ssh-terminal/id1501532023
- https://apps.apple.com/us/app/neoserver-docker-ssh-sftp/id6448362669
- https://hn.svelte.dev/item/44867184 ; https://taoofmac.com/space/apps/serverbuddy
- https://github.com/xpipe-io/xpipe ; https://github.com/xpipe-io/xpipe/releases ; https://xpipe.io/pricing
- https://docs.termius.com/changelog
- https://github.com/Termix-SSH/Termix ; https://docs.termix.site/features/networking/host-metrics
- https://secureshellfish.app/help/ ; https://secureshellfish.app/help/widgets
- https://apps.apple.com/app/id1594420480 (Prompt 3)
- https://docs.blink.sh/basics/notifications
- https://apps.apple.com/us/app/webssh-ssh-client/id497714887
- https://apps.apple.com/app/id6758614736 (ServerGlance)
- https://apps.apple.com/sb/app/serverkeep/id6759196608
- https://alternativeto.net/software/daremote/about
- https://lowendspirit.com/discussion/11336/meows-monitoring-and-managing-linux-servers-from-android-over-ssh
- https://termai.sh/blog/juicessh-removed-play-store ; https://hn.nuxt.dev/item/46768909 (secondary)
- https://apps.apple.com/py/app/beszel/id6747600765
- https://bjango.com/istatserver/
- https://fedoramagazine.org/using-cockpit-to-graphically-manage-systems-without-installing-cockpit-on-them/

TUIs and desktop tools
- https://github.com/derailed/k9s ; https://k9scli.io/ ; https://github.com/derailed/k9s/releases
- https://github.com/aristocratos/btop
- https://github.com/htop-dev/htop
- https://github.com/nicolargo/glances ; https://glances.readthedocs.io/en/latest/aoa/index.html
- https://github.com/bcicen/ctop
- https://github.com/jesseduffield/lazydocker
- https://github.com/Lifailon/lazyjournal
- https://lenshq.io/pricing ; https://github.com/freelensapp/freelens
- https://docs.docker.com/desktop/use-desktop/container/ ; https://docs.docker.com/desktop/release-notes/
- https://orbstack.dev/ ; https://orbstack.dev/pricing
- https://www.raycast.com/priithaamer/docker

Platform constraints
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- https://developer.apple.com/documentation/widgetkit/widgetpushhandler
- https://developer.apple.com/forums/thread/797676
- https://wwdcnotes.com/documentation/wwdc23-10185-update-live-activities-with-push-notifications/
- https://developer.android.com/develop/background-work/services/fgs/timeout
- https://developer.android.com/reference/androidx/work/PeriodicWorkRequest
- https://developer.android.com/develop/ui/views/appwidgets

Unverified or secondary items called out in text: JuiceSSH removal date and
licence breakage (secondary), DaRemote details (listing aggregators),
ServerBuddy cron/package features (single directory listing), Android
WorkManager and widget minimums (from Android reference docs, not re-fetched
during this research), dartssh2 3.0.2 streamlocal forwarding support (not
checked).
