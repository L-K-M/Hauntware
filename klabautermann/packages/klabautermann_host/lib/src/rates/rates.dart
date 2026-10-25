/// Counter-to-rate maths over two snapshots (03 §6.4, CN-04).
///
/// All functions are pure: they take the previous and next readings plus
/// the elapsed seconds between them (derived from the ticks' uptimes) and
/// return rates, or null/absent entries when a counter reset or a zero
/// interval makes a rate meaningless.
library;

import 'package:meta/meta.dart';

import '../parse/metrics.dart' show CoreSnapshot;
import '../parse/models.dart';
import '../parse/parse_result.dart';
import '../parse/procs.dart' show ProcsSnapshot;

/// The delta of one monotonically increasing counter (03 §6.4, CN-04).
///
/// A decrease means a wrap on a 32-bit counter (continued modulo 2^32)
/// and a reset on a 64-bit one, which cannot wrap in practice: a reset
/// yields `null` so the caller starts a new series instead of reporting a
/// huge bogus rate.
int? counterDelta(
  int previous,
  int next, {
  CounterWidth width = CounterWidth.bits64,
}) {
  if (previous < 0 || next < 0) return null;
  if (next >= previous) return next - previous;
  if (width == CounterWidth.bits32) {
    return (1 << 32) - previous + next;
  }
  return null;
}

/// Whether the host rebooted between two readings (03 §6.4): a changed
/// `btime` starts a new series. Unknown on either side stays false —
/// without both boot times a reboot cannot be told from a plain gap.
bool seriesReset(int? previousBtime, int? nextBtime) =>
    previousBtime != null && nextBtime != null && previousBtime != nextBtime;

/// Per-field CPU occupancy in percent of the jiffy delta between two
/// `/proc/stat` readings (03 §6.4, §7.1). Percentages of the fields sum
/// to 100.
@immutable
final class CpuPercentages {
  const CpuPercentages(this.perField, this.busy);

  /// user, nice, system, idle, iowait, irq, softirq, steal in the order
  /// of [CpuTimes] field constants; indexes beyond the shorter line read
  /// as 0.
  final List<double> perField;

  /// `100 - idle - iowait`: what the overview gauges show (03 §7.1).
  final double busy;

  double get user => _f(CpuTimes.user);
  double get nice => _f(CpuTimes.nice);
  double get system => _f(CpuTimes.system);
  double get idle => _f(CpuTimes.idle);
  double get iowait => _f(CpuTimes.iowait);
  double get irq => _f(CpuTimes.irq);
  double get softirq => _f(CpuTimes.softirq);
  double get steal => _f(CpuTimes.steal);

  double _f(int i) => i < perField.length ? perField[i] : 0;

  Map<String, Object?> toJson() => {
    'user': user,
    'nice': nice,
    'system': system,
    'idle': idle,
    'iowait': iowait,
    'irq': irq,
    'softirq': softirq,
    'steal': steal,
    'busy': busy,
  };
}

/// CPU occupancy between [previous] and [next] (03 §6.4). `null` when the
/// total jiffy delta is zero or negative, or when any primary field
/// decreased (a reset starts a new series, CN-04). The guest fields are
/// excluded from the total because the kernel already accounts them in
/// user and nice (proc_stat(5)); a guest decrease is tolerated rather
/// than treated as a reset.
CpuPercentages? cpuDeltaPercent(CpuTimes previous, CpuTimes next) {
  const primary = CpuTimes.guest; // fields below guest form the total
  final len = previous.jiffies.length > next.jiffies.length
      ? previous.jiffies.length
      : next.jiffies.length;
  final deltas = List<int>.filled(len, 0);
  var total = 0;
  for (var i = 0; i < len; i++) {
    final p = i < previous.jiffies.length ? previous.jiffies[i] : 0;
    final n = i < next.jiffies.length ? next.jiffies[i] : 0;
    if (n < p) {
      if (i < primary) return null;
      continue;
    }
    deltas[i] = n - p;
    if (i < primary) total += n - p;
  }
  if (total <= 0) return null;
  final perField = deltas.map((d) => d * 100.0 / total).toList();
  var idleD = 0;
  if (len > CpuTimes.idle) idleD += deltas[CpuTimes.idle];
  if (len > CpuTimes.iowait) idleD += deltas[CpuTimes.iowait];
  return CpuPercentages(perField, 100 - idleD * 100.0 / total);
}

