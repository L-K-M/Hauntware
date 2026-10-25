/// Shared models for the `/proc` and `/sys` payload blocks the fast
/// collectors read (03 §6.4). Every `parse*` function is pure, returns
/// `null` or a partial value on malformed input, and never throws.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Splits a collector payload into its `== <name> ==` sub-blocks (03 §6.4).
/// Returns the block name to its lines, the number of lines seen before
/// the first header (dropped preamble), and whether the
/// `hw_timeout=absent` marker was present.
({Map<String, List<String>> blocks, int preambleLines, bool timeoutAbsent})
splitBlocks(String payload, String timeoutAbsentMarker) {
  final blocks = <String, List<String>>{};
  var preamble = 0;
  var absent = false;
  var current = 'preamble';
  // Hyphens are allowed so the `os-release` block parses (03 §6.4).
  final header = RegExp(r'^== ([a-z0-9_-]+) ==$');
  for (final line in payload.split('\n')) {
    if (line == timeoutAbsentMarker) {
      absent = true;
      continue;
    }
    final m = header.firstMatch(line.trim());
    if (m != null) {
      current = m[1]!;
      blocks.putIfAbsent(current, () => []);
      continue;
    }
    if (current == 'preamble') {
      if (line.trim().isNotEmpty) preamble++;
      continue;
    }
    blocks[current]!.add(line);
  }
  return (blocks: blocks, preambleLines: preamble, timeoutAbsent: absent);
}

/// One `cpu`/`cpuN` line of /proc/stat as jiffy counters (03 §6.4).
///
/// [jiffies] holds the fields in file order: user, nice, system, idle,
/// iowait, irq, softirq, steal, guest, guest_nice; older kernels may ship
/// fewer than ten.
@immutable
final class CpuTimes {
  CpuTimes(this.name, List<int> jiffies) : jiffies = List.unmodifiable(jiffies);

  /// `cpu` for the aggregate line, `cpu0`.. for cores.
  final String name;

  /// Jiffies per field, in file order.
  final List<int> jiffies;

  /// Field indices (proc_stat(5)).
  static const user = 0,
      nice = 1,
      system = 2,
      idle = 3,
      iowait = 4,
      irq = 5,
      softirq = 6,
      steal = 7,
      guest = 8,
      guestNice = 9;

  /// Total jiffies across every field.
  int get total => jiffies.fold(0, (a, b) => a + b);

  Map<String, Object?> toJson() => {'name': name, 'jiffies': jiffies};
}

/// One core as the `core` collector sends it (D48): `cpuN <busy> <idle>`,
/// where idle is the line's idle plus iowait jiffies and busy its user,
/// nice, system, irq, softirq and steal jiffies (guest time is already in
/// user and nice). CPU-02 shows only busy per core. A shell with 32-bit
/// arithmetic sends the line's first eight counters instead, and the
/// parser sums them.
@immutable
final class CoreCpuTimes {
  const CoreCpuTimes(this.name, {required this.busy, required this.idle});

  /// `cpu0`, `cpu1` and so on.
  final String name;

  final int busy, idle;

  Map<String, Object?> toJson() => {'name': name, 'busy': busy, 'idle': idle};
}

/// The result of parsing the `== stat ==` block.
@immutable
final class StatBlock {
  StatBlock({this.aggregate, Map<String, CoreCpuTimes>? cores, this.btime})
    : cores = Map.unmodifiable(cores ?? {});

  /// The aggregate `cpu` line.
  final CpuTimes? aggregate;

  /// `cpu0`..`cpuN` keyed by name.
  final Map<String, CoreCpuTimes> cores;

  /// `btime`: boot epoch seconds, when the block carried it (core only).
  final int? btime;
}

