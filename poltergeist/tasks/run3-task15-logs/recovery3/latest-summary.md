## GLM 5.3 Code Review

> [!NOTE]
> Review scope: **hybrid**, changes from `4bcde93` to `a07601d` (20 file(s))
> plus 2 rotating unchanged PR section(s).

**Actionable suggestions identified: 3**

> [!NOTE]
> Inline suggestions are posted on a best-effort basis; GitHub may reject invalid or outdated diff anchors.

<details>
<summary>🟠 Major comments (2)</summary><blockquote>

**app/poltergeist_app/lib/services/pane_controller.dart:173 - Stale `_pendingRemotePath` leaks into a different bookmark's first navigation**
**Problem:** `_pendingRemotePath` is only cleared on successful navigation, `unbind()`, or `openLocalHome()`. If a bind carrying an `initialPath` fails before navigating (e.g., server down), the remembered path survives. When the user then selects a *different* bookmark — `connectRemote(bookmarkB)` with `initialPath == null` — the line `_pendingRemotePath = initialPath ?? _pendingRemotePath` keeps bookmark A's remembered path, and the success handler resolves `remotePath = initialPath ?? _pendingRemotePath ?? bookmark.remotePath` to A's stale path on B's server.
**Impact:** After a failed reconnect to server A, connecting to server B lands the pane in A's remembered directory (or a spurious "not found" error if it doesn't exist on B). The "return the user where they were" contract only holds per-bookmark, but the memory is keyed to nothing.
**Suggested fix:**
```diff
     if (_disposed || _lanes == null) return;
+    if (bookmark.id != _pendingRemote?.id) _pendingRemotePath = null;
     _pendingRemote = bookmark;
     _pendingRemotePath = initialPath ?? _pendingRemotePath;
```
```
[[suggestion:path:app/poltergeist_app/lib/services/pane_controller.dart:173:Clear stale pending path when switching bookmarks:    if (bookmark.id != _pendingRemote?.id) _pendingRemotePath = null;
    _pendingRemote = bookmark;
    _pendingRemotePath = initialPath ?? _pendingRemotePath;]]
```
**Prompt for AI Agents:**
```
In app/poltergeist_app/lib/services/pane_controller.dart, examine connectRemote. Trace: connectRemote(bookmarkA, initialPath: 'X') fails before the success handler's _pendingRemotePath = null (path retained per the new doc comment); the user then calls connectRemote(bookmarkB) with initialPath null. Confirm the success handler resolves remotePath to 'X' on server B. Fix by clearing _pendingRemotePath when bookmark.id differs from _pendingRemote?.id, placed BEFORE _pendingRemote is reassigned (otherwise the comparison always sees the new bookmark). Add a regression test: failed bind with initialPath, then connect a different bookmark, assert landing path is the new bookmark's remotePath/home, not the stale one.
```

**packages/poltergeist_core/lib/src/engine/local_watch_backend.dart:70 - Parent-watch failure fatally kills a healthy root watch**
**Problem:** `_start` wires the auxiliary parent subscription's `onError` to `_fail` and `onDone` to `_closed`. The parent stream can fail for reasons that say nothing about the watched directory: `ReadDirectoryChangesW` buffer overflow caused by sibling churn in a busy parent (the class docs in `local_directory_watcher.dart` explicitly note overflow surfaces as a stream error), a parent that is unreadable or list-denied while the target itself is watchable, or a transient error on a UNC parent. Any of these flows through `_fail` → `_finish`, emitting an error on `_events` and tearing down the still-healthy root subscription and probe.
**Impact:** This is a functional regression relative to the previous `DartIoWatchBackend` default: on Windows, watch installs that used to succeed (or keep running) now fail or die mid-stream purely because of activity in the *parent* directory — e.g., watching a project under a busy home or temp directory. Since real root loss is independently detectable via the metadata probe and root events, the fatal parent path adds spurious failures without adding detection power. Note that parent deletion itself is still handled under the degraded path: the probe will fail on the now-gone root and emit loss.
**Suggested fix:**
```diff
         _parentSubscription = events.listen(
           _onParentEvent,
-          onError: _fail,
-          onDone: _closed,
+          // A dead parent watch (overflow, unreadable parent) must not
+          // kill a healthy root watch: drop it and fall back to root
+          // events plus probes, which still detect actual root loss.
+          onError: (Object error, StackTrace stack) => _requestProbe(),
+          onDone: () {
+            _parentSubscription = null;
+            _requestProbe();
+          },
         );
```
Degraded mode loses rename-away detection (an idle renamed directory produces no root events), so a follow-up could re-establish the parent watch once, but the immediate change stops unrelated parent churn from destroying an otherwise healthy watch. The root subscription's `onError`/`onDone` should stay fatal.
**Prompt for AI Agents:**
```
In packages/poltergeist_core/lib/src/engine/local_watch_backend.dart, _WindowsWatch._start subscribes to Directory(_parent).watch() with onError: _fail and onDone: _closed, so any parent-watch failure (buffer overflow, permission-denied parent, transient UNC error) emits an error on _events and tears down the healthy root watch via _fail/_finish. Confirm by tracing _fail -> _finish -> _stop. Change only the parent subscription so its onError/onDone degrade instead: null out _parentSubscription and call _requestProbe(), letting the metadata probe report genuine root loss while unrelated parent failures no longer fail the watch. Keep the root subscription fatal. Add a test that pushes an error or done on the parent stream while the root stream stays healthy and asserts root events keep flowing (or loss is only reported when the probe actually finds the root missing).
```
[[suggestion:path:packages/poltergeist_core/lib/src/engine/local_watch_backend.dart:line:70:Parent-watch errors should not kill the root watch:onError: (Object error, StackTrace stack) => _requestProbe(),
          onDone: () {
            _parentSubscription = null;
            _requestProbe();
          },]]

