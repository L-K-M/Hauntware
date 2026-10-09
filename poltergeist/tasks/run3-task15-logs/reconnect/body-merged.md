## Scope

Task15 post-merge repair, companion to merged #84 (`6e8b686`). Not another credited task or M3 closure. Preserve #84's route guards, toolbar repair, review history and explicit gaps.

02 UX §2.7 requires cached rows to stay disabled until a listing arrives over the healed connection. Independent supervisor tests proved #84 left verbs enabled on status-only loss and cleared the banner on `connected` alone.

## Repair

- Latch loss, invalidate old generations, preserve cache, disable pane commands/Refresh.
- Re-list the retained channel after connected. Production `reconnect.dart` rebinds healthy `PaneChannel`s before publishing that status; a failed binding can still expose a permanent error. Only an accepted healed listing removes the banner.
- Failed healing exposes localized Retry. Reopen awaits the old channel's release, retains cached rows, and respects attempt/channel ownership. Cancel/detach invalidate healing and cannot disconnect a newer same-id bind or a healthy sibling.
- Loss owns one dim layer, not loading/error overlays. Reserve banner space so the cached first rows remain visible. `canRetryRecovery` exposes only Retry availability to its view; recovery/binding modes stay private.

No core/backend/protocol, dependency/pin, port, or unrelated layout/font change. Stable STATUS IDs14/18/19 retained. PORTS unchanged: no source port.

## Evidence

Persistent artifacts: `tasks/run3-task15-logs/reconnect/`.
- `baseline-red.log`: both portable supervisor regressions fail at runtime on unchanged main; `supervisor-after.log`: the unchanged external supervisor file passes (2 tests).
- `pane_reconnect_test.dart`:13 cases cover status-only/failed/delayed healing, old answers, retry/release waits, cancellation, same-id replacement, sibling isolation, cancelled-first-listing recovery.
- Widget tests cover real session/toolbar enablement, single loss dim and first-row visibility. `overlay-red.log` and `cached-row-red.log` are runtime failures; final widget proof passes.
- Full app565 tests, focused89 tests, analyze clean. Commands, full bounded output and explicit exits retained; `verify.sh` reproduces final checks. Core remains unchanged; exact-head CI validates its gates.
- Seven fresh readable widget captures inspected under `captures/`. Installed Roboto/MaterialIcons and a monospace substitute load only in the isolated harness. Native/install QA remains unverified. No real-SFTP/native or release claim.

Earlier harness corrections (frame settlement and an explicit replacement landing path) are not product red evidence. Full-suite localization failure was a missing reviewed technical-string allowlist, now repaired.

## Review policy

Stabilization carries from #84 (>10 rounds): fix confirmed defects, not optional nits. No claim from green job/count alone; inspect complete edited summaries and paginated feedback, disposition each thread. Exact-head CI/review pending at opening. Hourly check-in armed; PR subscription API unavailable. Supervisor independently accepts task15 after this companion; no next task starts here.


## Corrective audit: status-watch termination

Opening counts above belong to `c753712`. A further runtime audit proved EOF/error still dismissed unhealed loss through `_endRecoveryWatch`. Three runtime failures in `watch-red.log` establish this as a correctness repair, not stabilization cleanup.

`994a2c0` keeps a retryable loss after watch failure/EOF while clearing stale status. Existing tests were corrected from “clear banner” to “clear status, retain loss, offer Retry”; a new delayed-listing test proves a dead watch cannot accept its old answer, while a valid explicit replacement does heal. No indefinite reconnect label.

Final local proof: unchanged supervisor file2 tests, focused90, full app566, analysis clean, capture harness pass. Fourteen recovery controller cases. Original c753712 logs retained in `c753712/`. The first review revision was superseded during execution by this demonstrated defect repair; it is not a completed review round or approval. Latest-head gates and complete feedback remain required.


## Final review disposition at 994a2c0

Read the full edited summary, all actual comments/reviews and fully paginated threads/nested comments. Seven findings, three posted threads; the summary's “3 actionable” count is not the review scope. No confirmed production blocker. Stabilization continues from #84; no optional source push.

1. **Connected from failed: decline blanket relaxation.** The synthetic surviving-error premise is reproducible with a still-usable channel: connected updates status, but Retry remains required. It is not a production status path. `engine_host.dart:531-550` forwards manager values and explicitly absorbs status errors; manager streams do not error today. `engine_client.dart:173-188,318-321` only publishes status data. Request errors complete futures (`:357-367`); isolate errors terminate/close watches (`:348-354,418-426`), not error then resume them. For real failed bindings, `reconnect.dart:340-399` rebinds healthy views but removes a permanently failed view from the rebind set; `_PaneChannelView.fs` retains that failure. Pool blocked/disconnected also clear bindings (`connection_manager.dart:1251,1686`). Thus “healthy channels rebind” does not prove a failed channel is reusable. Explicit Retry intentionally reopens, then requires a fresh listing. The synthetic case is not stranded: an independently successful retained-channel read and delayed explicit replacement both pass in `surviving-status.log`. Automatic recovery after errors from a future status adapter is deferred, not silently claimed implemented.
2. **Missing-channel else: decline speculative hardening.** A null channel during connected is legitimate while its open awaits; the completion handles the listing. The stale-attempt return and channel assignment have no intervening await. No present path was established with waiting plus no binding/open; a future-refactor premise does not justify a stabilization push.
3. **Scrim key: defer maintenance.** Current rendering already uses `withValues(alpha: 0.6)` and the controlled widget regression was observed red with stacked overlays, then green. A new key is optional test maintenance, not a demonstrated float failure.
4. **200ms constant: defer maintenance.** It steps beyond the current150ms grace. Held listings are completer-controlled; advancing the clock cannot resolve them as claimed. Sharing a delay may help a future timing change, but no present failure exists.
5. **STATUS blank line: defer prose nit.**
6. **STATUS attribution wording: defer prose nit.** Runtime reds exposed the assumption; the implementation repaired it. No audit claim that tests edited production code is intended.
7. **Fake map helper: defer; reject teardown rationale.** Repeated controller close is idempotent. Removal obtains a new open status controller on Retry rather than reusing EOF; it is not needed to avoid teardown closing twice. Both facts pass in `surviving-status.log`. The first probe incorrectly compared stream-wrapper identity; that harness failure is retained separately, not product red evidence.

Post-restart source proof: unchanged supervisor2, focused90, app566, analysis clean, retained lifecycle5, production-core lifetime59, supplemental status/fake probes2. All full bounded logs have explicit exit0. Seven freshly regenerated PNGs are byte-identical to the inspected pre-restart captures. Native/install/real-SFTP QA remains unverified.

Exact-head CI34776539036, review34776537541, secret34776538992 passed. CI includes five client builds and three native-host Dart suites. SSH integration/M0 jobs were scope-skipped, not run. The earlier bounded review watcher lost its process at the proven daemon/container restart; its missing exit is not a provider failure. Completed GitHub run metadata and full published feedback supply the final evidence.

This companion repairs task15 only. Supervisor acceptance/counting remains separate; no M3/release closure or successor launch.
