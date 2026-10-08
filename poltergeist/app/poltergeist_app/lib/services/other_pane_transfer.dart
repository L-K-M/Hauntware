import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileEntry, TransferOperation;

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
