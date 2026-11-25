import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// The catalog-write bookkeeping the alert-rule, server-preference and
/// server-editor controllers share (03 §4.8): each [write] sends its
/// request under its own id and completes with the engine's
/// [CatalogWritten], or fails with [refuse] when the engine refused it or
/// stopped before it answered. One per concern, for one engine run.
final class CatalogWrites {
  CatalogWrites(this._engine, this._refuse, {this.settleOnRejection = false}) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;

  /// Builds the exception a refusal fails the write with, or the one the
  /// engine stopping before it answered builds when [failure] is null.
  final Exception Function(CatalogWriteFailure? failure, String? detail)
  _refuse;

  /// Whether a [RequestRejected] naming a pending write's id fails it,
  /// as ServerEditorController settled its ids; the rule and preference
  /// writes answer only [CatalogWritten] and [CatalogWriteRefused], and
  /// keep leaving a rejection alone.
  final bool settleOnRejection;

  late final StreamSubscription<EngineEvent> _events;
  final Map<String, Completer<CatalogWritten>> _pending = {};
  bool _engineStopped = false;

  /// Sends [request] under [requestId] and completes with the engine's
  /// answer, or fails with [refuse] when the engine is or goes away.
  Future<CatalogWritten> write(String requestId, EngineRequest request) {
    if (_engineStopped) return Future.error(_refuse(null, null));
    final written = Completer<CatalogWritten>();
    _pending[requestId] = written;
    try {
      _engine.send(request);
    } on StateError {
      _pending.remove(requestId);
      return Future.error(_refuse(null, null));
    }
    return written.future;
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case CatalogWritten(:final requestId):
        _pending.remove(requestId)?.complete(event);
      case CatalogWriteRefused(:final requestId, :final failure, :final detail):
        _pending.remove(requestId)?.completeError(_refuse(failure, detail));
      case RequestRejected(:final requestId?, :final reason)
          when settleOnRejection:
        _pending
            .remove(requestId)
            ?.completeError(_refuse(CatalogWriteFailure.other, reason));
      case _:
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final written in _pending.values) {
      written.completeError(_refuse(null, null));
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
