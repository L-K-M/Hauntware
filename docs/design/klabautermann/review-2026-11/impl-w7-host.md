# impl-w7-host: Klabautermann host fixes (plan rows 2.3, 2.8, host lows, QA-02)

Two ready PRs, not subscribed, not merged.

- PR #807 `klab/host-fixes`, head 01cc3ec78 (commits 7f2b64f08, 082abc355, merge of main 01cc3ec78): OPS-1, OPS-6, HST-1, HST-2, HST-3, HST-4, HST-5, HST-8, QA-02.
- PR #812 `klab/host-fixes-2`, head 4836f38e5 (commit d9b2e3d2d, merge of main): HST-6, HST-7, HST-9 (part), HST-10, HST-11, OPS-8, OPS-9.

All findings were re-read on current main and still held.

## Per finding

| Item | Status | Where | Test, red -> green |
|---|---|---|---|
| OPS-1 | FIXED 7f2b64f08 | `commands/edit.dart` `_kCopyAttributesScript`, new `EditExit.ownerNotCarried` = 107 | `edit_shell_test` 4 new cases per shell (stand-in stat/chown, and a real drop to nobody with setpriv as root), `edit_test`. Old lib: 12 shell failures + 1; green under dash, bash, mksh, BusyBox ash |
| OPS-6 | FIXED 7f2b64f08 | `parse/ops.dart` header lines read as UTF-8 | `ops_test` "a directory with non-ASCII characters reads as UTF-8": red, green. No core change needed |
| HST-1 | FIXED 7f2b64f08 | `hws/program.dart` `hw_dfst` + `c_fs`; `parse/fs.dart` `FsSnapshot.errors` | `fs_test`, `partial_sources_shell_test` (fs cases). Old lib: section `error`/`denied`; green in 4 shells |
| HST-5 | FIXED 7f2b64f08 | `parse/fs.dart` right-anchored row regexes | `fs_test` "a source with a space". Red only as a compile failure of the file (it also uses the new field); the reviewer's run stands for the old behaviour |
| HST-2 | FIXED 7f2b64f08 | `parse/procs.dart` `_parseCmdline` | `procs_test` 3 new cases: red (5 other rows null), green |
| HST-3 | FIXED 7f2b64f08 | `hws/collector.dart` `_unitNamePattern` | `request_test`: red, green |
| HST-4 | FIXED 7f2b64f08 (engine side) | `c_cron` `unreadable` block, `CronSnapshot.unreadableSources` | `cron_test`, `partial_sources_shell_test` (cron cases, run as nobody via setpriv here). Old lib: `denied`; green |
| HST-8 | FIXED 7f2b64f08 | `parse/cron.dart` `_crontabMeta` | `cron_test` BusyBox case; message checked against BusyBox 1.36.1 here |
| QA-02 | FIXED 7f2b64f08 | `shell_sampler_test.dart` | `error` allowed for units/timers only when `/run/systemd/system` is absent. Was 2 failures here, now 0 |
| HST-6 | FIXED d9b2e3d2d (aggregate); per-core part DECLINED | `rates/rates.dart` | `rates_test`: red, green. Per-core: the idle sum holds iowait, clamping would read 100 % busy; gap kept and documented |
| HST-7 | FIXED d9b2e3d2d | `parse/timers.dart`: 0 -> null, JSON `leftUs`/`passedUs` null | `timers_test` new + 1 updated: red, green. Hand-written JSON payloads not replaced (parser no longer reads the fields they got wrong) |
| HST-9 | FIXED d9b2e3d2d for oom and ports; meminfo DEFERRED | `parse/oom.dart`, `parse/ports.dart` | `robustness_test` group: 2 red, green. Meminfo: `klabautermann_core/test/sampling/sample_pipeline_test.dart:504` uses that throw to test the pipeline's catch; fixing it needs a test seam in `lib/src/sampling` (not mine) |
| HST-10 | FIXED d9b2e3d2d | `rules/threshold.dart` `hasInvertedBand`, `fromJson` | `threshold_test`: red, green |
| HST-11 | FIXED d9b2e3d2d | `parse/boots.dart` `kernelFlavour` | `boots_test` 3 new: red (load), green |
| OPS-8 | FIXED d9b2e3d2d | core `operations/edit_reader.dart` (`kIndexReadMaxBytes`), `plans/backup_plans.dart`, `plans/edit_plan.dart`; test support `edit_host.dart` records caps | `footprint_test`, `edit_plan_test`: red (load), green. Root reads stay at 256 KiB (seance_core's executor has no cap parameter) and are refused with the reason above it. Hashing on the host not done |
| OPS-9 | FIXED d9b2e3d2d | `commands/commands.dart` `RunAsTool.installed` + `_kRunAsScript` | `document_test`, new `run_as_shell_test` (stand-ins and real runuser, su, BusyBox su as root, 4 shells), `host_plans_test` 2 assertions updated: red, green |

## Core changes outside klabautermann_host

- OPS-8: `lib/src/operations/edit_reader.dart`, `plans/backup_plans.dart`, `plans/edit_plan.dart`; tests `footprint_test.dart`, `edit_plan_test.dart`, `test/support/edit_host.dart` (+`outputCaps`).
- OPS-9: `test/operations/host_plans_test.dart` only.
- HST-1 needed no core change: `FsSnapshot` crosses the protocol as it is. No protocol.dart edit, no version bump; protocol guard exit 0.

## Fixture goldens regenerated

- #807: `rhel-8/procs.golden.json` only. Its hand-written payload has headers in numeric order (1, 2, 900, 1000), which no host prints; the new rule marks all four command lines (2 forged, was 1). Payload untouched. Worth fixing the payload order in a follow-up.
- #812: `timers.golden.json` and `timer_jobs.golden.json` of debian-12, debian-12-lxc, debian-12-lxc-lxcfs, ubuntu-2404, ubuntu-2404-runner-dash (`leftUs`/`passedUs` null, `lastUs` 0 -> null).
- Collector set version 14 -> 15 (#807).

## Deferred to other owners

- App: show `FsSnapshot.errors` (disk panel) and `CronSnapshot.unreadableSources` (jobs panel; with only closed directories it can still say "no jobs").
- Core `edit_plan.dart` + protocol + app: map exit 107 to a typed "needs admin mode to keep the group" refusal. Today it is a failed step with chown's stderr; the target is untouched.
- HST-9 meminfo (see above).
- `docs/design/klabautermann/03-ARCHITECTURE.md` §7.2 describes the old cmdline header rule.
- HST-12, HST-13 were not in the brief.

## Checks

- #807: analyze --fatal-infos host+core clean; host+core suites 3574 passed, 37 skipped, 0 failed before merging main; host suite after the merge 1577 passed, 17 skipped, 0 failed (core not rerun, merge was Docker only); protocol guard exit 0; format clean.
- #812: analyze clean (also after the merge); host+core suites before the merge 3589 passed, 46 skipped, 2 failed = the known shell_sampler slow-program cases, fixed in #807.
- One unrelated flake seen once under load: `link_connector_test` "an encrypted key ... is not kept past its attempt" (passed alone).
- Not verified: real dead mount, hardened host, Alpine host, zsh.

## Noticed

- During the run someone installed mksh and a BusyBox that runs its applets before PATH. A PATH stand-in for `df` or `su` is then ignored under its ash; my tests name the stand-in by path or skip with a reason. Other shell tests that shim BusyBox applets may be affected.
- HST-2 trade-off: an order conflict blanks both sides (forger, named pid, exposing header), at most three command lines per forged header.
- CHANGELOG: #807 conflicted with #805 at the end of the list (resolved by merge); #812 inserts three entries higher and merged cleanly.

## STATUS sentences

- The filesystem list survives a mount `df` cannot read; the engine reports the failed mounts (`FsSnapshot.errors`), the panel does not show them yet.
- The cron reading names system sources the login user may not read (`CronSnapshot.unreadableSources`); the Jobs panel does not show them yet.
- An edit that cannot keep a file's owner and group is refused (exit 107); the typed admin-mode wording is open.
- Run now as another user falls back to `su` on hosts without `runuser`; not yet checked on a real Alpine host.
- Root's backup index is readable up to 256 KiB; above that Keep last and Remove backups refuse with the reason.
