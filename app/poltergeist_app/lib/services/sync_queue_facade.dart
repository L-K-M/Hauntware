// The activity-panel seam for sync runs (05 §10): a run is ONE task
// row — the panel's pause/cancel/retry verbs land on the run's
// SyncRunPause / RemoteTransferCancellation / retryFailed through
// [CompositeAppTransferQueue], and executor events land on the task's
// item rows. Sync tasks never reach the transfer journal — their own
// JSONL journal (05 §8) is the durability record — so they live in a
// side registry this composite splices into the [AppTransferQueue]
// interface rather than in the TransferQueue itself.
import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'app_transfer_queue.dart';
import 'archive_queue_tasks.dart';

/// The live per-run handle a [SyncPlanController] reports through.
/// Created by [SyncQueueTasks.beginTask]; the controller drives events
/// in, the composite queue drives pause/cancel/retry out.
final class SyncTaskBinding {
  SyncTaskBinding._({
    required this.task,
    required this.pause,
    required this.cancellation,
    required this.retry,
    required this._items,
    required this._syncItems,
    required this._owner,
  });

  /// The panel-visible task row. [TransferTask]'s mutable fields are
  /// engine-owned by convention; the binding owns this one's mutations.
  final TransferTask task;

  /// §10's between-items hold — `pauseTask`/`resumeTask` land here.
  /// Mutable: a retry mints fresh run controls and [rebind] swaps
  /// them, so the panel's verbs never drive a dead run's objects.
  SyncRunPause pause;

  /// The sticky whole-run cancel — `cancelTask` trips it.
  RemoteTransferCancellation cancellation;

  /// A retry mints a fresh [SyncRunPause]/[RemoteTransferCancellation]
  /// — the controller calls this so the panel row keeps driving the
  /// live attempt.
  void rebind({
    required SyncRunPause pause,
    required RemoteTransferCancellation cancellation,
  }) {
    this.pause = pause;
    this.cancellation = cancellation;
    _resetForRetry();
  }

  /// `retryTask` → the controller's `retryFailed`. Null once the run is
  /// superseded by a fresh plan (a retried run keeps the same binding).
  Future<void> Function()? retry;

  final Map<String, TransferItem> _items;
  final Map<String, SyncItem> _syncItems;
  final SyncQueueTasks _owner;

  /// The panel row for [relativePath], or null when the plan item was
  /// never a task row (skip/conflict rows carry no work).
  TransferItem? itemFor(String relativePath) => _items[relativePath];

  /// Clears the failed attempt while preserving rows that Retry Failed does
  /// not execute, such as conflicts.
  void _resetForRetry() {
    task
      ..error = null
      ..failureKind = null;
    for (final entry in _items.entries) {
      if (_syncItems[entry.key]?.status != SyncItemStatus.failed ||
          entry.value.state != TransferItemState.failed) {
        continue;
      }

      final row = entry.value
        ..state = TransferItemState.pending
        ..error = null
        ..transferredBytes = 0;
      _owner._emit(
        TransferQueueItemEvent(task.id, row.id, TransferItemState.pending),
      );
    }
    task.failedItems = task.items
        .where((item) => item.state == TransferItemState.failed)
        .length;
  }

  /// Registers one SyncRunEvent's item progress on the matching row and
  /// the task rollups, then emits the queue event the panel rebuilds
  /// on.
  void emitProgress(String relativePath, int transferred, int? total) {
    final item = _items[relativePath];
    if (item == null) return;
    // Task rollups count committed bytes only — a mid-flight progress
    // bump would otherwise double-count at item completion.
    item.transferredBytes = transferred;
    _owner._emit(
      TransferQueueProgressEvent(
        task.id,
        itemId: item.id,
        transferred: transferred,
        total: total,
        taskTransferredBytes: task.transferredBytes,
        taskTotalBytes: task.totalBytes ?? 0,
        taskTotalFiles: task.totalFiles,
        taskTotalDirectories: task.totalDirectories,
        taskCompletedFiles: task.completedFiles,
        taskCompletedDirectories: task.completedDirectories,
        scanComplete: true,
      ),
    );
  }

