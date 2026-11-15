import 'package:flutter/foundation.dart' show immutable;
import 'package:poltergeist_core/poltergeist_core.dart'
    show FsLocation, RemoteFileEntry, TransferOperation;

import 'pane_controller.dart';
import 'pane_drop.dart';
import 'pane_tabs_controller.dart';
import 'workspace_controller.dart';

/// The pane a transfer from [from] sends to (02 §8's Transfer and Move to
/// Other Pane, and the double-click Transfer): the opposite strip's active
/// tab, while the second pane is shown and that tab shows a folder.
PaneController? otherPaneTarget(
  WorkspaceController workspace,
  PaneTabsController from,
) {
  if (!workspace.secondPaneShown) return null;
  final other = identical(from, workspace.left)
      ? workspace.right
      : workspace.left;
  final target = other.activeTab?.controller;
  if (target == null || target.location == null) return null;
  return target;
}

/// The roots a selection verb acts on: the selected rows, else the
/// cursor row (Finder's "the focused item is the selection" rule). A row
/// inside a selected folder is not a root of its own (02 §2.5).
List<String> paneSelectionRoots(PaneController pane) {
  final selected = pane.selectedRoots;
  if (selected.isNotEmpty) return [for (final e in selected) e.path];
  final cursor = pane.cursorIndex;
  if (cursor == null || cursor < 0 || cursor >= pane.entries.length) {
    return const [];
  }
  return [pane.entries[cursor].path];
}

/// UI-06's "Copy to…" snapshot: what the phone's confirmation sheet shows
/// and, unchanged, exactly what Copy enqueues. Captured once when the
/// sheet opens, so a later selection change, reconnect or tab closure
/// cannot make the queued target differ from the one on screen.
@immutable
class OtherPaneCopyPlan {
  const OtherPaneCopyPlan({
    required this.source,
    required this.rootPaths,
    required this.target,
    required this.destination,
    required this.folder,
  });

  final FsLocation source;
  final List<String> rootPaths;

  /// The other pane's controller: lists folders for Change folder.
  final PaneController target;
  final FsLocation destination;

  /// The other pane's folder when the plan was taken.
  final String folder;

  /// Whether copying the roots into [folder] passes 02 §5.1's
  /// containment rules (never into a root or below it).
  bool allows(String folder) => paneDropAllowed(
    source: source,
    sourceRoots: rootPaths,
    destination: destination,
    destinationDir: folder,
    operation: TransferOperation.copy,
  );
}

/// Snapshots Copy to Other Pane from the active tab of [workspace]: null
/// while the verb cannot run (no live source listing, no selection, or
/// the other pane shows no folder).
OtherPaneCopyPlan? planSelectionCopyToOtherPane(WorkspaceController workspace) {
  final source = workspace.activeTabController;
  final target = otherPaneTarget(workspace, workspace.activePane);
  if (source == null || target == null || !source.verbsEnabled) return null;
  if (source.batchRenameActive) return null;
  final sourceLocation = source.location;
  final targetLocation = target.location;
  if (sourceLocation == null || targetLocation == null) return null;
  final roots = paneSelectionRoots(source);
  if (roots.isEmpty) return null;
  return OtherPaneCopyPlan(
    source: fsLocationForLocation(sourceLocation),
    rootPaths: List.unmodifiable(roots),
    target: target,
    destination: fsLocationForLocation(targetLocation),
    folder: targetLocation.path,
  );
}

/// Enqueues [plan]'s copy into [folder] on the plan's destination host.
/// Returns false, enqueuing nothing, when the containment rules refuse it.
bool enqueueOtherPaneCopy(
  PaneDropDelegate delegate,
  OtherPaneCopyPlan plan,
  String folder,
) {
  if (!plan.allows(folder)) return false;
  delegate.enqueue(
    source: plan.source,
    rootPaths: plan.rootPaths,
    destination: plan.destination,
    destinationDir: folder,
    operation: TransferOperation.copy,
  );
  return true;
}

/// "Double-click action: Transfer to other pane" (02 §2.6): queues [entry]
/// from [source] as a copy into the opposite pane's folder, under the rules
/// of Transfer to Other Pane (F5). The opposite pane is found from the pane
/// the file was opened in, not from the workspace's active pane, so an
/// activation in either pane sends across. The source gate is F5's, except
/// that a directory watch's background re-list does not refuse it.
/// [dropDelegate] is the queue seam; null when no queue is wired.
OtherPaneTransferOutcome transferEntryToOtherPane({
  required WorkspaceController workspace,
  required PaneDropDelegate? dropDelegate,
  required PaneController source,
  required RemoteFileEntry entry,
}) {
  final strip = _stripShowing(workspace, source);
  if (strip == null) return OtherPaneTransferOutcome.unavailable;
  final target = otherPaneTarget(workspace, strip);
  final targetLocation = target?.location;
  if (targetLocation == null) return OtherPaneTransferOutcome.needsOtherPane;

  final sourceLocation = source.location;
  if (dropDelegate == null ||
      sourceLocation == null ||
      !source.activatedRowVerbsEnabled) {
    return OtherPaneTransferOutcome.unavailable;
  }

  final from = fsLocationForLocation(sourceLocation);
  final to = fsLocationForLocation(targetLocation);
  final roots = [entry.path];
  final allowed = paneDropAllowed(
    source: from,
    sourceRoots: roots,
    destination: to,
    destinationDir: targetLocation.path,
    operation: TransferOperation.copy,
  );
  if (!allowed) return OtherPaneTransferOutcome.unavailable;

  dropDelegate.enqueue(
    source: from,
    rootPaths: roots,
    destination: to,
    destinationDir: targetLocation.path,
    operation: TransferOperation.copy,
  );
  return OtherPaneTransferOutcome.queued;
}

/// The strip whose tab is [pane], or null for a controller in neither.
PaneTabsController? _stripShowing(
  WorkspaceController workspace,
  PaneController pane,
) {
  for (final strip in [workspace.left, workspace.right]) {
    if (strip.tabs.any((tab) => identical(tab.controller, pane))) {
      return strip;
    }
  }
  return null;
}
