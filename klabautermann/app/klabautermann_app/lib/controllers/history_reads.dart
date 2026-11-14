import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// The on-device history reads (HIS-01, 03 §7.20): each [read] asks the
/// engine for a server's buckets and gaps in one tier and completes with
/// its answer. A stopped engine answers nothing recorded.
final class HistoryReads {
  HistoryReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          HistoryRead(:final requestId, :final range) => (requestId, range),
          _ => null,
        },
      );

  final EngineReads<HistoryRange> _reads;
  var _count = 0;

  static const _empty = HistoryRange(buckets: [], gaps: []);

  /// [serverId]'s history in [tier].
  Future<HistoryRange> read(String serverId, HistoryTier tier) {
    final requestId = 'rollup-${_count++}';
    return _reads.read(
      requestId,
      ReadHistory(serverId, tier, requestId: requestId),
      () => _empty,
    );
  }

  void dispose() => _reads.dispose();
}
