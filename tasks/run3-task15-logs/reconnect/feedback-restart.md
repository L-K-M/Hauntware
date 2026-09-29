## THREAD PRRT_kwDOUIzfcM6h7RdV resolved=False outdated=False app/poltergeist_app/lib/services/pane_controller.dart:542
https://github.com/L-K-M/Poltergeist/pull/95#discussion_r4000597780 {'login': 'github-actions'} updated=2026-09-13T19:18:02Z
Resume healing from failed recovery when transport reports connected
```suggestion
(_recovery == _RecoveryPhase.waiting ||
            _recovery == _RecoveryPhase.failed)) {
```

## THREAD PRRT_kwDOUIzfcM6h7RdX resolved=False outdated=False docs/STATUS.md:2666
https://github.com/L-K-M/Poltergeist/pull/95#discussion_r4000597786 {'login': 'github-actions'} updated=2026-09-13T19:18:02Z
Insert blank line between paragraphs
```suggestion
tests and analysis pass.

Bounded logs/exits and seven inspected readable widget captures live under
```

## THREAD PRRT_kwDOUIzfcM6h7RdZ resolved=False outdated=False docs/STATUS.md:2664
https://github.com/L-K-M/Poltergeist/pull/95#discussion_r4000597788 {'login': 'github-actions'} updated=2026-09-13T19:18:02Z
Clarify that runtime reds exposed the flawed assumption
```suggestion
state and single-overlay rendering. Three status-watch runtime reds exposed the
old assumption that EOF/error could dismiss unhealed loss; the repair corrected
it. Full app 566 tests and analysis pass.
```

## ISSUES 5655493791 https://github.com/L-K-M/Poltergeist/pull/95#issuecomment-5655493791 commit=None
## GLM 5.3 Code Review

> [!NOTE]
> Review scope: **full PR** at `994a2c0`.  hybrid mode is bootstrapping without prior completed state.

**Actionable suggestions identified: 3**

> [!NOTE]
> Inline suggestions are posted on a best-effort basis; GitHub may reject invalid or outdated diff anchors.

<details>
<summary>🟠 Major comments (1)</summary><blockquote>

