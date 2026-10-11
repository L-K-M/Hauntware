# R2: Self-hosting platforms, PaaS and home-server OSes

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Survey for the planned fourth Hauntware app: a native server management, observability and Docker management client. It shares the synced server list with Seance and Poltergeist and talks to servers over SSH (dartssh2).

- Research date: 2026-10-10.
- Method: official sites, docs and GitHub READMEs/LICENSE files (fetched raw from `raw.githubusercontent.com`), vendor version manifests and Docker Hub tag listings. The GitHub REST API and github.com Atom feeds were blocked in the research environment. Release numbers therefore come from Docker Hub tag timestamps, GitHub release pages read through a page fetcher, or vendor manifests. Each one names its source.
- Confidence markers: **[verified]** means read from a primary source during the research (2026-10-10). **[secondary]** means a third-party or vendor-marketing source. **[prior knowledge, unverified]** means from background knowledge and not re-checked today.

---

## 0. Key findings

1. **Coolify is the best existence proof for an agentless design.** A central panel manages remote hosts *over SSH only*. The docs say: "You only need an SSH connection". Coolify later added Sentinel, an optional Rust agent container, for three things SSH polling handles badly: heartbeat, container health push and metric history. When Sentinel goes stale, Coolify "falls back to SSH-based checks". So SSH can cover the live management surface. Only *history* and *push* need something resident.
2. **Every PaaS takes over the host.** Coolify, Dokploy, CapRover and Easypanel need ports 80/443 (and often 3000) and a proxy they own. Most also need Docker Swarm. Cloudron, YunoHost, Umbrel and ZimaOS want a fresh OS or *are* the OS. Coolify's server validation "can restart the Docker service, which may temporarily take down existing containers". None of them adopts hand-written compose projects that already exist. A client that reads and respects existing state has a real gap to fill.
3. **The non-takeover tools are the ones people praise for trust.** Dockge says it "won't kidnap your compose files". CapRover advertises "No lock-in! Remove CapRover and your apps keep working!". Cosmos backs up with restic "allowing you more control, even if you were to stop using Cosmos". Kamal is "just basic Docker commands", and it keeps its audit log and deploy lock *on the servers*. These are the patterns to copy.
4. **Many "always-on" features do not need our own daemon.** They can be delegated to facilities the host already has: systemd timers and units, cron, Docker restart policies and HEALTHCHECK, logrotate, unattended-upgrades. The client writes plain, human-readable files over SSH. Dokku already does this with cron tasks: it installs them into the `dokku` user's crontab. Runtipi's docs recommend host cron for auto-backup and auto-update. Three things really need a resident listener: inbound git webhooks, fine-grained metric history, and event-driven alerting with deduplication.
5. **Templates converge on "compose plus metadata".** Examples: CapRover's `captainVersion: 4` with `$$cap_*` variables and `validRegex`, CasaOS's `x-casaos` extension, Runtipi's `x-runtipi` plus `config.json` form fields, Umbrel's `umbrel-app.yml` manifest, Coolify's comment headers and `SERVICE_PASSWORD_*` "magic" variables, and Dokploy's `template.toml` plus `meta.json`. A standard compose file with an `x-<app>` extension block is the safe, interoperable choice.
6. **Backups are where platforms disappoint most.** CapRover's backup covers only `/captain/data`, not volumes or images. Dokploy volume backups work "only with Docker named volumes, not with bind mounts". Coolify does not back up Redis, Dragonfly or KeyDB. TrueNAS rollback "only affects data saved in the apps dataset". Cloudron is the gold standard: about 25 storage targets, encryption, integrity checks with signed checksums, retention semantics it explains, and a backup before every update kept for 3 weeks.
7. **Licensing has drifted away from OSI.** Dokploy has a proprietary `/proprietary` directory under its DSAL license. Cosmos uses Commons Clause plus an Anti-Tampering clause. umbrelOS uses PolyForm Noncommercial. Cloudron is source-available behind a subscription. Easypanel is proprietary. 1Panel keeps multi-node behind its Pro tier. Hauntware is public domain (Unlicense). Template catalogs can be reused only by license: CapRover, CasaOS and Coolify catalogs are Apache-2.0, Dokploy templates are MIT, Runtipi and 1Panel stores are GPL-3.0, and umbrel-apps has no LICENSE file.

---

## 1. Platform profiles

Abbreviations used in later tables: CO Coolify, DP Dokploy, CR CapRover, EP Easypanel, DK Dokku, KA Kamal, CC Cosmos Cloud, CA CasaOS/ZimaOS, UM Umbrel, RT Runtipi, UN Unraid, TN TrueNAS, SY Synology Container Manager, YH YunoHost, CL Cloudron, 1P 1Panel.

### 1.1 Developer PaaS

#### Coolify (CO)
- **What:** Self-hostable Heroku/Netlify/Vercel alternative for apps, databases and services.
- **License:** Apache-2.0 **[verified, LICENSE]**.
- **Version:** v4 stable 4.4.6; nightly 4.5-rc.1; Sentinel 1.0.2; helper 1.0.17. Source: `cdn.coollabs.io/coolify/versions.json`, fetched 2026-10-10 **[verified]**. The same manifest pins Traefik 3.7.13 as the current v3.7 proxy.
- **Architecture:** A panel installed with `curl ... | bash` on one server. It manages "deployment servers" over SSH and supports optional build-only servers. The panel host is "localhost" and can also host workloads. Validation checks SSH, OS and tools, then "installs or verifies Docker Engine and Docker Compose" and may restart Docker. Coolify can create servers at Hetzner, DigitalOcean, Vultr and Hostinger. It also manages "OS package patching and scheduled Docker cleanup" **[verified]**.
- **Sentinel:** A "Rust-based lightweight agent", run as the `coolify-sentinel` container. It covers heartbeat, container state and health, and root filesystem disk usage, plus CPU and memory history when metrics are enabled. It pushes to the panel and stores history under `/data/coolify/sentinel`. It is not available on Swarm or build servers. When stale, Coolify "falls back to SSH-based checks" **[verified]**.
- **Feature areas [verified unless noted]:**
  - *Deploy sources:* GitHub, GitLab, Bitbucket, Gitea. Build packs: Nixpacks, Railpack, Dockerfile, Docker Compose, prebuilt image. Deploy on push, deployment webhooks, PR previews, rollback "to retained application images".
  - *Catalog:* "more than 300 one-click services". Templates live in the repo as compose files with comment headers (`# slogan`, `# category`, `# tags`, `# logo`, `# port`). They use magic variables such as `SERVICE_URL_<ID>_<PORT>`, `SERVICE_FQDN_*` and `SERVICE_PASSWORD_*`, which generate domains and credentials that "persist across deployments".
  - *Compose handling:* Coolify injects labels (`coolify.managed=true`, `coolify.applicationId`, proxy labels), creates a per-resource network, and turns each `${VAR}` into an editable variable; `:?` blocks deploy until a value is set. A "Raw (deploy file as-is)" mode skips most changes, and then Coolify "cannot repair missing proxy or networking configuration".
  - *Proxy/TLS:* One `coolify-proxy` per server: Traefik (default), Caddy (caddy-docker-proxy 2.13), or None. Generated compose is shown in the UI, plus dynamic file-provider configs and proxy logs. Configs are validated before saving. Warning: "An invalid proxy configuration can make every application and service on the server unreachable." Notifications flag outdated Traefik.
  - *Backups:* Scheduled backups for PostgreSQL, MySQL, MariaDB, MongoDB, ClickHouse and SQLite, not Redis, Dragonfly or KeyDB. Schedules use cron or named frequencies. Dumps go to `/data/coolify/backups`, with retention by count, age or size and separate S3 retention. Coolify says: "A successful backup only proves that Coolify created a file". It recommends test restores into a disposable database.
  - *Scheduled tasks:* Per application and service, with success and failure notifications.
  - *Monitoring:* Reachability, disk usage threshold, container state and health, CPU and memory history (Sentinel), log drains (workload output only), and Traefik/Caddy traffic analytics (off by default). The docs say CPU and memory *threshold alerts*, external endpoint checks and long-term log analysis need an external system.
  - *Notifications:* Email (SMTP or Resend), Discord, Telegram, Slack/Mattermost, Pushover, generic webhook. Events can be selected per channel and per event: deploy success/failure, container stopped unexpectedly or restarted, restart limit reached, backup success/failure (including S3 upload failure), scheduled task success/failure, Docker cleanup success/failure, disk usage over threshold, server unreachable "after two consecutive checks", server reachable again, OS patches available, Traefik outdated.
  - *Access:* Teams, API, CLI, MCP.