/// Parses the `stat` block (03 §6.4, D48): the whole aggregate `cpu`
/// line, `cpuN <busy> <idle>` or the eight counters per core, and
/// `btime`.
StatBlock parseStatBlock(List<String> lines, List<String> warnings) {
  CpuTimes? aggregate;
  final cores = <String, CoreCpuTimes>{};
  int? btime;
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('btime')) {
      final parts = t.split(RegExp(r'\s+'));
      final v = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (v == null) {
        warnings.add('stat: malformed btime line');
      } else {
        btime = v;
      }
      continue;
    }
    if (!t.startsWith('cpu')) {
      warnings.add('stat: unexpected line "$t"');
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    final name = parts[0];
    if (name != 'cpu' && !RegExp(r'^cpu\d+$').hasMatch(name)) {
      warnings.add('stat: unexpected cpu line "$name"');
      continue;
    }
    final fields = <int>[];
    var bad = false;
    for (final p in parts.skip(1)) {
      final v = int.tryParse(p);
      if (v == null || v < 0) {
        bad = true;
        break;
      }
      fields.add(v);
    }
    final core = name != 'cpu';
    if (bad || fields.isEmpty || (core && ![2, 8].contains(fields.length))) {
      warnings.add('stat: malformed cpu line "$t"');
      continue;
    }
    if (!core) {
      aggregate = CpuTimes(name, fields);
    } else if (fields.length == 2) {
      cores[name] = CoreCpuTimes(name, busy: fields[0], idle: fields[1]);
    } else {
      final f = fields;
      cores[name] = CoreCpuTimes(
        name,
        busy: f[0] + f[1] + f[2] + f[5] + f[6] + f[7],
        idle: f[3] + f[4],
      );
    }
  }
  return StatBlock(aggregate: aggregate, cores: cores, btime: btime);
}

/// The filtered /proc/meminfo subset the collectors keep (03 §6.4), in kB.
@immutable
final class MemInfo {
  MemInfo(Map<String, int> fields) : fields = Map.unmodifiable(fields);

  /// `MemTotal`-style key to kB value.
  final Map<String, int> fields;

  int? get totalKb => fields['MemTotal'];
  int? get freeKb => fields['MemFree'];
  int? get availableKb => fields['MemAvailable'];
  int? get buffersKb => fields['Buffers'];
  int? get cachedKb => fields['Cached'];
  int? get sReclaimableKb => fields['SReclaimable'];
  int? get shmemKb => fields['Shmem'];
  int? get swapTotalKb => fields['SwapTotal'];
  int? get swapFreeKb => fields['SwapFree'];

  /// Used memory per 03 §7.1 (MemAvailable semantics).
  int? get usedKb =>
      totalKb == null || availableKb == null ? null : totalKb! - availableKb!;

  Map<String, Object?> toJson() => {'fields': fields};
}

/// Parses the filtered `== meminfo ==` block: `Key: <n>` lines in kB, as
/// the collector sends them (D48); a trailing `kB` is accepted.
MemInfo parseMemInfoBlock(List<String> lines, List<String> warnings) {
  final fields = <String, int>{};
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^([A-Za-z_()]+):\s+(\d+)(?:\s+kB)?$').firstMatch(t);
    if (m == null) {
      warnings.add('meminfo: malformed line "$t"');
      continue;
    }
    fields[m[1]!] = int.parse(m[2]!);
  }
  return MemInfo(fields);
}

/// /proc/loadavg (03 §6.4).
@immutable
final class LoadAvg {
  const LoadAvg({
    required this.load1,
    required this.load5,
    required this.load15,
    this.running,
    this.total,
    this.lastPid,
  });

  final double load1, load5, load15;

  /// Running/total process counts from the `k/n` field.
  final int? running, total;

  /// Highest pid ever allocated.
  final int? lastPid;

  Map<String, Object?> toJson() => {
    'load1': load1,
    'load5': load5,
    'load15': load15,
    'running': running,
    'total': total,
    'lastPid': lastPid,
  };
}

/// Parses `== loadavg ==` (`0.01 0.05 0.10 2/345 12345`).
LoadAvg? parseLoadAvgBlock(List<String> lines, List<String> warnings) {
  final line = lines.where((l) => l.trim().isNotEmpty).firstOrNull;
  if (line == null) return null;
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 3) {
    warnings.add('loadavg: malformed line "${line.trim()}"');
    return null;
  }
  final l1 = double.tryParse(parts[0]);
  final l5 = double.tryParse(parts[1]);
  final l15 = double.tryParse(parts[2]);
  if (l1 == null || l5 == null || l15 == null) {
    warnings.add('loadavg: malformed averages "${line.trim()}"');
    return null;
  }
  int? running, total, lastPid;
  if (parts.length >= 4) {
    final slash = parts[3].split('/');
    if (slash.length == 2) {
      running = int.tryParse(slash[0]);
      total = int.tryParse(slash[1]);
    }
    if (running == null || total == null) {
      warnings.add('loadavg: malformed k/n field "${parts[3]}"');
      running = total = null;
    }
  }
  if (parts.length >= 5) lastPid = int.tryParse(parts[4]);
  return LoadAvg(
    load1: l1,
    load5: l5,
    load15: l15,
    running: running,
    total: total,
    lastPid: lastPid,
  );
}

