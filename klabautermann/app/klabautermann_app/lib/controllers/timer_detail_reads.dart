import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// JOB-02's timer reads (03 §7.7, D57): each [read] asks the engine for
/// one timer's triggers and completes with its [TimerDetailReport]. A
/// concern of its own for one engine run, beside the monitoring
/// controller, as the accounts reads are. A stopped engine, or one that
/// stops before it answers, answers [TimerDetailFailure.noLink].
final class TimerDetailReads {
  TimerDetailReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, (String, String, Completer<TimerDetailReport>)> _pending =
      {};
  var _count = 0;
  bool _engineStopped = false;

  /// [unit]'s triggers on [serverId] as they are now.
  Future<TimerDetailReport> read(String serverId, String unit) {
    final requestId = 'timer-detail-${_count++}';
    if (_engineStopped) {
      return Future.value(_noLink(serverId, requestId, unit));
    }
    final answer = Completer<TimerDetailReport>();
    _pending[requestId] = (serverId, unit, answer);
    try {
      _engine.send(ReadTimerDetail(serverId, unit, requestId: requestId));
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_noLink(serverId, requestId, unit));
    }
    return answer.future;
  }

  static TimerDetailReport _noLink(
    String serverId,
    String requestId,
    String unit,
  ) => TimerDetailReport(
    serverId: serverId,
    requestId: requestId,
    unit: unit,
    user: false,
    failure: TimerDetailFailure.noLink,
  );

  void _onEvent(EngineEvent event) {
    if (event case TimerDetailReport(:final requestId)) {
      _pending.remove(requestId)?.$3.complete(event);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final MapEntry(key: requestId, value: (serverId, unit, answer))
        in _pending.entries) {
      answer.complete(_noLink(serverId, requestId, unit));
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