  /// One item's terminal state, mirrored onto its row and rollups.
  void emitItemFinished(SyncItem item) {
    final row = _items[item.relativePath];
    if (row == null) return;
    row.state = switch (item.status) {
      SyncItemStatus.done => TransferItemState.completed,
      SyncItemStatus.failed || SyncItemStatus.conflicted =>
        TransferItemState.failed,
      // Cancelled pending work journals 'skipped' with a 'Cancelled'
      // error — the panel's cancelled state reads more honestly.
      SyncItemStatus.skipped =>
        item.error == 'Cancelled'
            ? TransferItemState.cancelled
            : TransferItemState.skipped,
      // pending/running never reach this edge — keep the row's state.
      SyncItemStatus.pending || SyncItemStatus.running => row.state,
    };
    row.error = row.state == TransferItemState.completed ? null : item.error;
    if (row.state == TransferItemState.completed) {
      if (row.isDirectory) {
        task.completedDirectories++;
      } else {
        task.completedFiles++;
        task.transferredBytes += row.size ?? 0;
      }
    } else if (row.state == TransferItemState.failed) {
      task.failedItems++;
      task.error ??= item.error;
    } else if (row.state == TransferItemState.skipped) {
      task.skippedItems++;
    }
    _owner._emit(
      TransferQueueItemEvent(
        task.id,
        row.id,
        row.state,
        error: item.error,
      ),
    );
  }

  /// The item-dispatched edge — the row flips to active.
  void emitItemStarted(SyncItem item) {
    final row = _items[item.relativePath];
    if (row == null) return;
    row
      ..state = TransferItemState.active
      ..error = null
      ..transferredBytes = 0;
    _owner._emit(TransferQueueItemEvent(task.id, row.id, row.state));
  }

  /// The run's lifecycle transition (running → paused/completed/
  /// failed/cancelled).
  void emitTaskState(
    TransferTaskState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    task.state = state;
    if (task.isTerminal) {
      task.finishedAt = DateTime.now();
    } else if (state == TransferTaskState.running) {
      // A retry flips the row live again — mirror TransferQueue's
      // restart semantics (transfer_queue.dart clears it the same way).
      task.finishedAt = null;
    }
    if (state == TransferTaskState.completed ||
        state == TransferTaskState.cancelled) {
      task
        ..error = null
        ..failureKind = null;
    } else {
      task.error = error ?? task.error;
      task.failureKind = failureKind ?? task.failureKind;
    }
    _owner._emit(
      TransferQueueTaskEvent(
        task.id,
        state,
        error: error,
        failureKind: failureKind,
      ),
    );
  }
}

/// The sync side of the composite queue: creates the task row a run
/// renders as and routes the panel's verbs onto the run's own controls.
final class SyncQueueTasks {
  final _tasks = <TransferTask>[];
  final _bindings = <String, SyncTaskBinding>{};
  final _settlingRuns = <Future<void>>{};
  final _events = StreamController<TransferQueueEvent>.broadcast();

  /// Live + terminal task rows, admission order (the panel's listing).
  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  Stream<TransferQueueEvent> get events => _events.stream;

  /// Registers a controller run so the quit safe point can wait for its
  /// executor and journal work to settle after cancellation.
  Future<void> trackSettlingRun(Future<void> run) {
    final observed = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _settlingRuns.add(observed);
    unawaited(observed.whenComplete(() => _settlingRuns.remove(observed)));
    return run;
  }

  /// Waits for the runs active when the quit safe point is reached.
  Future<void> waitForSettlingRuns() async {
    await Future.wait(_settlingRuns.toList(growable: false));
  }