- **Pitfalls:** A secondary source reports that Coolify "takes over Docker networking and may conflict with Docker Compose stacks you deployed manually". It recommends a fresh server or redeploying through Coolify **[secondary]**. There is no migration or adoption path for existing stacks. Issue #5014 asks even to migrate a Coolify instance itself **[secondary]**.
- **Sources:** https://github.com/coollabsio/coolify, https://cdn.coollabs.io/coolify/versions.json, https://coolify.io/docs/knowledge-base/server/introduction, https://coolify.io/docs/knowledge-base/server/sentinel, https://coolify.io/docs/knowledge-base/server/proxies, https://coolify.io/docs/databases/backups, https://coolify.io/docs/knowledge-base/docker/compose, https://coolify.io/docs/knowledge-base/notifications, https://coolify.io/docs/core/notifications/events, https://coolify.io/docs/core/observability/monitoring/overview, https://raw.githubusercontent.com/coollabsio/coolify/v4.x/templates/compose/uptime-kuma.yaml, https://www.tencentcloud.com/techpedia/144014, https://github.com/coollabsio/coolify/issues/5014

#### Dokploy (DP)
- **What:** Self-hostable PaaS ("Open Source Alternative to Vercel, Netlify and Heroku").
- **License:** Apache-2.0, except anything under `/proprietary`. That part uses the "Dokploy Source Available license (DSAL) 1.0", which allows production use only with a commercial agreement **[verified, LICENSE.MD and LICENSE_PROPRIETARY.md]**. The docs list the Enterprise features: SSO, SCIM, whitelabeling, custom roles, audit logs.
- **Version:** v0.30.8 = `latest` on Docker Hub (2026-09-29); `canary` 2026-10-05 **[verified, Docker Hub]**.
- **Architecture:** A Next.js app (UI and backend) with PostgreSQL and Traefik, installed by script. Ports 80, 443 and 3000 must be free, and "The installation will fail if any of these ports are already in use". Requirements are 2 GB RAM and 30 GB disk. It uses Docker Swarm: the installer accepts `DOCKER_SWARM_INIT_ARGS` and `ADVERTISE_ADDR`. Swarm service discovery "requires IPVS support in the kernel", and there is a `dnsrr` fallback for Proxmox LXC. Remote servers get "only a traefik instance". One docs page says remote server monitoring is not supported "due to performance reasons". Build servers work for Applications only **[verified]**.
- **Feature areas [verified unless noted]:**
  - *Apps:* Sources are GitHub, Git and Docker. Builds use Dockerfile, Nixpacks, Heroku or Paketo buildpacks. Each app has env vars, CPU/memory/disk/network monitoring, real-time logs, a deployments list (queued deployments can be cancelled), domains, redirects, security headers, resource limits, volumes, and detailed Traefik config.
  - *Compose:* Sources are GitHub, Git and Raw. Per-service monitoring and logs, a custom command override, volume management.
  - *Databases:* MySQL, PostgreSQL, MongoDB, Redis, MariaDB, plus libsql (README). Manual and scheduled backups to S3 destinations.
  - *Volume backups:* Work "only with Docker named volumes, not with bind mounts". Two modes: "Container OFF (recommended)" stops the container during backup, "Container ON" does not. Cron schedule, S3 target. Restore requires that the target volume does not already exist.
  - *Schedule jobs:* Four types, all cron-based with a log entry per run: in an app container (docker exec), in a compose service, as a bash script on the host, or inside the Dokploy container.
  - *Notifications:* Slack, Telegram, Discord, Lark, Email, Resend, Gotify, ntfy, Pushover, Webhook. Mattermost has a provider page. Events: app deploy, build error, database backup, volume backup, Docker cleanup, Dokploy restart **[verified via docs index and search summary of docs.dokploy.com]**.
  - *Rollbacks:* Swarm automatic rollback on failed health check (needs a health endpoint and curl in the image) and registry-based rollback to any earlier deployment **[secondary summary of official page]**.
  - *Preview deployments:* GitHub PRs. Off by default, with a warning not to enable them on public repos ("external people can execute builds"). Default domains use traefik.me, and there is a per-app limit (default 3) **[secondary summary of official page]**.
  - *Templates:* MIT-licensed repo. Each template has `docker-compose.yml`, `template.toml` and `meta.json`, and PRs auto-deploy previews **[verified]**.
  - *Other:* Multi-tenancy, registry, secrets providers, DNS providers, certificates, Cloudflare Tunnels and Tailscale guides, an "AI Assistant", API and CLI.
- **Sources:** https://github.com/Dokploy/dokploy, https://raw.githubusercontent.com/Dokploy/dokploy/canary/LICENSE.MD, https://docs.dokploy.com/docs/core, https://docs.dokploy.com/docs/core/architecture, https://docs.dokploy.com/docs/core/features, https://docs.dokploy.com/docs/core/installation, https://docs.dokploy.com/docs/core/remote-servers, https://docs.dokploy.com/docs/core/schedule-jobs, https://docs.dokploy.com/docs/core/volume-backups, https://docs.dokploy.com/docs/core/overview, https://docs.dokploy.com/docs/core/applications/rollbacks, https://docs.dokploy.com/docs/core/applications/preview-deployments, https://raw.githubusercontent.com/Dokploy/templates/main/README.md

#### CapRover (CR)
- **What:** "Scalable PaaS (automated Docker+nginx), aka Heroku on Steroids".
- **License:** Apache-2.0 **[verified]**.
- **Version:** 1.15.4 (2026-08-30, Docker Hub) **[verified]**.
- **Architecture:** A captain container with the Docker socket mounted. It runs Docker Swarm (clustering), nginx (customizable template), Let's Encrypt and NetData. It publishes ports 80, 443 and 3000 and needs a public IP. HTTPS needs a wildcard DNS A record (`*.root.domain`), and Cloudflare proxying is "not officially supported". Setup uses the npm CLI `caprover serversetup` or the web UI with default password `captain42` **[verified]**.
- **Features:** One-click apps, deploy via CLI, tarball, git or image (`captain-definition`), "No lock-in! Remove CapRover and your apps keep working!" **[verified]**.
  - *One-click template format:* A compose file with `captainVersion: 4` and a `caproverOneClickApp` block holding variables (`id`, `label`, `defaultValue`, `validRegex`, `description`) and `instructions.start`/`end`. Built-ins are `$$cap_appname`, `$$cap_root_domain` and `$$cap_gen_random_hex(n)`. **Only 8 compose keys are honored**: `image`, `environment`, `ports`, `volumes`, `depends_on`, `hostname`, `command`, `cap_add`. "Other parameters are currently being ignored". Third-party repositories can be added by URL **[verified]**.
  - *Backup:* "backs up everything in your `/captain/data/` directory" (settings, configs, certs). Not images ("apps are reverted to the default state") and not volumes ("you have to use a custom solution"). Labeled "experimental" **[verified]**.
- **Sources:** https://github.com/caprover/caprover, https://caprover.com/docs/get-started.html, https://caprover.com/docs/one-click-apps.html, https://raw.githubusercontent.com/caprover/one-click-apps/master/README.md, https://caprover.com/docs/backup-and-restore.html

#### Easypanel (EP)
- **What:** Self-hosted control panel for apps, databases and "more than 750 open-source services".
- **License:** Proprietary freemium. The site states no license, and third-party directories list it as proprietary **[secondary]**.
- **Pricing [verified]:** Free gives 3 projects, unlimited services and deployments, and basic monitoring. Paid plans are per server per month: Hobby $14.90 ($10.90 annual), Growth $23.90, Business $37.90.
- **Architecture:** Fresh Ubuntu with at least 2 GB RAM. Ports 80/443 must be free. The installer "initializes Docker Swarm" **[verified]**. Traefik is the integrated proxy **[secondary, AWS Marketplace listing and guides]**.
- **Features [verified, homepage]:** GitHub deploys "with zero downtime", managed Postgres/MySQL/Mongo/Redis, automatic backups with one-click restore, CPU/mem/disk/network monitoring, logs, app shells, automatic SSL, 2FA, cloud-marketplace one-click installs.
- **Sources:** https://easypanel.io/, https://easypanel.io/pricing, https://easypanel.io/docs, https://alternativeto.net/software/easypanel/about, https://aws.amazon.com/marketplace/pp/prodview-a63ebk6esztwu

#### Dokku (DK)
- **What:** "An extensible, open source Platform as a Service that runs on a single server". Heroku-style `git push` over SSH.
- **License:** MIT **[verified]**.
- **Version:** 0.38.31 (Docker Hub, 2026-09-26; also in the install docs) **[verified]**.
- **Architecture:** A CLI and plugins on the host. There is no web UI in OSS (Dokku Pro is commercial). Builders: Dockerfile, Cloud Native Buildpacks, Herokuish, Nixpacks, Railpack, Lambda, Null. Schedulers: docker-local, k3s, Nomad, null. Proxies: nginx, Caddy, HAProxy, OpenResty, Traefik. Supported OS: Ubuntu 22.04/24.04/26.04 and Debian 11+ **[verified]**.
- **Zero-downtime checks [verified]:** By default Dokku waits 10 s after start. `app.json` `healthchecks.web` sets path, port, initialDelay, timeout, wait, attempts and type. HTTP checks run "via `curl` on Dokku host". Old containers are retired after `wait-to-retire` (60 s). `checks:disable` means downtime.
- **Cron [verified]:** `app.json` `cron` entries run in one-off `run` containers, capped at 24 h. On docker-local they live in the host `dokku` user crontab, which "should be considered reserved". Failures email `MAILTO`, and output can go to a vector sink. CLI: `cron:list --format json`, `cron:run --detach`.
- **Other:** Env config, domains, SSL, persistent storage, resource management, event logs, backup/recovery docs, CI integrations (GitHub Actions, GitLab, Woodpecker).
- **Sources:** https://dokku.com/docs/getting-started/installation/, https://dokku.com/docs/deployment/zero-downtime-deploys/, https://dokku.com/docs/processes/scheduled-cron-tasks/, https://raw.githubusercontent.com/dokku/dokku/master/LICENSE