</blockquote></details>

<details>
<summary>🟡 Minor comments (9)</summary><blockquote>

**app/poltergeist_app/lib/services/pane_controller.dart:235 - Unguarded clear of `_pendingRemotePath` can race a newer bind**
**Problem:** The clear after `await _navigate` has no `attempt == _bindAttempt` staleness guard, unlike the `onError`/`onDone` handlers added in the same block. If a second `connectRemote` starts while the first navigation is still being awaited (e.g., a reconnect watchdog or user re-selection) and sets a new `_pendingRemotePath`, the older callback's unguarded clear wipes the newer bind's pending path.
**Impact:** The newer bind loses its intended landing directory, and its retry falls back to the bookmark root — the exact symptom this change set is meant to prevent. The window is narrow, but the file already guards its other callbacks against precisely this cross-bind race.
**Suggested fix:**
```diff
-        // The landing directory is consumed by the bind that used it.
-        _pendingRemotePath = null;
+        // The landing directory is consumed by the bind that used it —
+        // and only that bind: a newer one may have set its own.
+        if (attempt == _bindAttempt) _pendingRemotePath = null;
```
**Prompt for AI Agents:**
```
In app/poltergeist_app/lib/services/pane_controller.dart, locate the _bind success callback in connectRemote that executes `_pendingRemotePath = null;` after `await _navigate(...)`. Confirm whether `attempt`/`_bindAttempt` (referenced by the neighboring onError/onDone closures) are in scope at that point, and whether _bind bumps _bindAttempt when re-entered while the first navigation is awaited. If a concurrent bind is possible, add the same staleness guard to the clear, then compile and run the pane controller test suite.
```

**app/poltergeist_app/test/services/pane_cancel_regressions_test.dart:302 - Successful retry never asserts the stale error is cleared**
**Problem:** The new "failed reconnect preserves the user directory" test verifies the healed retry lands on `/srv/www`, but it never checks that the earlier `RemoteFileErrorKind.disconnected` error (set at line 281 and asserted non-null at line 291) is cleared once the reconnect succeeds.
**Impact:** A regression where `PaneController.retry()` succeeds but leaves the stale error latched (user sees an error banner over a connected, working pane) would pass this test. Elsewhere in this PR suite (e.g., `pane_view_test.dart` "Esc retried the failed navigation") the error-clearing behavior is asserted, so this test's silence on it is a real coverage gap for exactly the recovery path it exercises.
**Suggested fix:**
```diff
     expect(healed.listCalls, ['/srv/www'],
         reason: 'the preserved directory survives a failed reconnect');
+    expect(controller.error, isNull,
+        reason: 'a successful retry clears the stale disconnected error');
     expect(
       controller.location,
       const RemotePaneLocation('srv-1', '/srv/www'),
```
[[suggestion:path:app/poltergeist_app/test/services/pane_cancel_regressions_test.dart:302:assert stale error clears after successful retry:    expect(healed.listCalls, ['/srv/www'],
        reason: 'the preserved directory survives a failed reconnect');
    expect(controller.error, isNull,
        reason: 'a successful retry clears the stale disconnected error');]]
