import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// JOB-05's reads (03 §7.7): a timer's last trigger and how its service
/// ended, and the job starts cron logged, each one [JobHistoryQuery]
/// answered by its [JobHistoryResult]. A concern of its own for one
/// engine run, listening to the engine beside the monitoring controller.
final class JobHistoryReads {
  JobHistoryReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          JobHistoryResult(:final requestId, :final payload) => (
            requestId,
            payload,
          ),
          _ => null,
        },
      );

  final EngineReads<JobHistoryPayload> _reads;
  var _count = 0;

  /// Reads [spec] on [serverId]. A stopped engine, or one that stops
  /// before it answers, answers [JobHistoryFailure.noLink].
  Future<JobHistoryPayload> read(String serverId, JobHistorySpec spec) {
    final requestId = 'history-${_count++}';
    return _reads.read(
      requestId,
      JobHistoryQuery(serverId: serverId, requestId: requestId, query: spec),
      () => _noLink,
    );
  }

  static const _noLink = JobHistoryFailed(JobHistoryFailure.noLink);

  void dispose() => _reads.dispose();
}