/// One interface as the overview and core collectors send it (D48):
/// `<name> <rx bytes> <tx bytes>` from /proc/net/dev.
@immutable
final class NetDevEntry {
  const NetDevEntry(this.name, {required this.rxBytes, required this.txBytes});

  final String name;
  final int rxBytes, txBytes;

  Map<String, Object?> toJson() => {
    'name': name,
    'rxBytes': rxBytes,
    'txBytes': txBytes,
  };
}

/// Parses `== netdev ==` rows of `<name> <rx bytes> <tx bytes>`.
List<NetDevEntry> parseNetDevBlock(List<String> lines, List<String> warnings) {
  final out = <NetDevEntry>[];
  for (final (name, counters) in _counterRows(
    lines,
    const {2},
    'netdev',
    warnings,
  )) {
    out.add(NetDevEntry(name, rxBytes: counters[0], txBytes: counters[1]));
  }
  return out;
}

/// One disk as the core collector sends it (D48): the name, then
/// fields 4, 6, 8 and 10 of /proc/diskstats (reads completed, sectors
/// read, writes completed, sectors written) and, from collector-set
/// version 10 (DSK-04), fields 7, 11 and 13 (ms reading, ms writing,
/// ms doing I/O). A row of the four counters alone, as earlier versions
/// and the recorded fixtures send, leaves the three timings null.
@immutable
final class DiskStatEntry {
  const DiskStatEntry(
    this.name, {
    required this.readsCompleted,
    required this.sectorsRead,
    required this.writesCompleted,
    required this.sectorsWritten,
    this.readMs,
    this.writeMs,
    this.ioMs,
  });

  final String name;
  final int readsCompleted, sectorsRead, writesCompleted, sectorsWritten;

  /// Milliseconds spent on reads, on writes, and with any I/O in flight
  /// (`io_ticks`); null from a four-counter row.
  final int? readMs, writeMs, ioMs;

  /// /proc/diskstats counts sectors of 512 bytes (CN-04).
  static const sectorBytes = 512;

  Map<String, Object?> toJson() => {
    'name': name,
    'readsCompleted': readsCompleted,
    'sectorsRead': sectorsRead,
    'writesCompleted': writesCompleted,
    'sectorsWritten': sectorsWritten,
    'readMs': ?readMs,
    'writeMs': ?writeMs,
    'ioMs': ?ioMs,
  };
}

/// Parses `== diskstats ==` rows of `<name>` and four counters, or seven
/// with DSK-04's timings.
List<DiskStatEntry> parseDiskStatsBlock(
  List<String> lines,
  List<String> warnings,
) {
  final out = <DiskStatEntry>[];
  for (final (name, c) in _counterRows(
    lines,
    const {4, 7},
    'diskstats',
    warnings,
  )) {
    final timed = c.length == 7;
    out.add(
      DiskStatEntry(
        name,
        readsCompleted: c[0],
        sectorsRead: c[1],
        writesCompleted: c[2],
        sectorsWritten: c[3],
        readMs: timed ? c[4] : null,
        writeMs: timed ? c[5] : null,
        ioMs: timed ? c[6] : null,
      ),
    );
  }
  return out;
}

/// The rows of a `<name> <counter>...` block with one of [counts]
/// non-negative counters each; any other row warns and is skipped.
Iterable<(String, List<int>)> _counterRows(
  List<String> lines,
  Set<int> counts,
  String block,
  List<String> warnings,
) sync* {
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    final counters = parts.skip(1).map(int.tryParse).toList();
    if (!counts.contains(counters.length) ||
        counters.any((c) => c == null || c < 0)) {
      warnings.add('$block: malformed row "$t"');
      continue;
    }
    yield (parts[0], counters.cast<int>());
  }
}

