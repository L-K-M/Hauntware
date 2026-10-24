import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// JOB-05's reads (03 §7.7): a timer's last trigger and how its service
/// ended, and the job starts cron logged, each one [JobHistoryQuery]
/// answered by its [JobHistoryResult]. A concern of its own for one
/// engine run, listening to the engine beside the monitoring controller.
final class JobHistoryReads {
  JobHistoryReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, Completer<JobHistoryPayload>> _pending = {};
  var _count = 0;
  bool _engineStopped = false;

  /// Reads [spec] on [serverId]. A stopped engine, or one that stops
  /// before it answers, answers [JobHistoryFailure.noLink].
  Future<JobHistoryPayload> read(String serverId, JobHistorySpec spec) {
    if (_engineStopped) return Future.value(_noLink);
    final requestId = 'history-${_count++}';
    final answer = _pending[requestId] = Completer<JobHistoryPayload>();
    try {
      _engine.send(
        JobHistoryQuery(serverId: serverId, requestId: requestId, query: spec),
      );
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_noLink);
    }
    return answer.future;
  }

  static const _noLink = JobHistoryFailed(JobHistoryFailure.noLink);

  void _onEvent(EngineEvent event) {
    if (event case JobHistoryResult(:final requestId, :final payload)) {
      _pending.remove(requestId)?.complete(payload);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final answer in _pending.values) {
      answer.complete(_noLink);
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