  void _emit(TransferQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// The binding for [taskId], or null for transfer-queue tasks.
  SyncTaskBinding? bindingFor(String taskId) => _bindings[taskId];

  /// Registers a run about to start: builds the [TransferTask] row from
  /// the plan's actionable items (skip/conflict rows carry no work, so
  /// they get no panel row) and emits the queued → running edge.
  SyncTaskBinding beginTask({
    required TransferTaskSpec spec,
    required SyncPlan plan,
    required SyncRunPause pause,
    required RemoteTransferCancellation cancellation,
    required Future<void> Function() retry,
  }) {
    final task = TransferTask(spec)
      ..state = TransferTaskState.running
      ..startedAt = DateTime.now()
      ..scanComplete = true;
    final items = <String, TransferItem>{};
    final syncItems = <String, SyncItem>{};
    var totalBytes = 0;
    for (final item in plan.items) {
      final source = _actionableSource(item);
      if (source == null) continue;
      final isDirectory = source.kind == EntryKind.directory;
      final row = TransferItem(
        id: item.relativePath,
        sourcePath: item.relativePath,
        isDirectory: isDirectory,
        destinationPath: item.relativePath,
        size: source.size,
      );
      items[item.relativePath] = row;
      syncItems[item.relativePath] = item;
      task.items.add(row);
      if (isDirectory) {
        task.totalDirectories++;
      } else {
        task.totalFiles++;
        totalBytes += source.size ?? 0;
      }
    }
    task.totalBytes = totalBytes;
    final binding = SyncTaskBinding._(
      task: task,
      pause: pause,
      cancellation: cancellation,
      retry: retry,
      items: items,
      syncItems: syncItems,
      owner: this,
    );
    _tasks.add(task);
    _bindings[task.id] = binding;
    _emit(TransferQueueTaskEvent(task.id, TransferTaskState.running));
    return binding;
  }

  /// The source snapshot an actionable item moves (null for
  /// skip/conflict rows — they carry no work and no row).
  EntrySnapshot? _actionableSource(SyncItem item) => switch (
        item.effective) {
        SyncActionType.copyLeftToRight ||
        SyncActionType.updateLeftToRight ||
        SyncActionType.makeDirRight => item.left,
        SyncActionType.copyRightToLeft ||
        SyncActionType.updateRightToLeft ||
        SyncActionType.makeDirLeft => item.right,
        // Delete-phase rows execute real removals — the panel shows
        // them as zero-byte rows.
        SyncActionType.deleteLeft => item.left,
        SyncActionType.deleteRight => item.right,
        SyncActionType.skip || SyncActionType.conflict => null,
      };

  /// `pauseTask`/`resumeTask` → the run's §10 gate (the panel labels
  /// the row paused through the task event, not the flag).
  bool setPaused(String taskId, bool paused) {
    final binding = _bindings[taskId];
    if (binding == null || binding.task.isTerminal) return false;
    paused ? binding.pause.pause() : binding.pause.resume();
    binding.emitTaskState(
      paused ? TransferTaskState.paused : TransferTaskState.running,
    );
    return true;
  }

  /// `cancelTask` → the run's sticky cancellation; item states unwind
  /// through the executor's own finish events.
  bool cancel(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || binding.task.isTerminal) return false;
    binding.cancellation.cancel();
    return true;
  }

  /// Whether a terminal task still has failed work [retry] can drive.
  bool canRetry(String taskId) {
    final binding = _bindings[taskId];
    return binding != null &&
        binding.retry != null &&
        binding.task.state == TransferTaskState.failed;
  }

  /// `retryTask` → `SyncExecutor.retryFailed` through the controller;
  /// the same binding keeps reporting (attempt n+1, 05 §11).
  bool retry(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || !canRetry(taskId)) return false;
    binding._resetForRetry();
    binding.emitTaskState(TransferTaskState.running);
    unawaited(binding.retry!());
    return true;
  }

  /// `removeTask` — terminal rows only, same rule as the real queue.
  bool remove(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || !binding.task.isTerminal) return false;
    _tasks.remove(binding.task);
    _bindings.remove(taskId);
    _emit(TransferQueueOrderEvent(taskId));
    return true;
  }

  /// Drops every binding (app teardown); rows already emitted stay the
  /// panel's record.
  void dispose() {
    _bindings.clear();
    _tasks.clear();
    unawaited(_events.close());
  }
}

/// [AppTransferQueue] splicing sync and archive tasks into the real queue's
/// seam: reads concatenate every task list and event stream; verbs route on
/// task-id ownership. The transfer queue keeps every verb it owns.
final class CompositeAppTransferQueue implements AppTransferQueue {
  CompositeAppTransferQueue(this._inner, this._syncTasks, this._archiveTasks);

  final AppTransferQueue _inner;
  final SyncQueueTasks _syncTasks;
  final ArchiveQueueTasks _archiveTasks;

  bool _isSyncTask(String taskId) => _syncTasks.bindingFor(taskId) != null;

  bool _isArchiveTask(String taskId) => _archiveTasks.owns(taskId);

  @override
  TransferTask enqueue(TransferTaskSpec spec) => _inner.enqueue(spec);

  @override
  List<TransferTask> get tasks => List.unmodifiable([
    ..._inner.tasks,
    ..._syncTasks.tasks,
    ..._archiveTasks.tasks,
  ]);

  @override
  AppTaskPresentation presentationFor(String taskId) {
    final archive = _archiveTasks.presentationFor(taskId);
    if (archive != null) return archive;
    if (_isSyncTask(taskId)) return AppTaskPresentation.sync;
    return _inner.presentationFor(taskId);
  }

  @override
  Future<DeleteConfirmation> prepareDelete({
    required FsLocation source,
    required List<String> rootPaths,
    bool preferTrash = true,
    RemoteTransferCancellation? cancellation,
  }) => _inner.prepareDelete(
    source: source,
    rootPaths: rootPaths,
    preferTrash: preferTrash,
    cancellation: cancellation,
  );

