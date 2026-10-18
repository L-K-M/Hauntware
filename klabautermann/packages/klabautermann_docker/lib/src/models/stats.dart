import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../time.dart';

/// `cpu_stats` / `precpu_stats` (03 §5.6, §7.12 CST-01).
@immutable
final class CpuStats {
  const CpuStats({
    this.totalUsage,
    this.perCpuUsage = const [],
    this.usageInKernelmode,
    this.usageInUsermode,
    this.systemCpuUsage,
    this.onlineCpus,
  });

  final int? totalUsage;
  final List<int> perCpuUsage;
  final int? usageInKernelmode;
  final int? usageInUsermode;
  final int? systemCpuUsage;
  final int? onlineCpus;

  static CpuStats parse(JsonReader r) {
    final usage = r.map('cpu_usage');
    final ur = usage == null ? null : JsonReader(usage, r.warnings);
    return CpuStats(
      totalUsage: ur?.integer('total_usage'),
      perCpuUsage: [
        for (final e in ur?.list('percpu_usage') ?? const <Object?>[])
          if (e is int) e,
      ],
      usageInKernelmode: ur?.integer('usage_in_kernelmode'),
      usageInUsermode: ur?.integer('usage_in_usermode'),
      systemCpuUsage: r.integer('system_cpu_usage'),
      onlineCpus: r.integer('online_cpus'),
    );
  }
}

/// `memory_stats` (03 §5.6, §7.12 CST-01).
@immutable
final class MemoryStats {
  const MemoryStats({
    this.usage,
    this.maxUsage,
    this.limit,
    this.stats = const {},
  });

  final int? usage;
  final int? maxUsage;
  final int? limit;

  /// cgroup counters, including `inactive_file` (v2), `total_inactive_file`
  /// (v1) and `cache` (v1).
  final Map<String, int> stats;

  static MemoryStats parse(JsonReader r) {
    final stats = <String, int>{};
    final statMap = r.map('stats');
    if (statMap != null) {
      for (final e in statMap.entries) {
        final v = e.value;
        if (v is int) {
          stats[e.key] = v;
        } else if (v is double && v.isFinite) {
          stats[e.key] = v.toInt();
        }
      }
    }
    return MemoryStats(
      usage: r.integer('usage'),
      maxUsage: r.integer('max_usage'),
      limit: r.integer('limit'),
      stats: stats,
    );
  }
}

/// One entry of the stats `networks` map (03 §7.12 CST-01).
@immutable
final class NetworkStats {
  const NetworkStats({
    this.rxBytes,
    this.rxPackets,
    this.rxErrors,
    this.txBytes,
    this.txPackets,
    this.txErrors,
  });

  final int? rxBytes;
  final int? rxPackets;
  final int? rxErrors;
  final int? txBytes;
  final int? txPackets;
  final int? txErrors;

  static NetworkStats parse(JsonReader r) => NetworkStats(
    rxBytes: r.integer('rx_bytes'),
    rxPackets: r.integer('rx_packets'),
    rxErrors: r.integer('rx_errors'),
    txBytes: r.integer('tx_bytes'),
    txPackets: r.integer('tx_packets'),
    txErrors: r.integer('tx_errors'),
  );
}

/// Block I/O totals from `blkio_stats` (03 §7.12 CST-03). The service
/// entries are summed for the read and write byte counters.
@immutable
final class BlockIoStats {
  const BlockIoStats({this.readBytes, this.writeBytes});

  final int? readBytes;
  final int? writeBytes;

  static BlockIoStats parse(JsonReader r) {
    final entries = r.list('io_service_bytes_recursive');
    if (entries == null) return const BlockIoStats();
    var read = 0;
    var write = 0;
    var sawRead = false;
    var sawWrite = false;
    for (final e in entries) {
      if (e is! Map) continue;
      final er = JsonReader(asStringMap(e), r.warnings);
      final op = er.string('op')?.toLowerCase();
      final value = er.integer('value');
      if (value == null) continue;
      if (op == 'read') {
        read += value;
        sawRead = true;
      } else if (op == 'write') {
        write += value;
        sawWrite = true;
      }
    }
    return BlockIoStats(
      readBytes: sawRead ? read : null,
      writeBytes: sawWrite ? write : null,
    );
  }
}

/// One `/containers/{id}/stats` sample (03 §5.6, §7.12 CST-01, CST-03).
@immutable
final class ContainerStats {
  const ContainerStats({
    this.id,
    this.name,
    this.read,
    this.cpu = const CpuStats(),
    this.preCpu = const CpuStats(),
    this.memory = const MemoryStats(),
    this.pids,
    this.networks = const {},
    this.blockIo = const BlockIoStats(),
    this.raw = const {},
  });

  final String? id;
  final String? name;
  final DateTime? read;
  final CpuStats cpu;
  final CpuStats preCpu;
  final MemoryStats memory;
  final int? pids;
  final Map<String, NetworkStats> networks;
  final BlockIoStats blockIo;

  /// The decoded sample, for fields this model does not name.
  final Map<String, Object?> raw;

