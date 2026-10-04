import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';

typedef _CreateZipJob =
    LocalArchiveJob Function({
      required List<String> sourcePaths,
      required String destinationPath,
    });
typedef _ExtractZipJob =
    LocalArchiveJob Function({
      required String archivePath,
      required String destinationPath,
    });

/// Session-only archive jobs projected onto the shared activity surface.
///
/// The compatibility [TransferTask] records stay local-to-local copy tasks;
/// [AppTaskPresentation] carries the create/extract meaning and supported
/// controls without expanding the persisted transfer protocol.
final class ArchiveQueueTasks {
  ArchiveQueueTasks(LocalArchiveService service)
    : this._(
        createZip: service.createZip,
        extractZip: service.extractZip,
        closeService: service.close,
      );

  @visibleForTesting
  ArchiveQueueTasks.forTesting({
    required LocalArchiveJob Function({
      required List<String> sourcePaths,
      required String destinationPath,
    })
    createZip,
    required LocalArchiveJob Function({
      required String archivePath,
      required String destinationPath,
    })
    extractZip,
  }) : this._(createZip: createZip, extractZip: extractZip, closeService: null);

  ArchiveQueueTasks._({
    required _CreateZipJob createZip,
    required _ExtractZipJob extractZip,
    required this._closeService,
  }) : _createZipJob = createZip,
       _extractZipJob = extractZip;

  static const _multipleRootsArchiveName = 'Archive.zip';

  final _CreateZipJob _createZipJob;
  final _ExtractZipJob _extractZipJob;
  final Future<void> Function()? _closeService;
  final _tasks = <TransferTask>[];
  final _bindings = <String, _ArchiveTaskBinding>{};
  final _events = StreamController<TransferQueueEvent>.broadcast();
  final _cancellationCleanups = <Future<void>>{};

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  Stream<TransferQueueEvent> get events => _events.stream;

  bool owns(String taskId) => _bindings.containsKey(taskId);

  AppTaskPresentation? presentationFor(String taskId) =>
      _bindings[taskId]?.presentation;

  Future<TransferTask> createZip({
    required List<String> roots,
    required String destinationDirectory,
  }) async {
    if (roots.isEmpty) {
      throw ArgumentError.value(roots, 'roots', 'must not be empty');
    }

    final sourcePaths = List<String>.unmodifiable(roots);
    final archiveName = sourcePaths.length == 1
        ? '${p.basename(sourcePaths.single)}.zip'
        : _multipleRootsArchiveName;
    final destinationPath = p.join(destinationDirectory, archiveName);
    return _begin(
      roots: sourcePaths,
      destinationDirectory: destinationDirectory,
      requestedOutputPath: destinationPath,
      presentation: AppTaskPresentation.archiveCreate,
      start: () => _createZipJob(
        sourcePaths: sourcePaths,
        destinationPath: destinationPath,
      ),
    );
  }

  Future<TransferTask> extractZip({
    required String archivePath,
    required String destinationDirectory,
  }) async {
    final destinationPath = p.join(
      destinationDirectory,
      p.basenameWithoutExtension(archivePath),
    );
    return _begin(
      roots: [archivePath],
      destinationDirectory: destinationDirectory,
      requestedOutputPath: destinationPath,
      presentation: AppTaskPresentation.archiveExtract,
      start: () => _extractZipJob(
        archivePath: archivePath,
        destinationPath: destinationPath,
      ),
    );
  }

  TransferTask _begin({
    required List<String> roots,
    required String destinationDirectory,
    required String requestedOutputPath,
    required AppTaskPresentation presentation,
    required LocalArchiveJob Function() start,
  }) {
    final task =
        _ArchiveTransferTask(
            TransferTaskSpec(
              source: const LocalFsLocation(),
              destination: const LocalFsLocation(),
              rootPaths: roots,
              destinationDir: destinationDirectory,
              policy: ResolvedConflictPolicy(
                files: ConflictResolution.keepBoth,
                folders: ConflictResolution.keepBoth,
              ),
            ),
          )
          ..state = TransferTaskState.scanning
          ..startedAt = DateTime.now();
    final binding = _ArchiveTaskBinding(
      task: task,
      presentation: presentation,
      start: start,
      requestedDestinationDirectory: destinationDirectory,
      requestedOutputPath: requestedOutputPath,
    );
    _tasks.add(task);
    _bindings[task.id] = binding;
    _emit(TransferQueueTaskEvent(task.id, task.state));
    _launch(binding);
    return task;
  }

