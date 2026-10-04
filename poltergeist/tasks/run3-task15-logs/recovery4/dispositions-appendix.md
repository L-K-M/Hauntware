

## Final recovery disposition (03f5819)

All feedback pages read through 03f5819, including edited summaries and outside-diff notes. Stabilization (>10 rounds): no optional cleanup push. Earlier records remain; these dispositions supersede conflicting claims.

### f38c97f review
- **Refute route blocker:** Flutter 3.47.2 [isActive](https://github.com/flutter/flutter/blob/d3b14c876900e553bc736ca19295fc09e3853e8e/packages/flutter/lib/src/widgets/navigator.dart#L640-L643) reads entry presence, NOT `_navigator != null`. `handlePop` sets `popping` (3357); `isPresent` excludes it (3524). Runtime: successful animated pop opens before disposal, with navigator nonnull/isActive false; veto/local history stay active; a covering route during the await leaves Connections active but not current. Keep both ownership guards. Replacing post-pop isActive with isCurrent would break the latter case.
- **Defer detach assert:** cancelRecovery's synchronous preconditions ensure detach claims one attempt before yielding; all counter mutations increase it. Replacement-bind regression passes; no present leak established.
- **Defer heldListing one-shot:** helper policy, not a current hang; completing its future releases waiters.
- **Decline pumpView rewrite:** this action requires a pushed route; mounting it as the root reintroduces the previously corrected non-poppable fixture.
- **Defer retry entries assertion:** this scenario intentionally returns an empty listing; existing listing-render/retry suites cover delivery. Additional seeded coverage is optional.
- **Defer duplicate-open assert and bounded-pump helper:** test-maintenance suggestions, no reproduced defect.
- **Defer core LIFO comment:** imported unchanged from #93; teardown order preserved.
- **Refute old-channel leak:** isolated runtime proof captures the fake's old channel AFTER the replacement consumes its slot, before releasing the held open. Old closes once, never lists; replacement stays open and refreshes. The suggested earlier seeding would script the wrong channel. Committing extra coverage is deferred.
- **Defer STATUS typo:** prose-only stabilization nit.
- **Unusable info entry:** malformed `reply`/JSON ends at “missing watch for”; no concrete finding can be inferred. Recorded review gap.

### 03f5819 review
- **Defer held-path recording:** valid extra fake coverage; this test pins toolbar transitions. The sibling refresh test asserts exact requested paths and sibling isolation.
- **Defer enablement-source comment:** future-maintenance note; current pane/workspace sources are observed and session command state still rebuilds the shell.

### Verified repair and gates
Readable captures exposed a real stale-toolbar defect. Three final runtime regressions failed on unchanged f38c97f shell, then passed with the toolbar-only listener repair. No route/core changes. App:551 tests; post-restart focused:92; isolated lifecycle/cleanup:5; analyze clean. Full logs/exits: `tasks/run3-task15-logs/recovery4/`; core/protocol evidence remains in recovery3 and final CI. Exact-head CI34773511916, review34773510966, secret34773511923 pass; five client builds pass. SSH/M0 jobs skipped by scope, not executed.

Five readable widget captures/provenance retained in recovery4/captures; font substitution is harness-only. Before captures include explicitly labeled premature/no-op states. Native/install QA remains open. Historical #78/#83 truncations and two cancelled integrations remain gaps. Subscription API unavailable; hourly trigger is torn down on merge. No M3 closure or release claim.