#### Kamal (KA, 37signals)
- **What:** Deploy tool, "basically Capistrano for Containers". Imperative, not declarative reconciliation. Deployments are "just basic Docker commands".
- **License:** MIT **[verified]**.
- **Version:** 2.12.0 (docs) **[verified]**.
- **Architecture:** Fully agentless. It runs on the developer machine and talks SSH to the servers listed in `config/deploy.yml`, and it auto-installs Docker on fresh Ubuntu. Traffic goes through **kamal-proxy**, a tiny Go proxy. `kamal-proxy deploy svc --target web-1:3000` health-checks the new instance (`GET /up` every 1 s, 5 s timeout) and switches traffic only once it is healthy. It then *waits for in-flight requests to drain* from the old instance before returning **[verified]**.
- **Features [verified]:** Roles; destinations (`deploy.<dest>.yml` overlays); accessories (DBs and other side services); host- and path-based routing; Let's Encrypt via `ssl: true` (single server); custom certs via secrets; buffering limits; `.kamal/secrets` with password-manager adapters (1Password, LastPass, Bitwarden, Bitwarden SM, AWS Secrets Manager, Doppler, GCP Secret Manager, Passbolt); hooks; aliases; `retain_containers` (default 5); `rollback`; `prune`; and **`audit` ("Displays the audit log from servers") and `lock` (deploy lock)**. Coordination state lives on the servers, not in a central database. Strict config parsing rejects unknown keys, and `x-` keys are allowed for YAML anchors.
- **Sources:** https://kamal-deploy.org/, https://kamal-deploy.org/docs/configuration/overview/, https://kamal-deploy.org/docs/configuration/proxy/, https://kamal-deploy.org/docs/commands/secrets/, https://kamal-deploy.org/docs/commands/view-all-commands/, https://raw.githubusercontent.com/basecamp/kamal-proxy/main/README.md

### 1.2 Home-server platforms and app stores

#### Cosmos Cloud (CC)
- **What:** "Secure and easy" home-server gateway and manager: reverse proxy, SSO, container manager, app market.
- **License:** "Apache 2.0 with Commons Clause and Anti Tampering Clause" **[verified, LICENCE]**. It may not be sold or offered as SaaS or PaaS.
- **Version:** 0.23.4 stable (Docker Hub, 2026-08-30). 0.24.0-unstable builds were published daily in Oct 2026 **[verified]**.
- **Architecture:** One container with the Docker socket. It owns ports 80/443 and becomes the front door.
- **Features [verified]:**
  - *Proxy:* Let's Encrypt including wildcard certs via DNS challenge. Routes to containers, other servers or static folders.
  - *Security:* MFA, OpenID/forward-header SSO, and SmartShield (rate limiting, bans, geo-blocking).
  - *Containers:* Containers can be created by form or by importing compose or "cosmos-compose". "Docker Compose features that cosmos-compose doesn't support are silently ignored during import". Labels and env changes "will be applied when you recreate the container". The update checker runs "Every 6h" and needs updatable tags such as `latest`. **Lazy containers** stop when idle and wake when their URL is opened ("Dormant"). Exposed public ports are shown in orange as insecure.
  - *Backups:* restic, explicitly so you keep control "even if you were to stop using Cosmos". Targets are local, remote or rclone. Six-field cron, separate forget schedule, retention by count or duration. A "stop containers using the folder" option is recommended for DBs and config but not for media. Restore can target selected files or another path.
  - *Other:* Constellation VPN, MergerFS/parity disk management, rclone network storage, monitoring with "customizable alerts", a cron scheduler. The Pro tier adds clusters, managed DBs, S3, CI/CD.
- **Sources:** https://github.com/azukaar/Cosmos-Server, https://raw.githubusercontent.com/azukaar/Cosmos-Server/master/LICENCE, https://cosmos-cloud.io/doc/1%20index/, https://cosmos-cloud.io/docs/servapps/, https://cosmos-cloud.io/docs/backups/

#### CasaOS / ZimaOS (CA)
- **What:** CasaOS is a "Personal Cloud" web UI installed on Debian, Ubuntu or Raspberry Pi OS. ZimaOS is IceWhale's Buildroot-based OS "evolved from CasaOS", with OTA updates and better disk management.
- **License:** CasaOS Apache-2.0 **[verified]**. No LICENSE file was found in the public ZimaOS repo, which is a release and test-image repo **[verified absence]**.
- **Status:** A vendor page says CasaOS core "stable release cadence has stalled since v0.4.15 in December 2024". The App Store stayed active and published v2.0.0 in July 2026, and development focus moved to ZimaOS **[secondary, vendor-authored]**.
- **Features [verified README]:** Home-oriented UI ("No code, no forms"), curated one-click store, "Over 100,000 apps from the Docker ecosystem" via custom install, drive and file management, resource-usage widgets.
- **Template format [verified]:** A standard compose file with an `x-casaos` extension. It holds per-env and per-port descriptions in multiple languages (`en_US`, `zh_CN`), uses `$PUID/$PGID/$TZ`, and binds to `/DATA/AppData/$AppID`. Third-party stores are supported. The store repo is Apache-2.0.
- **Sources:** https://raw.githubusercontent.com/IceWhaleTech/CasaOS/main/README.md, https://raw.githubusercontent.com/IceWhaleTech/ZimaOS/main/README.md, https://raw.githubusercontent.com/IceWhaleTech/CasaOS-AppStore/main/Apps/Jellyfin/docker-compose.yml, https://shop.zimaspace.com/pages/is-casaos-abandoned-development-status

#### Umbrel (UM)
- **What:** umbrelOS, "A beautiful home server OS for self-hosting". It sells Umbrel Home hardware and also installs on Raspberry Pi, Ubuntu and Debian.
- **License:** PolyForm Noncommercial 1.0.0 **[verified, LICENSE.md]**. umbrel-apps has no LICENSE file at the repo root **[verified absence]**.
- **Version:** umbrelOS 2.0 (22 Sep 2026). The previous stable was 1.7.4 **[verified, GitHub releases page]**.
- **Features:**
  - *2.0 [verified]:* iPhone app (background camera-roll backup) and Mac app (mounts Umbrel as a Finder drive on LAN or over Tailscale); multiple user accounts; an MCP server for AI agents with per-agent revocable tokens; automatic HTTPS; Storage Manager with FailSafe RAID and drive health; a new App Store with an update shelf, compatibility checks and release history.
  - *1.5 [verified, announcement and community posts]:* Backups: automatic, encrypted and incremental, to another Umbrel, a NAS or USB, with "Rewind" file recovery. Users "cannot currently change the schedule or configure Kopia directly" (community post).
  - *App packages [verified]:* `docker-compose.yml` with a special `app_proxy` service (`APP_HOST`, `APP_PORT`, `PROXY_AUTH_ADD`) plus a `umbrel-app.yml` manifest (id, category, version, tagline, description, releaseNotes, storage). Images are **pinned by digest**. The **App Store Standard** says every app "should open to a web UI, setup flow, login page, or status page ... without SSH, CLI access, log scraping, or manual file edits". Community app stores have existed since 0.5.2.
- **Pitfall observed:** The official Nextcloud package ships *static* DB credentials in compose (`MYSQL_PASSWORD=moneyprintergobrrr`). That is safe only because the app network is isolated, and a client should never copy the practice **[verified]**.
- **Sources:** https://raw.githubusercontent.com/getumbrel/umbrel/main/README.md, https://raw.githubusercontent.com/getumbrel/umbrel/main/LICENSE.md, https://github.com/getumbrel/umbrel/releases/tag/2.0.0, https://community.umbrel.com/t/introducing-backups-on-umbrelos/23961, https://raw.githubusercontent.com/getumbrel/umbrel-apps/master/README.md, https://raw.githubusercontent.com/getumbrel/umbrel-apps/master/nextcloud/docker-compose.yml

