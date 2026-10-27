import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerListStats;

import '../ui/charts/time_series.dart';

/// How many reads one container's charts keep: half an hour at the
/// engine's 5 s stats cadence (CST-01 [E]).
const kContainerUsageCapacity = 360;

/// How long between two reads before the charts break the line rather
/// than join them: four stats rounds, as when the container's row left
/// the screen and nothing pinned its stats.
const _gapAfter = Duration(seconds: 20);

/// The memory share of its limit from which a container reads as at risk
/// of an OOM kill (CST-04) [E].
const kMemoryRiskShare = 0.9;

/// One container's list stats since this device began reading them
/// (CST-03): a ring per chart, fed by every stats round that names it.
/// Network and block I/O arrive as totals since the container started;
/// the rings hold their rates between two reads, and none across a
/// total that went down, as after a restart, or across a gap, whose
/// totals would average the whole break into one point.
final class ContainerUsageHistory {
  ContainerUsageHistory({int capacity = kContainerUsageCapacity})
    : cpu = TimeSeriesRing(capacity: capacity, lanes: 1),
      memory = TimeSeriesRing(capacity: capacity, lanes: 2),
      network = TimeSeriesRing(capacity: capacity, lanes: 2),
      blockIo = TimeSeriesRing(capacity: capacity, lanes: 2),
      pids = TimeSeriesRing(capacity: capacity, lanes: 1);

  /// CPU % of one core times the cores.
  final TimeSeriesRing cpu;

  /// Bytes in use, then the limit.
  final TimeSeriesRing memory;

  /// Bytes a second in, then out.
  final TimeSeriesRing network;

  /// Bytes a second read, then written.
  final TimeSeriesRing blockIo;

  final TimeSeriesRing pids;

  ContainerListStats? _latest;

  /// The newest read; null before the first.
  ContainerListStats? get latest => _latest;

  List<TimeSeriesRing> get _rings => [cpu, memory, network, blockIo, pids];

  /// Takes [row], a read newer than the last; a repeat or an older one is
  /// ignored.
  void add(ContainerListStats row) {
    final last = _latest;
    if (last != null && !row.at.isAfter(last.at)) return;

    final span = last == null ? null : row.at.difference(last.at);
    final broke = last != null && span! > _gapAfter;
    if (broke) {
      for (final ring in _rings) {
        ring.openGap(last.at, ChartGapReason.readingFailed);
      }
    }
    final before = broke ? null : last;
    cpu.add(row.at, [row.cpuPercent]);
    memory.add(row.at, [
      row.memoryUsed?.toDouble(),
      row.memoryLimit?.toDouble(),
    ]);
    network.add(row.at, [
      _rate(before?.networkRx, row.networkRx, span),
      _rate(before?.networkTx, row.networkTx, span),
    ]);
    blockIo.add(row.at, [
      _rate(before?.blockRead, row.blockRead, span),
      _rate(before?.blockWrite, row.blockWrite, span),
    ]);
    pids.add(row.at, [row.pids?.toDouble()]);
    _latest = row;
  }

  void dispose() {
    for (final ring in _rings) {
      ring.dispose();
    }
  }
}

/// The rate between two totals [span] apart; null without both, across a
/// total that went down, or over no time.
double? _rate(int? before, int? now, Duration? span) {
  if (before == null || now == null || span == null || now < before) {
    return null;
  }
  if (span <= Duration.zero) return null;
  return (now - before) * Duration.microsecondsPerSecond / span.inMicroseconds;
}

/// The share of its limit [row]'s memory uses (CST-04), or null without
/// both or with no limit.
double? memoryLimitShare(ContainerListStats row) {
  final used = row.memoryUsed;
  final limit = row.memoryLimit;
  if (used == null || limit == null || limit <= 0) return null;
  return used / limit;
}