**Prompt for AI Agents:**
```
In app/poltergeist_app/test/services/pane_cancel_regressions_test.dart, inside the test 'a failed reconnect still preserves the user directory on the next retry', insert `expect(controller.error, isNull, reason: 'a successful retry clears the stale disconnected error');` immediately after the `expect(healed.listCalls, ['/srv/www'], ...)` assertion. Run `flutter test test/services/pane_cancel_regressions_test.dart` and confirm the new assertion passes. If it fails, PaneController.retry() is leaking the previous error after a successful reconnect — investigate the retry success path in the controller before weakening or removing the assertion.
```

**app/poltergeist_app/test/services/pane_cancel_regressions_test.dart:355 - Test reaches into FakePaneLanes internals to close the status lane**
**Problem:** The new "cleanly closed status lane" test closes the lane via `lanes.statesControllers['srv-1']!.close()`, poking the fake's public internal map directly, while the sibling operation (emitting state) goes through the `emitState` helper.
**Impact:** The test couples to the fake's storage layout rather than its behavior. If `FakePaneLanes` is later refactored (e.g., the map is renamed or per-server controllers are wrapped), this test breaks for reasons unrelated to the behavior it guards. It also sets a precedent that future lane-lifecycle tests will copy.
**Suggested fix:**
```diff
-    await lanes.statesControllers['srv-1']!.close();
+    await lanes.closeLane('srv-1');
```
(Requires adding a `closeLane(String serverId)` helper to `FakePaneLanes` — likely in `test/services/pane_controller_test.dart` or wherever the fake is defined — mirroring the existing `emitState` helper.)
**Prompt for AI Agents:**
```
Locate the FakePaneLanes definition used by app/poltergeist_app/test/services/pane_cancel_regressions_test.dart (likely test/services/pane_controller_test.dart or a shared test helper). Add a helper mirroring emitState, e.g. `Future<void> closeLane(String serverId) => statesControllers[serverId]!.close();`. Then in the test 'a cleanly closed status lane cannot latch the connection-lost banner' replace `await lanes.statesControllers['srv-1']!.close();` with `await lanes.closeLane('srv-1');`. Run `flutter test test/services/pane_cancel_regressions_test.dart` to confirm the test still passes unchanged.
```

**docs/STATUS.md:3052 - Stale open-item cross-references in the new Windows loss section**
**Problem:** The CI paragraph in the new "M3: Windows watched-directory loss (2026-09-13)" section cross-references the wrong open items. "its job passed on retry (item 19)" points at item 19, but the incident-store intermittency is item 20 (item 19 is the ancestor-rename gap — the very next sentence correctly says "Higher-ancestor renames remain item 19", making the two adjacent "item 19" references contradictory). The following line says "Linux overflow remains item 14", but the Linux inotify overflow is item 15 — the rewritten item 16 in this same delta says "Linux overflow remains item 15", and the pre-delta item 16 text said "item 15's Linux overflow stays its own gap."
**Impact:** In a status document whose numbered items are load-bearing (this PR itself renumbers items to fix a collision), two wrong references misdirect readers to unrelated open items and introduce an internal contradiction within the same change.
**Suggested fix:**
```diff
-passed on retry (item 19). Higher-ancestor renames remain item 19; Linux
-overflow remains item 14. M3 stays open.
+passed on retry (item 20). Higher-ancestor renames remain item 19; Linux
+overflow remains item 15. M3 stays open.
```
[[suggestion:path:docs/STATUS.md:line:3052:Point the incident-store retry reference at item 20:passed on retry (item 20). Higher-ancestor renames remain item 19; Linux]]
[[suggestion:path:docs/STATUS.md:line:3053:Point the Linux overflow reference at item 15:overflow remains item 15. M3 stays open.]]
**Prompt for AI Agents:**
```
In docs/STATUS.md, locate the section "## M3: Windows watched-directory loss (2026-09-13)". Find the sentence containing "its job passed on retry (item 19)". Cross-check the "## Open items" list in the same file: item 19 is "Windows ancestor rename detection (#92)" and item 20 is "Windows incident-store test intermittency (#92 CI)", which is the item describing the incident-store retry. Change "(item 19)" to "(item 20)". On the next line, change "overflow remains item 14" to "overflow remains item 15", verified against item 16's own text ("Linux overflow remains item 15"). Do not alter any other text in the paragraph.
```