#### Runtipi (RT)
- **What:** "A personal homeserver orchestrator", built on Docker with a web UI.
- **License:** GPL-3.0. The app store is also GPL-3.0 **[verified]**.
- **Version:** v4.10.2 (8 Sep 2026) **[verified, releases page]**. Its headline change: updates "pull target images before stopping the current deployment", and "failed updates restore the previous app files, environment, network assignment, and containers where possible".
- **Architecture:** One compose project per app behind Traefik, on `tipi_main_network`. The CLI manages the stack. Apps carry the `runtipi.managed: true` label **[verified]**.
- **Template format [verified]:** `docker-compose.yml` with `x-runtipi` metadata (the legacy `docker-compose.json` schemaVersion 2 is converted internally) plus `config.json` (port, `form_fields`, `supported_architectures`, `min_tipi_version`, `exposable`, `dynamic_config`). Traefik labels are auto-generated for the main service, using `{{RUNTIPI_APP_ID}}` templating.
- **Docs topics [verified, index]:** Customize compose and Traefik (user overrides), custom env, local SSL certs, DNS challenge, Cloudflare tunnels, backup and restore, **"Auto-backup with cron"** and **"Auto-update with cron"**, custom app stores.
- **Sources:** https://raw.githubusercontent.com/runtipi/runtipi/master/README.md, https://github.com/runtipi/runtipi/releases, https://runtipi.io/docs/introduction, https://runtipi.io/docs/reference/dynamic-compose, https://raw.githubusercontent.com/runtipi/runtipi-appstore/master/apps/jellyfin/docker-compose.yml

#### YunoHost (YH)
- **What:** A Debian-based OS layer "aiming to simplify as much as possible the administration of a server".
- **License:** AGPL-3.0 **[verified]**.
- **Version:** The stable line is built on Debian 12. YunoHost 13 (Debian 13 "Trixie") was in alpha and beta through 2025-2026, and 13.0.4 builds were in unstable in April 2026 **[secondary, forum and dev logs]**.
- **Architecture:** **No Docker**. Apps are natively packaged and run under dedicated low-privilege users. It has an NGINX + SSOwat user portal, LDAP users, a full mail stack (Postfix, Dovecot, OpenDKIM), Let's Encrypt, an nftables firewall and fail2ban **[verified]**.
- **Catalog:** "more than 500 apps" **[verified]**.
- **Diagnosis system:** Checks port exposure, DNS records, outbound port 25, reverse DNS, mail blacklists and mail queue size (>100) **[secondary, source commits and older docs]**. A forum request from Nov 2025 asks to add memory and disk to the diagnosis, which suggests it is not there yet **[secondary]**.
- **Relevance:** Not Docker, but the diagnosis UX (a checklist of what is wrong with your server and how to fix it) transfers well.
- **Sources:** https://raw.githubusercontent.com/YunoHost/yunohost/master/README.md, https://doc.yunohost.org/admin/what_is_yunohost/, https://forum.yunohost.org/t/yunohost-13-0-trixie-spooky-beta/40656, https://git.yunohost.org/YunoHost/doc/raw/commit/24602b11dd2544650927056c05cf7f26a9636c18/diagnostic.md

#### Cloudron (CL)
- **What:** A platform to "install, manage and secure web apps on your server". It has an app store with continuous updates, centralized users, SSO and email.
- **License:** Source-available, gated by subscription **[secondary, forum statements by staff]**. Pricing **[verified]**: Free allows 2 apps. Pro costs €15 or €30 per month, and Max €25 or €50 (the billing period was not labeled). Max adds groups and roles, a directory server, multiple backup sites and VPN-only app access.
- **Architecture:** Takes over a *fresh* "Ubuntu Resolute 26.04 (x64)" server with at least 2 GB RAM and 20 GB disk. There is no ARM, LXC, Docker or OpenVZ support. It manages iptables ("don't modify directly") and runs an internal mail server **[verified]**.
- **Backups, the best in class [verified]:**
  - *Scope:* Per-app backups of data and DB, not code or logs.
  - *Targets:* About 25, including S3, B2, R2, GCS, Wasabi, Hetzner, CIFS, NFS, SSHFS and local disks. A "User-managed Mount Point" checks the mount is up "so it never writes to the local disk by mistake".
  - *Formats:* tgz or rsync (incremental, hardlinks).
  - *Encryption:* AES-256 with a scrypt-derived key. The password is not stored.
  - *Retention:* Policies such as "7 daily", explained precisely. The latest backup is always kept, and **pre-update backups are kept 3 weeks**.
  - *Robustness:* Backups run at nice 15 with a 12 h timeout. The nightly Backup Cleaner logs "why each backup is retained".
  - *Integrity:* A `.backupinfo` file holds SHA256s and is signed in the database. A "Check integrity" action verifies it.
  - *Restore:* Restore, clone to a new domain, import, migrate, and a whole-server dry-run restore tested via `/etc/hosts` before the DNS switch.
- **Sources:** https://docs.cloudron.io/, https://docs.cloudron.io/installation/, https://docs.cloudron.io/backups/, https://www.cloudron.io/pricing.html, https://forum.cloudron.io/topic/2862/why-not-make-cloudron-fully-open-source-again/12, https://bmannconsulting.com/notes/cloudron/

### 1.3 NAS appliances

#### Unraid (UN), Docker tab and Community Applications
- **What:** A paid NAS OS (Lime Technology) with KVM VMs and Docker.
- **Version:** 7.3.x, with 7.4.0 in RC. Wikipedia gives 7.3.3 and 7.4.0-rc.1 on 8 Oct 2026, but its dates are internally inconsistent. A search result cites 7.3.2 on 8 Jul 2026 **[secondary]**.
- **Licensing:** Term licenses (6 drives or unlimited, 1 year of updates) or Lifetime **[secondary]**.
- **Docker tab [verified]:**
  - *Controls:* Per-container Auto-Start switch, drag-to-reorder start order, per-container wait delay in seconds (Advanced View), WebUI link, console, logs, edit template.
  - *Networks:* bridge, host, none, and custom macvlan/ipvlan (own LAN IP).
  - *Storage:* Data lives in an `appdata` share. Templates are saved as XML on the boot device, so reinstalls are easy. `docker.img` is a BTRFS image.
- **Compose:** "Unraid does not natively support Docker Compose" (official docs). The community "Compose Manager Plus" plugin ships Compose v5 and can *hide compose containers from the native Docker UI*, a sign of two parallel worlds **[verified docs; secondary plugin]**.
- **Community Applications:** A moderated catalog of apps and plugins with an app-store UX **[verified, docs and Wikipedia]**. Features like "Previous Apps" reinstall and deprecation and blacklisting of bad templates are **[prior knowledge, unverified]**. The CA docs page rendered empty for the fetcher.
- **Notifications:** Notification agents (Discord, Telegram, Pushover, Slack, Gotify, ntfy, email and more) **[prior knowledge, unverified]**.
- **Sources:** https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/overview/, https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/managing-and-customizing-containers/, https://en.wikipedia.org/wiki/Unraid, https://forums.unraid.net/topic/197334-plugin-compose-manager-plus/

#### TrueNAS (TN) apps
- **What:** The TrueNAS Community Edition (formerly SCALE) apps system.
- **Architecture:** Apps "changed in 24.10 to Docker images managed with Docker Compose" (previously k3s). Compose is generated and owned by TrueNAS middleware. The catalog repo is LGPL-3.0 **[verified, repo]**.
- **Version:** 25.10 "Goldeye" is current stable. TrueNAS 26 betas started 2026-04-07, move to an annual cadence and **remove the REST API in favor of WebSocket** **[secondary, release notes and blog via search]**.
- **Features [verified docs]:**
  - *Catalog:* Trains (stable, enterprise, community, test), a Discover screen, and a 3-month deprecation period shown in the UI.
  - *Custom apps:* A "Custom App" wizard or "Install via YAML" (an advanced compose editor). "Convert to custom app" exposes YAML.
  - *Storage:* Host Path ("recommended ... production"), ixVolume ("better suited to app testing"), SMB share as volume, tmpfs.
  - *Resources:* Default limit is 2 CPUs and 4096 MB. The default run-as user is UID/GID 568.
  - *Upgrades:* Update with a version picker and changelog; the app stops during the update. **Roll Back reverts only the apps dataset; "Data in mounted host paths is not rolled back"**.
  - *Images:* Image management, registry logins, and "Check for docker image updates" on by default.
  - *Workloads:* Shell and logs remain available for stopped apps.
- **Pitfall:** 25.10 started rejecting include-only YAML without a top-level `services:` key, which broke existing custom stacks on upgrade **[secondary, forum and TechnoTim]**. Middleware ownership means hand edits outside the UI are not supported **[prior knowledge, unverified]**.
- **Sources:** https://raw.githubusercontent.com/truenas/apps/main/README.md, https://apps.truenas.com/managing-apps/installing-custom-apps/, https://www.truenas.com/docs/scale/25.10/scaleuireference/apps/, https://www.truenas.com/blog/blog-truenas-26-beta1-release, https://forums.truenas.com/t/25-10-0-ge-custom-app-vs-ee-custom-app-deployment/57684, https://technotim.com/posts/truenas-docker-pro/

