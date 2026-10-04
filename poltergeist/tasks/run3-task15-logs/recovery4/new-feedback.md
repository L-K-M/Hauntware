## PRRT_kwDOUIzfcM6h6kpO resolved=True app/poltergeist_app/lib/ui/connections/connections_view.dart:249
https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000326771 {'login': 'github-actions'}
Check isCurrent, not isActive
```suggestion
if (route.isCurrent) return;
```

## PRRT_kwDOUIzfcM6h6kpd resolved=True app/poltergeist_app/test/ui/panes/pane_session_lifetime_test.dart:47
https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000326796 {'login': 'github-actions'}
Guard duplicate pending opens
```suggestion
assert(
      !pending.containsKey(serverId),
      'Duplicate openBrowseChannel for $serverId while a prompt is pending',
    );
    final result = pending[serverId] = Completer<AppBrowseChannel>();
```

## PRRT_kwDOUIzfcM6h6kp1 resolved=True docs/STATUS.md:3724
https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000326832 {'login': 'github-actions'}
Fix verb agreement in item cross-reference
```suggestion
ancestor invalidation remains item 18; Linux overflow remains item 14.
```

## PRRT_kwDOUIzfcM6h6zu0 resolved=True app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:28
https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000418249 {'login': 'github-actions'}
Record and expose the held listing's requested path
```suggestion
Completer<List<RemoteFileEntry>>? nextListing;

  /// Path of the most recent held request, so tests can assert it.
  String? heldPath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    final held = nextListing;
    nextListing = null;
    if (held == null) return super.listDirectory(path);
    heldPath = path;
    return held.future;
  }
```

## PRRT_kwDOUIzfcM6h6zvz resolved=True app/poltergeist_app/lib/ui/workspace_shell.dart:240
https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000418334 {'login': 'github-actions'}
Document the enablement-source invariant
```suggestion
// Re-evaluate enablement without rebuilding the pane listings.
// Every notifier that feeds command enablement must be merged here;
// a missing source reintroduces stale toolbar state.
```
