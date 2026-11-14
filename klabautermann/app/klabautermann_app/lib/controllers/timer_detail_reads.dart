import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// JOB-02's timer reads (03 §7.7, D57): each [read] asks the engine for
/// one timer's triggers and completes with its [TimerDetailReport]. A
/// concern of its own for one engine run, beside the monitoring
/// controller, as the accounts reads are. A stopped engine, or one that
/// stops before it answers, answers [TimerDetailFailure.noLink].
final class TimerDetailReads {
  TimerDetailReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          TimerDetailReport(:final requestId) => (requestId, event),
          _ => null,
        },
      );

  final EngineReads<TimerDetailReport> _reads;
  var _count = 0;

  /// [unit]'s triggers on [serverId] as they are now.
  Future<TimerDetailReport> read(String serverId, String unit) {
    final requestId = 'timer-detail-${_count++}';
    return _reads.read(
      requestId,
      ReadTimerDetail(serverId, unit, requestId: requestId),
      () => TimerDetailReport(
        serverId: serverId,
        requestId: requestId,
        unit: unit,
        user: false,
        failure: TimerDetailFailure.noLink,
      ),
    );
  }

  void dispose() => _reads.dispose();
}