  static ContainerStats parse(JsonReader r) {
    final cpu = r.map('cpu_stats');
    final precpu = r.map('precpu_stats');
    final memory = r.map('memory_stats');
    final pidsStats = r.map('pids_stats');
    final blkio = r.map('blkio_stats');
    final networks = <String, NetworkStats>{};
    final netMap = r.map('networks');
    if (netMap != null) {
      for (final e in netMap.entries) {
        final v = e.value;
        if (v is Map) {
          networks[e.key] = NetworkStats.parse(
            JsonReader(asStringMap(v), r.warnings),
          );
        }
      }
    }
    return ContainerStats(
      id: r.string('id'),
      name: r.string('name'),
      read: dateTimeFromString(r.string('read')),
      cpu: cpu == null
          ? const CpuStats()
          : CpuStats.parse(JsonReader(cpu, r.warnings)),
      preCpu: precpu == null
          ? const CpuStats()
          : CpuStats.parse(JsonReader(precpu, r.warnings)),
      memory: memory == null
          ? const MemoryStats()
          : MemoryStats.parse(JsonReader(memory, r.warnings)),
      pids: pidsStats == null
          ? r.integer('num_procs')
          : JsonReader(pidsStats, r.warnings).integer('current'),
      networks: networks,
      blockIo: blkio == null
          ? const BlockIoStats()
          : BlockIoStats.parse(JsonReader(blkio, r.warnings)),
      raw: r.raw,
    );
  }
}

/// Parses one stats sample; never throws.
DockerParseResult<ContainerStats> parseContainerStats(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(ContainerStats(), [
      'stats sample is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(ContainerStats.parse(r), r.warnings);
}

/// Client-side CPU and memory maths for the list and detail views
/// (03 §7.12 CST-01, r5 §1.7).
@immutable
final class StatsDelta {
  const StatsDelta({
    this.cpuPercent,
    this.memoryUsage,
    this.memoryLimit,
    this.memoryPercent,
    this.networkRxBytes,
    this.networkTxBytes,
    this.blockReadBytes,
    this.blockWriteBytes,
    this.pids,
  });

  final double? cpuPercent;
  final int? memoryUsage;
  final int? memoryLimit;
  final double? memoryPercent;
  final int? networkRxBytes;
  final int? networkTxBytes;
  final int? blockReadBytes;
  final int? blockWriteBytes;
  final int? pids;
}

/// The memory usage Docker shows: `usage` minus `inactive_file` (cgroup
/// v2) or the v1 cache counter (03 §7.12 CST-01). The plan names `cache`
/// for v1; Docker's own CLI uses `total_inactive_file`, so both are
/// accepted here (deviation noted in the task report).
int? effectiveMemoryUsage(MemoryStats m) {
  final usage = m.usage;
  if (usage == null) return null;
  final inactive =
      m.stats['inactive_file'] ??
      m.stats['total_inactive_file'] ??
      m.stats['cache'];
  if (inactive != null && inactive < usage) return usage - inactive;
  return usage;
}

/// The CPU percent of the Docker spec formula: `(cpuDelta / systemDelta)
/// * onlineCpus * 100`, null when no previous sample exists (one-shot
/// stats carry a meaningless `precpu_stats`; 03 §5.6), when the system
/// counter did not advance, or when the container's counter went back
/// (a restart), or when either sample lacks the container's counter.
/// An idle container whose counter stood still is 0 %: the recorded
/// Podman stream shows exactly that.
double? cpuPercentDelta(CpuStats previous, CpuStats current) {
  final (before, now) = (previous.totalUsage, current.totalUsage);
  if (before == null || now == null) return null;
  final cpuDelta = now - before;
  final systemDelta =
      (current.systemCpuUsage ?? 0) - (previous.systemCpuUsage ?? 0);
  if (cpuDelta < 0 || systemDelta <= 0) return null;
  final cpus = current.onlineCpus ?? current.perCpuUsage.length;
  final effectiveCpus = cpus > 0 ? cpus : 1;
  return cpuDelta / systemDelta * effectiveCpus * 100.0;
}

/// Computes the display values from the current sample and, for a stream,
/// the previous one. Without [previous] CPU is null (one-shot) but memory
/// is still valid.
StatsDelta computeStatsDelta(
  ContainerStats current, {
  ContainerStats? previous,
}) {
  final usage = effectiveMemoryUsage(current.memory);
  final limit = current.memory.limit;
  final memoryPercent = (usage != null && limit != null && limit > 0)
      ? usage / limit * 100.0
      : null;

  int? netRx;
  int? netTx;
  if (previous != null) {
    for (final e in current.networks.entries) {
      final prev = previous.networks[e.key];
      if (prev == null) continue;
      netRx = (netRx ?? 0) + ((e.value.rxBytes ?? 0) - (prev.rxBytes ?? 0));
      netTx = (netTx ?? 0) + ((e.value.txBytes ?? 0) - (prev.txBytes ?? 0));
    }
  }

  int? blockRead;
  int? blockWrite;
  if (previous != null &&
      current.blockIo.readBytes != null &&
      previous.blockIo.readBytes != null) {
    blockRead = current.blockIo.readBytes! - previous.blockIo.readBytes!;
  }
  if (previous != null &&
      current.blockIo.writeBytes != null &&
      previous.blockIo.writeBytes != null) {
    blockWrite = current.blockIo.writeBytes! - previous.blockIo.writeBytes!;
  }

  return StatsDelta(
    cpuPercent: previous == null
        ? null
        : cpuPercentDelta(previous.cpu, current.cpu),
    memoryUsage: usage,
    memoryLimit: limit,
    memoryPercent: memoryPercent,
    networkRxBytes: netRx,
    networkTxBytes: netTx,
    blockReadBytes: blockRead,
    blockWriteBytes: blockWrite,
    pids: current.pids,
  );
}