/// One `some`/`full` line of a /proc/pressure file (03 §6.4); the core
/// collector drops the cumulative `total` (D48).
@immutable
final class PressureLine {
  const PressureLine({
    required this.avg10,
    required this.avg60,
    required this.avg300,
  });

  final double avg10, avg60, avg300;

  Map<String, Object?> toJson() => {
    'avg10': avg10,
    'avg60': avg60,
    'avg300': avg300,
  };
}

/// One /proc/pressure file: its `some` and `full` lines (03 §7.1 "PSI
/// (absence is normal)"). Kernels before 5.13 have no `full` line for
/// cpu, and later ones report zero for it at the system level; an lxcfs
/// `pressure/cpu` carries the container's own `full` (D48, D50).
@immutable
final class Pressure {
  const Pressure({this.some, this.full});

  final PressureLine? some, full;

  Map<String, Object?> toJson() => {
    'some': some?.toJson(),
    'full': full?.toJson(),
  };
}

/// Parses `== pressure_cpu/io/memory ==`.
Pressure parsePressureBlock(List<String> lines, List<String> warnings) {
  PressureLine? some, full;
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    final kind = parts[0];
    if (kind != 'some' && kind != 'full') {
      warnings.add('pressure: unexpected line "$t"');
      continue;
    }
    double? a10, a60, a300;
    var bad = false;
    for (final kv in parts.skip(1)) {
      final eq = kv.indexOf('=');
      if (eq < 0) {
        bad = true;
        break;
      }
      final k = kv.substring(0, eq);
      final v = kv.substring(eq + 1);
      switch (k) {
        case 'avg10':
          a10 = double.tryParse(v);
        case 'avg60':
          a60 = double.tryParse(v);
        case 'avg300':
          a300 = double.tryParse(v);
        default:
          break; // forward-compatible: ignore unknown keys
      }
    }
    if (bad || a10 == null || a60 == null || a300 == null) {
      warnings.add('pressure: malformed line "$t"');
      continue;
    }
    final pl = PressureLine(avg10: a10, avg60: a60, avg300: a300);
    if (kind == 'some') {
      some = pl;
    } else {
      full = pl;
    }
  }
  return Pressure(some: some, full: full);
}

/// Parses `== uptime ==`: field 1 is uptime seconds, field 2 idle jiffies
/// summed over cores (03 §6.4).
({double uptimeSeconds, double? idleSeconds})? parseUptimeBlock(
  List<String> lines,
  List<String> warnings,
) {
  final line = lines.where((l) => l.trim().isNotEmpty).firstOrNull;
  if (line == null) return null;
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return null;
  final up = double.tryParse(parts[0]);
  if (up == null || up < 0) {
    warnings.add('uptime: malformed line "${line.trim()}"');
    return null;
  }
  final idle = parts.length > 1 ? double.tryParse(parts[1]) : null;
  return (uptimeSeconds: up, idleSeconds: idle);
}

/// The ZFS ARC as the core collector sends it (D48): `c_min` and `size`
/// from /proc/spl/kstat/zfs/arcstats, in bytes. A host without that file
/// has no block, and its snapshot no [ZfsArc] at all: absent is not zero.
@immutable
final class ZfsArc {
  const ZfsArc({this.sizeBytes, this.minBytes});

  /// The ARC's current size, which MEM-01 counts as used memory; null
  /// when the block lacked it.
  final int? sizeBytes;

  /// `c_min`, the size the ARC does not shrink below.
  final int? minBytes;

  Map<String, Object?> toJson() => {
    'sizeBytes': sizeBytes,
    'minBytes': minBytes,
  };
}

/// Parses `== arcstats ==` rows of `<name> <bytes>`.
ZfsArc parseArcStatsBlock(List<String> lines, List<String> warnings) {
  int? size, min;
  for (final (name, c) in _counterRows(
    lines,
    const {1},
    'arcstats',
    warnings,
  )) {
    switch (name) {
      case 'size':
        size = c.single;
      case 'c_min':
        min = c.single;
      default:
        warnings.add('arcstats: unexpected row "$name"');
    }
  }
  if (size == null) warnings.add('arcstats: no size row');
  return ZfsArc(sizeBytes: size, minBytes: min);
}
