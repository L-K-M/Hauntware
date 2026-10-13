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

/// The result of parsing the `== stat ==` block.
@immutable
final class StatBlock {
  StatBlock({this.aggregate, Map<String, CpuTimes>? cores, this.btime})
    : cores = Map.unmodifiable(cores ?? {});

  /// The aggregate `cpu` line.
  final CpuTimes? aggregate;

  /// `cpu0`..`cpuN` keyed by name.
  final Map<String, CpuTimes> cores;

  /// `btime`: boot epoch seconds, when the block carried it (core only).
  final int? btime;
}

/// Parses the cpu lines and `btime` of /proc/stat (03 §6.4).
StatBlock parseStatBlock(List<String> lines, List<String> warnings) {
  CpuTimes? aggregate;
  final cores = <String, CpuTimes>{};
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
    if (bad || fields.isEmpty) {
      warnings.add('stat: malformed cpu line "$t"');
      continue;
    }
    final ct = CpuTimes(name, fields);
    if (name == 'cpu') {
      aggregate = ct;
    } else {
      cores[name] = ct;
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

/// Parses the filtered `== meminfo ==` block (`Key: <n> kB` lines).
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

/// One interface row of /proc/net/dev (03 §6.4). [rx] and [tx] hold the
/// eight counters in file order each.
@immutable
final class NetDevEntry {
  NetDevEntry(this.name, List<int> rx, List<int> tx)
    : rx = List.unmodifiable(rx),
      tx = List.unmodifiable(tx);

  final String name;

  /// rx: bytes, packets, errs, drop, fifo, frame, compressed, multicast.
  final List<int> rx;

  /// tx: bytes, packets, errs, drop, fifo, colls, carrier, compressed.
  final List<int> tx;

  int get rxBytes => rx[0];
  int get txBytes => tx[0];
  int get rxPackets => rx[1];
  int get txPackets => tx[1];
  int get rxErrors => rx[2];
  int get txErrors => tx[2];
  int get rxDropped => rx[3];
  int get txDropped => tx[3];

  Map<String, Object?> toJson() => {'name': name, 'rx': rx, 'tx': tx};
}

/// Parses `== netdev ==`, skipping the two `|`-header lines.
List<NetDevEntry> parseNetDevBlock(List<String> lines, List<String> warnings) {
  final out = <NetDevEntry>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.contains('|')) continue;
    final colon = t.indexOf(':');
    if (colon < 0) {
      warnings.add('netdev: malformed line "$t"');
      continue;
    }
    final name = t.substring(0, colon).trim();
    final counters = t
        .substring(colon + 1)
        .trim()
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .toList();
    if (counters.length != 16 || counters.any((c) => c == null || c < 0)) {
      warnings.add('netdev: bad counter row for "$name"');
      continue;
    }
    out.add(
      NetDevEntry(
        name,
        counters.sublist(0, 8).cast<int>(),
        counters.sublist(8).cast<int>(),
      ),
    );
  }
  return out;
}

/// One device row of /proc/diskstats (03 §6.4, §7.3). Field counts vary by
/// kernel (14 fields since 2.6.25, +4 discard fields since 4.18, +2 flush
/// fields since 5.5); [fields] keeps everything after the name.
@immutable
final class DiskStatEntry {
  DiskStatEntry(this.major, this.minor, this.name, List<int> fields)
    : fields = List.unmodifiable(fields);

  final int major, minor;
  final String name;

  /// Counter fields in file order: reads completed, reads merged, sectors
  /// read, ms reading, writes completed, writes merged, sectors written,
  /// ms writing, ios in progress, ms doing io, weighted ms doing io, then
  /// discard and flush fields on newer kernels.
  final List<int> fields;

  int get sectorsRead => fields.length > 2 ? fields[2] : 0;
  int get sectorsWritten => fields.length > 6 ? fields[6] : 0;
  int get readsCompleted => fields.isNotEmpty ? fields[0] : 0;
  int get writesCompleted => fields.length > 4 ? fields[4] : 0;

  /// /proc/diskstats counts sectors of 512 bytes (CN-04).
  static const sectorBytes = 512;

  Map<String, Object?> toJson() => {
    'major': major,
    'minor': minor,
    'name': name,
    'fields': fields,
  };
}

/// Parses `== diskstats ==`; rows with too few fields warn and skip.
List<DiskStatEntry> parseDiskStatsBlock(
  List<String> lines,
  List<String> warnings,
) {
  final out = <DiskStatEntry>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 14) {
      warnings.add('diskstats: short row "$t"');
      continue;
    }
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final fields = <int>[];
    var bad = major == null || minor == null;
    for (final p in parts.skip(3)) {
      final v = int.tryParse(p);
      if (v == null || v < 0) {
        bad = true;
        break;
      }
      fields.add(v);
    }
    if (bad) {
      warnings.add('diskstats: malformed row "$t"');
      continue;
    }
    out.add(DiskStatEntry(major!, minor!, parts[2], fields));
  }
  return out;
}

/// One `some`/`full` line of a /proc/pressure file (03 §6.4).
@immutable
final class PressureLine {
  const PressureLine({
    required this.avg10,
    required this.avg60,
    required this.avg300,
    this.total,
  });

  final double avg10, avg60, avg300;
  final int? total;

  Map<String, Object?> toJson() => {
    'avg10': avg10,
    'avg60': avg60,
    'avg300': avg300,
    'total': total,
  };
}

/// One /proc/pressure file: cpu has only `some`, io and memory add `full`
/// (03 §7.1 "PSI (absence is normal)").
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
    int? total;
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
        case 'total':
          total = int.tryParse(v);
        default:
          break; // forward-compatible: ignore unknown keys
      }
    }
    if (bad || a10 == null || a60 == null || a300 == null) {
      warnings.add('pressure: malformed line "$t"');
      continue;
    }
    final pl = PressureLine(avg10: a10, avg60: a60, avg300: a300, total: total);
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
