## GLM 5.3 Code Review

> [!NOTE]
> Review scope: **hybrid**, changes from `f38c97f` to `03f5819` (3 file(s))
> plus 1 rotating unchanged PR section(s).

**Actionable suggestions identified: 2**

> [!NOTE]
> Inline suggestions are posted on a best-effort basis; GitHub may reject invalid or outdated diff anchors.

<details>
<summary>🟡 Minor comments (1)</summary><blockquote>

**app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:31 - Held-listing fake ignores the requested path and skips call recording**
**Problem:** `_HeldListingChannel.listDirectory` returns `held.future` for whatever `path` is requested, without calling `super.listDirectory(path)` on that branch. Since the default channel's `listCalls` assertions elsewhere in this file imply recording happens inside the base fake's `listDirectory`, held calls are also invisible to `listCalls`.
**Impact:** The pending-listing test cannot detect a refresh regression that requests the wrong path — the held future's entries would be served and rendered regardless of what path the product actually asked for, so the test would still pass. Any future `listCalls` assertion against this channel will silently miss held calls too.
**Suggested fix:**
```diff
   Completer<List<RemoteFileEntry>>? nextListing;
+  String? heldPath;
   @override
   Future<List<RemoteFileEntry>> listDirectory(String path) {
     final held = nextListing;
     nextListing = null;
-    return held?.future ?? super.listDirectory(path);
+    if (held == null) return super.listDirectory(path);
+    heldPath = path;
+    return held.future;
   }
```
And in the "toolbar parent tracks pending and completed listings" test:
```diff
     await tester.tap(find.byKey(const ValueKey('command.$kViewRefreshCommandId')));
     await tester.pump();
     expect(tester.widget<TextButton>(parent).onPressed, isNull);
+    expect(channel.heldPath, '/home/tester');
```
**Prompt for AI Agents:**
```
In app/poltergeist_app/test/ui/panes/workspace_panes_test.dart, update _HeldListingChannel: add a `String? heldPath;` field, and in listDirectory, when a held Completer is consumed, store the requested path in heldPath before returning held.future (only the non-held branch should call super). In the 'toolbar parent tracks pending and completed listings' test, immediately after the assertion that the parent button is disabled while pending, add `expect(channel.heldPath, '/home/tester');`. Run the widget test file and confirm all tests still pass.
```
[[suggestion:path:app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:line:28:Record and expose the held listing's requested path:  Completer<List<RemoteFileEntry>>? nextListing;
  /// Path of the most recent held request, so tests can assert it.
  String? heldPath;
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    final held = nextListing;
    nextListing = null;
    if (held == null) return super.listDirectory(path);
    heldPath = path;
    return held.future;
  }]]

</blockquote></details>

<details>
<summary>ℹ️ Info comments (1)</summary><blockquote>

**app/poltergeist_app/lib/ui/workspace_shell.dart:240 - Enablement-source invariant is undocumented at the merge site**
**Problem:** The new `Listenable.merge` over `workspace`/`workspace.left`/`workspace.right` is now the sole trigger for toolbar enablement re-evaluation, but nothing at the site records that invariant. This same PR repaired three regressions caused by exactly this staleness class.
**Impact:** When a future command's enablement starts reading a notifier outside this set (e.g., connection/session state once remote commands land), the toolbar will silently go stale again — reintroducing the bug class this change fixes, with no local hint why.
**Suggested fix:**
```diff
-              // Re-evaluate enablement without rebuilding the pane listings.
+              // Re-evaluate enablement without rebuilding the pane listings.
+              // Every notifier that feeds command enablement must be merged
+              // here; a missing source reintroduces stale toolbar state.
```
**Prompt for AI Agents:**
```
In app/poltergeist_app/lib/ui/workspace_shell.dart, extend the comment directly above the ListenableBuilder (around line 240) to state that every notifier feeding command enablement must be added to the merged listenable list, otherwise toolbar enablement goes stale. Comment-only change; verify with flutter analyze.
```
[[suggestion:path:app/poltergeist_app/lib/ui/workspace_shell.dart:line:240:Document the enablement-source invariant:// Re-evaluate enablement without rebuilding the pane listings.
// Every notifier that feeds command enablement must be merged here;
// a missing source reintroduces stale toolbar state.]]

</blockquote></details>

<!-- zai-code-review-state:{"version":1,"lastReviewedSha":"03f58198089c1020b54be3347df78d369ed14d95","lastFullReviewSha":"f75a219832960470cff44dd8a5f809b328470173","auditCursor":9,"mode":"hybrid"} -->
<!-- zai-code-review -->