/// Busy percent per `cpuN` name present in both maps (03 §6.4, CPU-02):
/// the busy jiffy delta over the busy plus idle delta. A decrease (a
/// reset, CN-04) or a zero total delta yields no entry.
Map<String, double> perCpuBusyPercent(
  Map<String, CoreCpuTimes> previous,
  Map<String, CoreCpuTimes> next,
) {
  final out = <String, double>{};
  for (final e in next.entries) {
    final p = previous[e.key];
    if (p == null) continue;
    final busy = e.value.busy - p.busy;
    final idle = e.value.idle - p.idle;
    if (busy < 0 || idle < 0 || busy + idle <= 0) continue;
    out[e.key] = busy * 100.0 / (busy + idle);
  }
  return out;
}

/// Throughput of one interface between two readings (03 §6.4).
@immutable
final class NetRate {
  const NetRate({
    required this.rxBytesPerSecond,
    required this.txBytesPerSecond,
  });

  final double rxBytesPerSecond, txBytesPerSecond;

  Map<String, Object?> toJson() => {
    'rxBytesPerSecond': rxBytesPerSecond,
    'txBytesPerSecond': txBytesPerSecond,
  };
}

/// Per-interface byte rates from /proc/net/dev counters (03 §6.4).
/// Interfaces missing from either side, reset 64-bit counters and a
/// zero-or-negative interval yield no entry.
Map<String, NetRate> netRates(
  List<NetDevEntry> previous,
  List<NetDevEntry> next,
  double elapsedSeconds, {
  CounterWidth width = CounterWidth.bits64,
}) {
  final out = <String, NetRate>{};
  if (elapsedSeconds <= 0) return out;
  final prev = {for (final e in previous) e.name: e};
  for (final n in next) {
    final p = prev[n.name];
    if (p == null) continue;
    final rx = counterDelta(p.rxBytes, n.rxBytes, width: width);
    final tx = counterDelta(p.txBytes, n.txBytes, width: width);
    if (rx == null || tx == null) continue;
    out[n.name] = NetRate(
      rxBytesPerSecond: rx / elapsedSeconds,
      txBytesPerSecond: tx / elapsedSeconds,
    );
  }
  return out;
}

/// One block device between two readings (03 §6.4): its throughput
/// (CN-04, DSK-03), and with collector-set version 10's timings its
/// latency and utilization (DSK-04).
@immutable
final class DiskRate {
  const DiskRate({
    required this.readBytesPerSecond,
    required this.writeBytesPerSecond,
    this.readsPerSecond = 0,
    this.writesPerSecond = 0,
    this.readAwaitMs,
    this.writeAwaitMs,
    this.busyPercent,
  });

  /// Sectors converted at 512 bytes each (CN-04).
  final double readBytesPerSecond, writeBytesPerSecond;

  /// Completed reads and writes per second (IOPS).
  final double readsPerSecond, writesPerSecond;

  /// The mean time a read or write took, queueing included (iostat's
  /// `r_await` and `w_await`): null without the timings, or when none
  /// completed in the interval.
  final double? readAwaitMs, writeAwaitMs;

  /// The share of the interval with any I/O in flight (iostat's `%util`),
  /// 0 to 100; null without the timings. A device serving requests in
  /// parallel, as SSDs and arrays do, can be busy at 100 % with room left.
  final double? busyPercent;

  Map<String, Object?> toJson() => {
    'readBytesPerSecond': readBytesPerSecond,
    'writeBytesPerSecond': writeBytesPerSecond,
    'readsPerSecond': readsPerSecond,
    'writesPerSecond': writesPerSecond,
    'readAwaitMs': ?readAwaitMs,
    'writeAwaitMs': ?writeAwaitMs,
    'busyPercent': ?busyPercent,
  };
}

/// Per-device rates from /proc/diskstats counters (03 §6.4). Devices
/// missing from either side, reset counters and a zero interval yield no
/// entry; a device whose timings are missing on either side, or reset,
/// keeps its throughput without latency and utilization.
Map<String, DiskRate> diskRates(
  List<DiskStatEntry> previous,
  List<DiskStatEntry> next,
  double elapsedSeconds, {
  CounterWidth width = CounterWidth.bits64,
}) {
  final out = <String, DiskRate>{};
  if (elapsedSeconds <= 0) return out;
  final prev = {for (final e in previous) e.name: e};
  for (final n in next) {
    final p = prev[n.name];
    if (p == null) continue;
    final rd = counterDelta(p.sectorsRead, n.sectorsRead, width: width);
    final wr = counterDelta(p.sectorsWritten, n.sectorsWritten, width: width);
    final reads = counterDelta(
      p.readsCompleted,
      n.readsCompleted,
      width: width,
    );
    final writes = counterDelta(
      p.writesCompleted,
      n.writesCompleted,
      width: width,
    );
    if (rd == null || wr == null || reads == null || writes == null) continue;

    int? delta(int? before, int? after) => before == null || after == null
        ? null
        : counterDelta(before, after, width: width);
    final readMs = delta(p.readMs, n.readMs);
    final writeMs = delta(p.writeMs, n.writeMs);
    final ioMs = delta(p.ioMs, n.ioMs);
    out[n.name] = DiskRate(
      readBytesPerSecond: rd * DiskStatEntry.sectorBytes / elapsedSeconds,
      writeBytesPerSecond: wr * DiskStatEntry.sectorBytes / elapsedSeconds,
      readsPerSecond: reads / elapsedSeconds,
      writesPerSecond: writes / elapsedSeconds,
      readAwaitMs: readMs == null || reads == 0 ? null : readMs / reads,
      writeAwaitMs: writeMs == null || writes == 0 ? null : writeMs / writes,
      // io_ticks advances in jiffies on some kernels, so a reading can
      // overshoot the interval a little; the share never exceeds 100 %.
      busyPercent: ioMs == null
          ? null
          : (ioMs / (elapsedSeconds * 1000) * 100).clamp(0, 100).toDouble(),
    );
  }
  return out;
}