  void pause(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || binding.task.isTerminal) return;
    if (binding.task.state == TransferTaskState.paused) return;

    final job = binding.job;
    if (job == null) return;
    job.pause();
    if (!job.isPaused) return;
    binding.task.state = TransferTaskState.paused;
    _emit(TransferQueueTaskEvent(taskId, TransferTaskState.paused));
  }

  void resume(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null ||
        binding.task.isTerminal ||
        binding.task.state != TransferTaskState.paused) {
      return;
    }

    final job = binding.job;
    if (job == null) return;
    job.resume();
    if (job.isPaused) return;
    binding.task.state = binding.hasPrepared
        ? TransferTaskState.running
        : TransferTaskState.scanning;
    _emit(TransferQueueTaskEvent(taskId, binding.task.state));
  }

  void cancel(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || binding.task.isTerminal) return;

    final job = binding.job;
    final settling = binding.settling;
    if (job == null || settling == null) return;
    job.cancel();
    _trackCancellationCleanup(settling);
  }

  bool canRetry(String taskId) =>
      _bindings[taskId]?.task.state == TransferTaskState.failed;

  bool retry(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || !canRetry(taskId)) return false;

    binding.task
      ..state = TransferTaskState.scanning
      ..startedAt = DateTime.now()
      ..finishedAt = null
      ..scanComplete = false
      ..totalFiles = 0
      ..completedFiles = 0
      ..failedItems = 0
      ..transferredBytes = 0
      ..totalBytes = null
      ..error = null
      ..failureKind = null;
    binding.hasPrepared = false;
    binding.lastCompletedEntries = 0;
    binding
      ..outputPath = binding.requestedOutputPath
      ..task.updateDestinationDirectory(binding.requestedDestinationDirectory);
    binding.items.clear();
    binding.task.items.clear();
    _emit(TransferQueueTaskEvent(taskId, TransferTaskState.scanning));
    _launch(binding);
    return true;
  }

  bool remove(String taskId) {
    final binding = _bindings[taskId];
    if (binding == null || !binding.task.isTerminal) return false;

    _bindings.remove(taskId);
    _tasks.remove(binding.task);
    _emit(TransferQueueOrderEvent(taskId));
    return true;
  }

  /// Quit waits here after cancelling session-only jobs. The archive worker's
  /// `done` future does not settle until its hidden staging output is gone.
  Future<void> waitForCancellationCleanup() async {
    await Future.wait(_cancellationCleanups.toList(growable: false));
  }

  Future<void> dispose() async {
    for (final binding in _bindings.values) {
      if (!binding.task.isTerminal) binding.job?.cancel();
    }
    await _closeService?.call();
    await Future.wait(
      _bindings.values.map((binding) => binding.settling).nonNulls,
    );
    await _events.close();
  }

  void _launch(_ArchiveTaskBinding binding) {
    binding.generation++;
    final generation = binding.generation;
    late LocalArchiveJob job;
    try {
      job = binding.start();
    } on Object catch (error) {
      _failToStart(binding, error);
      return;
    }

    binding.job = job;
    final subscription = job.progress.listen(
      (progress) => _onProgress(binding, job, generation, progress),
      // `done` owns the terminal result and typed error. Consuming the stream
      // error prevents a duplicate unhandled failure while that future settles.
      onError: (Object _, StackTrace _) {},
    );
    binding.progressSubscription = subscription;
    final settling = _settle(binding, job, generation, subscription);
    binding.settling = settling;
  }

  void _onProgress(
    _ArchiveTaskBinding binding,
    LocalArchiveJob job,
    int generation,
    LocalArchiveProgress progress,
  ) {
    if (!_isCurrent(binding, job, generation) || binding.task.isTerminal) {
      return;
    }

    final task = binding.task;
    final item = _recordEntryProgress(binding, progress);
    final prepared = progress.phase != LocalArchivePhase.preparing;
    binding.hasPrepared = binding.hasPrepared || prepared;
    task
      ..scanComplete = binding.hasPrepared
      ..totalFiles = progress.totalEntries
      ..completedFiles = progress.completedEntries
      ..transferredBytes = progress.processedBytes
      ..totalBytes = progress.totalBytes;
    if (task.state != TransferTaskState.paused) {
      final nextState = binding.hasPrepared
          ? TransferTaskState.running
          : TransferTaskState.scanning;
      if (task.state != nextState) {
        task.state = nextState;
        _emit(TransferQueueTaskEvent(task.id, nextState));
      }
    }
    _emit(
      TransferQueueProgressEvent(
        task.id,
        itemId: item?.id ?? job.id,
        transferred: item?.transferredBytes ?? progress.processedBytes,
        total: item?.size,
        taskTransferredBytes: task.transferredBytes,
        taskTotalBytes: task.totalBytes ?? 0,
        taskTotalFiles: task.totalFiles,
        taskTotalDirectories: 0,
        taskCompletedFiles: task.completedFiles,
        taskCompletedDirectories: 0,
        scanComplete: task.scanComplete,
      ),
    );
  }

  Future<void> _settle(
    _ArchiveTaskBinding binding,
    LocalArchiveJob job,
    int generation,
    StreamSubscription<LocalArchiveProgress> subscription,
  ) async {
    try {
      final result = await job.done;
      if (!_isCurrent(binding, job, generation)) return;

      _rebaseOutput(binding, result.destinationPath);
      binding.task
        ..state = TransferTaskState.completed
        ..finishedAt = DateTime.now()
        ..scanComplete = true
        ..totalFiles = result.entries
        ..completedFiles = result.entries
        ..transferredBytes = result.uncompressedBytes
        ..totalBytes = result.uncompressedBytes
        ..error = null
        ..failureKind = null;
      for (final item in binding.task.items) {
        if (item.state == TransferItemState.completed) continue;
        item.state = TransferItemState.completed;
        _emit(
          TransferQueueItemEvent(
            binding.task.id,
            item.id,
            TransferItemState.completed,
          ),
        );
      }
      _emit(
        TransferQueueTaskEvent(binding.task.id, TransferTaskState.completed),
      );
    } on Object catch (error) {
      if (!_isCurrent(binding, job, generation)) return;

      final cancelled =
          error is LocalArchiveException &&
          error.kind == LocalArchiveErrorKind.cancelled;
      binding.task
        ..state = cancelled
            ? TransferTaskState.cancelled
            : TransferTaskState.failed
        ..finishedAt = DateTime.now()
        ..scanComplete = true
        ..failedItems = 0
        ..error = cancelled ? null : error.toString();
      for (final item in binding.task.items) {
        if (item.isTerminal) continue;
        item.state = cancelled
            ? TransferItemState.cancelled
            : TransferItemState.failed;
        item.error = binding.task.error;
        _emit(
          TransferQueueItemEvent(
            binding.task.id,
            item.id,
            item.state,
            error: item.error,
          ),
        );
      }
      if (!cancelled) {
        binding.task.failedItems = binding.task.items
            .where((item) => item.state == TransferItemState.failed)
            .length;
      }
      _emit(
        TransferQueueTaskEvent(
          binding.task.id,
          binding.task.state,
          error: binding.task.error,
        ),
      );
    } finally {
      await subscription.cancel();
      if (_isCurrent(binding, job, generation) &&
          identical(binding.progressSubscription, subscription)) {
        binding.progressSubscription = null;
      }
    }
  }

  TransferItem? _recordEntryProgress(
    _ArchiveTaskBinding binding,
    LocalArchiveProgress progress,
  ) {
    final entryName = progress.entryName;
    if (entryName == null || entryName.isEmpty) {
      binding.lastCompletedEntries = progress.completedEntries;
      return null;
    }

    var item = binding.items[entryName];
    if (item == null) {
      final isDirectory = progress.entryIsDirectory ?? entryName.endsWith('/');
      final displayPath = isDirectory && entryName.endsWith('/')
          ? entryName.substring(0, entryName.length - 1)
          : entryName;
      item =
          TransferItem(
              id: '${binding.task.id}:$entryName',
              sourcePath: displayPath,
              isDirectory: isDirectory,
              destinationPath: _itemDestination(binding, entryName),
              size: progress.entryTotalBytes,
            )
            ..state = TransferItemState.active
            ..transferredBytes = progress.entryProcessedBytes;
      binding.items[entryName] = item;
      binding.task.items.add(item);
      _emit(
        TransferQueueItemEvent(
          binding.task.id,
          item.id,
          TransferItemState.active,
        ),
      );
    }

    item.transferredBytes = progress.entryProcessedBytes;
    if (progress.completedEntries > binding.lastCompletedEntries &&
        item.state != TransferItemState.completed) {
      item.state = TransferItemState.completed;
      _emit(
        TransferQueueItemEvent(
          binding.task.id,
          item.id,
          TransferItemState.completed,
        ),
      );
    }
    binding.lastCompletedEntries = progress.completedEntries;
    return item;
  }

  String _itemDestination(_ArchiveTaskBinding binding, String entryName) {
    if (binding.presentation.kind == AppTaskKind.archiveCreate) {
      return binding.outputPath;
    }

    return p.joinAll([
      binding.outputPath,
      ...entryName.split('/').where((part) => part.isNotEmpty),
    ]);
  }

  void _rebaseOutput(_ArchiveTaskBinding binding, String destinationPath) {
    binding.outputPath = destinationPath;
    final taskDestination =
        binding.presentation.kind == AppTaskKind.archiveExtract
        ? destinationPath
        : p.dirname(destinationPath);
    binding.task.updateDestinationDirectory(taskDestination);
    for (final entry in binding.items.entries) {
      entry.value.destinationPath = _itemDestination(binding, entry.key);
    }
  }

  void _failToStart(_ArchiveTaskBinding binding, Object error) {
    binding.task
      ..state = TransferTaskState.failed
      ..finishedAt = DateTime.now()
      ..scanComplete = true
      ..failedItems = binding.task.items
          .where((item) => item.state == TransferItemState.failed)
          .length
      ..error = error.toString();
    _emit(
      TransferQueueTaskEvent(
        binding.task.id,
        TransferTaskState.failed,
        error: binding.task.error,
      ),
    );
  }

  bool _isCurrent(
    _ArchiveTaskBinding binding,
    LocalArchiveJob job,
    int generation,
  ) => identical(binding.job, job) && binding.generation == generation;

  void _trackCancellationCleanup(Future<void> settling) {
    if (!_cancellationCleanups.add(settling)) return;
    unawaited(
      settling.whenComplete(() => _cancellationCleanups.remove(settling)),
    );
  }

  void _emit(TransferQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

final class _ArchiveTaskBinding {
  _ArchiveTaskBinding({
    required this.task,
    required this.presentation,
    required this.start,
    required this.requestedDestinationDirectory,
    required this.requestedOutputPath,
  }) : outputPath = requestedOutputPath;

  final _ArchiveTransferTask task;
  final AppTaskPresentation presentation;
  final LocalArchiveJob Function() start;
  final String requestedDestinationDirectory;
  final String requestedOutputPath;
  String outputPath;
  LocalArchiveJob? job;
  StreamSubscription<LocalArchiveProgress>? progressSubscription;
  Future<void>? settling;
  int generation = 0;
  bool hasPrepared = false;
  int lastCompletedEntries = 0;
  final items = <String, TransferItem>{};
}

/// Session-only adapter whose effective destination may change after Keep
/// Both without weakening the persisted transfer task model.
final class _ArchiveTransferTask extends TransferTask {
  // The explicit parameter initializes the backing spec before its
  // overridden getter can be observed.
  // ignore: use_super_parameters
  _ArchiveTransferTask(TransferTaskSpec initialSpec)
    : _archiveSpec = initialSpec,
      super(initialSpec);

  TransferTaskSpec _archiveSpec;

  @override
  TransferTaskSpec get spec => _archiveSpec;

  void updateDestinationDirectory(String destinationDirectory) {
    final current = _archiveSpec;
    _archiveSpec = TransferTaskSpec(
      source: current.source,
      destination: current.destination,
      rootPaths: current.rootPaths,
      destinationDir: destinationDirectory,
      policy: current.policy,
      operation: current.operation,
      disposition: current.disposition,
      managedCheckout: current.managedCheckout,
      produce: current.produce,
    );
  }
}