**packages/poltergeist_core/lib/src/engine/engine_host.dart:612 - Drain fixed-point termination depends on the unshown loop body awaiting and removing `_pendingCloses`**
**Problem:** The visible half of the rewritten drain only shows `_channels` being snapshotted, cleared, and local channels retired via `unawaited(_retireChannel(...))` — which *registers* entries in `_pendingCloses`. Termination of `while (_channels.isNotEmpty || _pendingCloses.isNotEmpty)` therefore depends entirely on the truncated remainder of the loop body: it must (a) await a *fresh* snapshot of `_pendingCloses` on every iteration under the drain bound, and (b) remove each awaited entry whether it settles or is abandoned via the `_DrainAbandoned` timeout. Note the common case where `_channels` is empty but `_pendingCloses` is not (closes already in flight when shutdown arrives): the visible `for` loop is a no-op there, so all progress comes from the invisible await-and-remove code.
**Impact:** If abandoned (timed-out) retirements stay in `_pendingCloses`, the disjunction never becomes false — shutdown hangs, potentially as a hot spin loop once `_channels` is empty. If entries registered mid-drain by `_rejectMintAfterShutdown` (parked opens resuming) are not re-awaited on a later iteration, the shutdown ack fires over a still-live backend release — precisely the no-false-success violation this repair is meant to eliminate.
**Suggested fix:**
```diff
     while (_channels.isNotEmpty || _pendingCloses.isNotEmpty) {
       final entries = List.of(_channels.entries);
       _channels.clear();
+      // Invariant: every iteration must await a fresh snapshot of
+      // _pendingCloses (taken after the retirements above register) under
+      // the drain bound AND remove each awaited entry — settled or
+      // abandoned — or this condition can never become false.
       for (final entry in entries) {
```
**Prompt for AI Agents:**
```
Open engine_host.dart and read the FULL body of the shutdown drain `while (_channels.isNotEmpty || _pendingCloses.isNotEmpty)` loop, including everything after `unawaited(_retireChannel(entry.key, entry.value));`. Verify: (1) each iteration awaits a snapshot of _pendingCloses taken AFTER the _channels retirements are registered; (2) awaited entries are removed from _pendingCloses whether they settle or the await is abandoned via the _DrainAbandoned timeout; (3) entries added to _pendingCloses mid-drain by _rejectMintAfterShutdown are captured by the next iteration's snapshot; (4) no path exists where the body performs zero awaits while _pendingCloses is non-empty (hot spin); (5) _shuttingDown is set to true BEFORE any drain-side mutation of _channels/_pendingCloses, so the entry/mint gates cannot race the first snapshot; (6) no request handler other than the two open handlers inserts into _channels. If any check fails, restructure the body to snapshot → await → remove per iteration.
```

**packages/poltergeist_core/test/engine/engine_host_test.dart:146 - `shutdownDrainTimeout` now bounds ordinary closes, making the name misleading**
**Problem:** The new tests prove that `shutdownDrainTimeout` is the knob that bounds *non-shutdown* close-settlement too: `supervisor_close_timeout_test.dart` is explicitly titled "non-shutdown close timeout" yet configures only `shutdownDrainTimeout`, and `concurrent_channel_close_test.dart`'s "close timeout reports failure while the release stays tracked" and "a duplicate close survives shutdown-drain abandonment" tests likewise obtain their 'did not settle' close errors purely from this parameter with no shutdown involved. So the engine treats this as a general release-settle bound, but the harness (and presumably the engine config) still names it as shutdown-drain-specific.
**Impact:** Future maintainers tuning or grepping for close-timeout behavior will look for a `closeTimeout`-style knob and miss this one; conversely, someone adjusting the shutdown drain bound will unknowingly change close semantics for a live engine. Tests encoding the shared-bound contract under the wrong name also make the contract harder to discover.
**Suggested fix:**
```diff
     LocalWatchBackend? localWatch,
-    Duration? shutdownDrainTimeout,
+    Duration? releaseSettleTimeout,
   ]) : opener = opener ?? FakeTransportOpener() {
@@
       localWatch: localWatch,
-      shutdownDrainTimeout: shutdownDrainTimeout,
+      releaseSettleTimeout: releaseSettleTimeout,
     );
```
(Rename the engine-side field/parameter in lockstep and update the three test call sites that pass `shutdownDrainTimeout:` today.)
**Prompt for AI Agents:**
```
1. In engine_host_test.dart rename the HostHarness parameter `shutdownDrainTimeout` to `releaseSettleTimeout` and update its pass-through to the engine constructor.
2. Find the engine-side configuration field that currently receives `shutdownDrainTimeout` and rename it (and its uses in the drain and close paths) to `releaseSettleTimeout`.
3. Update all call sites in concurrent_channel_close_test.dart and supervisor_close_timeout_test.dart that pass `shutdownDrainTimeout:` to the new name.
4. Run: flutter test packages/poltergeist_core/test/engine/ — all tests must pass with no behavioral change.
```

