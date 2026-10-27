import 'package:flutter/foundation.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostSessionState;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart' show FleetServer;
import 'fleet_row_state.dart' show kFleetRowStaleAfter;

/// FL-10's order: the servers with open problems first, most first, then
/// the rest, each run in fleet order, so a server with nothing wrong
/// never moves.
List<FleetServer> attentionFirst(
  List<FleetServer> servers,
  Map<String, int> openProblems,
) {
  final indexed = servers.indexed.toList()
    ..sort((a, b) {
      final byProblems = (openProblems[b.$2.id] ?? 0).compareTo(
        openProblems[a.$2.id] ?? 0,
      );
      return byProblems != 0 ? byProblems : a.$1.compareTo(b.$1);
    });
  return [for (final (_, server) in indexed) server];
}

/// FL-09's fleet summary: how many servers answer, how many need
/// attention, and the CPU and memory of those whose readings are fresh.
@immutable
final class FleetSummary {
  const FleetSummary({
    required this.total,
    required this.online,
    required this.needAttention,
    required this.reporting,
    this.cpuPercent,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
  });

  final int total;

  /// Servers whose link is up or whose probe answered.
  final int online;

  /// Servers with at least one open problem in the attention queue.
  final int needAttention;

  /// Servers with a fresh CPU or memory reading. The CPU average covers
  /// those that reported CPU, the memory sums those that reported both
  /// used and total memory.
  final int reporting;

  /// The mean CPU busy share of the [reporting] servers; null when none.
  final double? cpuPercent;

  /// The memory the [reporting] servers use and have, summed; null when
  /// none reported memory.
  final int? memoryUsedBytes, memoryTotalBytes;
}

/// [servers]' summary from each one's link [session], [probe] answer and
/// latest [overview] or [core] sample at [now]. A reading counts while its
/// link is up and it is younger than the fleet rows' stale limit, as a
/// row's pressure bar does (03 §10.3).
FleetSummary fleetSummary({
  required List<FleetServer> servers,
  required GhostSessionState Function(String serverId) session,
  required ReachabilityStatus? Function(String serverId) probe,
  required Sample? Function(String serverId) overview,
  required Sample? Function(String serverId) core,
  required Map<String, int> openProblems,
  required DateTime now,
}) {
  var online = 0;
  var reporting = 0;
  var cpuSum = 0.0;
  var cpuCount = 0;
  int? used;
  int? total;
  for (final server in servers) {
    final link = session(server.id);
    final up = link == GhostSessionState.connected;
    if (up || probe(server.id) == ReachabilityStatus.online) online++;
    if (!up) continue;

    final sample = _newer(overview(server.id), core(server.id));
    if (sample == null) continue;
    if (now.difference(sample.at) >= kFleetRowStaleAfter[sample.stream]!) {
      continue;
    }
    final (cpu, memory) = switch (sample.result) {
      OverviewResult(:final cpu, :final memory) ||
      CoreResult(:final cpu, :final memory) => (cpu, memory),
      _ => (null, null),
    };
    if (cpu == null && memory == null) continue;

    reporting++;
    if (cpu?.busy case final busy?) {
      cpuSum += busy;
      cpuCount++;
    }
    if ((memory?.usedBytes, memory?.totalBytes) case (
      final u?,
      final t?,
    ) when t > 0) {
      used = (used ?? 0) + u;
      total = (total ?? 0) + t;
    }
  }
  return FleetSummary(
    total: servers.length,
    online: online,
    needAttention: servers
        .where((server) => (openProblems[server.id] ?? 0) > 0)
        .length,
    reporting: reporting,
    cpuPercent: cpuCount == 0 ? null : cpuSum / cpuCount,
    memoryUsedBytes: used,
    memoryTotalBytes: total,
  );
}

Sample? _newer(Sample? a, Sample? b) => switch ((a, b)) {
  (null, null) => null,
  (final only?, null) || (null, final only?) => only,
  (final x?, final y?) => x.at.isAfter(y.at) ? x : y,
};
