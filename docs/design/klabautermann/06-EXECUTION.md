# Klabautermann execution notes

Status: implementation started on 2026-10-13. These notes record how the
plan is executed (approvals, environment, PR order, manual gates,
releases); on those points they win over 03 and 04. Design and owner
decisions stay in 03 and 04.

## Approvals

On 2026-10-13 the owner asked to review this plan and implement it fully.
That instruction approves the gates the plan reserves for the owner:

- the extraction design docs of D3 and the S9 catalog design doc; each
  doc's status line names this approval;
- the Rust toolchain policy of open item 1, when S10 proposes it.

Open items 2 to 9 of 04, section 15 are settled when their milestone
starts, following the plan's recommendation, and recorded below. Open
item 6: pin publication starts at v1, behind the enrollment assertion;
the Séance release it names is the first suite release after the #56 fix
(F3d) merges, which the owner cuts as a separate task (see Releases).

The M3 plan's one owner question, Q1, is settled the same way, by its
recommendation: a corpus recorded in CI from rootful daemons meets exit
E1. D01 recorded Docker 20.10.24, 25.0.5, 29.0.4 and 29.7.2 and Podman
5.8.7's compat service (03, 11.1). Rootless Docker, rootless Podman and
Docker on real hosts stay on the manual checklist, under the real-hosts
gate below.

## Environment

Implementation runs on Linux without Docker or a C compiler. Docker,
privileged DinD, the runner VM systemd leg (03, 11.3), macOS, Windows,
iOS and Android run only in CI.

Spikes run as the first PRs of the milestone that needs them and commit
their evidence (recorded fixtures, strategy tables, budget numbers) with
those PRs. Distributions and shells that CI cannot provide stay on the
manual VM checklist (03, 11.3).

## Pull requests and shared files

Each F step and milestone lands as a series of focused PRs in the order
of 04, section 13 (F1a before F1b; F3 move, then one PR per divergence
resolution, then F3d; M1 registration before the scaffold's CI legs).
Pure product packages (`klabautermann_host`, `klabautermann_docker`) are
built against fakes in parallel with the F steps, as 04 section 13
allows. Root files that every track edits (`scripts/test.sh`,
`.github/workflows/ci.yml`, `.github/workflows/release.yml`,
`scripts/release-manifest.txt`, `tool/release_version/`,
`tool/guards.yaml`, `poltergeist/docs/PORTS.md`, root `README.md`,
`AGENTS.md` and `CHANGELOG.md`) change in one open PR at a time; a
parallel PR that needs them rebases after the earlier one merges.
Changes under `seance/` merge one at a time with merge commits, because
Poltergeist's pin audit records each lineage change.

New fixture base images publish through `fixture-images.yml` under its
existing public package with their own digest; a new GHCR package starts
private, and only the owner can make it public.

## Manual sign-off gates

The milestone's PRs merge on their automated exits; these gates stay open
until a person with the hardware signs them off (04, section 13).

| Gate | Milestone | Status |
|---|---|---|
| macOS keychain check after the keystore switch | F3 | open |
| Engine budgets on a low-end Android phone and an older iPhone | S5 | open |
| Real hosts on systemd 239 and 245, Alpine and a BusyBox NAS | M2 to M4 | open |
| Docker on real hosts: rootful and rootless Docker, rootless Podman, Snap Docker, the socat relay | M3 to M4 | open |
| Manual checklist on one phone per OS and three real hosts | M4 | open |
| 24 h soak against ten hosts (03 §11.4) | M4 | open |
| Privileged file writes under SELinux on RHEL 9 (labels kept, `restorecon`) | M5 | open |
| Link intake on real devices: Séance and Poltergeist hand-offs on each phone and desktop OS | M5 | open |
| The container terminal on an Android phone and an iPhone | M5 | open |
| Manual checklist on every platform; owner sign-off | M7 | open |

M4's checklist suggests Debian 12, Ubuntu 26.04 (sudo-rs) and RHEL 9 or
a BusyBox NAS as the three hosts; who provides the phones and hosts, and
runs the soak, is the owner's call (M4 plan Q6). STATUS lists what each
gate exercises.

## Releases

No release is cut as part of this work. No release workflow leg builds
Klabautermann clients before M4: the `client_klabautermann` job, its
manifest entries and workflow contracts land there (04, decision 16).
M4 and M7 end with a release dry run; cutting a suite release stays a
separate explicit task.
