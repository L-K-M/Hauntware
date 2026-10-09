import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';
import 'archive_queue_tasks.dart';
import 'pane_controller.dart';
import 'pane_drop.dart' show fsLocationForLocation;
import 'pane_location.dart';

/// The pane selection verbs that run as transfer-queue tasks (02 §2.6,
/// D15/D16): delete (Move to Trash / Delete permanently) and duplicate.
/// A queue task — not a browse-channel call — because both can be
/// arbitrarily large and recursive: the queue gives them the journal,
/// progress, pause/cancel, and the activity-panel record every transfer
/// gets, and remote endpoints lease engine-side channels through the
/// bridge like any other task.
///
/// The UI layer owns the dialogs. Delete is two steps so the dialog can
/// quantify what is lost (02 §10) before anything runs:
///
/// ```
/// prepareDeleteSelection(pane) ─► DeleteConfirmation ─► dialog
///                                                        │ confirmed
///                          deleteSelection(confirmation) ◄┘
/// ```
///
/// Every task these verbs enqueue refreshes the pane when it settles
/// (remote panes have no directory watch — 03 §7.5 — so without this the
/// listing would keep showing what was deleted or miss the duplicate);
/// [refreshWhenSettled] is the same hook for any other task a caller
/// enqueues against a pane, such as a drop.
final class PaneFileOps {
  PaneFileOps(AppTransferQueue queue, {ArchiveQueueTasks? archives})
    : _queue = queue,
      // Keep the public named seam free of a private identifier.
      // ignore: prefer_initializing_formals
      _archives = archives;

  final AppTransferQueue _queue;
  final ArchiveQueueTasks? _archives;

  bool get archivesAvailable => _archives != null;

  /// Whether `file.createArchive` can act on the pane's selected local
  /// roots. Archive work is local-only in D27's first slice.
  bool canCreateArchive(PaneController pane) {
    if (_archives == null || pane.location is! LocalPaneLocation) return false;
    return _selectionOf(pane) != null;
  }

  /// Whether `file.extractArchive` has exactly one selected local ZIP.
  bool canExtractArchive(PaneController pane) {
    if (_archives == null || pane.location is! LocalPaneLocation) return false;
    final roots = pane.selectedRoots;
    if (!pane.verbsEnabled || roots.length != 1) return false;
    final archive = roots.single;
    return archive.type == RemoteFileType.file &&
        archive.name.toLowerCase().endsWith('.zip');
  }

  /// Enqueues one ZIP creation beside the selected roots. Null means the
  /// command became inapplicable between enablement and invocation.
  Future<TransferTask?> createArchive(PaneController pane) async {
    final archives = _archives;
    final location = pane.location;
    final target = _selectionOf(pane);
    if (archives == null || location is! LocalPaneLocation || target == null) {
      return null;
    }
    final task = await archives.createZip(
      roots: target.paths,
      destinationDirectory: location.path,
    );
    refreshWhenSettled(pane, task);
    return task;
  }

  /// Enqueues extraction of the selected ZIP into its pane directory.
  /// Null means the command became inapplicable before invocation.
  Future<TransferTask?> extractArchive(PaneController pane) async {
    final archives = _archives;
    final location = pane.location;
    if (archives == null ||
        location is! LocalPaneLocation ||
        !canExtractArchive(pane)) {
      return null;
    }
    final task = await archives.extractZip(
      archivePath: pane.selectedRoots.single.path,
      destinationDirectory: paneParentPath(pane.selectedRoots.single.path),
    );
    refreshWhenSettled(pane, task);
    return task;
  }

  /// Step 1 of `file.delete` (⌘⌫ / Delete) and `file.deletePermanently`
  /// (⌥⌘⌫ / Shift+Delete): the confirmation model for [pane]'s current
  /// selection — the disposition that will really run (OS trash,
  /// `.poltergeist-trash/`, or permanent), counts and bytes when the
  /// quantifying walk finished in time, and the trash-unavailable notice.
  /// [permanent] is the gesture. Null when there is nothing to delete
  /// (no selection, or the pane's verbs are disabled). Throws `cancelled`
  /// when [cancellation] trips mid-quantify (the dialog was dismissed).
  Future<DeleteConfirmation?> prepareDeleteSelection(
    PaneController pane, {
    bool permanent = false,
    RemoteTransferCancellation? cancellation,
  }) async {
    final target = _selectionOf(pane);
    if (target == null) return null;
    return _queue.prepareDelete(
      source: target.source,
      rootPaths: target.paths,
      preferTrash: !permanent,
      cancellation: cancellation,
    );
  }