#### Synology Container Manager (SY)
- **What:** The DSM package that replaced "Docker" in DSM 7.2.
- **License:** Proprietary.
- **Features:**
  - *Tabs:* Overview, Project, Container, Image, Registry, Network, Log.
  - *Projects:* The Project dashboard runs compose stacks. It arrived with Container Manager 20.10.23 on DSM 7.2 **[verified, DSM feature page via search]**.
  - *Later additions:* CLI `docker compose` came in 24.0.2-1543 (DSM 7.2.1+). Container health status and update detection for `latest` tags were also added **[secondary, release notes via search]**.
  - *Images:* Update and unused-image cleanup.
  - *Shell access:* In-app terminal coverage is weak. The guide uses SSH + `docker exec` **[secondary, wundertech, Aug 2026]**.
- **Pitfalls [secondary]:** Relative volume paths fail, and missing host folders are *not created* (projects fail). Port 80 collides with DSM's own reverse proxy. A macvlan container is not reachable from the NAS by default.
- **Sources:** https://www.synology.com/en-in/dsm/feature/docker, https://www.synology.com/en-uk/releaseNote/ContainerManager, https://www.wundertech.net/how-to-use-docker-on-a-synology-nas

### 1.4 Server panel

#### 1Panel (1P)
- **What:** "Modern, open-source Linux server management panel and a lightweight AI management platform". It claims "2.5M+" self-hosters.
- **License:** GPL-3.0. The app store is also GPL-3.0 **[verified]**.
- **Architecture:** One-line install. The web panel listens on a custom port with a "security path", and `1pctl user-info` prints credentials over SSH **[verified]**.
- **Features [verified README; cron list from v2 docs via search]:**
  - *Panel modules:* Host monitoring, file manager, databases, containers, websites (OpenResty) with one-click domain and SSL, an app store (165+ apps), WAF and log auditing, one-click backup and restore to cloud storage.
  - *Cron types:* Shell Script, App Backup, Website Backup, Database Backup, Directory/File Backup, Log Backup, URL Visit, Website Log Rotation, Cache Cleanup, System Snapshot, Server Time Sync. A task can write to several backup accounts.
  - *Pro/Ent only:* Multi-node management, website uptime monitoring, tamper protection, KVM UI.
- **Relevance:** 1Panel is the closest feature match for the *server* half of the planned app: cron, logs, monitoring, processes, firewall, SSH config. It is still a resident web panel.
- **Sources:** https://raw.githubusercontent.com/1Panel-dev/1Panel/master/README.md, https://1panel.pro/docs/v2/user_manual/cronjobs/, https://raw.githubusercontent.com/1Panel-dev/appstore/main/README.md

### 1.5 Contrast: stack-oriented managers (for reference only; likely covered by another report)
- **Dockge** (MIT; 1.5.0 latest tag 2025-03-30, nightlies ongoing): "File based structure - Dockge won't kidnap your compose files, they are stored on your drive as usual." Default directory `/opt/stacks`. Converts `docker run` commands to compose, has multi-agent support and real-time pull/up/down output **[verified]**.
- **Dockhand:** Container and compose management, Git integration with webhooks and auto-sync, environments via socket, agent or TCP, container file browser, restic backups with check and prune, OIDC, RBAC in Enterprise **[verified README]**. The LICENSE file was not at the default path.
- **Sources:** https://raw.githubusercontent.com/louislam/dockge/master/README.md, https://raw.githubusercontent.com/Finsys/dockhand/main/README.md, https://hub.docker.com/r/louislam/dockge

---

## 2. Architecture and footprint matrix

| Tool | License | Install footprint | Host takeover | Swarm | Proxy owned | Central state |
|---|---|---|---|---|---|---|
| Coolify | Apache-2.0 | Panel on 1 host, SSH to others, optional Sentinel container | Proxy on 80/443; validation may restart Docker | Optional | Traefik/Caddy/none | Panel DB |
| Dokploy | Apache-2.0 + proprietary dir | Panel (Next.js+PG+Traefik); Traefik on remotes | Needs 80/443/3000 free | Yes | Traefik | Panel DB |
| CapRover | Apache-2.0 | Captain container | 80/443/3000, wildcard DNS | Yes | nginx | `/captain/data` |
| Easypanel | Proprietary | Panel container | Fresh Ubuntu, 80/443 | Yes | Traefik [secondary] | Panel |
| Dokku | MIT | Host CLI + plugins | Owns proxy, `dokku` user crontab | No (k3s/Nomad optional) | nginx etc. | Host files |
| Kamal | MIT | Nothing resident except kamal-proxy and app containers | Proxy on 80/443 | No | kamal-proxy | Local config + server-side lock/audit |
| Cosmos | Apache+Commons+Anti-Tamper | One container with socket | Front door on 80/443 | No (Pro cluster) | Built-in | Cosmos config |
| CasaOS / ZimaOS | Apache-2.0 / n.a. | Services on Debian / whole OS | High / total | No | none by default | Local |
| Umbrel | PolyForm NC | Whole OS | Total | No | app_proxy | OS |
| Runtipi | GPL-3.0 | Compose stack + CLI | 80/443 via Traefik | No | Traefik | Runtipi dir |
| YunoHost | AGPL-3.0 | OS layer on Debian | Total (mail, nginx, LDAP, firewall) | n/a | nginx | LDAP + config |
| Cloudron | Source-available | Fresh Ubuntu 26.04 | Total (iptables, mail) | No | nginx | Cloudron DB |
| Unraid / TrueNAS / Synology | Proprietary / mixed / proprietary | NAS OS | Total (appliance) | No | DSM/none | Appliance DB/middleware |
| 1Panel | GPL-3.0 | Panel service | High (OpenResty sites) | No | OpenResty | Panel DB |

**Takeaway:** Only Kamal resembles what the fourth app would be: a client holding config and speaking SSH. Kamal is a deploy tool, not a manager, and it still installs kamal-proxy. Nothing in this set is a *native GUI client* that manages arbitrary existing hosts without installing a panel. That is the product's niche.

---

## 3. Consolidated feature inventory, with agentless verdicts

### Verdict legend
- **A, agentless live:** Works over SSH on demand with tools normally present (docker CLI/API via socket, `systemctl`, `journalctl`, `/proc`, `df`, `crontab`, `ss`, package managers). Works while the app is open.
- **H, host-native delegation:** Must keep working while the app is closed, but can use facilities the host already has: systemd timers and units, cron, Docker restart policies and HEALTHCHECK, logrotate, unattended-upgrades. The client writes transparent, removable plain-text files over SSH and runs no daemon of its own. It may need a CLI tool such as restic installed. This is the Dokku cron pattern and Runtipi's "auto-backup with cron".
- **D, needs a resident server-side component:** A listener (webhooks), a continuously running collector (fine-grained metric history, `docker events` streaming), stateful alerting with dedup and escalation, or a push relay. It is an optional agent or an external service.
- **X, out of scope:** For a management client, either another product's job or a host takeover.

### 3.1 App catalog and one-click installs
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Curated catalog with one-click install | CO (300+), EP (750+), DP, CR, CC, CA, UM, RT, YH (500+), CL, 1P (165+), TN, UN (CA) | **A** | Render template, write compose via SFTP, `docker compose up -d`. The catalog can be fetched by the client and needs no server component. |
| Template variables with form fields and validation | CR (`$$cap_*`, `validRegex`), RT (`form_fields`), CA (`x-casaos` multilingual descriptions), DP (`template.toml`) | **A** | Adopt compose + `x-<app>` block. |
| Generated secrets and domains | CO (`SERVICE_PASSWORD_*`, `SERVICE_FQDN_*`, persisted), CR (`$$cap_gen_random_hex`) | **A** | Generate client-side and store in the project `.env` on the host, so the host stays the source of truth. |
| Pre/post-install instructions and release notes | CR (`instructions.start/end`), UM (`releaseNotes`, release history) | **A** | |
| Multiple and third-party catalogs | CR, CA, UM (community stores), RT, TN (trains) | **A** | Catalog licenses differ (see section 6.7). |
| Architecture and compatibility checks | RT (`supported_architectures`, `min_tipi_version`), UM 2.0 | **A** | `uname -m` and `docker info` give this. |
| Image pinning by digest | UM | **A** | Good default for reproducibility. |
| `docker run` to compose conversion | Dockge | **A** | Also "adopt a running container into a compose file" (`docker inspect` to compose). |

### 3.2 Compose stack lifecycle
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Discover existing stacks | (none of the PaaS adopt stacks); Dockge reads `/opt/stacks` | **A** | Standard compose labels on containers (`com.docker.compose.project`, `.project.working_dir`, `.project.config_files`, `.service`) reveal hand-written projects anywhere on disk **[prior knowledge: standard Docker Compose labels]**. |
| Create, edit, up, down, restart, pull, recreate | all | **A** | Stream output live (Dockge pattern). |
| Visual or structured editor with env side-by-side | Dockhand, Dockge, TN YAML editor | **A** | Round-trip YAML must preserve comments and order. |
| Validation before apply | CO (proxy config validation), TN 25.10 (`services` key) | **A** | `docker compose config -q` on the host. |
| Safe update (pull first, restore on failure) | RT 4.10.2 | **A** | Pull, snapshot files and image digests, `up -d`, health-gate, roll back. |
| Start order and delays | UN (drag order + wait) | **A/H** | Compose `depends_on: condition: service_healthy` covers it within a stack. Boot order across stacks needs a systemd unit (**H**). |
| Lazy start (stop idle, wake on request) | CC | **D/X** | Needs a request-intercepting proxy. |
| Labels identifying ownership | CO `coolify.managed=true`, RT `runtipi.managed: true` | **A** | Read these and show "managed by Coolify/Runtipi" as read-only or warn (section 6.2). |

