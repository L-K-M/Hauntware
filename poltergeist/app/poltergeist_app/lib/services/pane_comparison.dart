import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileEntry, RemoteFileType;
import 'package:poltergeist_sync/poltergeist_sync.dart'
    show EntryKind, EntrySnapshot, SyncSide;

import 'other_pane_transfer.dart' show otherPaneTarget;
import 'pane_controller.dart';
import 'pane_location.dart';
import 'sync_compare_controller.dart';
import 'workspace_controller.dart';

/// The two files File ▸ Compare Files opens in 06 §6's side-by-side view,
/// with the names its title shows.
final class PaneComparison {
  const PaneComparison({
    required this.request,
    required this.leftName,
    required this.rightName,
  });

  final SyncCompareRequest request;
  final String leftName;
  final String rightName;
}

/// Resolves Compare Files from the panes' selections (the cross-pane
/// entry point 06 §6 deferred to v1.x), checked in this order:
///
/// 1. Two files in the focused pane: the first in listing order is the
///    left side.
/// 2. One file in the focused pane and one in the other pane: each keeps
///    its pane's side, so the left pane's file is always on the left.
///
/// A pane's files are its selected rows, else its cursor row: the rule
/// the other selection verbs follow. Only regular files compare, as in
/// the sync plan; a folder, link or special file disables the command
/// rather than being skipped. Null when neither rule applies.
PaneComparison? resolvePaneComparison(WorkspaceController workspace) {
  final focused = workspace.activePane;
  final source = focused.activeTab?.controller;
  if (source == null || !source.verbsEnabled) return null;
  final sourceLocation = source.location;
  if (sourceLocation == null) return null;

  final sourceFiles = _comparedFiles(source);
  if (sourceFiles == null) return null;
  if (sourceFiles.length == 2) {
    return _comparison(
      left: (sourceLocation, sourceFiles.first),
      right: (sourceLocation, sourceFiles.last),
    );
  }
  if (sourceFiles.length != 1) return null;

  final other = otherPaneTarget(workspace, focused);
  if (other == null || !other.verbsEnabled) return null;
  final otherLocation = other.location;
  if (otherLocation == null) return null;
  final otherFiles = _comparedFiles(other);
  if (otherFiles == null || otherFiles.length != 1) return null;

  final focusedSide = (sourceLocation, sourceFiles.single);
  final otherSide = (otherLocation, otherFiles.single);
  return identical(focused, workspace.left)
      ? _comparison(left: focusedSide, right: otherSide)
      : _comparison(left: otherSide, right: focusedSide);
}

typedef _ComparedFile = (PaneLocation location, RemoteFileEntry entry);

/// [pane]'s selected roots, else its cursor row; null when any of them
/// is not a regular file.
List<RemoteFileEntry>? _comparedFiles(PaneController pane) {
  // Menu enablement asks on every render, so a select-all over a large
  // listing stops here. More than two selected rows never leaves two file
  // roots: a row dropped from the roots sits under a selected folder,
  // which is itself a root that disables the comparison.
  if (pane.selectedCount > 2) return null;

  var entries = pane.selectedRoots;
  if (entries.isEmpty) {
    final cursor = pane.cursorIndex;
    if (cursor == null || cursor < 0 || cursor >= pane.entries.length) {
      return null;
    }
    entries = [pane.entries[cursor]];
  }

  if (entries.any((entry) => entry.type != RemoteFileType.file)) return null;
  return entries;
}

PaneComparison _comparison({
  required _ComparedFile left,
  required _ComparedFile right,
}) {
  final leftName = left.$2.name;
  return PaneComparison(
    request: SyncCompareRequest(
      relativePath: leftName,
      left: _source(SyncSide.left, left),
      right: _source(SyncSide.right, right),
    ),
    leftName: leftName,
    rightName: right.$2.name,
  );
}

SyncCompareSource _source(SyncSide side, _ComparedFile file) {
  final (location, entry) = file;
  final snapshot = EntrySnapshot(
    kind: EntryKind.file,
    size: entry.size,
    // Truncated to whole seconds the way previewCacheKey truncates, so a
    // remote side reuses a copy the preview panel already cached.
    mtimeSecs: switch (entry.modifiedAt) {
      null => null,
      final modifiedAt =>
        modifiedAt.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
    },
    mode: entry.mode,
  );
  return switch (location) {
    LocalPaneLocation() => LocalSyncCompareSource(
      side: side,
      fullPath: entry.path,
      snapshot: snapshot,
    ),
    RemotePaneLocation(:final serverId) => RemoteSyncCompareSource(
      side: side,
      fullPath: entry.path,
      snapshot: snapshot,
      serverId: serverId,
    ),
  };
}
