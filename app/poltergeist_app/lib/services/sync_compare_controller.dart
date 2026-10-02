import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

/// One half of a sync comparison.
sealed class SyncCompareSource {
  const SyncCompareSource({
    required this.side,
    required this.fullPath,
    required this.snapshot,
  });

  final SyncSide side;
  final String fullPath;
  final EntrySnapshot snapshot;
}

/// A comparison source already available on the local filesystem.
final class LocalSyncCompareSource extends SyncCompareSource {
  const LocalSyncCompareSource({
    required super.side,
    required super.fullPath,
    required super.snapshot,
  });
}

/// A comparison source that must be materialized through the preview lane.
final class RemoteSyncCompareSource extends SyncCompareSource {
  const RemoteSyncCompareSource({
    required super.side,
    required super.fullPath,
    required super.snapshot,
    required this.serverId,
  });

  final String serverId;
}

/// The canonical pair of sources opened by a sync-plan row.
final class SyncCompareRequest {
  SyncCompareRequest({
    required this.relativePath,
    required this.left,
    required this.right,
  }) : assert(left.side == SyncSide.left),
       assert(right.side == SyncSide.right);

  final String relativePath;
  final SyncCompareSource left;
  final SyncCompareSource right;
}

enum SyncComparePhase {
  loading,
  confirming,
  downloading,
  gateConfirm,
  ready,
  refused,
  cancelled,
  failed,
}

enum SyncCompareRefusal {
  editorLimit,
  cacheUnavailable,
  producerUnavailable,
  cacheLimit,
}

enum SyncCompareFailure { invalidUtf8, binary, changed, missing, other }

/// Immutable view state for one comparison column.
final class SyncCompareSideState {
  const SyncCompareSideState._({
    required this.source,
    required this.phase,
    required this.document,
    required this.refusal,
    required this.failure,
    required this.transferred,
    required this.totalBytes,
  });

  final SyncCompareSource source;
  final SyncComparePhase phase;
  final BuiltInTextDocument? document;
  final SyncCompareRefusal? refusal;
  final SyncCompareFailure? failure;
  final int transferred;
  final int? totalBytes;

  String get fullPath => source.fullPath;
  EntrySnapshot get snapshot => source.snapshot;
}

/// Loads the two sides independently and materializes remote bytes safely.
final class SyncCompareController extends ChangeNotifier {
  SyncCompareController({
    required this.request,
    PreviewCache? previewCache,
    PreviewProducer? previewProducer,
    required int Function() largeDownloadThresholdBytes,
  }) : _cache = previewCache,
       _producer = previewProducer,
       // Keep the public constructor label free of a private underscore.
       // ignore: prefer_initializing_formals
       _largeDownloadThresholdBytes = largeDownloadThresholdBytes,
       _left = _SideOperation(request.left),
       _right = _SideOperation(request.right);

  final SyncCompareRequest request;
  final PreviewCache? _cache;
  final PreviewProducer? _producer;
  final int Function() _largeDownloadThresholdBytes;
  final _SideOperation _left;
  final _SideOperation _right;

  Future<void>? _startFuture;
  bool _disposed = false;

  SyncCompareSideState get left => _left.state;
  SyncCompareSideState get right => _right.state;

  Future<void> start() =>
      _startFuture ??= Future.wait([_load(_left), _load(_right)]);

  void confirm(SyncSide side) {
    final operation = _operation(side);
    if (_disposed || operation.cancelRequested) return;

    final confirmation = operation.confirmation;
    if (confirmation != null && !confirmation.isCompleted) {
      confirmation.complete(true);
      _setPhase(operation, SyncComparePhase.downloading);
      return;
    }

    final gate = operation.gate;
    if (gate == null || !gate.isAwaitingConfirmation) return;
    gate.confirm();
    _setPhase(operation, SyncComparePhase.downloading);
  }

  void cancel(SyncSide side) {
    final operation = _operation(side);
    if (_disposed || _isTerminal(operation.phase)) return;

    operation.cancelRequested = true;
    operation.signalCancellation();
    final confirmation = operation.confirmation;
    if (confirmation != null && !confirmation.isCompleted) {
      confirmation.complete(false);
    }
    operation.gate?.deny();
    _cancelTicket(operation);
    _setPhase(operation, SyncComparePhase.cancelled);
  }

