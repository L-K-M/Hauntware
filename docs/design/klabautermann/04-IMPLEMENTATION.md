# 04. Implementation plan

Status: plan with owner decisions of 2026-10-10. Nothing here is implemented.

This chapter continues [03-ARCHITECTURE.md](03-ARCHITECTURE.md), and its
section numbers continue from there: sections 1 to 11 are in 03, sections
12 to 15 and Appendices A to C are here. A bare section number below 12
(for example "8.3") and a decision number (D1 onward) refer to 03. The
markers [V], [L], [R], [U] and [E], the path abbreviations `SC`, `SP`,
`PC`, `PA` and `SA`, and the report markers r1 to r5 and c1 to c4 are
defined at the top of 03. "Decision N" cites the owner decisions of
2026-10-10, numbered 1 to 22 as listed in section 15.

---

## 12. Suite integration checklist

### 12.1 Registration points

Items marked M1 land in the scaffold PR series together. Items marked M4
land with the MVP preview, which ships in suite releases labelled preview
(decision 16); until then no suite release publishes Klabautermann
builds. The Rust rows marked M8 serve the `klabautermann-notify` helper
of T1 alert delivery (decision 21), and the companion reuses them; items
marked M9 belong to the Rust companion alone. The release tool
must not register the product before its app pubspec, README marker and
plists exist, and must not miss it either, because an unregistered directory
is silently unmanaged (`tool/release_version/lib/release_version.dart:785-794`
[V]).