/// All rates between two `core` snapshots (03 §6.4), or the pieces that
/// are computable: a changed `btime` or a zero/negative uptime delta
/// yields empty rate maps (the tick is a gap, not a stale value).
@immutable
final class CoreDelta {
  const CoreDelta({
    required this.rebooted,
    required this.elapsedSeconds,
    this.cpu,
    required this.perCpu,
    required this.net,
    required this.disk,
  });

  /// `btime` changed: the host rebooted and every counter restarted.
  final bool rebooted;

  /// Uptime delta between the two ticks, null when either side lacks it.
  final double? elapsedSeconds;

  /// Aggregate CPU occupancy.
  final CpuPercentages? cpu;

  /// Per-core busy percent.
  final Map<String, double> perCpu;

  /// Per-interface byte rates.
  final Map<String, NetRate> net;

  /// Per-device byte rates.
  final Map<String, DiskRate> disk;
}

/// Diffs two `core` snapshots against each other and their uptimes
/// (03 §6.4).
CoreDelta diffCoreSnapshots(
  CoreSnapshot previous,
  CoreSnapshot next, {
  CounterWidth width = CounterWidth.bits64,
}) {
  final rebooted = seriesReset(previous.btime, next.btime);
  final prevUp = previous.uptimeSeconds;
  final nextUp = next.uptimeSeconds;
  final elapsed = prevUp != null && nextUp != null ? nextUp - prevUp : null;
  if (rebooted || elapsed == null || elapsed <= 0) {
    return CoreDelta(
      rebooted: rebooted,
      elapsedSeconds: elapsed,
      perCpu: const {},
      net: const {},
      disk: const {},
    );
  }
  final prevCpu = previous.cpu;
  final nextCpu = next.cpu;
  return CoreDelta(
    rebooted: false,
    elapsedSeconds: elapsed,
    cpu: prevCpu != null && nextCpu != null
        ? cpuDeltaPercent(prevCpu, nextCpu)
        : null,
    perCpu: perCpuBusyPercent(previous.perCpu, next.perCpu),
    net: netRates(previous.netdev, next.netdev, elapsed, width: width),
    disk: diskRates(previous.diskstats, next.diskstats, elapsed, width: width),
  );
}

/// Per-pid CPU occupancy between two `procs` snapshots in percent of one
/// CPU (03 §7.2, PRC-03): the `(utime + stime)` jiffy delta over
/// [elapsedSeconds] at [ticksPerSecond] jiffies per second (100 on
/// Linux). A pid absent on either side, a changed `startTicks` (a PID
/// reuse, PRC-02) or a jiffy decrease yields no entry; values may exceed
/// 100 on multithreaded processes.
Map<int, double> procCpuPercent(
  ProcsSnapshot previous,
  ProcsSnapshot next,
  double elapsedSeconds, {
  int ticksPerSecond = 100,
}) {
  final out = <int, double>{};
  if (elapsedSeconds <= 0 || ticksPerSecond <= 0) return out;
  final prev = {for (final p in previous.processes) p.pid: p};
  for (final n in next.processes) {
    final p = prev[n.pid];
    if (p == null) continue;
    // PRC-02: a reused pid is a different process; startTicks differs.
    if (p.startTicks != null &&
        n.startTicks != null &&
        p.startTicks != n.startTicks) {
      continue;
    }
    final pj = p.jiffies;
    final nj = n.jiffies;
    if (pj == null || nj == null || nj < pj) continue;
    out[n.pid] = (nj - pj) * 100.0 / (ticksPerSecond * elapsedSeconds);
  }
  return out;
}