  Future<void> _load(_SideOperation operation) async {
    if (_stopped(operation)) return;

    final source = operation.source;
    final knownSize = operation.source.snapshot.size;
    if (source is RemoteSyncCompareSource &&
        knownSize != null &&
        knownSize > builtInEditorMaximumBytes) {
      _refuse(operation, SyncCompareRefusal.editorLimit);
      return;
    }

    try {
      if (source is LocalSyncCompareSource) {
        await _loadDocument(operation, File(source.fullPath));
        return;
      }

      await _loadRemote(operation, source as RemoteSyncCompareSource);
    } on CheckoutLimitException {
      _refuse(
        operation,
        operation.limitRefusal ?? SyncCompareRefusal.editorLimit,
      );
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.cancelled) {
        _cancelled(operation);
        return;
      }
      final failure = error.kind == RemoteFileErrorKind.notFound
          ? SyncCompareFailure.missing
          : SyncCompareFailure.other;
      _fail(operation, failure);
    } on Object {
      _fail(operation, SyncCompareFailure.other);
    }
  }

  Future<void> _loadRemote(
    _SideOperation operation,
    RemoteSyncCompareSource source,
  ) async {
    final cache = _cache;
    if (cache == null) {
      _refuse(operation, SyncCompareRefusal.cacheUnavailable);
      return;
    }

    final key = _cacheKey(source);
    final cached = await _lookupReserved(operation, cache, key);
    if (_stopped(operation)) return;
    if (cached != null) {
      await _loadDocument(operation, cached);
      return;
    }

    final size = source.snapshot.size;
    if (size != null && !cache.canAccommodate(size)) {
      _refuse(operation, SyncCompareRefusal.cacheLimit);
      return;
    }

    final producer = _producer;
    if (producer == null) {
      _refuse(operation, SyncCompareRefusal.producerUnavailable);
      return;
    }

    if (size != null && size > _largeDownloadThresholdBytes()) {
      final confirmation = Completer<bool>();
      operation.confirmation = confirmation;
      _setPhase(operation, SyncComparePhase.confirming);
      final accepted = await confirmation.future;
      operation.confirmation = null;
      if (!accepted || _stopped(operation)) return;
      operation.knownSizeConfirmed = true;
    }

    _setPhase(operation, SyncComparePhase.downloading);
    final file = await _materialize(operation, source, cache, producer, key);
    if (file == null || _stopped(operation)) return;
    await _loadDocument(operation, file);
  }

  Future<File?> _materialize(
    _SideOperation operation,
    RemoteSyncCompareSource source,
    PreviewCache cache,
    PreviewProducer producer,
    String key,
  ) async {
    final reservation = await cache.reserveProduction(
      key,
      cancellation: operation.cancellation,
    );
    if (reservation == null) return null;
    try {
      if (_stopped(operation)) return null;

      // A peer may have filled the cache while this side waited.
      final cached = await cache.lookup(key);
      if (cached != null || _stopped(operation)) return cached;

      return await _produce(operation, source, cache, producer, key);
    } finally {
      reservation.release();
    }
  }

  Future<File?> _lookupReserved(
    _SideOperation operation,
    PreviewCache cache,
    String key,
  ) async {
    final reservation = await cache.reserveProduction(
      key,
      cancellation: operation.cancellation,
    );
    if (reservation == null) return null;
    try {
      if (_stopped(operation)) return null;
      return await cache.lookup(key);
    } finally {
      reservation.release();
    }
  }

  Future<File?> _produce(
    _SideOperation operation,
    RemoteSyncCompareSource source,
    PreviewCache cache,
    PreviewProducer producer,
    String key,
  ) async {
    final size = source.snapshot.size;
    final cacheCap = cache.capacityBytes;
    final maximumBytes = cacheCap < builtInEditorMaximumBytes
        ? cacheCap
        : builtInEditorMaximumBytes;
    operation.limitRefusal = cacheCap < builtInEditorMaximumBytes
        ? SyncCompareRefusal.cacheLimit
        : SyncCompareRefusal.editorLimit;
    final slot = await cache.prepare(
      key,
      extension: previewRawExtension(source.fullPath),
      expectedBytes: size,
    );
    operation.slot = slot;
    if (_stopped(operation)) {
      await slot.abort();
      operation.slot = null;
      return null;
    }

    final gate = size == null || !operation.knownSizeConfirmed
        ? PreviewByteGate(
            thresholdBytes: _largeDownloadThresholdBytes(),
            onThresholdReached: (transferred) {
              if (_stopped(operation)) return;
              operation.transferred = transferred;
              _setPhase(operation, SyncComparePhase.gateConfirm);
            },
          )
        : null;
    operation.gate = gate;

    try {
      final ticket = producer.start(
        PreviewProduceSpec(
          serverId: source.serverId,
          remotePath: source.fullPath,
          destinationPath: slot.tempFile.path,
          expectedSize: size,
          maximumBytes: maximumBytes,
          gate: gate,
          onProgress: (transferred, total) {
            if (_stopped(operation)) return;
            operation.transferred = transferred;
            operation.totalBytes = total ?? operation.totalBytes;
            _notify();
          },
        ),
      );
      operation.ticket = ticket;
      await ticket.result;
      operation.ticket = null;
      if (_stopped(operation)) {
        await slot.abort();
        operation.slot = null;
        return null;
      }

      final file = await slot.commit();
      operation.slot = null;
      if (!await file.exists()) {
        _refuse(operation, SyncCompareRefusal.cacheLimit);
        return null;
      }
      return file;
    } on Object {
      operation.ticket = null;
      await slot.abort();
      operation.slot = null;
      rethrow;
    } finally {
      operation.gate = null;
    }
  }

  Future<void> _loadDocument(_SideOperation operation, File file) async {
    if (_stopped(operation)) return;

    try {
      final document = await loadBuiltInTextDocumentDetails(
        file,
        maximumBytes: builtInEditorMaximumBytes,
      );
      if (_stopped(operation)) return;
      operation.document = document;
      operation.refusal = null;
      operation.failure = null;
      _setPhase(operation, SyncComparePhase.ready);
    } on BuiltInEditorException catch (error) {
      if (await _exceedsEditorLimit(file)) {
        _refuse(operation, SyncCompareRefusal.editorLimit);
        return;
      }
      _fail(operation, _failureFor(error));
    } on FileSystemException {
      final failure = await file.exists()
          ? SyncCompareFailure.other
          : SyncCompareFailure.missing;
      _fail(operation, failure);
    }
  }

  Future<bool> _exceedsEditorLimit(File file) async {
    try {
      return await file.length() > builtInEditorMaximumBytes;
    } on FileSystemException {
      return false;
    }
  }

  String _cacheKey(RemoteSyncCompareSource source) {
    final mtimeSecs = source.snapshot.mtimeSecs;
    final modifiedAt = mtimeSecs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            mtimeSecs * Duration.millisecondsPerSecond,
            isUtc: true,
          );
    return previewCacheKey(
      source.serverId,
      source.fullPath,
      modifiedAt,
      source.snapshot.size,
    );
  }

  _SideOperation _operation(SyncSide side) => switch (side) {
    SyncSide.left => _left,
    SyncSide.right => _right,
  };

  bool _stopped(_SideOperation operation) =>
      _disposed || operation.cancelRequested;

  static bool _isTerminal(SyncComparePhase phase) => switch (phase) {
    SyncComparePhase.ready ||
    SyncComparePhase.refused ||
    SyncComparePhase.cancelled ||
    SyncComparePhase.failed => true,
    _ => false,
  };

  void _setPhase(_SideOperation operation, SyncComparePhase phase) {
    if (_disposed) return;
    operation.phase = phase;
    _notify();
  }

  void _refuse(_SideOperation operation, SyncCompareRefusal refusal) {
    if (_stopped(operation)) return;
    operation.document = null;
    operation.refusal = refusal;
    operation.failure = null;
    _setPhase(operation, SyncComparePhase.refused);
  }

  void _cancelled(_SideOperation operation) {
    if (_disposed) return;
    operation.cancelRequested = true;
    operation.document = null;
    operation.refusal = null;
    operation.failure = null;
    _setPhase(operation, SyncComparePhase.cancelled);
  }

  void _fail(_SideOperation operation, SyncCompareFailure failure) {
    if (_stopped(operation)) return;
    operation.document = null;
    operation.refusal = null;
    operation.failure = failure;
    _setPhase(operation, SyncComparePhase.failed);
  }

  SyncCompareFailure _failureFor(BuiltInEditorException error) =>
      switch (classifyBuiltInTextDocumentFailure(error)) {
        BuiltInTextDocumentFailure.invalidUtf8 =>
          SyncCompareFailure.invalidUtf8,
        BuiltInTextDocumentFailure.binary => SyncCompareFailure.binary,
        BuiltInTextDocumentFailure.changed => SyncCompareFailure.changed,
        BuiltInTextDocumentFailure.missing => SyncCompareFailure.missing,
        BuiltInTextDocumentFailure.other => SyncCompareFailure.other,
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _cancelTicket(_SideOperation operation) {
    final ticket = operation.ticket;
    final producer = _producer;
    if (ticket == null || producer == null) return;
    try {
      producer.cancel(ticket.taskId);
    } on Object {
      // Cancellation is best-effort; the ticket's terminal result still wins.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final operation in [_left, _right]) {
      operation.cancelRequested = true;
      operation.signalCancellation();
      final confirmation = operation.confirmation;
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete(false);
      }
      operation.gate?.deny();
      _cancelTicket(operation);
      final slot = operation.slot;
      if (slot != null) unawaited(slot.abort());
    }
    super.dispose();
  }
}

final class _SideOperation {
  _SideOperation(this.source) : totalBytes = source.snapshot.size;

  final SyncCompareSource source;
  SyncComparePhase phase = SyncComparePhase.loading;
  BuiltInTextDocument? document;
  SyncCompareRefusal? refusal;
  SyncCompareFailure? failure;
  int transferred = 0;
  int? totalBytes;
  bool cancelRequested = false;
  bool knownSizeConfirmed = false;
  Completer<bool>? confirmation;
  PreviewByteGate? gate;
  PreviewProduceTicket? ticket;
  PreviewCacheSlot? slot;
  SyncCompareRefusal? limitRefusal;
  final _cancellation = Completer<void>();

  Future<void> get cancellation => _cancellation.future;

  void signalCancellation() {
    if (!_cancellation.isCompleted) _cancellation.complete();
  }

  SyncCompareSideState get state => SyncCompareSideState._(
    source: source,
    phase: phase,
    document: document,
    refusal: refusal,
    failure: failure,
    transferred: transferred,
    totalBytes: totalBytes,
  );
}
