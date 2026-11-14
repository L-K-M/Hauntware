import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// DSK-07's folder reads (03 §7.3): each [read] asks the engine for one
/// folder of a server and completes with its [DiskUsageReport]. A concern
/// of its own for one engine run, beside the monitoring controller, as
/// the accounts reads are. A stopped engine, or one that stops before it
/// answers, answers [DiskUsageReportFailure.noLink].
final class DiskUsageReads {
  DiskUsageReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          DiskUsageReport(:final requestId) => (requestId, event),
          _ => null,
        },
      );

  final EngineReads<DiskUsageReport> _reads;
  var _count = 0;

  /// [path] on [serverId]; as root through admin mode when [elevated].
  /// [root] is the mount point the explorer started at, whose whole
  /// filesystem the engine may read once and answer each folder from;
  /// [fresh] reads again rather than answering from that.
  Future<DiskUsageReport> read(
    String serverId,
    String path, {
    bool elevated = false,
    String? root,
    bool fresh = false,
  }) {
    final requestId = 'disk-usage-${_count++}';
    return _reads.read(
      requestId,
      ReadDiskUsage(
        serverId,
        path,
        requestId: requestId,
        elevated: elevated,
        root: root,
        fresh: fresh,
      ),
      () => DiskUsageReport(
        serverId: serverId,
        requestId: requestId,
        path: path,
        failure: DiskUsageReportFailure.noLink,
      ),
    );
  }

  void dispose() => _reads.dispose();
}