  @override
  Future<TransferTask> enqueueDelete(DeleteRequest request) =>
      _inner.enqueueDelete(request);

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Stream<TransferQueueEvent> get events => Stream.multi((listener) {
    final innerSub = _inner.events.listen(listener.add);
    final syncSub = _syncTasks.events.listen(listener.add);
    final archiveSub = _archiveTasks.events.listen(listener.add);
    listener.onCancel = () async {
      await innerSub.cancel();
      await syncSub.cancel();
      await archiveSub.cancel();
    };
  });

  @override
  List<PendingConflict> get pendingConflicts => _inner.pendingConflicts;

  @override
  PendingConflict? pendingConflictFor(String taskId, String itemId) =>
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? null
      : _inner.pendingConflictFor(taskId, itemId);

  @override
  List<TransferHistoryEntry> get history => _inner.history;

  @override
  BandwidthLimiter get downloadLimiter => _inner.downloadLimiter;

  @override
  BandwidthLimiter get uploadLimiter => _inner.uploadLimiter;

  // Sync runs keep their own per-pair concurrency (05 §6): the caps bound
  // the queue's transfers only.
  @override
  ServerTransferLimits get serverTransferLimits => _inner.serverTransferLimits;

  @override
  set serverTransferLimits(ServerTransferLimits limits) =>
      _inner.serverTransferLimits = limits;

  @override
  void pauseQueue() => _inner.pauseQueue();

  @override
  void resumeQueue() => _inner.resumeQueue();

  @override
  void pauseTask(String taskId) {
    if (_isArchiveTask(taskId)) {
      _archiveTasks.pause(taskId);
      return;
    }
    if (_isSyncTask(taskId)) {
      _syncTasks.setPaused(taskId, true);
      return;
    }
    _inner.pauseTask(taskId);
  }

  @override
  void resumeTask(String taskId) {
    if (_isArchiveTask(taskId)) {
      _archiveTasks.resume(taskId);
      return;
    }
    if (_isSyncTask(taskId)) {
      _syncTasks.setPaused(taskId, false);
      return;
    }
    _inner.resumeTask(taskId);
  }

  @override
  void cancelTask(String taskId) {
    if (_isArchiveTask(taskId)) {
      _archiveTasks.cancel(taskId);
      return;
    }
    if (_isSyncTask(taskId)) {
      _syncTasks.cancel(taskId);
      return;
    }
    _inner.cancelTask(taskId);
  }

  @override
  bool removeTask(String taskId) {
    if (_isArchiveTask(taskId)) return _archiveTasks.remove(taskId);
    if (_isSyncTask(taskId)) return _syncTasks.remove(taskId);
    return _inner.removeTask(taskId);
  }

  @override
  bool moveTask(String taskId, {String? beforeTaskId}) =>
      // Sync rows are not reorderable — they are session reports, not
      // queued admissions.
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? false
      : _inner.moveTask(taskId, beforeTaskId: beforeTaskId);

  @override
  bool cancelItem(String taskId, String itemId) =>
      // The sync executor has no per-item cancel seam — the whole run
      // unwinds or nothing does; never a silent no-op read as success.
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? false
      : _inner.cancelItem(taskId, itemId);

  @override
  bool canRetryItem(String taskId, String itemId) =>
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? false
      : _inner.canRetryItem(taskId, itemId);

  @override
  bool retryItem(String taskId, String itemId) =>
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? false
      : _inner.retryItem(taskId, itemId);

  @override
  bool canRetryTask(String taskId) {
    if (_isArchiveTask(taskId)) return _archiveTasks.canRetry(taskId);
    if (_isSyncTask(taskId)) return _syncTasks.canRetry(taskId);
    return _inner.canRetryTask(taskId);
  }

  @override
  bool retryTask(String taskId) {
    if (_isArchiveTask(taskId)) return _archiveTasks.retry(taskId);
    if (_isSyncTask(taskId)) return _syncTasks.retry(taskId);
    return _inner.retryTask(taskId);
  }

  @override
  bool resolveConflict(
    String taskId,
    String itemId,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  }) =>
      // Sync conflicts resolve in the plan view before the run — a
      // running sync task never parks an item for an answer.
      _isSyncTask(taskId) || _isArchiveTask(taskId)
      ? false
      : _inner.resolveConflict(taskId, itemId, verb, scope: scope);

  @override
  Future<void> clearHistory() => _inner.clearHistory();

  /// The quit safe point (D16): the inner queue flushes its transfer journal,
  /// while session-only sync and archive jobs finish unwinding.
  @override
  Future<void> flushJournal() async {
    await Future.wait([
      _inner.flushJournal(),
      _syncTasks.waitForSettlingRuns(),
      _archiveTasks.waitForCancellationCleanup(),
    ]);
  }
}
