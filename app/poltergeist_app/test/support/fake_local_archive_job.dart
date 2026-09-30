import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

/// Controllable archive job for app-side queue and composition tests.
final class FakeLocalArchiveJob implements LocalArchiveJob {
  FakeLocalArchiveJob({required this.operation, String? id})
    : id = id ?? 'archive-${_nextId++}';

  static int _nextId = 1;

  @override
  final String id;

  @override
  final LocalArchiveOperation operation;

  final _progress = StreamController<LocalArchiveProgress>.broadcast(
    sync: true,
  );
  final _done = Completer<LocalArchiveResult>.sync();
  var pauseCalls = 0;
  var resumeCalls = 0;
  var cancelCalls = 0;
  var _paused = false;
  var _cancelled = false;

  @override
  Stream<LocalArchiveProgress> get progress => _progress.stream;

  @override
  Future<LocalArchiveResult> get done => _done.future;

  @override
  bool get isPaused => _paused;

  @override
  bool get isCancelled => _cancelled;

  bool get isDone => _done.isCompleted;

  @override
  void pause() {
    if (_done.isCompleted || _cancelled) return;
    pauseCalls++;
    _paused = true;
  }

  @override
  void resume() {
    if (_done.isCompleted || _cancelled || !_paused) return;
    resumeCalls++;
    _paused = false;
  }

  @override
  void cancel() {
    if (_done.isCompleted || _cancelled) return;
    cancelCalls++;
    _cancelled = true;
  }

  void emit({
    required LocalArchivePhase phase,
    required int completedEntries,
    required int totalEntries,
    required int processedBytes,
    required int totalBytes,
    String? entryName,
    bool? entryIsDirectory,
    int entryProcessedBytes = 0,
    int entryTotalBytes = 0,
  }) {
    _progress.add(
      LocalArchiveProgress(
        operation: operation,
        phase: phase,
        completedEntries: completedEntries,
        totalEntries: totalEntries,
        processedBytes: processedBytes,
        totalBytes: totalBytes,
        entryName: entryName,
        entryIsDirectory: entryIsDirectory,
        entryProcessedBytes: entryProcessedBytes,
        entryTotalBytes: entryTotalBytes,
      ),
    );
  }

  void succeed({
    required String requestedDestinationPath,
    String? destinationPath,
    int entries = 1,
    int uncompressedBytes = 1,
  }) {
    _done.complete(
      LocalArchiveResult(
        operation: operation,
        requestedDestinationPath: requestedDestinationPath,
        destinationPath: destinationPath ?? requestedDestinationPath,
        entries: entries,
        uncompressedBytes: uncompressedBytes,
      ),
    );
  }

  void fail([LocalArchiveErrorKind kind = LocalArchiveErrorKind.io]) {
    _done.completeError(LocalArchiveException(kind, 'scripted failure'));
  }

  Future<void> close() => _progress.close();
}