| Area | Item and location | Milestone |
|---|---|---|
| Root build | `scripts/build.sh:31` `PRODUCTS="planchette seance poltergeist"` and the argument `case` at `:46` (otherwise `scripts/build.sh klabautermann` exits 2) [V]; header prose `:2-26` | M1 |
| Root tests | `scripts/test.sh`: header "all three subtrees" (`:5` [V]); a pure-Dart block (pattern of Poltergeist's block at `:77-132` [V]); a Flutter block (pattern `:163-167` [V]); new shared packages in the Planchette loop and `dart format` line | M1 (shared packages in their F PRs) |
| Root release | `scripts/release.sh:78` `RELEASE_CI_NOTE` names the products [V] | M1 |
| Release manifest | `scripts/release-manifest.txt`: a "Klabautermann clients (5 targets, 8 assets)" block mirroring Poltergeist's at `:46-54` (apk, linux tar.gz, deb, AppImage, flatpak, macos zip, unsigned ipa, windows zip) and the header prose `:11-15` [V] | M4, with the `client_klabautermann` release job (decision 16) |
| Workflow contracts | `scripts/check-workflows.sh:244` loop `for leg in client_seance client_poltergeist` gains `client_klabautermann` (APK version-code check) [V]; header item 11 | M4, with the `client_klabautermann` release job (the loop inspects `release.yml` legs) |
| Release tool | `_projectNames` at `tool/release_version/lib/release_version.dart:39` [V]; a `SuiteProduct` in `_defaultProducts` (`:123` [V]) with `flutterVariablePlistPaths` for iOS and macOS `Info.plist` | M1, together with the scaffold |
| Release tool tests | `release_script_test.dart` owned-pubspec list (add the app and every `klabautermann/packages/*` pubspec, assert `klabautermann/pubspec.yaml` is not owned) and the forwarder loop; `release_workspace_test.dart` fixture block and `_syncTargets`; `release_version_cli_test.dart` fixture loop and plists; `windows_version_test.dart` app list; `build_script_test.dart` `--check`, macOS bundle and failure-format expectations [R: c4 R5 to R12] | M1 |
| CI | Jobs in 03, section 11.6; header and target-count comments (`ci.yml:3-9`, the "3 Planchette desktop + 5 Séance + 5 Poltergeist" comment); the client matrix builds on every PR without a path filter, like the siblings (decision 15); the integration job runs privileged `docker:dind` on ephemeral GitHub-hosted Linux runners, pinned by digest, with loopback-only ports (decision 15) | M1; integration job M2 |
| Release workflow | `test` gate step for the `klabautermann` packages and guards; `flutter` gate step; `client_klabautermann` job copied from `client_poltergeist` (`.github/workflows/release.yml:925` [V]) with SHA-pinned actions, the provenance step and the lock-drift guard; `docker.needs` (`:1168` [V]) and `sums.needs` (`:1247` [V]) gain `client_klabautermann`; asset-count comment (25 to 33); header comment (`:3-9`, "13 client targets (3 Planchette desktop, 5 Séance, 5 Poltergeist)" becomes 18) and a release notes line labelling Klabautermann preview until v1; signing stance (`:18-23`) | M1 for the `test` and `flutter` gate steps; M4 for the `client_klabautermann` job (with its `docker.needs` and `sums.needs` edges), the comments and the notes line (decision 16) |
| Guards | Root import guard entry, private-key scope list, `.gitleaks.toml` allowlist entries for `klabautermann/app/klabautermann_app/android/(app/ci-release.jks\|key.properties)` and fixture keys (pattern `.gitleaks.toml:11-17` [V]) | F1, M1 |
| Repository config | `.github/dependabot.yml` gradle entry for `/klabautermann/app/klabautermann_app/android` (pattern `:18-19` [V]); `fixture-images.yml` matrix; `secret-scan.yml` key-scope step; `klabautermann/.gitignore` | M1, M2 |
| Root docs | `README.md` product table, counts and the "distinct names, IDs, storage locations and keystore namespaces" sentence; root `AGENTS.md` product list, layout, boundaries ("Klabautermann consumes the shared SSH/protocol implementation through its core barrel"), "all 18 clients" (with the `client_klabautermann` release job), the `klabautermann-notify` helper (with the Rust release job) and "the companion"; root `CHANGELOG.md`; design docs in `docs/design/` for each extraction | F1 onward, M1; client counts at M4; helper at M8; companion at M9 |
| History checker | Nothing: a greenfield product must not get a `docs/history/source-refs.json` entry (`scripts/check-history.py` iterates recorded sources only [R: c4 §3]) | n/a |
| Packaging | `klabautermann/scripts/build.sh` (Poltergeist's client-only pattern, `HAUNTWARE_BUILD_ORCHESTRATED`); `package-linux.sh` as a thin wrapper over a new shared root helper extracted from the three ~500-line copies [R: c4 P2]; `build-flatpak.sh` sourcing `scripts/flatpak-repack.sh`; `flatpak/ch.lkmc.klabautermann.yml` with `--share=network`, `--socket=ssh-auth`, `--talk-name=org.freedesktop.secrets`, display sockets, and no `--filesystem=home` (exports through portals); `release.sh` forwarder; macOS keyboard fixture stub; icon master | M1 |
| Platform identities | Android committed public debug-grade keystore with a pinned certificate digest; unsigned IPA; macOS ASCII `PRODUCT_NAME`, empty `Release.entitlements`, legacy login keychain; Linux binary and WM class; Windows `Runner.rc` with `CompanyName` `ch.lkmc` and semantic-only `VERSION_AS_NUMBER`; Android label (12.3) | M1 |
| Product docs | `AGENTS.md` with the byte-identical shared-rules block, `CLAUDE.md` (pointer plus the PR babysitting block), `README.md` with exactly one version marker, `CHANGELOG.md` starting with `## Unreleased`, `LICENSE` (Unlicense), `docs/plan/00-OVERVIEW.md` (the decision log of 03, section 2), `docs/plan/07-MILESTONES.md`, `docs/STATUS.md`, `docs/SHARED.md` | M1 |
| URL scheme | `klabautermann://` on five platforms: `CFBundleURLTypes` (macOS, iOS), Android intent filter, Linux `MimeType=x-scheme-handler/klabautermann;`, Windows registration plus single-instance forwarding (ledgered copy of `deep_link_scheme.cpp`) | v1.x (X-06) |
| Sibling changes | Séance: pulled-pin conflict check through the catalog library's quarantine handler (#56, F3d); `ghost_theme` switch (F4b); `RecordKind` switch update with the enum value (v1); link intake with the starting-folder parameter for X-10 (F5d); inbox skip of marked Klabautermann app ids: `InboxService.refresh` advances its cursor past them and never decrypts or deletes them (`SC/src/inbox/inbox_service.dart:214-222` [V]), in a suite release before T1 alert delivery (M8, owner decision 2026-10-10 (21/22): was before M9); no Settings > Inbox change, because it lists only Séance's local `inboxApp` records, not `GET /v1/apps` (A.1); adoption of shared packages per extraction. Poltergeist: catalog switch (F3a), stores and keystore (F3b, F3c), `ghost_servers` (F4, F5a), `ghost_theme` follow-up (after F4b), Android and iOS link registration (F5d) | per F phase |
| Rust toolchain | `klabautermann/rust/` Cargo workspace (the shared sealing and posting crate, the `klabautermann-notify` binary, later the companion) with a `rust-toolchain.toml` pinning an exact toolchain (rustup, cargo) and a committed `Cargo.lock`; `cargo fmt --check`, `cargo clippy` and `cargo test` in `scripts/test.sh` and a new `klabautermann_rust` CI job on every PR; the release tool keeps the crate versions at the suite version; a dependabot `cargo` entry | M8 (policy from S10; owner decision 2026-10-10 (21/22): was M9) |
| Rust cross builds | Static binaries for Linux x86_64 and aarch64 on musl (`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`), plus glibc targets only if S10 shows a need; built on GitHub-hosted Linux runners; `klabautermann-notify` from M8, the companion from M9 | M8 (proven in the helper part of S10; was M9) |
| Sealing interop CI | Known-answer vectors shared by the Rust sealing crate and the Dart opener: a blob sealed by the crate opens in the client under Klabautermann's associated-data domain (for example `klabautermann/v1/alert/` + appId) and never under Séance's (`seance/v1/inbox/` + appId, `SP/inbox/inbox.dart:39` [V]); alert format v1 validation cases; runs on every PR in `klabautermann_rust` and the Dart test job | M8 |
| Parity CI | One shared fixture corpus run through the Dart collectors, parsers and rules (`klabautermann_host`, `klabautermann_docker`) and the Rust ones; identical parsed results and rule verdicts required; runs on every PR | Harness in the parity part of S10; enforced from M9 |
| Licence and advisory checks | `cargo-deny` or an equivalent for licences (AGPL excluded: ServerBox's `sbm_parser` crate is neither used nor copied), advisories, bans and sources; in the `klabautermann_rust` CI job and the release `test` gate | M8 (was M9) |
| Rust release job | `rust_klabautermann` in `release.yml` builds `klabautermann-notify` for both targets (M8) and adds the companion binaries (M9), and writes their SHA-256 hashes; `client_klabautermann.needs` gains it so the client build of the same release embeds the hashes; `sums.needs` gains it, so `SHA256SUMS` covers the binaries; `scripts/release-manifest.txt` gains a Klabautermann host binaries block: two helper assets at M8 (asset-count comment 33 to 35), two companion assets at M9 (35 to 37; more if glibc builds are needed); `check-workflows.sh` asserts the `needs:` edge and, as for every leg, that the manifest lists the attached globs; release header comment; no signing key, no new CI secret, no GHCR image (the single `packages: write` job stays untouched) | M8 for the helper, M9 for the companion assets (owner decision 2026-10-10 (21/22): the job was M9) |
| Sync server sender quota | `seance/packages/seance_sync_server/lib/src/inbox_handlers.dart`: today `_inboxMaxAppsPerAccount = 50` (`:12`) counts every app of the account and answers `429 too_many_apps` (`:58-65`) [V]; marked Klabautermann senders get their own per-account quota (for example 500) and stop counting against the shared 50; the marker stays inside the existing app id format so 1.9.0 servers still accept marked senders under the shared 50 (15, new open item 8); server tests for both quotas and, once chosen, for the bound on what one `GET /v1/inbox` returns (15, new open item 7); limits in `seance/docs/INBOX.md` and a Séance changelog line; no envelope change and no `kProtocolVersion` bump (the inbox endpoints are separate from record sync); shipped by the existing `server` and `docker` release jobs, no new release machinery (decision 22) | M8, in a suite release before the one that ships T1 alert delivery |

### 12.2 Shared-package registration

Each new shared package (`ghost_servers`, `ghost_keystore`, `ghost_theme`,
`seance_terminal`) adds an owned pubspec at the suite version and the
matching release-tool owned-list entry; CI resolve, analyze, test and format
lines; a `scripts/test.sh` entry; an approved design doc; ledger entries in
`poltergeist/docs/PORTS.md` where Poltergeist code moves; and a refreshed
Séance pin-audit record when `seance/` lineage changes. Owned package names
must not collide with any dependency name in any lockfile, because the
release tool re-pins lock entries by exact name [R: c4 §2]. `ghost_theme`
now lands before M1 as F4b (decision 5). The Rust crates (the
`klabautermann-notify` helper and its shared sealing and posting crate
from M8, the companion from M9) are not Dart packages, but their versions
also follow the suite version, so the release tool gains a `Cargo.toml`
target (15, new open items).

### 12.3 Identities (fixed by the owner on 2026-10-10, D38)

The owner chose the name and the Windows `CompanyName` (decision 1). Every
value below is permanent once anything ships.

| Item | Value |
|---|---|
| Display name | `Klabautermann` |
| Directory and package stem | `klabautermann`: `klabautermann_host`, `klabautermann_docker`, `klabautermann_core`, `klabautermann_app`, workspace `_klabautermann_workspace` |
| Android `applicationId`, Linux and Flatpak id | `ch.lkmc.klabautermann` (frozen after the first release) |
| Apple bundle id | `ch.lkmc.klabautermannApp`; `PRODUCT_NAME` ASCII |
| Linux binary, WM class | `klabautermann`, `Ch.lkmc.klabautermann` (equals `StartupWMClass`) |
| Windows | `klabautermann.exe`; `CompanyName` `ch.lkmc`, as for Séance and Planchette and matching the `ch.lkmc.*` ids; it fixes the Windows data path (Poltergeist stays the outlier with `L-K-M` [R: c4 G6]) |
| Keystore entries | `klabautermann.vault.masterKey.v1`, `klabautermann.apikey.sync.token`, `klabautermann.apikey.<name>`; a remembered sudo password (v1.x) lives in the vault behind the master key, not in its own entry (D41, 4.5) |
| Settings keys | `klabautermann.sync.deviceId`, `klabautermann.*` |
| Method channels | `klabautermann/settings_window`, `klabautermann/settings_link`, `klabautermann/window`, `klabautermann/menu_checks`, `klabautermann/keepalive` |
| URL scheme | `klabautermann://` |
| Record kind and id prefix | `RecordKind.klabautermann`, `klabautermann:` (distinct from every existing prefix, 4.8); types `pref` and `rule` (v1), `query`, `layout`, `window` and `sudo` (`klabautermann:sudo:<serverConfigId>`, v1.x), `sender` (`klabautermann:sender:<serverConfigId>`, v1.x, decision 22) and `alertstatus` (`klabautermann:alertstatus:<senderAppId>:<alertId>`, bounded, v1.x, decision 21; 4.8) |
| Host artifacts | `klabautermann-op-<id>` units, `logger -t klabautermann`, `~/.local/state/klabautermann/`, `~/.config/klabautermann/`, `~/.local/share/klabautermann/`, `/var/lib/klabautermann/`, `/etc/klabautermann/`, `/usr/local/lib/klabautermann/`, `/etc/sudoers.d/klabautermann-readonly` (v1.x); the `klabautermann-notify` binary and its 0600 sender file inside the T1 directories of the chosen scope (v1.x, decision 21) |
| Inbox alert identities (v1.x) | Associated-data domain `klabautermann/v1/alert/` + appId (the owner's example; fixed by the helper part of S10); Klabautermann alert format v1; reserved app id marker (15, new open item 8) |
| Windows deep-link mutex | `Local\ch.lkmc.klabautermann.deep-link-primary-v1` |

---

## 13. Milestones

Sizes in engineer-weeks of focused work [E]: S up to 1, M 2 to 3, L 4 to 6,
XL 7 to 10. M0 refines every estimate. Each milestone leaves main mergeable
and demoable, with checkable exit criteria (Poltergeist milestone posture
[R: c4 §2]). Prerequisites come first; only the extractions the MVP needs
precede the scaffold.

### M0: spikes (S1 to S9: 5 to 7 in total, parallel; calendar 3 to 4 weeks)

S10 is listed here but may run later; it is not part of the MVP totals.
It covers the `klabautermann-notify` helper first, which must finish
before M8, and then the companion parity harness, which must finish
before M9 (owner decision 2026-10-10 (21/22): S10 was due only before
M9).

| Spike | Size | Scope | Exit criterion |
|---|---|---|---|
| S1 Transport | M | Streamlocal duplex with listen-before-write, custom HTTP/1.1, stdcopy, exec hijack and resize, `dial-stdio` and elevated `dial-stdio`; Docker 29.9 rootful and rootless, daemons at API 1.41 and 1.44, Podman 6.1 rootful and rootless; sshd reason codes and texts for `MaxSessions` and streamlocal refusals (expected: connect-failed "open failed" for every streamlocal refusal, 03 section 5.3); a 1,000 lines/s follow; the `HttpClient` alternative | Pure-Dart CLI demo passes a scripted scenario on every target; API fixtures recorded; D20 confirmed |
| S2 Sampler | M | HWS/1 under dash, bash, BusyBox ash, mksh and zsh as `/bin/sh`, with bash, zsh, fish and tcsh login shells; Debian 12, Ubuntu 24.04 and 26.04, RHEL 8 and 9, Alpine 3.22, a BusyBox NAS; `systemctl --output=json` on systemd 239, 245, 252, 257; journal paging flags | No framing or read-ahead failures; budgets of 11.4 met; fixture corpus v0 |
| S3 Elevation | S | The prelude on sudo 1.9.x with `tty`, `ppid` and `global` timestamp types, `timestamp_timeout=0`, `requiretty`; sudo-rs 0.2.x; doas; run0; `printf` builtin per shell | Strategy table of 03, section 8.3 confirmed or amended; rejection-text fixtures |
| S4 Detached operations | S | `systemd-run` system and `--user` over non-interactive SSH, linger, `KillUserProcesses`, `setsid` on Alpine and BusyBox, re-attach after reconnect, root-run file ownership | Runner table of 03, section 7.17 confirmed or amended |
| S5 Engine budgets | S to M | Engine isolate with 10 hosts at 2 s and one 1,000 lines/s follow on a low-end Android phone and an older iPhone | Numbers for 11.4 |
| S6 Privileged files | S | Elevated `sftp-server`; owner, mode, ACL and SELinux label after an atomic replace | Before M5 |
| S7 Port access | S | In-app web view through an SSH channel without a loopback listener | Before M6 |
| S8 Update checks | S | Registry `HEAD` against DistributionInspect against the host CLI for private registries; `ratelimit-remaining` | Before M6 |
| S9 Catalog design doc | S | Design doc recording the five approved divergence resolutions (4.4, decision 3) and Séance's pulled-pin conflict check through the quarantine handler (#56, decision 12) | Owner approval of the design doc; each resolution then lands as its own PR in F3 |
| S10 Rust helper and companion | M to L | Helper part: Cargo workspace with an exact toolchain pin and the shared sealing and posting crate; `klabautermann-notify` as static musl builds for Linux x86_64 and aarch64 on GitHub-hosted runners (glibc only if needed); a blob sealed by the crate under Klabautermann's associated-data domain opens in the Dart client and fails under Séance's; a deposit to a real 1.9.0 sync server with the token and key read from a 0600 file (never argv or environment); binary size, memory and run time on a small VPS and an arm64 board; `cargo-deny` licence and advisory policy; hash embedding through a `needs:` edge in a dry-run workflow. Parity part: a parity harness running the S2 fixture corpus through `klabautermann_host` and through a Rust port of two collectors, their parsers and one threshold rule | Helper part, before M8: the deposit opens in the Dart client in CI for both targets; size, memory and build time recorded; Rust toolchain policy proposed for owner approval; estimate of the M8 alert delivery increment. Parity part, before M9: parity harness green in CI for both targets; M9 estimate |

### F1: guards and shared tooling (M to L, 3 to 4)

Scope: F1a and F1b (03, section 3.5); design docs for F2 to F4 and F4b
approved.
Exit: the root import guard reproduces Poltergeist's verdicts exactly and
passes for Séance (with the listed exceptions), Planchette and an empty
`klabautermann` entry; protocol guard, license gate and fixture-key scope
run from root; Poltergeist uses the shared localization scanner; no
behaviour change in any app.

### F2: `seance_core` transport and safety (L, 5 to 7)

Scope: F2a to F2e.
Exit: every existing `seance_core`, Séance and Poltergeist test green;
`SshSession.runCommand` on the shared exec core; both apps on
`CredentialResolver`; pin-audit record refreshed. Follow-up PR: Séance
sessions adopt dead-peer detection (own changelog line).

### F3: catalog, stores and keystore, Séance #56 fix (L to XL, 8 to 12)

Scope: F3a with one PR per approved divergence resolution (decision 3),
F3b, F3c, and F3d: Séance routes pulled `hostkey:` records through the
catalog library's quarantine handler, so a pulled pin is installed only
without conflict and conflicts wait behind a diff (#56, about 1 to 2
engineer-weeks [E], moved here from F7 by decision 12).
Exit: Poltergeist on the catalog library with byte-identical file shapes
(golden files), its sync suites and `sync_integration` green,
`poltergeist_sync` building; the suite convergence test green; tests assert
literal keystore entry names; a manual macOS keychain check recorded
(automated compilation is not a device test, root `AGENTS.md` [V]); a
Séance regression test for #56, observed failing before the fix, passes,
with Séance's sync suites green and its own changelog line. #56 is closed
before M4.

### F4: `ghost_servers` part 1 and formatters (M, 3 to 4; parallel with F2 and F3)

Scope: F4, including the IEC byte and rate formatters in `ghost_ui`.
Exit: both apps on the shared dots, sectioning, prompts and connection
views; Séance and Poltergeist pixel baselines unchanged; dead localization
allowlist entries removed in the same PRs.

### F4b: `ghost_theme` (L, 4 to 6; after or parallel with F4, preferably before M1)

Scope: both apps' theme stacks (palettes, presets, theme editing and the
extensions shared widgets need, such as `SidebarThemeTokens`,
`FamilyPalette` and the menu theme) move into
`planchette/packages/ghost_theme` under D3, Séance switched in the same PR
series; Poltergeist follows in its own PRs. Formerly F5b; moved onto the
MVP path by decision 5 so the preview ships theme editing and presets.
Finishing before M1 lets the scaffold build its themes through the
package; at the latest it finishes before M4.
Exit: Séance on `ghost_theme` with its real-font PNG pixel baselines
unchanged; theme editing and presets covered by the package's tests;
dead localization allowlist entries removed; the Poltergeist follow-up
planned with its baselines as the gate. Pasting a theme from a sibling app
stays v1 (X-01).

### M1: scaffold and suite registration (M, 2 to 3)

Scope: every M1 row of 12.1 in one PR series; engine isolate skeleton with
the plain-data protocol; pull-only enrollment (FL-22) and local-only import
(FL-02); read-only rail with reachability dots; settings window; light and
dark themes built through `ghost_theme` (if F4b finishes after M1, the
scaffold starts with minimal themes from `ghost_ui` tokens and switches to
`ghost_theme` before M4); contract tests.
Exit: `scripts/build.sh --check` and the release tool's `check` list the
product; all five client legs build on every PR and pass launch checks; no
release leg yet (decision 16); the guard
reports zero dartssh2 imports under `klabautermann/`; the pull-only test passes.

### M2: host read MVP (L, 5 to 6)

Scope: links over `SshLink` with jump hosts; batch endpoint confirmation
and monitor set; capability probe; HWS/1 fast and slow samplers; tier A
parsers with fixtures; fleet rows with pressure bars and freshness, search
and group sections; overview (OV-01 to OV-04); processes list; services
list, failed units and unit logs; journal viewer, follow, kernel log, text
search, file tail and access notice; unified jobs list with schedules in
words; system identity, LXC awareness, uptime; access check; coverage UI
and gap rendering; session rings, charts and the log viewer.
Exit: fixture suites for every MVP collector on tier A platforms;
integration tests for sampler start, tick, timeout recovery and reconnect
resume; 11.4 budgets met; coverage copy in ARB.

### M3: Docker read MVP (L, 4 to 5)

Scope: HTTP client, stream scanner, stdcopy, negotiation; endpoint
discovery and transport ladder ranks 1, 2 and 4 (the elevated relay and
elevated file reads arrive with admin mode in M4); engine info;
event-driven refresh; container list, inspect with masking, health; log
follow and search; list stats; image list; stack discovery with source
verification, overview and file view; managed-by badges; Docker summary
card; low-session mode.
Exit: recorded-API tests for 1.41, 1.44, 1.52, 1.55 and Podman compat;
integration tests on the Docker fixture and the negative variants
(no streamlocal, `DisableForwarding`, `MaxSessions 2`, `restrict`); the
header names the transport in every mode.

### M4: MVP actions and safety (L, 5 to 6). **MVP preview release point.**

Scope: operation plans and runner; observe-only default and read-only mode;
admin mode with the prelude, NOPASSWD and the S3 fallbacks; root badges,
previews, confirmation tiers, protected targets, masking everywhere; device
audit log; process kill with the PID-reuse guard; unit actions; run timer
now; other users' crontabs read-only; container lifecycle and removal;
image removal; stack start, stop and restart; pull and redeploy as detached
operations with re-attach; danger-rule annotations; theme editing and
presets through `ghost_theme` in settings (X-01, decision 5); the M4 rows
of 12.1 (release job, manifest entries, workflow contracts, client counts).
Exit: every MVP row in `02-FEATURES.md` §2 implemented or recorded as a
deviation (03, section 1.4); integration tests for each mutation path,
including the detached compose flow with re-attach under the user and the
admin runner; the host write inventory test (11.5); the elevation CI test
(11.1); the manual checklist on one phone per OS and three real hosts;
`check-workflows.sh` green with the `client_klabautermann` leg; a release
dry run that includes the five Klabautermann clients. The first suite
release after M4 contains Klabautermann labelled preview (decision 16);
cutting it is a separate explicit task.

Foundations F1 to F4 plus F4b: about 23 to 33 engineer-weeks [E]. MVP
total (M0 to M4, including F1 to F4 and F4b): about 44 to 60 engineer-weeks
[E]. With two contributors in parallel tracks (foundations and shared UI;
spikes and product code against fakes), the preview is roughly 7 to 8
months out [E]. The dartssh2 4.x re-pin (decision 17) ran as a separate
suite-wide task (its own PR across all apps with the full SSH test matrix)
outside these totals and landed as 4.1.0 (PR #113); 5.10 lists which
`SshLink` workarounds it made unnecessary.

### F5: v1 extractions (about 9 to 16, the sum of F5a and F5c to F5f in 03, section 3.5; parallel with M5 and M6)

F5a server editor (`ghost_servers` part 2), F5c `seance_terminal`, F5d
`suite_links` with Séance link intake (opens a known server and asks before
connecting; a link picks only a server and a starting folder and never
runs a command) and Poltergeist Android and iOS registration (decision
18), F5e palette, splitter and column table, F5f app lock. F5b moved to
F4b. Each under D3, each with its switched app's suite and baselines green.

### M5: v1 part 1, editing, shells and sync writes (L to XL, 7 to 9)

Scope: in-app server editing with catalog writes (FL-03); the Klabautermann
`RecordKind` with `pref` and `rule` (Séance's switch updated in the same
PR); container exec and one-off exec; the edit pipeline for user-owned and
privileged files; JOB-04 to JOB-07, JOB-09, JOB-19; STK-07 to STK-09,
STK-23; SVC-05 to SVC-10; LOG-06 to LOG-10; the host syslog line; the
footprint manifest and view (host writes accepted by decision 6);
publication of first-seen host-key pins with the catalog writes (D15,
decision 12; #56 fixed in F3), only after the user asserts that every
device runs a Séance release with the #56 fix (FL-22, X-02); X-03, X-04
and X-10 with the starting folder (decision 18; each needs its F5d
intake); theme paste from a sibling app (X-01).
Exit: two-device convergence tests (Séance plus Klabautermann) for server
edits and `klabautermann:` records against the real sync server image;
unknown-kind skip tests; a published first-seen pin reaches Séance through
its conflict check, and a conflicting pin waits behind the diff; edit
pipeline integration tests including hash conflicts; backups listed and
removable in the footprint view; manifest checksums verified on connect;
hand-off links carry no command parameter (parser tests).

### M6: v1 part 2, breadth (XL, 8 to 10)

Scope: volumes, networks, prune with preview, pull with progress, image
history, update detection (after S8), the remaining v1 DKE, CTR, CTX and CST
rows; disk I/O, mount details, disk explorer, swap devices; interfaces,
listening-ports map, firewall view, port forward (after S7); packages
read-only and refresh; temperatures, GPU, SMART; triage (TRI-01 to TRI-04);
time and NTP, reboot and wait, boot timeline, kernel check; users and
sessions; sshd posture; endpoint TLS expiry; in-app alerts with local
notifications through `flutter_local_notifications` (BSD-3, decision 13)
and rollup history; command palette and keyboard model; configurable
cards, top lists, bottom dock; diagnostic bundle; polling budget; app
lock; snippets; tablet layout; v1 accessibility rows.
Exit: every table-stakes item of `02-FEATURES.md` §4 complete; alert rules
covered by tests; notification copy states the coverage limit; gap
rendering covered by goldens.

### M7: v1 hardening and release readiness (M, 3). **v1 public release point.**

Scope: tier A fixture expansion from user-style captures; performance and
battery passes; `INSTALL.md` and the coverage explainer; a release dry run
of all 18 clients; the manual checklist on every platform; owner sign-off.
Cutting the release is a separate explicit task (root `AGENTS.md`).

v1 increment (F5 plus M5 to M7): about 27 to 38 engineer-weeks after the
preview [E].

### M8: v1.x (increments; XL before decisions 21 and 22, plus L to XL for alert delivery)

T1 (9.3) with user scope by default and system scope only in admin mode
(decision 7), parity tests and an extended inventory test; T1 is plain
scripts and timers plus the optional hash-pinned `klabautermann-notify`
helper for sync-server delivery (owner decision 2026-10-10 (21/22): T1
was "plain files, no binary"); desktop tray and
Android reachability checks; Android watch mode, a time-limited opt-in
foreground service that is off by default, started per session, and stops
automatically with a notice (D34, decision 14); host recorders and "Enable
sysstat" (HIS-03), which shows the exact package install and timer
commands and runs them only after explicit confirmation in admin mode
(decision 6); the remembered sudo password (SAF-16, D41, decision 11): a
per-server opt-in vault entry behind the device keystore, and a second
opt-in that syncs it as the sealed `klabautermann:sudo:<serverConfigId>`
sub-record only while the device's suite-wide "sync passwords" switch is
also on, never as a `secret:` record, with sealed removal and the risk
disclosed in the switch subtitle and 8.12; a remembered password only
skips the prompt and admin mode still expires; volume browsing (VOL-03)
with a confirmed, digest-pinned helper container that is removed
afterwards (decision 20); the T1 ring file and forecasts; tier B
portability with fixtures; the update pipeline (IMG-07 to IMG-12); drift
detection, deploy preview and host-side deploy history; log explorer and
unified stream; fleet tables and cross-host search; the remaining v1.x
SEC, CRT, ACC and HW rows; X-06; `query`, `layout`, `window` and `sudo`
types; hysteresis; the health file read by Séance and Poltergeist.

Alert delivery through the sync server (decisions 21 and 22, D42; L to
XL [E] on its own, including the Rust machinery moved from M9, refined
by S10; ALR-04 to ALR-08, ALR-17 to ALR-19): the `klabautermann-notify`
helper from the shared Rust crate, installed only with consent as part
of T1, hash-pinned in the client build of the same release, listed in
the footprint manifest and removed by the one-action uninstall, with the
M8 Rust rows of 12.1; sender management with one sender per server
(`POST /v1/apps`, the sealed `klabautermann:sender:<serverConfigId>`
sub-record naming the allowed server, revocation through
`DELETE /v1/apps/{appId}`, host uninstall and a sealed removed record,
and on `429 too_many_apps` an explanation of the limit and of the server
version that raises it, with a choice of which servers alert through the
sync server); check scripts that deposit only on state changes (firing,
resolved) and send a digest when many fire at once, falling back to the
host alert spool and history file and to the ntfy, email or webhook
notifier; Klabautermann alert format v1, validated after decryption,
shown as untrusted plain text and rejected when it names a server other
than its sender's; fetching at launch and on every sync round while
open; the "while you were away" view per server with a device-local
alert history; acknowledgement and dismissal synced as bounded sealed
status sub-records (older than 30 days pruned and not published); the
server item deleted once handled; optional peer reachability checks
that deposit "B unreachable from A" through A's sender. Prerequisites,
each in a suite release before the one that ships this increment: the
Séance inbox changes of 12.1 (marked unknown app ids advance the cursor
and are never decrypted or deleted; sender keys never stored as Séance
`inboxApp` records, because Séance deletes items of a known app that
fail to open (`SC/src/inbox/inbox_service.dart:238-249` [V])) and the
sync server sender quota (12.1); the Rust toolchain policy approved by
the owner after the helper part of S10.

Exit per increment: its rows covered by tests and the inventory test
extended by its 8.11 rows; for alert delivery, an end-to-end test in
which a T1 check on the sshd fixture host deposits a sealed alert through
the real sync server image and the app fetches and shows it, while Séance
on the same account neither stalls its cursor nor deletes the item (the
convergence test); a modified helper binary refused by the hash check; no
token or key in argv, environment or unit files (checked on the fixture
host); an alert naming another server rejected; a burst of firing checks
sent as a digest within 30 deposits per minute; acknowledgement converging across
two devices and statuses pruned after 30 days; revocation deleting the
app, its host files and its sender record, after which deposits fail;
the quota explanation shown against a 1.9.0 sync server image; the
fallback to the host spool when the sync server is unreachable;
`cargo-deny` clean and a release dry run with the helper assets and
hashes embedded; for the sudo type, tests that Poltergeist
skips it undecrypted and Séance skips it without applying or storing it,
that an unsealed tombstone is ignored,
that it is published only while both opt-ins and the "sync passwords"
switch are on, and that a receiving device applies it only while its own
switch is on (D41); the watch-mode service stops at its limit and says so.

### M9: Companion (Rust) (XL, estimated after S10; after M8)

Scope: the T2 companion of 9.4, written in Rust (decision 8), nothing by
default and an explicit opt-in per server. Shape unchanged: an inbox
producer with no listener, no inbound control and no SSH or account keys;
installed, updated and removed only by the client over SSH; never
self-updating; a dedicated system user and hardening. Its collectors,
parsers and rules are a second implementation, not built from
`klabautermann_host` and `klabautermann_docker`, held to the Dart ones by
the shared fixture corpus and parity tests; no code from ServerBox's AGPL
`sbm_parser` crate. The Later rows tagged T2 that `02-FEATURES.md`
schedules here (ALR-11, ALR-14, ALR-15, HIS-08); the M9 rows of 12.1.
It reuses what M8 built (owner decision 2026-10-10 (21/22)): the shared
sealing and posting crate, Klabautermann alert format v1, the server's
existing sender, the Rust toolchain, cross builds, `cargo-deny` and the
`rust_klabautermann` release job, which gains the companion binaries.
Prerequisites: the Séance inbox change for marked app ids and the sync
server sender quota, already shipped before M8 (decision 21; 9.4 item 1);
the companion deposits through its server's existing sender, with no
first-sight key pinning (9.4 item 3; owner decision 2026-10-10 (21/22));
bounded records (9.4 item 7); the parity part of S10.
Exit: the parity suite green in CI for both targets (same inputs, same
parsed results and rule verdicts in Dart and Rust); hash pinning enforced
for the companion as for the helper: the client refuses a binary whose
SHA-256 differs from the value pinned in its own build, tested with a
modified binary; install, update and removal
over SSH covered by integration tests on the sshd fixture, with nothing
left after removal (inventory test); hardening directives applied and
checked per systemd version [U]; `cargo-deny` clean; the coverage UI shows
T2 only on servers where the user enabled it; the companion assets in the
manifest and a release dry run.

### Later

Not scheduled: the push relay (ALR-13, an open decision); the heartbeat
dead-man (ALR-12, needs a sync server change); companion items in Séance
(X-09); backups inside Klabautermann built on T1, after v1.x (BAK-03
onward, decision 19; until then BAK-01 dumps and BAK-02 backup status
stay v1.x); permissive template catalogs only (TPL-04:
Apache-2.0 and MIT; GPL and unlicensed catalogs are not fetched, decision
19); the debug shell with a confirmed helper container (CTR-21, decision
20); the Séance metrics strip (X-07); macOS and FreeBSD hosts.

### F7: Séance on the catalog library (L, after v1)

Independent of Klabautermann milestones: Séance's coordinator replaced by the
library with the persistent mirror (the quarantine handler for pulled pins
is already in place since F3d, which closed #56), migration of
`servers.json` and `deleted_records.json`, `deviceId` preserved, Séance
sync suites green. The suite-wide fix for `host:port` pin collisions behind
different jump routes changes the pin locator convention; it is a
dedicated task with or after F7 (decision 12), and until then 4.6
documents it as a known limitation.

### Critical path

```
M0 -------+-------------------------+---------+
          | S9                      | S1      | S3
          v                         v         v
F1 --+--> F3 (a to d, #56) ---+     F2a --+   F2b, F2d -+
     +--> F2c, F2e -----------+           |             |
     +--> F4, F4b ------------+           v             v
                              +--> M1 --> M2 --> M3 --> M4 (MVP preview)
                                                        |
                                                        v
         F5 (a, c to f, parallel) --------------------> M5 --> M6 --> M7 (v1)
                                                                      |
                  +---------------------------------------------------+
                  |                                                   |
                  v                                                   v
Séance inbox ---> M8 (v1.x) --> M9 (Rust companion)                   F7 (Séance migration)
and server quota  ^             ^                                     |
                  | helper      | parity                              v
                  S10 ----------+                                     pin-collision fix (suite-wide)
```

M0 and F1 start together. F1 also precedes F2a, F2b and F2d, because it
approves the F2 to F4 and F4b design docs; F2a is needed only by M2, and
F2b and F2d only by M4 (03, section 3.5). F3d (Séance #56) must land before
M4. F4b runs after or in parallel with F4 and preferably finishes before
M1, so the scaffold builds its themes through `ghost_theme`; at the latest
it finishes before M4, which ships theme editing. S10 may run with M0 or
later; its helper part finishes before M8 and its parity part before M9
(owner decision 2026-10-10 (21/22): S10 was due only before M9). The
Séance inbox prerequisites and the sync server sender quota land in a
suite release before the one that ships T1 alert delivery in M8
(decisions 21 and 22). The suite-wide pin-collision fix runs with
or after F7. The dartssh2 4.x re-pin (decision 17) has landed and is not
on this path.

---

## 14. Risks and mitigations

| # | Risk | Likelihood / impact | Mitigation | Pre-authorized fallback |
|---|---|---|---|---|
| R1 | The catalog extraction is larger than estimated or changes Poltergeist behaviour | Medium / high | Design doc first (S9) with the approved resolutions (decision 3); byte-identical goldens; convergence test; pull-only MVP | Ship M2 and M3 on the read side of the library (stores plus `ServerConfigHandler`, no writer); still shared, never copied |
| R2 | An extraction regresses a shipped app (keychain entry, pixel drift, sync data) | Medium / high | D3; literal entry-name tests; manual macOS keychain check; sibling baselines | Narrow the move; revert is one PR because shims keep call sites |
| R3 | dartssh2 defects (keepalive, `env` refusal, close, no ML-KEM; the stall, chacha20 and Android KEX timeouts were fixed by the 4.1.0 re-pin, decision 17) | High / medium | Workarounds in `SshLink` (5.10); CN-23 errors | ML-KEM-only hosts documented as unsupported |
| R4 | Sampler portability on unusual hosts (ServerBox's top support cost, r4) | High / medium | Tiers, per-platform fixtures, diagnostic bundle, panels that hide with reasons | Tier B after v1 |
| R5 | Users expect alerts while the app is closed | High / medium | Coverage UI from first run; tray, Android reachability and Android watch mode in v1.x; T1 committed for v1.x, delivering alerts through the sync server to every device at its next launch or sync round (decision 21) | None needed: T1 is the answer; the opt-in Rust companion follows in M9 |
| R6 | Elevation variance (sudo-rs, `requiretty`, disabled cache, doas, run0) | Medium / medium | S3; fallback ladder; CI test against a real sudo | doas and run0 password modes stay out of v1 |
| R7 | Detached operations on hosts without a system manager, without linger, or with `KillUserProcesses=yes` | Medium / medium | Runner table; preview warnings; re-attach by PID and start time | Foreground run with an explicit warning |
| R8 | Low `MaxSessions` or forwarding disabled | Medium / medium | Low-session mode; transport ladder; header labels | Docker read-only on such hosts |
| R9 | Docker API drift and Podman compat gaps | Medium / medium | Negotiation, tolerant models, per-version fixtures | Hide newer fields at the negotiated version |
| R10 | Compose CLI flag changes; profiles not in labels | Medium / low | Version-gated flags; preview warnings | Stacks read-only when the CLI version is unknown |
| R11 | Shared-package blast radius (a bug in `ghost_servers` reaches three apps) | Medium / high | Tests inside the package, baselines in each app, owner-approved design docs | Per-app pin to the previous shim behaviour for one release |
| R12 | Several devices multiply polling, login records and fail2ban risk | Medium / medium | One long-lived connection per device; device-local monitor set; capped, jittered connects; pause when hidden | Lower default cadences |
| R13 | The unscoped account key; Séance #56 until F3d lands | Known / medium | #56 fixed in F3 before the preview (decision 12); pull-only MVP; first-seen pins published only from v1, after the fix; disclosure at enrollment | Keep publication disabled until the fix has shipped (D15) |
| R14 | Root-equivalent Docker access makes the device a high-value target | Medium / high | No local bridge; app lock; sudo password in memory only unless the user opts in to remembering it (v1.x); badges | n/a |
| R15 | Scope creep (494 catalog rows) | High / high | Tiers fixed here; deviations need decision-log entries | Defer whole areas, not half features |
| R16 | Foundations delay the product (F1 to F4 plus F4b, about 23 to 33 engineer-weeks [E]) | High / medium | Only MVP-needed extractions before M1; F4 and F4b in parallel with F2 and F3; spikes first | Narrow extractions (D3 cut line) |
| R17 | CI time growth: the client matrix builds on every PR (about 30 to 45 extra runner-minutes per PR, 9 macOS jobs against a cap of 5, longer macOS queues) | Certain / low | Accepted by the owner (decision 15); measure after M1; main runs stay uncancelled | None pre-authorized: a path filter needs a new owner decision |
| R18 | Native runner copies drift | Medium / low | Ledger in `docs/SHARED.md` | A shared native plugin later |
| R19 | Mobile background limits make monitoring look broken | High / medium | Coverage UI, T1 notifier through ntfy or Gotify, PLT-15, Android watch mode (v1.x, decision 14) | Reachability-only background checks on Android |
| R20 | Root-run operation files abused through symlinks | Low / high | Root never writes into user-writable directories (7.17) | n/a |
| R21 | Account growth from new record types | Low / medium | Per-type caps, 1 MiB prefix budget, SYN-09 view | Stop syncing a type; keep it device-local |
| R22 | Rust duplication and parser drift: collectors, parsers and rules exist in Dart (app) and Rust (companion) | High / medium | S10 first; one shared fixture corpus; parity CI on every PR comparing parsed results and rule verdicts; a companion row ships only with parity green | Ship the companion with fewer collectors; disable a collector whose parity fails |
| R23 | Rust toolchain and supply chain (crate advisories, licences such as ServerBox's AGPL `sbm_parser`) | Medium / medium | Exact toolchain pin; committed `Cargo.lock`; `cargo-deny` in CI and in the release gate; no code from `sbm_parser` | Hold the companion release; the T0 product is unaffected and T1 falls back as in R26 |
| R24 | Synced sudo password exposure: anyone holding the account key, and every device on the account, obtains a password that grants root on that server | Low / high | Two per-server opt-ins plus the device's "sync passwords" switch; sealed sub-record, never a `secret:` record, so Séance and Poltergeist never apply it; sealed removal; disclosure in the switch subtitle and 8.12; admin mode still expires | n/a: the owner accepted the disclosed risk (decision 11) |
| R25 | Theme extraction on the MVP path (F4b, L, against Séance's real-font PNG baselines) | Medium / medium | D3 move, switch, prove; Séance pixel baselines unchanged; Poltergeist as a follow-up; F4b in parallel with F4 | Finish after M1 (at the latest before M4); narrow the move, never copy |
| R26 | Rust arrives in v1.x (decision 21): the `klabautermann-notify` helper is a supply-chain surface on every alerting host, and the toolchain, musl builds, `cargo-deny` and the release job cost effort at M8 instead of M9 | Medium / medium | Hash pinning in the client build of the same release (decision 8 scheme); `cargo-deny` in CI and the release gate; a small single-purpose crate with few dependencies, shared with the companion; the helper part of S10 before M8; the helper optional, consented, in the footprint manifest and removed by the one-action uninstall | Ship T1 without the helper: the host alert spool and history file and the ntfy, email or webhook notifier |
| R27 | Alert flooding: many checks firing at once, a flapping check or a compromised host exhaust a sender's limits (30 deposits per minute, 100 pending items) or bury real alerts; with up to 500 marked senders, one unpaged `GET /v1/inbox` (`seance/packages/seance_sync_server/lib/src/inbox_handlers.dart:104-111` [V]) could return up to about 4.6 GiB (500 senders, 100 pending items each, 96 KiB per blob) [E], against about 470 MiB for today's 50 apps | Medium / medium | Deposits only on state changes, a digest when many fire at once, hysteresis (ALR-16); per-sender server limits; one sender per server confines a compromised host to its own server and is revoked alone; a bound on what one listing returns as part of the quota change (15, new open item 7) | Refused deposits go to the host alert spool and the notifier; the user revokes the sender |
| R28 | Séance compatibility: a Séance device on the same account stalls its inbox cursor at items of unknown apps (`SC/src/inbox/inbox_service.dart:214-222` [V]), and would delete every alert if sender keys were stored as its `inboxApp` records (`:238-249` [V]); after the change, a not yet updated Séance device still re-fetches such items on every refresh but never deletes them, because their app is unknown to it | Medium / high | The Séance prerequisites land in an earlier suite release (marked app ids skipped without decrypting or deleting; keys only in Klabautermann's record kind); convergence test with Séance and Klabautermann on one account against the real sync server image; Séance's Settings > Inbox lists only local `inboxApp` records (A.1) | Keep sync-server alerting off until that Séance release has shipped; T1 uses the host alert spool and the notifier meanwhile |

---

## 15. Owner decisions

The owner answered all 20 open questions of the proposal on 2026-10-10
and later that day added decisions 21 and 22 on alerts while the app is
not running. Decisions that deviate from the earlier recommendation are marked
"(deviates)". Section numbers below 12 and decision numbers point to 03;
catalog IDs point to `02-FEATURES.md`.

| # | Question | Decision | Where applied |
|---|---|---|---|
| 1 | Name and identities, including Windows `CompanyName` | **Klabautermann**, stem `klabautermann` (the second alternate in `05-NAMES.md`); `CompanyName` `ch.lkmc`, as for Séance and Planchette (deviates: `L-K-M` was recommended; Poltergeist stays the outlier) | D38, 12.1, 12.3, `05-NAMES.md` |
| 2 | Accept the foundations before the scaffold? | Accepted: F1 to F4, no third copies; F4b added by decision 5 | D3, 3.5, 13 |
| 3 | Approve the catalog divergence resolutions? | All five recommended resolutions approved; each lands as its own PR | 4.4, D6, S9, F3 |
| 4 | Pull-only MVP? | Accepted | D14, M1, M4 |
| 5 | Fixed brand preset in the MVP? | Theme editing and presets ship in the MVP preview through `ghost_theme`, extracted before the MVP as F4b (formerly F5b; Séance switched, Poltergeist follow-up); paste from a sibling app stays v1 (deviates) | D9, 3.5, 10.9, X-01, F4b, M1, M4, R25 |
| 6 | Are the host writes acceptable; does "Enable sysstat" fit? | All four accepted (operation records and logs, central backups, the audit syslog line, the footprint manifest); "Enable sysstat" shows the exact commands (package install and timer) and runs them only after explicit confirmation in admin mode | 8.11, D27, HIS-03, M5, M8 |
| 7 | T1 for v1.x? | Approved: user scope by default, system scope only in admin mode | 9.3, D30, M8 (optional `klabautermann-notify` helper added by decision 21) |
| 8 | T2 companion: wanted, language, signing, install stance? | Yes, milestone M9 after v1.x; Rust (deviates: Dart was recommended); SHA-256 hashes of the companion binaries pinned in the client build of the same release, no signing key, no new CI secret; nothing by default, an explicit opt-in per server; collectors, parsers and rules exist in Dart and Rust with a shared fixture corpus and parity CI; ServerBox's AGPL `sbm_parser` is neither used nor copied | 9.4, D31, 12.1, S10, M9, R22, R23 (Rust toolchain, builds, `cargo-deny` and release job moved to M8 by decision 21) |
| 9 | One record kind with typed sub-records? | Confirmed, with the 1 MiB budget | D17, 4.8 |
| 10 | Audit log device-local plus syslog? | Confirmed; never synced | D28, 8.10 |
| 11 | Saved sudo password device-only or synced? | Optional from v1.x and synced (deviates: device-only was recommended): a per-server opt-in remembers it in the vault; a second opt-in syncs it, only while the device's suite-wide "sync passwords" switch is on, as the sealed sub-record `klabautermann:sudo:<serverConfigId>`, never as a `secret:` record; sealed removal; risk disclosed in the switch subtitle and the threat model; admin mode still expires | D41, 4.5, 4.8, 8.12, SAF-16, 12.3, M8, R24 |
| 12 | Host-key publication and the `host:port` collision? | Séance #56 fixed first, in F3 (deviates); publication enabled once fixed, so first-seen pins are published from v1 with the catalog writes; the collision behind different jump routes is a suite-wide task after v1, with or after F7, documented as a known limitation | D15, 4.6, F3, M5, F7, R13 |
| 13 | Local-notification plugin; charts in-house? | `flutter_local_notifications` (BSD-3) for v1 alerts; charts stay in-house | D10, M6, PLT-15 |
| 14 | Android watch mode? | v1.x: a time-limited opt-in foreground service, off by default, started per session, stopping automatically and saying so | D34, M8, R19 |
| 15 | Path filter for the client matrix; privileged DinD in CI? | Client matrix builds on every PR, no path filter (deviates; about 30 to 45 extra runner-minutes per PR and longer macOS queues accepted); privileged `docker:dind` on ephemeral GitHub-hosted Linux runners, pinned by digest, loopback-only ports; other platforms use recorded fixtures | D36, D37, 11.3, 11.6, 12.1, R17 |
| 16 | Ship the MVP in suite releases labelled preview? | Yes, from M4: the release job, manifest entries and workflow contracts land at M4; M1 registers build, check and CI legs and the release gate steps only | 11.7, 12.1, M1, M4 |
| 17 | Start the dartssh2 4.x re-pin now? | Yes, as a separate suite-wide task in parallel (its own PR across all apps, full SSH test matrix), outside the estimates. Landed 2026-10-10 as 4.1.0 (PR #113) | D23, 5.10, 13, R3 |
| 18 | Hand-offs in v1; starting folder for X-10? | Séance link intake (opens a known server, asks before connecting, links only pick a server and a starting folder) and Poltergeist Android and iOS registration (F5d) in v1; starting folder accepted and X-10 moves to v1 | D12, 7.22, X-03, X-10, F5, M5 |
| 19 | Backup scope; GPL catalogs? | Backups inside Klabautermann after v1.x, built on T1 (until then the BAK-01 dump and BAK-02 backup status, both v1.x); only permissive catalogs (Apache-2.0, MIT); GPL (Runtipi, 1Panel) and unlicensed (umbrel-apps) catalogs are not fetched, so no legal review | 7.18, BAK-03, TPL-04, 13 (Later) |
| 20 | Helper containers for VOL-03 and CTR-21? | Allowed with explicit confirmation on each use: shows what will start and whether an image must be downloaded, image pinned by digest, an image already present preferred, helper removed afterwards; an engine change, not a host file write | 8.11, VOL-03, CTR-21, M8, 13 (Later) |
| 21 | Alerts while the app is not running: delivery path and encryption on the host? | In v1.x through the existing sync server's command inbox (server minimum stays 1.9.0): T1 checks, and later the companion, deposit sealed alerts only on state changes, with a digest when many fire at once; every device fetches pending alerts at launch and on every sync round while open, shows a "while you were away" list per server, keeps a device-local history, syncs acknowledgement and dismissal as a bounded sealed status sub-record of Klabautermann's record kind and deletes the server item once handled; Klabautermann alert format v1, validated after decryption and shown as plain text. A small single-purpose Rust helper, `klabautermann-notify`, seals (inbox blob layout under Klabautermann's own associated-data domain) and posts, reading token and key from a 0600 file; consented, hash-pinned (decision 8 scheme), in the footprint manifest, removed by the one-action uninstall, built from the companion's Rust workspace. This changes the T1 definition "plain files, no binary". The Rust toolchain, musl builds, `cargo-deny` and the release job move from M9 to M8, and S10 moves before M8 (helper first). Fallback without the helper: the host alert spool and history file and the ntfy, email or webhook notifier. Optional peer reachability checks. Séance prerequisites ship in an earlier release. | D42, D29, D30, D31, 8.12, 9.3, 9.4, ALR-04 to ALR-08, ALR-11, ALR-17, ALR-18, 12.1, 12.3, S10, M8, M9, R5, R23, R26 to R28 |
| 22 | One sender per server; the 50-app limit? | Each monitored server gets its own inbox app (sender) with its own deposit token and key; the app records the sender's allowed server and rejects alerts naming another. Sender keys are sealed `klabautermann:sender:<serverConfigId>` sub-records within the 1 MiB budget, removed with a sealed removed record; removing alerting for a server also calls `DELETE /v1/apps/{appId}` and uninstalls the host files. A small sync server change gives marked senders their own per-account quota (for example 500) beside the shared 50, with no envelope change and no `kProtocolVersion` bump; on older servers the app explains `429 too_many_apps` and lets the user choose which servers alert through the sync server | D42, 4.8, 9.3, ALR-19, 12.1, 12.3, M8, R27 |

New open items created by the decisions:

1. **Rust toolchain policy** (proposed by the helper part of S10, approved
   before M8; before M9 until decision 21): the exact toolchain pin and its
   update cadence, the minimum supported Rust version, the `cargo-deny`
   licence allowlist and advisory policy, crate review rules and the
   dependabot `cargo` entry.
2. **S10 outcome**: musl static builds for both targets, whether glibc
   builds are needed, the helper's binary size, memory and run time, the
   estimate of the M8 alert delivery increment, the parity harness design,
   and the M9 estimate; whether the client downloads `klabautermann-notify`
   from its own release's assets or bundles it (offline install against
   app size, 03 9.4 item 9).
3. **Release tool and hash embedding**: a `Cargo.toml` target so the crate
   versions follow the suite version, and how the client build embeds the
   helper and companion hashes (generated constant or bundled sums file).
4. **Pin locator convention** for the suite-wide `host:port` collision fix
   (a design doc for the task after v1).
5. Still open from the catalog: the push relay (ALR-13), the sync server
   change behind the heartbeat dead-man (ALR-12) and companion items in
   Séance (X-09).
6. **Séance release with the #56 fix**: the release number the enrollment
   assertion names, and confirmation of the derived rule that pin
   publication waits for that assertion (02 X-02, 03 D15).
7. **Sender quota and release numbers** (decisions 21 and 22): the final
   per-account quota for marked senders (500 is an example); a bound on
   what one `GET /v1/inbox` returns, which today lists every item since
   the cursor without paging
   (`seance/packages/seance_sync_server/lib/src/inbox_handlers.dart:104-111`
   [V]), for example a per-account pending cap for marked senders or a
   page limit (R27); the suite release whose sync
   server carries the quota, which the `429 too_many_apps` explanation
   names; and the suite release that carries the Séance inbox
   prerequisites.
8. **Reserved app id marker** (decision 21): a format that still passes
   the 1.9.0 server's app id check, exactly 16 bytes as unpadded base64url
   (`isValidInboxAppId`, `seance/packages/seance_protocol/lib/src/inbox/inbox.dart:34,78`,
   enforced at registration in
   `seance/packages/seance_sync_server/lib/src/inbox_handlers.dart:44`
   [V]), so older servers accept marked senders under the shared 50; for
   example a fixed leading byte sequence inside the 16 bytes, at the cost
   of fewer random bits. A prefix that lengthens the id or adds other
   characters would be refused with 400 by every 1.9.0 server. Fixed with
   D42 before M8.

---

## Appendix A. Verification notes

### A.1 Repository facts verified at `bf1da58`

- Root `AGENTS.md:5` (shared implementations are never copied); suite
  version 1.9.0 (`pubspec.yaml:16`, `seance/packages/seance_core/pubspec.yaml:7`).
- Command inbox released in 1.9.0: entry at `seance/CHANGELOG.md:111` under
  `## 1.9.0 (2026-10-04)` at `:86`, not under `## Unreleased` (`:3`).
- Séance inbox cursor stops at unknown apps:
  `seance/packages/seance_core/lib/src/inbox/inbox_service.dart:216-221`.
  Inbox constants: `kInboxMaxBlobBytes = 96 * 1024`, `kInboxRetention = 7 days`
  (`seance/packages/seance_protocol/lib/src/inbox/inbox.dart:14,26`); 50 apps
  per account (`seance/packages/seance_sync_server/lib/src/inbox_handlers.dart:12`);
  30 per minute and 100 pending (`seance/docs/INBOX.md:173-182`).
- Poltergeist gates hard-code `{'seance_core', 'seance_protocol'}`:
  `poltergeist/tool/license_gate/lib/license_gate.dart:33`,
  `poltergeist/tool/seance_pin_audit/lib/seance_pin_audit.dart:24`. Import
  guard constants at `poltergeist/tool/import_guard/lib/import_guard.dart:10-11,20`
  (220 lines). Tools present: `import_guard`, `license_gate`,
  `protocol_guard`, `release_version`, `seance_pin_audit`, `bench`; root
  `tool/` holds only `release_version`.
- dartssh2 imports: three `seance_core` library files, eight `seance_core`
  test files, one Séance app test; declarations in `seance_core`
  (`pubspec.yaml:18`), `poltergeist_core` (`:24`), `poltergeist_bench`
  (`:14`), and the Séance app's dev dependencies (`pubspec.yaml:85`). No
  `forwardLocalUnix` call anywhere in the repository.
- `seance_protocol/lib` imports no `dart:io`.
- `SA/services/xterm_engine.dart:5` imports `package:seance_core/seance_core.dart`;
  `docs/design/server-appearance-package.md:64,85` forbid shared UI packages
  from depending on `seance_core`.
- `SC/src/ssh/ssh_session.dart`: `runCommand` at `:488` with a 256 KiB cap at
  `:491` and the collapsed open error at `:504`; `openAuthenticatedClient` at
  `:694` with the keepalive note at `:692-693`; `SshSession` at `:373`.
- `PoolPolicy` defaults (2 transports, 8 channels per transport, 30 s
  keepalive and backoff cap; "Changing a default means re-measuring first")
  in `pool_policy.dart`.
- `RecordKind` at `SP/records/record.dart:22-32` with name matching
  documented at `:13-21`; `kProtocolVersion = 1` (`SP/version.dart:4`);
  push and blob caps (`SP/sync/dtos.dart:102-108`); Séance's apply switch at
  `SC/src/sync/sync_coordinator.dart:666-855` skipping `bookmark` and
  `unknown` at `:854-855`; `RefusedRecord` switch at
  `SC/src/sync/sync_engine.dart:41-48`; Séance auto-sync every 5 minutes
  (`SA/app_state.dart:524`).
- `DangerLinter` has 14 rules at `SC/src/llm/danger_linter.dart:25-101`, none
  for Docker, cron, ufw or nft; systemd only through the power-off rule
  (`:91-95`, which also matches `systemctl reboot` and `poweroff`).
- `quoteShellWord` at `SC/src/terminal/shell_command.dart:63`, fish-safe.
- `TcpBannerProber` and `ProbeService` at `SC/src/probe/probe_service.dart:27,64`;
  barrel exports `probe_service`, `remote_command`, `danger_linter`, not
  `push_batcher`.
- Keystore entries `seance.vault.masterKey.v1`
  (`SA/services/secure_master_key.dart:75`) and
  `poltergeist.vault.masterKey.v1` (`PA/services/secure_master_key.dart:45`);
  `kMinimumSharedAccountSeanceVersion = 'v0.9.0'`
  (`PA/services/sync_account_gate.dart:19`); `onHostKeyPinned` defined at
  `PC/src/bookmarks/bookmark_coordinator.dart:474` with no call site.
- Séance: Android manifest has only the launcher intent filter (`:39-42`) and
  a `dataSync` `KeepAliveService` (`:47-50`); no Apple URL types; app lock at
  `SA/services/app_lock.dart`. Poltergeist: `CFBundleURLTypes` in
  `macos/Runner/Info.plist:13-20`, `MimeType=x-scheme-handler/poltergeist;`
  at `poltergeist/scripts/package-linux.sh:314`, `windows/runner/deep_link_scheme.cpp`,
  no Android intent filter for its scheme (only `<queries>` for `seance`),
  no iOS URL types.
- Release tool `_projectNames` (`tool/release_version/lib/release_version.dart:39`),
  `_defaultProducts` (`:123`), unmanaged-path check (`:785-794`);
  `scripts/build.sh:31,46`; `scripts/check-workflows.sh:244`;
  `scripts/release.sh:78`; `scripts/release-manifest.txt` (54 lines,
  Poltergeist block at `:46-54`); `.gitleaks.toml:11-17`;
  `.github/dependabot.yml:18-19`; CI jobs in `.github/workflows/ci.yml`
  (`dart_tools` `:206`, `detect_integration` `:339`, `integration` `:397`,
  `poltergeist_client` `:1216`); release jobs (`client_poltergeist` `:925`,
  `docker.needs` `:1168`, `sums.needs` `:1247`); the "no cross-compilation"
  comment at `.github/workflows/release.yml:349-351`; `fixture-images.yml`
  with one hard-coded image; `AllowTcpForwarding no` at
  `poltergeist/test/integration/sshd-common/config/sshd_config.common:17`.
- Poltergeist's localization contract test is 2,803 lines.
- Added for decisions 21 and 22, read in the working tree on 2026-10-10
  (not re-checked against `bf1da58`): `InboxService.refresh` marks the
  run blocked at an item of an unknown app and advances its cursor only
  while not blocked (`SC/src/inbox/inbox_service.dart:214-222`); an item
  of a known app that fails to open or validate is deleted (`:238-249`).
  Séance's Settings > Inbox lists the local `inboxApp` records
  (`SA/ui/inbox_settings.dart:34`,
  `SA/services/local_settings_backend.dart:465-468`, loaded at
  `SA/app_state.dart:2633-2638`); the `GET /v1/apps` client
  (`SC/src/sync/http_sync_client.dart:187`) has no caller outside tests.
  App ids are exactly 16 bytes as unpadded base64url
  (`SP/inbox/inbox.dart:34,78`), checked at registration
  (`seance/packages/seance_sync_server/lib/src/inbox_handlers.dart:44`);
  the 50-app check counts every app of the account (`:58-65`);
  `GET /v1/inbox` returns every item since the cursor without paging
  (`:104-111`). Séance's associated data is `seance/v1/inbox/` + appId
  (`SP/inbox/inbox.dart:39`).

### A.2 Local experiments (Ubuntu 24.04 container; dash 0.5.12-6ubuntu5, bash 5.2.21, sudo 1.9.15p5; no tty)

| # | Experiment | Result |
|---|---|---|
| E1 | `printf 'while IFS= read -r l; do echo got:$l; done\ntick1\n' \| dash -s` (program and request in one write) | `dash: 2: tick1: not found`: dash reads ahead, the loop never sees the request |
| E2 | Function definitions, a READY `printf` and two tick command lines in one write, piped to `dash -s` | READY, then both ticks run in order |
| E3 | `printf 'pw\nrest1\nrest2\n' \| dash -c 'IFS= read -r p; echo "p=$p"; cat'` | `read` takes one line; `cat` receives the rest |
| E4 | Program as `dash -c` argument, requests on stdin with a `read` loop | Works (C's fallback shape) |
| E5 | `LC_ALL=C`, `v="héllo"; echo ${#v}` in dash and bash | 6 in both: byte counts |
| E6 | `-c 'echo $$; <child prints $PPID>'` with and without `; exit $?` | bash execs the last command (the child's parent changes); dash does not; `; exit $?` stops bash from doing it |
| E7 | The sketch of 03, section 6.3, with two ticks in the same write, under dash and bash | Correct frames; UTF-8 payload "héllo wörld" reported as 13 bytes |
| E8 | Temporary user with a password and `ALL` sudoers rule; run through `su` without a tty | Prelude (no `exec`, trailing `exit $?`) succeeds under dash and bash and passes remaining stdin to `cat`; `exec sudo -n` variant fails with "sudo: a password is required"; variant without `exit $?` fails the same way under bash; `sudo -S -v` in one shell does not help `sudo -n` in another; wrong password exits 125 with "Sorry, try again.", "sudo: no password was provided", "sudo: 1 incorrect password attempt"; with `timestamp_timeout=0` the prelude fails with "a password is required"; `sudo -S -p '' -- cat` reads exactly one password line and passes the rest. The user and sudoers files were removed afterwards |
| E9 | Detached wrapper under `setsid -f dash -c` with a command that prints, sleeps and exits 3 | "running" record with PID and start time, then "done" with `rc: 3`; log captured; directory 0700, files 0600 |
| E10 | `echo test \| openssl enc -chacha20-poly1305 -K 00 -iv 00` and the same with `-aes-256-gcm` (OpenSSL 3.0.13); `openssl enc -list` | Both print "enc: AEAD ciphers not supported"; the list has no XChaCha20 and no Poly1305 mode, only plain `-chacha20` without a MAC; `-K` would also put the key in argv (D42) |

### A.3 Not verified

No Dart or Flutter toolchain was run and no test results are claimed. No
spike was executed. Behaviour of OpenSSH, systemd, Docker, Podman, Compose,
sudo-rs, doas, run0, BusyBox, mksh and mobile operating systems beyond A.2
comes from the research reports and reviews and keeps their markers.
Repository line references from c1 to c4 not listed in A.1 are marked [R].
Estimates are estimates.

---

## Appendix B. Review "must address" items and where they are resolved

The items come from the engineering review and the product and security
review described at the top of [03](03-ARCHITECTURE.md). Resolutions below
section 12 and decision numbers point to 03.

| Review item | Resolution |
|---|---|
| Elevation: no `exec`, password never in the command's stdin, keep stderr, siblings of one shell with a trailing `exit`, disabled cache, password out of argv, sudo-rs and other flavours | 8.3, D24, S3, A.2 E6 and E8 |
| Sampler: dash read-ahead, READY before requests, fork budget, shells to test | 6.2, 6.3, D22, S2, A.2 E1, E2, E7 |
| Nonce not in argv; length-prefixed sections | 6.2 |
| Detached operations: results after unit unload, journal access, `--user` and linger, no `/tmp` | 7.17, D25, S4, A.2 E9 |
| dartssh2 confinement and a generalized guard with today's exceptions | D4, 3.4 |
| dartssh2 defects and the 4.1.0 re-pin | 5.10, D23 |
| `MaxSessions` classification; streamlocal failure codes | 5.2, 5.3, S1 |
| Catalog home, Poltergeist gates, divergences, Poltergeist first, pull-only test, byte preservation | D6, D14, 4.4, 11.2 |
| No third copies; native runner policy | D3, D7, D8, D9, D11, D32, 3.5 |
| Record kinds: one kind, Séance switch, v0.9.0 assertion, bounded classes, sealed removal, no new `ServerConfig` fields | D17, 4.3, 4.8 |
| Inbox prerequisites: release status, Séance cursor stall, 50-app limit, device-local key pinning | 1.4, 9.4, D42, 12.1 (Séance inbox skip, sync server sender quota), M8 and M9 prerequisites, Appendix C |
| Docker API negotiation, fixtures, custom client, no local bridge, re-list after gaps, rows and columns | D20, D21, 5.4 to 5.8 |
| Compose safety: no `--remove-orphans`, verified sources, owned stacks read-only, detached pull and up | 7.16, 8.6, 8.7 |
| Destructive defaults: no confirmation-free single keys, typed confirmation for protected targets, preview equals steps, re-validation | 8.5, 8.6, D26 |
| Host-key trust: no publication until #56, endpoint confirmation, cache purge, account-key disclosure, pin collision | D15, D16, 4.3, 4.6, 4.7; #56 fixed in F3 and the collision fix with or after F7 (15, decision 12) |
| Docker root-equivalence badge and disclosures | 8.4 |
| Secret handling | 8.9 |
| Engine isolate and protocol guard | D18, 3.4 |
| Integration fixtures and unverified live systemd and Podman | D36, 11.3 |
| Suite registration (release tool with the scaffold, workflow leg loop, manifest, `needs:` edges, shared `package-linux` helper, key scopes, CI path filter) | 12.1, D37; no path filter (15, decision 15) |
| No `dart:io` in `seance_protocol`; banner prober placement | 3.4 rule 6, 3.6 |
| Name, stem and `CompanyName` fixed before M1 | D38, 12.3 (fixed by the owner, 15, decision 1) |
| Monitoring expectation against mobile limits; T1 and T2 scope; coverage UI | D1, 9, 9.5, M8, M9 |
| Hand-offs need Séance and Poltergeist intake | D12, 7.22, F5d in v1 (15, decision 18) |
| Multi-device behaviour | D40, 4.3, 5.12 |
| Mobile UX: admin expiry on background, paused sampling with banner, detached long operations, batch first-run flow | D34, 4.3, 8.2, 10.5 |

---

## Appendix C. Factual errors in the inputs, corrected here

In the Source column, A, B and C are the three proposals and Review 1 and
Review 2 the two reviews described at the top of [03](03-ARCHITECTURE.md).
Those documents are not kept; their section numbers are given for the
record only. Corrections below section 12 point to 03.

| Source | Claim | Correction |
|---|---|---|
| A §8.2 | `sh -c 'sudo -S -p "" -v && exec sudo -n -- <cmd>'` shares the credential cache | Fails: "a password is required" [L]; replaced by the prelude (8.3) |
| A §4.9, §8.3; `02-FEATURES.md` SAF-08 | Password sudo cannot drive `docker system dial-stdio` | It can: the builtin `read` consumes one line and leaves the rest of stdin [L] |
| A §5.2 | The fast sampler runs only builtins | Its sketch forked a subshell per collector; builtin collectors now append to a variable (6.2) |
| A §7.8 | Fallback log at `${XDG_RUNTIME_DIR:-/tmp}/klabautermann-op-<id>.log` | Predictable shared path; replaced by user-owned or root-owned operation directories (7.17) |
| B §2.3 | `ghost_terminal` in `planchette/packages` | `xterm_engine.dart:5` imports `seance_core` [V]; `seance_terminal` instead (D11) |
| B rule 2.4.1 | dartssh2 declared only by four packages | The Séance app declares it as a dev dependency (`pubspec.yaml:85`) [V] |
| B §4.2 | A sessions refusal arrives as "resource shortage" | sshd sends connect-failed "open failed" [R]; classification by channel type and open count (5.2) |
| B §5.2 | No control channel without `read -t` | A client-clocked request loop needs no timed read (6.2) |
| B §10.6.9 | The command inbox is unreleased | Released in 1.9.0 (`seance/CHANGELOG.md:86,111`) [V]. Review 1's statement that it is "still under Unreleased" is also incorrect |
| B threat model | A compromised device cannot forge companion alerts | It can: every device holds the sealed sender keys, so it can rewrite a server's `sender` record and forge alerts for that server; a changed `sender` record is shown with its device and time (9.4 item 3, 8.12; owner decision 2026-10-10 (21/22)) |
| B §5.2 | Nonce passed in argv | Readable by local users; delivered on stdin (6.2) |
| Review 2 graft | Move `TcpBannerProber` into `seance_protocol` | Would add the first `dart:io` socket code to a package shared with the sync server; it stays (3.6) |
| C §5.3 | POSIX shells do not read ahead from stdin, so a `read` loop sees requests | dash reads ahead from pipes [L]; ticks are command lines (6.2) |
| C §2.3, §2.6 | Séance's only dartssh2 use outside `seance_core/lib` is one app test | Also eight `seance_core` tests and the app's dev dependency [V] |
| C §7.7 | Exit status from the unit's `Result` and `ExecMainStatus` after `--collect` | Units are unloaded after completion [R]; status record instead (7.17) |
| C §8.3 | Prelude with `2>/dev/null` on sudo | Hides the texts the app classifies; stderr kept (8.3) |
| C §7.7 | `up -d --remove-orphans` by default | Destructive; orphans listed and removed only by explicit choice (7.16) |
| C §9.1 | Tier 1 restart needs no confirmation on desktop | Every mutation needs at least a dialog (8.6) |
| C §3.6 | Publish first-seen pins before Séance #56 | No publication before the #56 fix (F3d); first-seen pins are published from v1 (D15) |
| `02-FEATURES.md` X-04, §6 | `poltergeist://` declared on macOS only | Also Linux and Windows; absent on Android and iOS [V]; 02 X-04 now states this |
| `02-FEATURES.md` SAF-23 | `systemd-run --collect` followed with `journalctl -u` | Status record and log in an operation directory (7.17) |
| `02-FEATURES.md` SAF-12, X-05 | Backups next to the edited file | Central backup directories (8.11) |
| c4 §1.1 S8 | Manifest block at `scripts/release-manifest.txt:123-155` | The file has 54 lines; Poltergeist's block is at `:46-54` [V] |
