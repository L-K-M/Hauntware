# PR84 recovery: waiting for exact-head gates

Head: f38c97f6f9287d41f2b4fa0b5256ecbc85d0e28c.
PR: https://github.com/L-K-M/Poltergeist/pull/84, OPEN.
Checkout: poltergeist/m3-panes-v1-foundation.
Intentional push: origin/poltergeist/m3-panes-v1.
Main36211a272cf5ce9afdc92b2c6a0a52392492f03c safely merged, no reset/abort/stash/checkout.
Only tasks/ remains untracked. All source committed/pushed. Not merged.

Pending exact-head runs:
- CI34769894697 (includes native/client gates).
- Review34769893885.
- Secret34769894720 already successful.

Next: inspect completed run results and full edited review on f38c97f; fetch
paginated threads again. Stabilization applies (>10 rounds): no optional
cleanup pushes. Address only verified important defects/human requests. Merge
without asking once exact-head gates and review permit; save URL/head/body
before PR mutation and use --repo L-K-M/Poltergeist and body-file. Retain all
body history/dispositions; current body is61837 characters, so final additions
must stay below GitHub's65536 limit. Do not start another slice or branch.

Recovery fixes, observed runtime red before repair:
1. Failed A bind landing leaked into B (/srv/www instead of B home).
2. cancelRecovery after detach could disconnect a replacement same-id bind.
3. Open-in-pane callback opened after a pop veto or popped a covering route.
Route ownership checks use isCurrent before maybePop/isActive after, not its
boolean. Prior descriptions declining veto concerns are superseded explicitly.

The requested parked-old-listing/newer-failed-bind/old-completion/retry proof
PASSES on unchanged a07601d: actual source issues navigation synchronously,
not await _navigate. Refuted that review premise with actual /new/path calls;
no speculative clear guard. Successful-retry stale-error assertion also passed.

Added pane_session_lifetime_test: two pending pane connects share production
session/coordinator, FIFO trust prompts, independent release and sibling refresh,
exactly-once shutdown; delayed old listing after session replacement cannot
repaint either new pane. Early harness runs hung awaiting a fake-zone completed
future in real teardown; diagnosed with stage logs, corrected harness awaits
and asserts releases within each widget test. No production shutdown change.

Final local code verification (before commit, identical source):
- app-analyze.log:0; app-tests.log:0,548 tests.
- core-analyze.log:0; core-tests.log:0,749 tests/16 skips.
- imports.log:0; protocol.log:0; protocol-tests.log:0,51 tests.
Commands in verify.sh; full bounded logs and explicit .log.exit retained here.
Core is byte-identical to origin/main, including #92/#93 watch behavior and
#88/#90 regression suites. No LaneB file edits; stable STATUS IDs14/18/19.
The first full-app recovery run caught the then-red cancellation test; final
rerun overwrote that broad log. Dedicated cancel-replacement-red.log retains
its complete failure. Mixed-owner r17 logs are NOT accepted evidence.

Review:
- Complete latest summary on a07601d matched archived pr84-summary-1620 exactly.
- All90 actual PR84 threads and nested comments fetched with pagination; zero
  remaining pages. Read every thread, record each disposition in PR body and
  thread-dispositions.md/.json, then resolve. threads-after.json proves90/0open.
- PR78/83 CLOSED/unmerged at581b988; predecessor bodies/comments/reviews/inline
  saved. Existing full dispositions retained in PR84 body. Their GitHub-truncated
  published summaries and two historical90min cancellations remain gaps, not
  approval. No attempt to reload old provider echo/context tail.
- Parent-watch silent degradation refuted: loss of parent loses rename/recreate
  coverage; metadata cannot restore identity. Shutdown loop reviewed through its
  full batch-await/remove/fixed-point body. Imported timeout/API/test deletion
  nits declined/deferred; core unchanged.

UI: visually inspected all5 inherited tasks/run3-task15-captures/*.png.
They are Ahem/transparent-background widget geometry captures, not readable-text
or native QA. Readable-font/native desktop/install QA remains unverified.
No full-M3, listing I/O cancellation, watch wiring or probe-driver claim.

Heartbeat21cfcd39 remains active for this worker4382e6fc. PR subscription
API unavailable. Keep heartbeat while waiting; delete at final teardown.
Old555a7421 was re-archived by supervisor; do not revive it. Sole ownership
confirmed by supervisor before resuming; captured unexpected patches compared
identical before editing. All workspace/task contents preserved.