**app/poltergeist_app/lib/services/pane_engine_lanes.dart:3 - Lane seam imports the composition root, creating an import cycle**
**Problem:** `PaneEngineLanes` is documented as the minimal seam widget-test fakes script against, but it imports `engine_session.dart` solely for `AppBrowseChannel` — while `engine_session.dart` imports `pane_engine_lanes.dart` so `AppEngine` can implement the interface. Dart resolves this cycle fine, but the "narrow" interface file now transitively drags in the entire session module (prompt coordinator, file stores, identity audit log, the engine spawner).
**Impact:** The seam file can't be consumed standalone: any test or pane widget importing only `pane_engine_lanes.dart` compiles against the whole engine layer. If `engine_session.dart` (or its transitive imports) ever picks up `dart:io` or isolate-heavy code, it leaks into every pane widget test that was supposed to run without an isolate — undermining the stated purpose of the seam.
**Suggested fix:**
```diff

**pane_engine_lanes.dart — own the channel type instead of importing it**
**Problem:** -import 'engine_session.dart';
+// AppBrowseChannel moves here (or into its own app_browse_channel.dart):
+abstract interface class AppBrowseChannel {
+  String get homePath;
+  Future<List<RemoteFileEntry>> listDirectory(String path);
+  Future<void> close();
+}

**engine_session.dart — keep existing importers working via re-export**
**Problem:** import 'pane_engine_lanes.dart';
+export 'pane_engine_lanes.dart' show AppBrowseChannel;
```
**Prompt for AI Agents:**
```
1. Move the `AppBrowseChannel` declaration from engine_session.dart into pane_engine_lanes.dart (or a new leaf file) without changing its members.
2. Add `export 'pane_engine_lanes.dart' show AppBrowseChannel;` to engine_session.dart so existing importers of AppBrowseChannel keep compiling.
3. Verify the import cycle is gone: pane_engine_lanes.dart must no longer import engine_session.dart.
4. Run `dart analyze` on app/poltergeist_app and run the engine_session and pane widget tests to confirm no import or type errors.
```

</blockquote></details>

<details>
<summary>ℹ️ Info comments (2)</summary><blockquote>

**packages/poltergeist_core/lib/src/engine/engine_host.dart:22 - `_DrainAbandoned` throw site is not established by this section**
**Problem:** `_DrainAbandoned` is documented as "thrown by the timeout wrapper", but the only timeout wrapper visible in this delta (`_awaitCloseRelease`) throws a typed `RemoteFileException`. The class is only load-bearing if the shutdown drain's own await wrapper — in the truncated remainder of the shutdown handler — throws `_DrainAbandoned` and the settled/abandoned classification catches it specifically.
**Impact:** If the drain instead routes retirements through `_awaitCloseRelease`, `_DrainAbandoned` is dead code (unused-element lint), and the documented discrimination between "retirement rejected with its own TimeoutException" and "drain abandoned it" does not actually exist — abandonment would surface as a spurious typed error or be indistinguishable from settlement failure inside the drain.
**Suggested fix:**
```diff
-/// The drain's own abandon-signal: thrown by the timeout wrapper, never
+/// The drain's own abandon-signal: thrown only by the shutdown drain's
+/// timeout wrapper (not [_awaitCloseRelease]'s request-level bound), never
```
**Prompt for AI Agents:**
```
Search engine_host.dart for every reference to _DrainAbandoned outside its own declaration. Confirm the drain's retirement-await wrapper throws it (e.g., onTimeout: () => throw const _DrainAbandoned()) and that the drain catches _DrainAbandoned separately from propagated retirement errors before classifying a batch as settled vs abandoned. If no throw site exists, delete the class; if it exists, apply the doc clarification so readers do not mistake _awaitCloseRelease for the intended throw site.
```

