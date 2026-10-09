# Task15 companion repair: merged, acceptance pending

PR: https://github.com/L-K-M/Poltergeist/pull/95
Head: 994a2c05bce9ea2ea2af6c37434fa5fdfb55040c
Merge: 57cabf7bc9e4d9c7906084d5a4cdc16954ae1eb4
Merged: 2026-09-13T19:30:22Z

Committed, pushed and merged. Supervisor alone accepts/counts task15. No new
task, M3 closure, release, successor or workspace archival.

## Repair

Status-only loss disables cached actions. Connected starts a retained-channel
listing, not premature recovery. Only accepted listing proof restores actions.
Failed healing/EOF retain one retryable loss banner and cache. Explicit Retry
awaits old-channel release before reopening; cancel, stale answers, same-id
replacement and healthy siblings preserve ownership. Banner space keeps the
first cached rows visible; loading/error overlays cannot stack beneath it.

Fourteen controller cases and widget regressions are committed. The two
supervisor tests failed on the unchanged foundation and pass unchanged now.
Runtime red evidence also covers stacked errors, covered rows, cancelled-first
listing home fallback and status-watch termination. Earlier harness mistakes
remain separately labeled, never counted as product red evidence.

## Final verification after restart

| Check | Result | Full log |
|---|---|---|
| Unchanged external supervisor | 2 pass | supervisor-after.log |
| Focused app/lifecycle suite | 90 pass | focused-final.log |
| Full app | 566 pass | app-final.log |
| App analysis | clean | analyze-final.log |
| Retained route/cleanup isolation | 5 pass | retained-lifecycle.log |
| Production-core lifetime tests | 59 pass | lifetime-production.log |
| Supplemental status/fake probes | 2 pass | surviving-status.log |
| Readable capture harness | pass | capture-final.log |

Every listed log has explicit exit0. verify.sh records app commands; full CI
and reviewer logs are retained as ci-complete.log/review-complete.log, with
separate successful-download exits and exact-run status metadata.

Exact-head CI34776539036, review34776537541 and secret34776538992 succeeded.
CI includes all five client builds and three native-host Dart suites. SSH/M0
jobs were scope-skipped. No skipped operation is counted as executed.

Seven post-restart PNGs are byte-identical to the inspected pre-restart
captures. Provenance and font substitutions: captures/PROVENANCE.md.
Prior recovery4 captures/provenance and all three toolbar reds were inspected;
its valid toolbar and route guards are preserved.

## Review

Read the complete edited summary and all paginated comments/reviews/threads,
including nested comments. Seven findings, three actual threads. All three
received dispositions and are resolved, reverified post-merge.

The failed->listing suggestion was declined, not blindly applied: production
EngineHost absorbs status errors and EngineClient never emits status addError.
Request failures complete futures; engine death closes watches. Permanent pane
failures leave the engine's rebind set; blocked/disconnected clear bindings.
Healthy-channel rebind therefore cannot establish failed-binding usability.

A synthetic surviving-error experiment did reproduce manual-Retry behavior
with a retained channel that independently answered a listing. A delayed
explicit replacement healed it, so it was not stranded. Automatic healing
from a future adapter's surviving stream errors remains deferred. This is a
production-path refutation, not a claim that synthetic auto-healing exists.

Missing-channel defensive fallback, scrim key, shared delay, prose changes and
fake-helper cleanup were declined/deferred under inherited stabilization.
Repeated controller close was verified idempotent; map removal creates a new
status stream, not a workaround for double-close teardown. The first probe's
stream-wrapper identity assertion was a harness error, retained separately.
Full details: dispositions.md, feedback-restart.md, threads-postmerge.json.
No optional source push followed review. PR body preserves its complete
historical prefix, now8081 characters; #84 history remains untouched.

## Preservation and teardown

Checkout remains poltergeist/m3-pane-reconnect-truth at994a2c0. Foundation
ref remains03f58198089c1020b54be3347df78d369ed14d95. Only tasks/ is untracked;
all source pushed. No core/backend/protocol or LaneB edits. Workspace and all
recovery artifacts retained. Stable STATUS IDs14/18/19 unchanged.

Heartbeat06703144 deleted; backing schedule absence verified in teardown.txt.
Its prior active-run scheduling collisions are recorded, not provider/task
failures. Subscription API was unavailable; no subscription was claimed.

The19:15:39 shutdown/19:16:05 new-container bootstrap interrupted the bounded
review watcher before it wrote an exit. It was not task/provider failure or
completion. Completed GitHub evidence and post-restart checks close that gap;
the raw partial watcher log remains unchanged. The earlier superseded c753712
review was cancelled before completion and does not count as a review round.

Native/install/real-SFTP QA remains unverified. Historical #84 truncated and
cancelled review evidence remains a disclosed gap. No broader closure claim.