### 3.3 Environment and secrets
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Env var editor per app or service | all PaaS | **A** | `.env` and `env_file` on host. |
| Required-variable gating (`:?`) | CO | **A** | Parse `${VAR:?}` and block apply. |
| Secret managers (1Password, Bitwarden, AWS SM, Doppler, GCP, Passbolt) | KA adapters, DP "Secrets Providers" | **A** | Resolve client-side at deploy time and write to host. Explain that values land on disk on the host. |
| Encrypted secrets at rest on host | (none clearly) | **X/A** | Docker Swarm secrets are Swarm-only. Out of scope beyond file permissions (`0600`). |

### 3.4 Reverse proxy, domains, TLS
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Managed proxy with auto-TLS (Let's Encrypt) | CO (Traefik/Caddy), DP/EP/RT (Traefik), CR (nginx), DK (multiple), KA (kamal-proxy), CC, CL, YH, 1P (OpenResty) | **A for configuration, H for renewal** | The proxy (Caddy/Traefik/certbot timer) renews itself. The client only edits config. **Do not force a proxy on the user.** Detect the existing one and offer an optional Caddy template. |
| Domain routing via labels | CO, RT (auto Traefik labels), CR | **A** | Only if the user opted into a proxy we manage. |
| Wildcard certs via DNS challenge | CC, RT (Cloudflare guide), CO (DNS page) | **A** config | |
| Certificate expiry monitoring | CO (Traefik outdated alerts, not cert expiry explicitly), YH diagnosis | **A** (on demand), **H** (alerts) | The client can open TLS connections to listed domains directly, with no SSH needed. It can also read `acme.json`, Caddy storage or `certbot certificates` over SSH. |
| Proxy config validation and safe reload | CO (validation, "invalid config makes every application unreachable") | **A** | `nginx -t`, `caddy validate`, `traefik` file checks before reload, with auto-revert. |
| Traffic analytics | CO (opt-in) | **D** | Parse access logs on demand (**A**) as a light alternative. |

### 3.5 Backups and restore
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| DB logical dumps (pg_dump, mysqldump, mongodump) | CO, DP, EP, CL; CR recommends native tools | **A** manual, **H** scheduled | `docker exec ... pg_dump` with credentials from container env (CO reads `POSTGRES_PASSWORD` etc.). |
| Volume and bind-mount backups | DP (named volumes only), CC (any folder), CL (per app) | **A/H** | Support bind mounts as well as named volumes (DP gap). |
| Stop-container-for-consistency option | DP ("Container OFF recommended"), CC (stop option, not for media) | **A/H** | Expose the trade-off with the same guidance. |
| Remote targets: S3, B2, R2, SFTP, rclone, NFS, CIFS | CL (~25), CO/DP (S3), CC (restic + rclone), 1P (multiple accounts), UM (Umbrel/NAS/USB, Kopia) | **H** | Use **restic** (or borg/kopia) so backups outlive our app (CC rationale). Poltergeist's SFTP stack could also serve as a target. |
| Retention policies | CO (count/age/size), CC (count/duration), CL ("7 daily" semantics) | **H** | `restic forget --keep-daily 7 ...`. Explain semantics as CL does. |
| Encryption | CL (AES-256, password not stored), CC/UM (restic/kopia) | **H** | |
| Integrity checks | CL (signed SHA256 `.backupinfo`), Dockhand (restic check) | **A** on demand, **H** scheduled | `restic check`. |
| Test restore / restore to scratch | CO (recommends disposable DB), CL (dry-run restore) | **A** | High-value differentiator: a "verify restore" action. |
| Pre-update automatic backup | CL (kept 3 weeks), TN (dataset snapshot for rollback) | **A** | Tie to the safe-update flow. |
| Clone / migrate app to another server | CL (clone, import, migrate), CR (instance restore) | **A** | The client already holds both servers' SSH sessions. The synced server list makes this natural (Poltergeist transfer). |
| Platform config backup | CR (`/captain/data`), CO | n/a | Our state is the host files, so there is nothing extra to back up. |

### 3.6 Deployments from git, webhooks, previews
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Build from git (Nixpacks, Railpack, buildpacks, Dockerfile) | CO, DP, CR, EP, DK | **A** manual ("pull and redeploy" button) | Builds run on the host via SSH: `git pull && docker compose build`. |
| Deploy on push via webhook | CO, DP, CR, Dockhand | **D** | Needs a listener. Alternatives: CI pushes over SSH (KA/DK CI integrations), or **H** polling with a systemd timer (`git fetch`, compare, redeploy). |
| PR preview environments | CO, DP (off by default, risky for public repos) | **D/X** | Out of scope for v1. |
| Build servers separate from runtime | CO, DP | **A** | Possible later: build on server A, push to registry, pull on B. |
| Registry management and logins | DP, TN, SY, KA | **A** | `docker login` on host, or client-side registry API for tag and update checks. |

### 3.7 Zero-downtime, rolling deploys, health checks, rollback
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Health-gated cutover with connection draining | KA (kamal-proxy), DK (checks + wait-to-retire 60 s), EP, DP (Swarm) | **A** (orchestrated from the client during the operation) | Without Swarm, needs a proxy that can swap upstreams (kamal-proxy, Traefik/Caddy with scale-up/scale-down). Offer only for proxied HTTP services. |
| Health checks | DK (`app.json`), KA (`/up`), CO (healthcheck page), TN, SY (health status) | **A** read, **H** enforcement via Docker HEALTHCHECK + restart policy | Show Docker health state. Offer to add `healthcheck:` to compose. |
| Rollback to previous image | CO (retained images), DP (registry/Swarm), KA (`rollback`, retain 5), TN (Roll Back, dataset only) | **A** | Record previous image digests in a host-side history file (KA audit pattern). |
| Deploy lock and audit log | KA (`lock`, `audit` on servers) | **A** | **Important for a multi-device client:** keep a lock file and append-only audit log on the host so two devices don't collide. |

### 3.8 Resource limits
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| CPU and memory limits per container | DP, CO, TN (default 2 CPU / 4096 MB), CC (Pro?), UN (extra params) | **A** | `deploy.resources.limits` / `mem_limit`; live `docker update` for running containers. |
| GPU assignment | TN, UM 2.0, CA (devices) | **A** | `device_requests` / `/dev/dri`. |
| Run-as user, capabilities, privileged warnings | TN (UID 568, privileged warning), CC (exposed ports orange) | **A** | Security lint for compose. |

### 3.9 Scheduled tasks
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Host cron and systemd timer viewer and editor | 1P (cron types), DP (server jobs), CC (cron) | **A** to view and edit, **H** by nature | `crontab -l` per user, `/etc/cron.d`, `systemctl list-timers --all`, plus next-run computation. Detect Dokku's reserved crontab and DP/CO-managed jobs and show them read-only. |
| Container-exec scheduled jobs | DP (app/compose jobs), CO, DK (one-off containers) | **H** | systemd timer running `docker compose exec` or `run --rm`. |
| Run now, run history and logs | DP (log per execution), DK (`cron:run`), CO notifications | **A/H** | With systemd: `journalctl -u <unit>` gives history for free (a strong argument for timers over cron). |
| Failure notification | DK (MAILTO), CO (task failure), 1P | **H** | systemd `OnFailure=` calling a notifier script (see 3.11). |
| Typed task presets (backup, log rotation, cache cleanup, time sync, URL ping) | 1P | **A/H** | Good template idea for v2. |

### 3.10 Monitoring, metrics, alerting
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Live CPU, RAM, disk, network, load | all panels | **A** | `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `df`, `free`; `docker stats --no-stream`. |
| Per-container resource usage | DP, CO, EP, Dockhand | **A** | Docker stats API over the socket via SSH. |
| Metric history (charts over days) | CO (Sentinel), DP (local host only), CR (NetData), EP, CC | **D** (fine-grained) or **H** (coarse) or reuse existing | Options: (1) sample only while open; (2) reuse sysstat `sar` if installed **[prior knowledge]**; (3) read existing Netdata, Prometheus node_exporter or Beszel if present; (4) **H** minute-level timer appending to a ring file; (5) optional agent later. |
| Disk usage threshold alerts | CO | **H** | Timer + threshold script. |
| Server unreachable alerts | CO (2 consecutive failed checks) | **D/external** | By definition the host can't report its own death. Needs an external watcher: another server in the list running a timer (**H** on a peer), or Uptime Kuma or Healthchecks-style dead-man's switch. |
| Container died or restart-loop alerts | CO (unexpected stop, restart limit) | **H** coarse (timer checking `docker ps -a` and restart counts) / **D** precise (`docker events`) | |
| CPU and memory threshold alerts | CO says this needs an external system | **H** | |
| Log drains and forwarding | CO (workload output only), DK (vector) | **X** | Recommend existing tools (Vector, Loki). Offer live tail only. |
| Server diagnosis checklist | YH (ports, DNS, mail, rDNS, blacklists) | **A** | High-value "doctor" screen: disk >90%, inodes, failed systemd units, pending security updates, reboot required, cert expiry, open ports, Docker disk use, dangling images, time sync. |

### 3.11 Notifications
| Channel | CO | DP | Others |
|---|---|---|---|
| Email | yes (SMTP/Resend) | yes (SMTP/Resend) | DK (MAILTO), CL, YH |
| Slack / Mattermost | yes | Slack yes; Mattermost page | |
| Discord | yes | yes | |
| Telegram | yes | yes | |
| Pushover | yes | yes | |
| ntfy | no (per docs) | yes | |
| Gotify | no | yes | |
| Lark / MS Teams | no | Lark yes; Teams unconfirmed | |
| Generic webhook | yes | yes | |

**Verdict:** Sending is trivial over HTTP: `curl` from a host script (**H**) or from the client (**A**, only while open). For alerts while the app is closed, the host-side script must hold the channel credentials (ntfy topic, Telegram bot token). Disclose this in the UI. Native mobile push from our app would need a push relay (APNs/FCM), which is **D**. Recommending ntfy or Gotify sidesteps that because they ship their own mobile apps. Apprise as a single host-side multiplexer is an option **[prior knowledge]**.

### 3.12 Multi-server and clusters
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Many servers in one UI | CO, DP, Dockhand, Dockge (agents), 1P (Pro), EP (paid) | **A, native strength** | The synced server list already exists. The client *is* the hub, with no panel host to secure. |
| Fleet overview (health tiles for all servers) | CO, Dockhand | **A** | Parallel SSH sessions with a bounded concurrency pool. |
| Bulk actions across servers (update images, prune) | partial | **A** | |
| Swarm / k3s orchestration | DP, CR, EP, DK (k3s, Nomad) | **X** (v1) | Read-only view of swarm services at most. |
| Cloud provisioning (Hetzner, DO, Vultr) | CO | **X** v1 | Later: provider API from the client. |

### 3.13 Users, teams, access
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Teams and RBAC | CO (teams), DP (Enterprise custom roles), Dockhand (Enterprise RBAC), CL Max | **X** mostly | Access = SSH account. A client-side "read-only server" toggle is a soft guard. |
| SSO / IdP | CC, YH, CL, DP Ent | **X** | |
| Audit log | DP Ent, KA (on servers), 1P | **A** | Host-side append-only log of actions taken by the app (KA pattern), attributed to device and user. |

### 3.14 Host maintenance
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| OS update checks and patching | CO (patch notifications, patching), CL, YH | **A** check and apply, **H** unattended | `apt list --upgradable`, `dnf check-update`, `needrestart`, `/var/run/reboot-required`. |
| Docker cleanup (prune) | CO (scheduled, notifications), DP | **A** manual, **H** scheduled | Show reclaimable space (`docker system df`) before pruning. |
| Image update detection | CC (every 6 h, needs `latest`), TN, SY (`latest` only), UM (update shelf) | **A** | The client compares registry digests and semver tags directly with registry APIs, without SSH. Better than "latest only". |
| Auto-update images | CC (auto-update mode), RT (cron guide) | **H** | Discourage for stateful apps. Pair with pre-update backup. |
| Firewall view and edit | CL (manages iptables), YH (nftables), 1P | **A** view; edit with lockout protection | Auto-revert timer (if not confirmed in 60 s, restore) via `systemd-run --on-active` (**H**). |
| fail2ban, WAF, antivirus | YH, 1P (WAF, ClamAV) | **A** view status / **X** manage | |

### 3.15 Storage and NAS functions
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Disk usage by mount, inode use, biggest dirs | all panels | **A** | `df -h`, `df -i`, `du`, or `ncdu`-style scan streamed. |
| SMART and RAID/ZFS health | UM 2.0 (drive health), TN, UN, CA/ZimaOS | **A** read-only | `smartctl`, `zpool status`, `mdadm --detail` (often needs root). |
| Pooling, parity, shares | UN, TN, CC (MergerFS), UM (FailSafe) | **X** | |

### 3.16 Onboarding and remote access
| Feature | Seen in | Verdict | Notes |
|---|---|---|---|
| Cloudflare Tunnel / Tailscale guides | DP, RT, CO (SSH via tunnel), UM (Tailscale) | **A** | The app needs only SSH reachability, so Tailscale works naturally. |
| VPN (Constellation) | CC | **X** | |
| AI assistant / MCP | CO (MCP), DP (AI assistant), UM 2.0 (MCP server), 1P (AI agents) | Optional | Trend worth noting for a later phase. |

---

## 4. Agentless vs server-side: summary and recommended tiering

**Tier 0, pure agentless (v1 core).** Needs SSH and Docker on the host, nothing installed:
- Fleet and server dashboards with live metrics, processes, services and journal logs.
- Disk, cron and timer viewer and editor; diagnosis checklist; OS update checks.
- Docker: containers, images, volumes, networks, live logs, exec terminal.
- Compose: discover, edit, validate, up/down/pull, safe update with rollback.
- Template catalog install; manual backups and restores; cert expiry checks; image update checks via registry APIs.
- Host-side lock file and audit log.
- Coolify's fallback design shows that SSH polling covers this surface.

**Tier 1, host-native delegation (v1.x).** Optional and explicit. Each item is a visible file the user can read and delete:
- systemd timers and units (cron fallback when systemd is absent) for scheduled backups (restic), retention, integrity checks, Docker prune, `git fetch` redeploy polling, threshold checks, container-died checks, and coarse metric sampling into a ring file.
- A small notifier script for ntfy, Gotify, Telegram, Discord, Slack, Pushover, email or webhook.
- Kept under one directory such as `/etc/<app>/` and `~/.config/<app>/` with a manifest, so the client can list, diff and uninstall everything it ever installed. Dokku's crontab ownership and Runtipi's cron guides are precedents. Unlike them, keep the footprint enumerable and removable.

**Tier 2, optional resident component (later, opt-in).**
- Webhook receiver for deploy-on-push.
- Fine-grained metric history and `docker events`-driven alerts. Coolify needed Sentinel for exactly these.
- An external "peer watcher" for host-down alerts. One server in the user's list watches others with a timer; this is Tier 1 on a peer.
- Note for the plan: the Seance sync server is described as E2E-encrypted, so by design it cannot run checks that need server credentials. Using it as a monitoring hub would break that model. **[inference from repo context; not verified against sync server code]**

**Out of scope:** Swarm and k8s orchestration, PR previews, SSO/IdP, mail servers, WAF, VPN, disk pooling, cloud provisioning (v1), log aggregation pipelines, lazy-start proxies.

---

## 5. UX lessons and onboarding patterns worth adopting

1. **Explain the next step after install.** Umbrel's App Store Standard requires that every app open to a web UI or setup page "without SSH, CLI access, log scraping, or manual file edits". For us: after a template install, show the URL, generated credentials (copyable, stored only in the host `.env`), and a health indicator that turns green when the container is healthy.
2. **Compose plus metadata, rendered as a form.** Combine CapRover's `validRegex` fields with start and end instructions, CasaOS's per-variable human descriptions (localized), Runtipi's `form_fields` and arch compatibility, and Coolify's auto-generated passwords and domains. Always show "View raw compose" so the form never hides what will run.
3. **Pull before stop, restore on failure** (Runtipi 4.10.2). Run updates as a transaction: pull, snapshot (files, image digests, optional pre-update backup as in Cloudron), apply, health-gate, auto-rollback. Tell the user what was restored.
4. **Be honest about coverage.** TrueNAS states rollback does not cover host paths. Coolify says "A successful backup only proves that Coolify created a file". Cloudron's cleaner logs why each backup was kept. Every backup or rollback screen should list exactly which volumes and paths are covered and which are not, and offer "Verify by test-restore".
5. **Validate before apply, with a safety net.** Coolify validates proxy configs and warns that one bad config takes down every app. Do the same for nginx, Caddy and Traefik (`nginx -t`, `caddy validate`) and compose (`docker compose config`). For firewall changes, use a dead-man auto-revert.
6. **Pre-flight checks that fix common traps.** Synology and Coolify both fail when bind-mount sources don't exist; Docker then creates a directory and you get `not a directory` errors. The app should detect missing paths, port conflicts (`ss -ltnp`, notably 80 on Synology), wrong arch, and low disk, and offer one-tap fixes.
7. **Per-channel, per-event notification matrix** (Coolify). Choose a channel, toggle events and test send. Defaults: failures on, successes off.
8. **Transparent operations.** Kamal's "just basic Docker commands" and Dockge's real-time output. Show the exact commands that ran, as an expandable log. This helps people learn Docker, which is the "approachability" angle CasaOS chases with "no code, no forms" without hiding the truth.
9. **Status colors that teach.** Cosmos shows exposed public ports in orange. Extend this to a compose security lint: privileged, host network, `docker.sock` mounts, `0.0.0.0` bindings of databases, `latest` tags, missing restart policy, missing healthcheck.
10. **Start order with wait delays** (Unraid) maps to `depends_on: condition: service_healthy` within a stack. Offer a simple drag-order UI that writes those conditions.
11. **Update shelf and release history** (Umbrel 2.0) instead of silent auto-update (Cosmos auto-update mode). Show changelog links per image when the template provides them.
12. **Diagnosis "doctor" screen** (YunoHost). Run read-only checks and give actionable fixes. This is cheap to build agentlessly and differentiates the app from Docker-only tools.
13. **Escape hatches everywhere.** Open a terminal (Seance) in the stack directory; open the files (Poltergeist) of a volume or bind mount; edit any file in Planchette. The suite already has these pieces.
14. **Multi-device coordination** (Kamal lock and audit). With 5 platforms and a synced server list, two devices may act on one host. Use a host lock file with owner, device and TTL plus an append-only audit log.
15. **Clear security posture for public repos** (Dokploy warns against previews on public repos). Similar warnings belong anywhere an action could run untrusted code, such as building from arbitrary git URLs.

---

## 6. Pitfalls these platforms hit, and how a client should avoid them

### 6.1 Taking over the host
- Panels need ports 80/443 (DP adds 3000, CR adds 3000 and wildcard DNS), a proxy they own, and often Swarm (DP, CR, EP). Cloudron needs a fresh Ubuntu 26.04 and manages iptables. YunoHost brings its own mail, LDAP and firewall. Umbrel and ZimaOS are whole OSes. Coolify's validation may restart Docker and drop running containers.
- **Rule for us:**
  - Never install a proxy, init Swarm, restart dockerd or change firewall rules without an explicit, separately confirmed action.
  - The default mode must be *observe only* until the user opts in per server.
  - Never require a fresh server.

### 6.2 Conflicts with existing compose setups and other managers
- None of the PaaS adopt existing stacks. A secondary source says Coolify "may conflict with Docker Compose stacks you deployed manually". Unraid's compose plugin even hides compose containers from the native Docker tab: two worlds that don't see each other.
- **Rules for us:**
  - Discover every compose project from container labels, wherever it lives. Treat the file on disk as the single source of truth and re-read it on every open, with no shadow database.
  - Detect ownership markers and default those projects to read-only with a "managed by X" badge: `coolify.managed=true`, `runtipi.managed: true`, Umbrel `app_proxy` services, CasaOS `x-casaos` files, Swarm `com.docker.stack.namespace`, TrueNAS-managed projects **[label conventions for the last three: prior knowledge, verify during implementation]**. Editing behind another manager's back gets overwritten, or worse, desynchronizes it.
  - Detect Dokku's reserved `dokku` user crontab and never edit it.

### 6.3 Rewriting user files
- Coolify injects labels, networks and variables (Raw mode exists because of this). CapRover honors only 8 compose keys and ignores the rest. Cosmos "silently ignores" unsupported compose features on import. Runtipi has migrated template formats (JSON to YAML). TrueNAS 25.10 began rejecting previously valid YAML.
- **Rules for us:**
  - Edit compose with a comment- and order-preserving YAML round-trip.
  - Never drop unknown keys. Always show a diff before writing and keep a timestamped backup copy next to the file.
  - Put app-specific metadata in `x-<app>` keys (ignored by Docker) or in a sidecar override file, never in fields Docker interprets.

### 6.4 Opaque central state and lock-in
- Panel databases (Coolify, Dokploy PostgreSQL, Cloudron) become the source of truth. Migrating a Coolify instance itself is an open request (#5014), and CapRover's restore needs its own `backup.tar` dance.
- **Rules for us:**
  - Keep all durable state on the host in standard formats: compose files, `.env`, systemd units, restic repos, and a small JSON manifest of what we installed.
  - Uninstalling the app must leave everything running, as CapRover's "No lock-in" promises. Back up with restic or borg so data is restorable without us (Cosmos rationale).

### 6.5 Incomplete backups presented as complete
- CapRover excludes volumes and images. Dokploy excludes bind mounts. Coolify excludes Redis-family databases. TrueNAS rollback excludes host paths. Umbrel 1.5 does not let users set schedules.
- **Rules for us:** Enumerate every mount of every service in a stack. Classify each one as backed up, excluded by choice, or unsupported, and show the list. Make "verify restore" a first-class action.

### 6.6 Insecure defaults
- CapRover's default dashboard password is `captain42`. Panels listen on 3000 or a random port, so an exposed web panel is attack surface by itself (1Panel uses a "security path" as mitigation). Umbrel templates ship static DB passwords. Cosmos needs `latest` tags to detect updates. Many tools mount `docker.sock`, which is root-equivalent.
- **Rules for us:** No listening ports in Tier 0/1, which is a major selling point. Generate random secrets per install. Encourage pinned tags with digest-aware update checks. Lint for socket mounts and public DB ports.

### 6.7 Licensing traps when reusing catalogs and code
- **Licenses:**

  | Source | License |
  |---|---|
  | CapRover one-click-apps | Apache-2.0 |
  | CasaOS-AppStore | Apache-2.0 |
  | Coolify templates (in the Apache-2.0 repo) | Apache-2.0 |
  | Dokploy templates | MIT |
  | Runtipi app store | GPL-3.0 |
  | 1Panel app store | GPL-3.0 |
  | umbrel-apps | no LICENSE file (all rights reserved by default) |
  | Cosmos | Commons Clause + Anti-Tampering |
  | umbrelOS | PolyForm Noncommercial |
  | Dokploy `/proprietary` | DSAL |

- Hauntware is public domain (Unlicense, root `LICENSE`).
- **Rules for us:**
  - Bundle only permissively licensed templates, with attribution and NOTICE handling for Apache-2.0.
  - GPL catalogs can be *fetched at runtime as user-selected third-party sources* rather than bundled. That legal question needs confirmation.
  - Never vendor code from the source-available projects.

### 6.8 Platform churn and stalled projects
- CasaOS core stalled after v0.4.15 (Dec 2024) while the store continued **[secondary]**. TrueNAS moved k3s to Docker in 24.10 and drops REST in 26. Synology renamed the package. Unraid changed its licensing model.
- **Rule for us:** Depend on stable primitives only: SSH, Docker Engine API/CLI, Compose spec, systemd, POSIX tools. Make catalogs pluggable data sources.

### 6.9 Swarm and kernel assumptions
- Dokploy needs IPVS (with a dnsrr fallback in LXC). Coolify Sentinel is unavailable on Swarm. Cloudron refuses ARM and LXC.
- **Rule for us:** Feature-detect (systemd present? docker vs podman? rootless? arm64? LXC?) and degrade gracefully per server rather than refusing.

### 6.10 Alerting that cannot fire
- Coolify notes CPU and memory threshold alerts need an external system. Host-down alerts can't come from the dead host.
- **Rule for us:** Be explicit in the UI. Live alerts while open are Tier 0. Host-side threshold alerts are Tier 1. Host-down needs a peer watcher or an external monitor such as Uptime Kuma. Never imply coverage that does not exist.

---

## 7. Implications for the product plan

- **Positioning:** "The control panel that isn't installed on your server." A native client with zero listening ports that respects existing compose files, built on the synced server list. Competitors either take over the host (Coolify, Dokploy, CapRover, Easypanel, Cloudron, YunoHost, Umbrel) or run a resident web UI per host (Dockge, Dockhand, 1Panel, Cosmos).
- **v1 scope candidates (Tier 0):**
  - Fleet dashboard; per-server overview (CPU, RAM, disk, load, uptime, updates, reboot-required, failed units).
  - Processes and services (systemd) with journal logs; cron and timer viewer and editor; diagnosis "doctor".
  - Docker containers, images, volumes and networks with logs, exec (Seance terminal) and stats.
  - Compose stack discovery, editing (diff + backup), validation, up/down/pull and safe update with rollback.
  - Template catalog (compose + `x-` metadata, generated secrets).
  - Manual DB dump and restic backup with verify-restore; cert expiry; registry-based image update checks.
  - Host-side lock and audit log.
- **v1.x (Tier 1):** Scheduled backups and retention via systemd timers, notifier script with ntfy, Gotify, Telegram, Discord, Slack, Pushover, email and webhook, threshold and container-died checks, scheduled prune and OS-update checks, coarse metric history ring, git-poll redeploy, uninstall-all manifest.
- **Later (Tier 2, opt-in):** Webhook receiver, fine-grained metrics agent, peer watcher, zero-downtime proxy integration (kamal-proxy or Caddy), cloud provisioning, MCP.
- **Suite synergies:** Seance (terminal, SSH core, sync server for the server list), Poltergeist (SFTP transfers for volume and file browsing, backup targets, cross-server migration), Planchette (compose and config editing).