**packages/poltergeist_core/test/engine/supervisor_close_timeout_test.dart:14 - Near-duplicate of "close timeout reports failure while the release stays tracked"**
**Problem:** This new test overlaps heavily with `concurrent_channel_close_test.dart`'s "close timeout reports failure while the release stays tracked": both use `GatedWatchBackend` + a 200 ms bound, fire a starter and a duplicate close on the same channel, and assert `everyElement(isA<EngineError>())` with `operation == 'close'` and message containing 'did not settle', plus `release.isCompleted` false. The only unique assertion here is that `h.openLocal` still succeeds while the release is wedged.
**Impact:** Two copies of the same scenario will drift independently; when the close-timeout contract or error message changes, both must be updated, and a failure in one will look like an unrelated regression in the other. If the intent was to pin supervisor-layer behavior specifically, that distinction isn't visible in the test body.
**Suggested fix:**
```diff
     expect(gate.isCompleted, isFalse);
+    // The engine stays live after a timed-out release: a new open must
+    // still succeed while the wedged resource remains unreleased.
+    final stillLive = await h.openLocal(root.path);
+    expect(stillLive, isA<BrowseChannelOpened>());
     // A later close while the release is STILL pending shares it and
```
…and delete `supervisor_close_timeout_test.dart` (or, if layer separation is intentional, rename the test to state its distinguishing assertion, e.g. "timed-out close keeps the engine serving opens").
**Prompt for AI Agents:**
```
1. Confirm with the author whether supervisor_close_timeout_test.dart targets a distinct layer; if it is just a duplicate scenario, delete the file.
2. Port its unique assertion (h.openLocal still succeeds while the release is gated) into the "close timeout reports failure while the release stays tracked" test in concurrent_channel_close_test.dart, immediately after `expect(gate.isCompleted, isFalse);` as shown.
3. Verify no import or suite registration references the deleted file.
4. Run: flutter test packages/poltergeist_core/test/engine/ — all tests must pass.
```
No qualifying findings in this delta.
Both files appear to correctly implement the prior review feedback:
- `supervisor_shutdown_close_test.dart`: The LIFO `addTearDown` ordering (gate release → `h.dispose` → temp dir deletion) is correctly registered and documented; the double-complete guard on the gate prevents `StateError` in teardown; the early error-swallowing `.then(...).ignore()` handlers prevent unhandled-async-error noise if the test fails at a checkpoint before the later handlers attach; and the precondition block (`backend.cancelled` contains the path, plus all three ack flags false) converts what would be silent false-passes into loud failures, matching the sibling suite's park strength.
- `windows_watch_backend_test.dart`: The `_NativeWatch.close()` pre-releasing the cancel gate correctly models Dart's post-done implicit `onCancel`; the `run()` finally orders cancel → probe completion → gate release → await, which is safe given the (independently tested) post-cancel probe suppression; probe indexing (`probes.single`/`probes[1]`/`probes.last`) is consistent with the coalescing semantics asserted elsewhere in the suite; and the filesystem-root case correctly expects a single non-recursive watch.

</blockquote></details>


<details>
<summary>⚠️ Outside diff range comments (1)</summary><blockquote>

<details>
<summary>docs/plan/03-ARCHITECTURE.md (1)</summary><blockquote>

## [Minor] (outside diff) docs/plan/03-ARCHITECTURE.md:2002 - Stale "open item 14" reference for the Linux overflow
**Problem:** The unchanged sentence anchoring the rewritten Windows backend paragraph still records the Linux inotify overflow limitation as "STATUS (open item 14)". The overflow limitation is STATUS open item 15 (confirmed by both the old and new item 16 text in this delta). This stale reference is also the likely source of the erroneous "item 14" now introduced at docs/STATUS.md:3053.
**Impact:** The architecture chapter and STATUS disagree on the item number for the same limitation, and the drift propagates into the newly added STATUS text; a reader tracing the reference lands on an unrelated open item.
**Suggested fix:**
```diff
- limitation is recorded in STATUS (open item 14): Linux's inotify queue
+ limitation is recorded in STATUS (open item 15): Linux's inotify queue
```
**Prompt for AI Agents:**
```
In docs/plan/03-ARCHITECTURE.md, search for the sentence beginning "limitation is recorded in STATUS (open item 14)". Open docs/STATUS.md, find the "## Open items" list, and confirm which numbered item covers the Linux inotify queue overflow / IN_Q_OVERFLOW limitation (it is item 15, per item 16's text "Linux overflow remains item 15"). Update the architecture reference from "open item 14" to "open item 15". Make no other changes to the paragraph.
```

</blockquote></details>

</blockquote></details>

<!-- zai-code-review-state:{"version":1,"lastReviewedSha":"a07601deaf7ff96f715bb8cdbd766e8ac92a7726","lastFullReviewSha":"f75a219832960470cff44dd8a5f809b328470173","auditCursor":7,"mode":"hybrid"} -->
<!-- zai-code-review -->