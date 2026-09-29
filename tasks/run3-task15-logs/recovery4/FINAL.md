# Task15 / PR84 complete

PR: https://github.com/L-K-M/Poltergeist/pull/84
Head: 03f58198089c1020b54be3347df78d369ed14d95
Merge: 6e8b6861231b758456e9d16b98cbe65bf917b33f
Merged: 2026-09-13T18:18:50Z

Checkout preserved: poltergeist/m3-panes-v1-foundation, HEAD unchanged at
03f5819. Intentional push ref: origin/poltergeist/m3-panes-v1. Only tasks/
is untracked; no unpushed code relative to that ref. No reset, stash, branch
switch, workspace archive, or next task. Supervisor owns task acceptance/count.

## Changes and proof

Inherited f38c97f binding/route fixes retained. Latest route blocker was false:
Flutter 3.47.2 framework d3b14c876900e553bc736ca19295fc09e3853e8e reads
entry presence in isActive (navigator.dart:640), sets popping in handlePop
(3357), excludes popping from isPresent (3524), and restores idle after
local-history refusal. maybePop rechecks the top entry after willPop (5582).

Isolated route_lifecycle_test.dart proves animated pop opens before disposal
(navigator nonnull, isActive false, reverse animation), veto refusal, local
history first-pop refusal/second-pop success, and a covering route appearing
inside the await. Pre-pop isCurrent and post-pop isActive stay unchanged.
cleanup_ownership_test.dart proves old channel close exactly once, no old
listing, replacement stays open/refreshable, and no server disconnect. The
fake consumes nextRemoteChannel after its held await; seed old AFTER the
replacement consumes its own slot. No false leak inferred from wrong seeding.

Readable captures exposed stale toolbar enablement. Committed only:
- app/poltergeist_app/lib/ui/workspace_shell.dart: toolbar-only observation
  of workspace/pane state, not root/listing rebuilds.
- app/poltergeist_app/test/ui/panes/workspace_panes_test.dart: three runtime
  regressions for post-bind Refresh, cursor/focus Open, pending Parent.
- docs/STATUS.md: evidence and remaining QA.

Final three tests failed against byte-identical f38c97f shell in
`toolbar-final-baseline-red.log` (exit1), then passed in
`toolbar-final-green.log` (11 tests, exit0). An earlier cursor tap assertion
ran before double-tap arbitration completed; final proof uses keyboard
selection. That harness failure is not accepted as product red evidence.
No core/backend/protocol change. Packages matched pre-merge main36211a2
byte-for-byte; #88/#90 lifetimes and #92/#93 watch behavior retained.
Stable STATUS IDs14/18/19 unchanged. LaneB/workspace untouched.

## Gates

All commands use installed /home/paseo/opt/flutter/bin, bounded timeouts,
kill-after, full stdout/stderr logs and explicit .log.exit files.

Recovery4 verify.sh, rerun after daemon restart on exact committed head:
- `flutter test --reporter expanded <route_lifecycle_test.dart> <cleanup_ownership_test.dart>`:
  lifecycle.log, exit0, 5 tests.
- `flutter test --reporter expanded test/services/pane_cancel_regressions_test.dart test/services/pane_controller_test.dart test/ui/connections/open_inpane_pop_test.dart test/ui/connections/connections_view_test.dart test/ui/panes/pane_session_lifetime_test.dart test/ui/panes/pane_view_test.dart test/ui/panes/workspace_panes_test.dart`:
  focused.log, exit0, 92 tests.
- `flutter analyze`: app-analyze.log, exit0, no issues.
- `flutter test --reporter expanded` (app cwd, same final source):
  app-tests.log, exit0, 551 tests. Reused after restart, not rerun needlessly.
- Readable isolated harness: capture-final.log, exit0. Command/provenance
  in captures/PROVENANCE.md; final PNG/font/harness hashes retained.

Recovery3 verify.sh/logs remain: app548 historical; core analyze749 tests
with16 platform/fixture skips; imports; protocol scan and51 guard tests, all
final logs exit0. Complete dedicated red/green logs were read. route-green.log
is actually exit1 (old root-route fixture); route-final.log is the passing
successor. Shared-session initial124 timeouts were fake-zone teardown harness
failures, not runtime regression red. The mixed-owner r17 run remains excluded.
log-audit.json scans complete retained logs/exits with hashes and failure
markers; named dedicated failures were inspected, not inferred from filenames.

Exact-head GitHub runs, all completed/success:
- CI34773511916: Dart tooling/packages/pin audit, app analyze/tests, all five
  client builds (Android/Linux/macOS/iOS/Windows).
- Review34773510966.
- Secret34773511923.
SSH integration/M0 measurement/evidence jobs skipped by scope, not executed.
Full job/step metadata: ci-final.json, review-run-final.json, secret-run-final.json.

## Review

Full f38 and03f edited summaries read, matched supervisor snapshots. Actual
paginated issue comments, inline comments, reviews and nested thread comments
fetched. All historical comments unchanged relative to recovery3; all new
feedback inspected. No human reviewer request. All95 actual threads resolved,
verified after individual dispositions and again after merge in
threads-postmerge.json. Last two summaries retained, not replaced by counts.

Body history preserved verbatim (61837-character prefix), appendix now65414
characters. Exact URL/head/body saved before each mutation. A local comparison
used the wrong snapshot filename once; corrected comparison proves both the
pre-edit body and final historical prefix exact. No history was overwritten.

Dispositions: route blocker refuted; old-channel leak refuted by runtime proof;
root-only pumpView rewrite declined because the action requires a pushed route.
Detach assert, heldListing policy, retry extra entries assertion, duplicate-open
assert, pump helper, imported #93 LIFO comment and typo deferred. Latest held-path
fake recording and enablement-source comment deferred under >10-round
stabilization. Only demonstrated toolbar defect generated the03f push.

Malformed reply/JSON “missing watch for” cannot establish a concrete finding:
explicit gap. #78/#83 remain closed/unmerged predecessors; their truncated
summaries and two historical90-minute cancelled integrations remain gaps,
not approvals or separate task completions. Detailed appendix and refutation
comment retained locally and on PR84.

## UI and teardown

All five inherited Ahem/transparent geometry PNGs inspected. Five final
readable full-shell widget PNGs inspected: local/connecting/connected/lost/error.
Harness uses fake lanes, installed Roboto/MaterialIcons, Roboto Mono aliased
as JetBrains Mono; no product font feature or toolchain installation.
Before-toolbar captures include mislabeled premature/no-op states, explicitly
corrected in provenance. No native window, install, real-SFTP, full-M3 or
release claim. Native/install QA remains open; other M3 follow-ups stay in STATUS.

Hourly heartbeatadfa2d5c deleted; backing schedule file absent, confirmed.
Before deletion its18:00 delivery attempts failed because this agent was already
running; persisted nextRunAt was21:00 despite hourly cron. No successful check-in
delivery claimed. PR subscription API unavailable throughout; no subscription
was created or falsely reported removed. No unrelated trigger changed.

Daemon restart18:05 was infrastructure interruption; initiator unknown, not
provider/task failure. Same worker resumed, sole ownership rechecked. Persistent
SDK/artifacts survived. Workspace/tasks preserved for supervisor acceptance.
