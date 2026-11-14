import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// PKG-01 to PKG-03's reads (03 §7.8): each [read] asks the engine for a
/// server's package check, which the engine keeps for an hour, and
/// completes with its [PackagesReport]. A concern of its own for one
/// engine run, listening to the engine beside the monitoring controller.
final class PackageReads {
  PackageReads(EngineClient engine)
    : _reads = EngineReads(
        engine,
        (event) => switch (event) {
          PackagesReport(:final requestId) => (requestId, event),
          _ => null,
        },
        sendFailure: SendFailure.engineStopped,
      );

  final EngineReads<PackagesReport> _reads;
  var _count = 0;

  /// [serverId]'s check: the engine's kept one unless [fresh]. A stopped
  /// engine, or one that stops before it answers, answers
  /// [PackagesReportFailure.noLink]; so does every waiting read when the
  /// engine's port refuses one, as a closed port means a stopped engine.
  Future<PackagesReport> read(String serverId, {bool fresh = false}) {
    final requestId = 'packages-${_count++}';
    return _reads.read(
      requestId,
      ReadPackages(serverId, requestId: requestId, fresh: fresh),
      () => PackagesReport(
        serverId: serverId,
        requestId: requestId,
        failure: PackagesReportFailure.noLink,
      ),
    );
  }

  void dispose() => _reads.dispose();
}