  /// Step 2, after the user confirmed [confirmation]'s dialog: enqueues
  /// the delete task with [disposition] — the one the user accepted,
  /// taken as is. It is never combined with the gesture or with the
  /// confirmation's effective disposition: a permanent-delete gesture
  /// whose dialog the user switched to the server trash must trash, and
  /// a trash gesture switched to permanent must delete permanently.
  /// Calling this IS the confirmation, so a permanent delete is enqueued
  /// confirmed — never call it without the dialog having been accepted
  /// (or, for a local Move to Trash, without the OS trash serving).
  ///
  /// Throws [TrashException] when a local trash request finds the OS
  /// trash unavailable (re-confirm permanent, D15), and [ArgumentError]
  /// for a filesystem root or a remote trash request the server did not
  /// opt into. [pane], when given, refreshes once the task settles.
  Future<TransferTask> deleteSelection(
    DeleteConfirmation confirmation, {
    required DeleteDisposition disposition,
    PaneController? pane,
  }) async {
    final task = await _queue.enqueueDelete(
      DeleteRequest(
        source: confirmation.source,
        rootPaths: confirmation.rootPaths,
        disposition: disposition,
        confirmed: true,
      ),
    );
    if (pane != null) refreshWhenSettled(pane, task);
    return task;
  }

  /// `file.duplicate` (⌘D / Ctrl+D): copy tasks that duplicate [pane]'s
  /// selection beside itself — keep-both on both kinds, so each copy
  /// lands as `name (2).ext` (folders `name (2)`), the same numbering the
  /// conflict verbs use, never an overwrite. One task per folder the
  /// roots sit in: with folders open in place (02 §2.5) a selection can
  /// span several, and each copy belongs next to its original. Empty
  /// when there is nothing to duplicate. The pane refreshes as each task
  /// settles.
  List<TransferTask> duplicateSelection(PaneController pane) {
    final target = _selectionOf(pane);
    if (target == null) return const [];
    final byFolder = <String, List<String>>{};
    for (final path in target.paths) {
      byFolder.putIfAbsent(paneParentPath(path), () => []).add(path);
    }
    final tasks = <TransferTask>[];
    for (final MapEntry(key: folder, value: paths) in byFolder.entries) {
      final task = _queue.enqueue(
        TransferTaskSpec(
          source: target.source,
          destination: target.source,
          rootPaths: paths,
          destinationDir: folder,
          policy: ResolvedConflictPolicy(
            files: ConflictResolution.keepBoth,
            folders: ConflictResolution.keepBoth,
          ),
        ),
      );
      refreshWhenSettled(pane, task);
      tasks.add(task);
    }
    return tasks;
  }

  /// Refreshes [pane] once [task] reaches a terminal state, if the pane
  /// still shows the directory it showed when the task was enqueued — a
  /// pane that navigated away is left alone. Safe to call for any task.
  void refreshWhenSettled(PaneController pane, TransferTask task) {
    final shownAtEnqueue = pane.location;
    if (shownAtEnqueue == null) return;
    if (task.isTerminal) {
      _refreshIfStill(pane, shownAtEnqueue);
      return;
    }
    late final StreamSubscription<TransferQueueEvent> subscription;
    subscription = _queue.events.listen((event) {
      if (event is! TransferQueueTaskEvent || event.taskId != task.id) return;
      if (!_terminal(event.state)) return;
      unawaited(subscription.cancel());
      _refreshIfStill(pane, shownAtEnqueue);
    });
  }

  static bool _terminal(TransferTaskState state) => switch (state) {
    TransferTaskState.completed ||
    TransferTaskState.failed ||
    TransferTaskState.cancelled => true,
    _ => false,
  };

  static void _refreshIfStill(PaneController pane, PaneLocation shown) {
    if (pane.location == shown) pane.refresh();
  }

  static ({FsLocation source, List<String> paths})? _selectionOf(
    PaneController pane,
  ) {
    final location = pane.location;
    if (location == null || !pane.verbsEnabled) return null;
    // Roots only: a row inside a selected folder travels with the
    // folder (02 §2.5), never a second time on its own.
    final paths = [for (final entry in pane.selectedRoots) entry.path];
    if (paths.isEmpty) return null;
    return (source: fsLocationForLocation(location), paths: paths);
  }
}
