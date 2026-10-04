## Recovery audit, superseding earlier readiness claims

Head: `f38c97f` (main `36211a2` merged). #78 and #83 are CLOSED/unmerged predecessors, not separate completions. Their published summaries are GitHub-truncated; two historical 90-minute review cancellations remain gaps, not approval. Original dispositions remain above; corrections below supersede mistaken declines. The mixed-owner r17 test run is excluded.

### Complete edited review 34762960221 on a07601d

- **Apply, landing-path ownership:** a failed A reconnect followed by B listed A's `/srv/www`. Fresh runtime red before the bookmark guard; green afterward. Same-bookmark retry still preserves the intended path.
- **Refute, post-await clear:** actual HEAD calls synchronous `_issueNavigation`, not `await _navigate`. The new held-old-listing/newer-failed-bind/old-completion/retry test passes on unchanged a07601d and on recovery. It asserts actual `/new/path` navigation. No speculative guard added.
- **Apply, retry error assertion:** the recovered reconnect test now asserts `error == null`; it passes before and after the fix.
- **Refute, parent-watch degradation:** losing the parent loses proven rename detection, including rename/recreate. A metadata query on the recreated pathname does not restore that coverage. Keep #92 fail-closed parent/root teardown and #93 native/permission contracts; no core delta against merged main.
- **Defer, fake closeLane helper:** optional helper/API polish during stabilization.
- **Apply, STATUS references:** reconcile against main identities, not the proposed numbers. Linux overflow14, ancestor18, incident19 remain stable; pane location is20.
- **Refute, shutdown drain missing progress:** the complete loop takes fresh `_pendingCloses` batches, awaits them under `_DrainAbandoned`, removes the awaited batch including abandoned entries, and repeats for newly tracked releases. No hot-spin or early-ack defect established. Preserve #88/#90 regression suites.
- **Defer, shutdown timeout rename:** imported configuration/API polish, not this app PR.
- **Defer, lane import-cycle extraction:** Dart supports the cycle; no runtime defect. No speculative seam move.
- **Refute, missing `_DrainAbandoned` throw:** the drain's `onTimeout` throws it and distinguishes it from retirement errors. Comment-only clarification deferred.
- **Decline, delete supervisor close-timeout regression:** preserve independently requested proofs, including serving new opens while a release remains wedged.
- **Refute, supervisor shutdown/native-test concerns:** review itself found their parked-release and probe-cancel assertions correct. Tests remain unchanged and run in the core suite.
- **Refute, architecture overflow15 suggestion:** main's stable overflow ID is14. Architecture remains byte-identical to main.

### Additional required ownership audit

- **Apply:** red-first cancellation test showed an old `cancelRecovery` disconnecting a new bind for the same server. Guard the detached attempt after the await.
- **Apply, correcting old pop declines:** actual PopScope-veto and stale-callback/covering-route tests failed. Guard `route.isCurrent` before maybePop and require `!route.isActive` afterward. `maybePop == true` still is NOT evidence of a pop. Existing single/double-tap cases remain green.
- **Shared successor coverage:** `pane_session_lifetime_test` runs two pending connects through one production session/coordinator, FIFO trust prompts, independent channel release, sibling refresh after detach, exactly-once shutdown, and delayed listing completion across session replacement. Existing prompt-coordinator, trust, probe, keyboard, hidden-row, and diagnostic-localization suites remain. Demo deletion alone is not accepted as coverage.

### Verification and remaining gates

Local: app analyze + 548 tests; core analyze + 749 tests (16 platform/fixture skips); import scan; protocol scan + 51 protocol tests. All exit0. Full bounded output and explicit exits: `tasks/run3-task15-logs/recovery3/{app-analyze,app-tests,core-analyze,core-tests,imports,protocol,protocol-tests}.log[.exit]`. Red/green evidence: `controller-*`, `cancel-replacement-*`, `route-*`, `shared-session-*` in the same directory. The first shared-session harness stalled in real teardown awaiting a fake-zone future; corrected tests await/assert shutdown inside their widget zone.

All five inherited `tasks/run3-task15-captures/*.png` were inspected. They use Ahem glyphs and transparent backgrounds: geometry evidence only, not readable-text, native desktop, or install QA. Those QA gaps remain. No full-M3, native install, listing-I/O cancellation, watch wiring, or restored probe-driver claim.

Exact-head CI/native client gates and the new edited review remain pending. No merge-readiness claim until they complete. Hourly check-in `21cfcd39` remains armed; PR subscription tooling is unavailable.
