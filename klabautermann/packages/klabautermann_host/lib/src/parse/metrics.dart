/// Parsers for the `overview` and `core` fast-collector payloads
/// (03 §6.4, filtered on the host per D48). The payloads share their
/// sub-blocks; `core` carries everything `overview` has plus per-core
/// busy and idle jiffies, btime, diskstats, pressure, uptime and the ZFS
/// ARC.
library;

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'package:meta/meta.dart';

import 'models.dart';
import 'parse_result.dart';

/// One `overview` tick (03 §6.4): fleet-row metrics.
@immutable
final class OverviewSnapshot {
  OverviewSnapshot({
    this.cpu,
    Map<String, CoreCpuTimes>? perCpu,
    this.btime,
    required this.meminfo,
    this.loadavg,
    List<NetDevEntry>? netdev,
  }) : perCpu = Map.unmodifiable(perCpu ?? {}),
       netdev = List.unmodifiable(netdev ?? []);

  /// The aggregate `cpu` line, when the block carried one.
  final CpuTimes? cpu;

  /// Per-core busy and idle jiffies (normally empty on `overview`, kept
  /// when present).
  final Map<String, CoreCpuTimes> perCpu;

  /// Boot epoch from `btime` (normally only on `core`).
  final int? btime;

  /// Filtered meminfo; missing keys stay null (03 §6.1 "unknown stays
  /// unknown").
  final MemInfo meminfo;

  /// Load averages, when the block parsed.
  final LoadAvg? loadavg;

  /// Interface counters: of the device-backed interfaces, else of those
  /// that are neither a bridge nor enslaved, else of every interface but
  /// lo (D48).
  final List<NetDevEntry> netdev;

  Map<String, Object?> toJson() => {
    'cpu': cpu?.toJson(),
    'perCpu': perCpu.map((k, v) => MapEntry(k, v.toJson())),
    'btime': btime,
    'meminfo': meminfo.toJson(),
    'loadavg': loadavg?.toJson(),
    'netdev': netdev.map((e) => e.toJson()).toList(),
  };
}

/// One `core` tick (03 §6.4): the focused-server superset.
@immutable
final class CoreSnapshot extends OverviewSnapshot {
  CoreSnapshot({
    super.cpu,
    super.perCpu,
    super.btime,
    required super.meminfo,
    super.loadavg,
    super.netdev,
    List<DiskStatEntry>? diskstats,
    this.cpuPressure,
    this.ioPressure,
    this.memoryPressure,
    this.uptimeSeconds,
    this.idleSeconds,
    this.zfsArc,
  }) : diskstats = List.unmodifiable(diskstats ?? []);

  /// /proc/diskstats rows of whole disks (D48).
  final List<DiskStatEntry> diskstats;

  /// /proc/pressure/{cpu,io,memory}; absent blocks stay null because PSI
  /// absence is normal (03 §7.1).
  final Pressure? cpuPressure, ioPressure, memoryPressure;

  /// /proc/uptime fields 1 and 2; field 1 also rides the `B` marker.
  final double? uptimeSeconds, idleSeconds;

  /// The ZFS ARC; null on a host without /proc/spl/kstat/zfs/arcstats.
  final ZfsArc? zfsArc;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'diskstats': diskstats.map((e) => e.toJson()).toList(),
    'cpuPressure': cpuPressure?.toJson(),
    'ioPressure': ioPressure?.toJson(),
    'memoryPressure': memoryPressure?.toJson(),
    'uptimeSeconds': uptimeSeconds,
    'idleSeconds': idleSeconds,
    'zfsArc': zfsArc?.toJson(),
  };
}

/// Parses an `overview` section payload (03 §6.4, §6.5).
ParseResult<OverviewSnapshot> parseOverview(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final r = _parseMetricBlocks(raw, warnings);
  return ParseResult(
    OverviewSnapshot(
      cpu: r.stat.aggregate,
      perCpu: r.stat.cores,
      btime: r.stat.btime,
      meminfo: r.meminfo,
      loadavg: r.loadavg,
      netdev: r.netdev,
    ),
    warnings,
  );
}

/// Parses a `core` section payload (03 §6.4, §6.5).
ParseResult<CoreSnapshot> parseCore(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final r = _parseMetricBlocks(raw, warnings);
  final blocks = r.blocks;

  List<DiskStatEntry> diskstats;
  if (blocks.containsKey('diskstats')) {
    diskstats = parseDiskStatsBlock(blocks['diskstats']!, warnings);
  } else {
    warnings.add('core: missing diskstats block');
    diskstats = const [];
  }

  Pressure? pressure(String name) {
    final lines = blocks[name];
    if (lines == null || lines.isEmpty) return null;
    return parsePressureBlock(lines, warnings);
  }

  final uptime = blocks.containsKey('uptime')
      ? parseUptimeBlock(blocks['uptime']!, warnings)
      : null;

  return ParseResult(
    CoreSnapshot(
      cpu: r.stat.aggregate,
      perCpu: r.stat.cores,
      btime: r.stat.btime,
      meminfo: r.meminfo,
      loadavg: r.loadavg,
      netdev: r.netdev,
      diskstats: diskstats,
      cpuPressure: pressure('pressure_cpu'),
      ioPressure: pressure('pressure_io'),
      memoryPressure: pressure('pressure_memory'),
      uptimeSeconds: uptime?.uptimeSeconds,
      idleSeconds: uptime?.idleSeconds,
      zfsArc: switch (blocks['arcstats']) {
        final lines? => parseArcStatsBlock(lines, warnings),
        null => null,
      },
    ),
    warnings,
  );
}

/// The sub-blocks `overview` and `core` share (03 §6.4).
@immutable
final class _MetricBlocks {
  _MetricBlocks({
    required this.stat,
    required this.meminfo,
    this.loadavg,
    required this.netdev,
    required this.blocks,
  });

  final StatBlock stat;
  final MemInfo meminfo;
  final LoadAvg? loadavg;
  final List<NetDevEntry> netdev;
  final Map<String, List<String>> blocks;
}

_MetricBlocks _parseMetricBlocks(String raw, List<String> warnings) {
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('payload ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }
  final blocks = split.blocks;

  StatBlock stat;
  if (blocks.containsKey('stat')) {
    stat = parseStatBlock(blocks['stat']!, warnings);
  } else {
    warnings.add('missing stat block');
    stat = StatBlock();
  }

  MemInfo meminfo;
  if (blocks.containsKey('meminfo')) {
    meminfo = parseMemInfoBlock(blocks['meminfo']!, warnings);
  } else {
    warnings.add('missing meminfo block');
    meminfo = MemInfo(const {});
  }

  LoadAvg? loadavg;
  if (blocks.containsKey('loadavg')) {
    loadavg = parseLoadAvgBlock(blocks['loadavg']!, warnings);
  } else {
    warnings.add('missing loadavg block');
  }

  List<NetDevEntry> netdev;
  if (blocks.containsKey('netdev')) {
    netdev = parseNetDevBlock(blocks['netdev']!, warnings);
  } else {
    warnings.add('missing netdev block');
    netdev = const [];
  }

  return _MetricBlocks(
    stat: stat,
    meminfo: meminfo,
    loadavg: loadavg,
    netdev: netdev,
    blocks: blocks,
  );
}