**app/poltergeist_app/lib/services/pane_controller.dart:542 - A `connected` status cannot resume healing from the `failed` phase**
**Problem:** The heal-listing branch only runs when `_recovery == _RecoveryPhase.waiting`. However, `_endRecoveryWatch()` (invoked from the status lane's `onError`/`onDone`) and the `disconnected`/`blocked` branch both park the pane in `failed` while leaving the status subscription alive. The pre-existing comment in the `onError` handler explicitly states the stream may survive an error and "the next event restores the truth" — but if that next event is `connected`, `_acceptStatus` only stores `_connectionStatus` and matches no branch, so `_recovery` stays `failed` forever.
**Impact:** A status lane that errors and then recovers leaves the banner showing "Connection to {label} could not be restored" while the engine reports `connected` — verbs disabled, navigation blocked, and the user is forced into a manual Retry (a full rebind + relist) even though the transport healed. By the file's own invariant ("The engine rebinds healthy PaneChannels before emitting connected"), issuing the prove-it listing from `failed` is just as safe as from `waiting`, and a `reconnecting` event already re-enters `waiting` from `failed`, so this is an inconsistency in the state machine rather than a deliberate stop.
**Suggested fix:**
```diff
     } else if (status.state == ServerConnectionState.connected &&
-        _recovery == _RecoveryPhase.waiting) {
+        (_recovery == _RecoveryPhase.waiting ||
+            _recovery == _RecoveryPhase.failed)) {
```
[[suggestion:path:app/poltergeist_app/lib/services/pane_controller.dart:line:542:Resume healing from failed recovery when transport reports connected:        (_recovery == _RecoveryPhase.waiting ||
            _recovery == _RecoveryPhase.failed)) {]]
**Prompt for AI Agents:**
```
1. Verify that after `lanes.statesControllers[serverId].addError(...)` the status subscription is still live (onError does not cancel it) and that a subsequent connected status reaches _acceptStatus while _recovery == failed.
2. Confirm the engine rebinds healthy PaneChannels before emitting connected (see the comment at the _issueNavigation heal site), so healing from failed cannot list on a dead channel.
3. Confirm no loop risk: a failed heal listing sets failed again, and connected is only re-emitted on a real state change, so there is no tight relist cycle.
4. Add a regression test: reconnecting -> lane addError (expect failed/canRetryRecovery) -> emit connected + successful listing -> expect connectionLost false, verbsEnabled true.
```

</blockquote></details>

<details>
<summary>🟡 Minor comments (5)</summary><blockquote>

**app/poltergeist_app/lib/services/pane_controller.dart:553 - Heal branch can silently no-op and strand the pane in `waiting`**
**Problem:** In the `connected` + recovery branch, when `channel == null || bookmark == null` the code falls through with no state change, leaving `_recovery == waiting` with no pending bind to complete the heal. Today this appears unreachable (`waiting` implies a live binding or an in-flight bind whose success callback heals), but a status event delivered synchronously between the connect closure's early return and `_channel` being assigned, or any future refactor, would land here with no exit.
**Impact:** If any path reaches it, the pane shows the endless "reconnecting…" waiting state with no Retry — exactly the dead-end the `failed` phase was introduced to eliminate. A one-line fallback converts the silent dead-end into the recoverable state.
**Suggested fix:**
```diff
         _recovery = _RecoveryPhase.listing;
         _issueNavigation(location, location.path, channel);
-      }
+      } else {
+        // No live binding to heal with: offer Retry instead of waiting.
+        _recovery = _RecoveryPhase.failed;
+      }
```
**Prompt for AI Agents:**
```
1. Trace whether _recovery == waiting with _channel == null and no in-flight bind is reachable (check where _channel is assigned relative to the connect closure's early-return branch and whether any status stream uses synchronous delivery).
2. If unreachable, apply the else branch as defensive hardening of the state machine; verify existing round-15 tests still pass since no test exercises connected-with-missing-binding.
```

**app/poltergeist_app/test/ui/panes/pane_view_test.dart:164 - Scrim detection scans the whole tree for an exact alpha match**
**Problem:** The "single dim" assertion finds every `ColoredBox` in the entire widget tree and filters by exact double equality `box.color.a == 0.6`. This couples the test to a color value rather than widget identity. With Flutter's wide-gamut `Color` API, `a` is a `double` backed by float storage, so if the app ever switches the scrim from `withOpacity(0.6)` to `withValues(alpha: 0.6)`, float32 rounding can make `0.60000002 != 0.6` and the test fails for a reason unrelated to the guarantee it protects.
**Impact:** Any unrelated widget that happens to render a 0.6-alpha `ColoredBox` — or a change in how the scrim color is constructed — makes this assertion fail or pass spuriously, eroding confidence in the "loss and loading must not stack dims" behavior.
**Suggested fix:**
```diff
-    final scrims = tester.widgetList<ColoredBox>(find.byType(ColoredBox))
-        .where((box) => box.color.a == 0.6);
-    expect(scrims, hasLength(1), reason: 'loss and loading must not stack dims');
+    // Requires tagging the pane's dim layer with ValueKey('pane.scrim') in the app code.
+    expect(find.byKey(const ValueKey('pane.scrim')), findsOneWidget,
+        reason: 'loss and loading must not stack dims');
```
**Prompt for AI Agents:**
```
Find the dim/scrim ColoredBox rendered by the pane overlay (banner/loading layer) in the app source, add a ValueKey('pane.scrim') to it, then update the test in pane_view_test.dart to match by that key instead of scanning all ColoredBox widgets for color.a == 0.6. Run the widget test to confirm it still passes and that no other scrim-bearing widget needs the same key.
```

**app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:405 - Magic 200 ms pump duplicated across heal tests**
**Problem:** Both this test (line 405) and `pane_view_test.dart` (line 163) hardcode `await tester.pump(const Duration(milliseconds: 200));` to step past an unspecified loading/debounce delay before asserting the banner is still visible while the healing listing is held. The value duplicates an app-side constant that is referenced nowhere.
**Impact:** If the app's overlay delay changes (e.g., 200 → 300 ms), these pumps will land *after* the held-listing state resolves differently, and the "banner stays up while recovery is pending" coverage silently disappears or the tests become flaky in CI.
**Suggested fix:**
```diff
-    await tester.pump(const Duration(milliseconds: 200));
+    await tester.pump(kPaneOverlaySettleDelay); // shared const mirroring the app's scrim/banner delay
```
**Prompt for AI Agents:**
```
Identify the app-side delay that the 200 ms pump in workspace_panes_test.dart and pane_view_test.dart is meant to cover (loading scrim / banner debounce in the pane UI). Extract a single named constant (ideally the app constant itself, or a shared test helper constant), replace both literals, and re-run both widget tests to confirm behavior is unchanged.
```

**docs/STATUS.md:2666 - Missing blank line merges the Validation and artifacts paragraphs**
**Problem:** The sentence "tests and analysis pass." is immediately followed by "Bounded logs/exits..." with no blank line, unlike every other paragraph in this new section.
**Impact:** In rendered Markdown the two paragraphs merge into one, so the validation results and the artifact-location/caveats text run together, making the status entry harder to scan and breaking the visual rhythm of the log.
**Suggested fix:**
```diff
-tests and analysis pass.
-Bounded logs/exits and seven inspected readable widget captures live under
+tests and analysis pass.
+
+Bounded logs/exits and seven inspected readable widget captures live under
```
**Prompt for AI Agents:**
```
In docs/STATUS.md, locate the "Post-merge reconnect truth repair (2026-09-13, #84 follow-up)" section. Confirm that the sentence ending "tests and analysis pass." and the sentence beginning "Bounded logs/exits" are separated by a blank line. If not, insert exactly one blank line between them so the paragraphs render separately, matching the blank-line separation used by all other paragraphs in the section. Change no other text.
```
[[suggestion:path:docs/STATUS.md:line:2666:Insert blank line between paragraphs:tests and analysis pass.
Bounded logs/exits and seven inspected readable widget captures live under]]

**docs/STATUS.md:2664 - Ambiguous attribution: runtime reds "corrected" the assumption**
**Problem:** "Three status-watch runtime reds corrected the old assumption that EOF/error could dismiss unhealed loss" reads as if the failing checks themselves performed the correction, when the intended meaning is that the reds exposed the flawed assumption and the repair fixed it.
**Impact:** A future reader auditing this status log against the code could misidentify what changed (the tests versus the recovery logic), weakening the entry's value as an audit record of the EOF/error false-healing fix.
**Suggested fix:**
```diff
-state and single-overlay rendering. Three status-watch runtime reds corrected
-the old assumption that EOF/error could dismiss unhealed loss. Full app 566
-tests and analysis pass.
+state and single-overlay rendering. Three status-watch runtime reds exposed the
+old assumption that EOF/error could dismiss unhealed loss; the repair corrected
+it. Full app 566 tests and analysis pass.
```
**Prompt for AI Agents:**
```
In docs/STATUS.md, find the sentence "Three status-watch runtime reds corrected the old assumption that EOF/error could dismiss unhealed loss." Rewrite it so the runtime reds are described as exposing the flawed assumption and the companion repair as correcting it, keeping the surrounding "Full app 566 tests and analysis pass." statement and the section's ~78-column wrapping. Do not modify any other sentence in the section.
```
[[suggestion:path:docs/STATUS.md:line:2664:Clarify that runtime reds exposed the flawed assumption:state and single-overlay rendering. Three status-watch runtime reds exposed the
old assumption that EOF/error could dismiss unhealed loss; the repair corrected
it. Full app 566 tests and analysis pass.]]

</blockquote></details>

<details>
<summary>ℹ️ Info comments (1)</summary><blockquote>

**app/poltergeist_app/test/services/pane_reconnect_test.dart:497 - EOF test performs load-bearing surgery on fake internals**
**Problem:** The status-EOF test closes the controller via `lanes.statesControllers[bookmark().id]!.close()` and later calls `lanes.statesControllers.remove(bookmark().id)` (line 508). The `remove` is required so the shared `tearDown` loop over `statesControllers.values` doesn't operate on the already-closed entry, but nothing in the test communicates that coupling.
**Impact:** If the fake later re-registers controllers on `openBrowse` (which the subsequent `pane.retry()` may trigger) or the `tearDown` shape changes, the EOF simulation breaks in non-obvious ways, and the intent ("simulate the server-state stream ending") stays buried in map manipulation.
**Suggested fix:**
```diff
-    await lanes.statesControllers[bookmark().id]!.close();
+    await lanes.closeServerState(bookmark().id); // fake helper: close + deregister in one step
```
(and delete the manual `lanes.statesControllers.remove(bookmark().id);` at line 508)
**Prompt for AI Agents:**
```
Add a helper to FakePaneLanes in pane_controller_test.dart, e.g. Future<void> closeServerState(String id), that closes the state controller and removes it from statesControllers. Use it in pane_reconnect_test.dart's 'status EOF cannot heal loss or accept its pending listing' test in place of the direct map close/remove, and verify the EOF test and the shared tearDown still behave identically.

</blockquote></details>

<!-- zai-code-review-state:{"version":1,"lastReviewedSha":"994a2c05bce9ea2ea2af6c37434fa5fdfb55040c","lastFullReviewSha":"994a2c05bce9ea2ea2af6c37434fa5fdfb55040c","auditCursor":0,"mode":"full"} -->
<!-- zai-code-review -->

## REVIEWS 5191863769 https://github.com/L-K-M/Poltergeist/pull/95#pullrequestreview-5191863769 commit=994a2c05bce9ea2ea2af6c37434fa5fdfb55040c

