import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// The on-device history reads (HIS-01, 03 §7.20): each [read] asks the
/// engine for a server's buckets and gaps in one tier and completes with
/// its answer. A stopped engine answers nothing recorded.
final class HistoryReads {
  HistoryReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, Completer<HistoryRange>> _pending = {};
  var _count = 0;
  bool _engineStopped = false;

  static const _empty = HistoryRange(buckets: [], gaps: []);

  /// [serverId]'s history in [tier].
  Future<HistoryRange> read(String serverId, HistoryTier tier) {
    if (_engineStopped) return Future.value(_empty);
    final requestId = 'rollup-${_count++}';
    final answer = _pending[requestId] = Completer<HistoryRange>();
    try {
      _engine.send(ReadHistory(serverId, tier, requestId: requestId));
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_empty);
    }
    return answer.future;
  }

  void _onEvent(EngineEvent event) {
    if (event case HistoryRead(:final requestId, :final range)) {
      _pending.remove(requestId)?.complete(range);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final answer in _pending.values) {
      answer.complete(_empty);
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
