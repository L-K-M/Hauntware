import 'package:klabautermann_core/klabautermann_core.dart'
    show CoreResult, DiskRate, MemoryUsage;

/// What TRI-02 reads in a core reading as slowing the host, most telling
/// first.
enum SlownessKind {
  /// Tasks waited for a CPU (PSI `cpu some`).
  cpuWait,

  /// More runnable tasks than cores, where the host has no PSI.
  loadHigh,

  /// The hypervisor ran other guests on this machine's CPUs.
  steal,

  /// Tasks stalled on storage (PSI `io some`).
  ioStall,

  /// Cores sat idle while tasks waited for storage, where the host has
  /// no PSI.
  iowait,

  /// A disk answers slowly.
  slowDisk,

  /// A disk is busy nearly all the time.
  busyDisk,

  /// Tasks stalled waiting for memory (PSI `memory some`).
  memoryStall,

  /// Swap is mostly full while little memory is available.
  swapHeavy,
}

/// One TRI-02 finding: its [value] in the unit its kind reads (a share in
/// percent, load per core, milliseconds), and for a disk its [device].
typedef SlownessSignal = ({SlownessKind kind, double value, String? device});

/// The share of the last 10 seconds tasks waited for a CPU from which it
/// reads as the bottleneck.
const double _cpuWaitPercent = 20;

/// Runnable tasks per core from which the CPU reads as the bottleneck.
const double _loadPerCore = 1.5;

/// The share of CPU time steal or iowait take from which they are worth
/// saying, as CPU-04's hints.
const double _cpuSharePercent = 10;

/// The share of the last 10 seconds tasks stalled on storage from which
/// storage reads as the bottleneck.
const double _ioStallPercent = 10;

/// A disk's mean time per request from which it reads as slow: a busy
/// hard disk answers in about 10 ms, an SSD in under one.
const double _slowDiskMs = 50;

/// A disk's busy share from which it reads as saturated.
const double _busyDiskPercent = 90;

/// The share of the last 10 seconds tasks stalled waiting for memory from
/// which memory reads as short: any sustained memory stall hurts.
const double _memoryStallPercent = 5;

/// Swap's used share, and the available share of memory below which, the
/// host reads as paging.
const double _swapUsedShare = 0.5;
const double _memoryAvailableShare = 0.1;

/// TRI-02's signals in [core], most telling first; empty when nothing in
/// the reading points to a slowdown. PSI, where the host has it, speaks
/// for the CPU and storage; load and iowait stand in without it.
List<SlownessSignal> slownessSignals(CoreResult core) {
  final cpu = core.cpu;
  final cpuSome = core.cpuPressure?.some?.avg10;
  final ioSome = core.ioPressure?.some?.avg10;
  final memorySome = core.memoryPressure?.some?.avg10;
  final load = core.loadPerCore;
  final memory = core.memory;
  final slowest = _worstDisk(core.disks, (rate) => _await(rate));
  final busiest = _worstDisk(core.disks, (rate) => rate.busyPercent);

  return [
    if (cpuSome != null && cpuSome >= _cpuWaitPercent)
      (kind: SlownessKind.cpuWait, value: cpuSome, device: null)
    else if (cpuSome == null && load != null && load >= _loadPerCore)
      (kind: SlownessKind.loadHigh, value: load, device: null),
    if (cpu != null && cpu.steal >= _cpuSharePercent)
      (kind: SlownessKind.steal, value: cpu.steal, device: null),
    if (ioSome != null && ioSome >= _ioStallPercent)
      (kind: SlownessKind.ioStall, value: ioSome, device: null)
    else if (ioSome == null && cpu != null && cpu.iowait >= _cpuSharePercent)
      (kind: SlownessKind.iowait, value: cpu.iowait, device: null),
    if (slowest case (final device, final ms) when ms >= _slowDiskMs)
      (kind: SlownessKind.slowDisk, value: ms, device: device),
    if (busiest case (final device, final busy) when busy >= _busyDiskPercent)
      (kind: SlownessKind.busyDisk, value: busy, device: device),
    if (memorySome != null && memorySome >= _memoryStallPercent)
      (kind: SlownessKind.memoryStall, value: memorySome, device: null),
    if (memory
        case MemoryUsage(
          swapTotalBytes: final swapTotal?,
          swapUsedBytes: final swapUsed?,
          totalBytes: final total?,
          availableBytes: final available?,
        )
        when swapTotal > 0 &&
            total > 0 &&
            swapUsed / swapTotal >= _swapUsedShare &&
            available / total < _memoryAvailableShare)
      (
        kind: SlownessKind.swapHeavy,
        value: swapUsed * 100 / swapTotal,
        device: null,
      ),
  ];
}

double? _await(DiskRate rate) =>
    switch ((rate.readAwaitMs, rate.writeAwaitMs)) {
      (final read?, final write?) => read > write ? read : write,
      (final read?, null) => read,
      (null, final write?) => write,
      (null, null) => null,
    };

/// The disk with the highest [measure], and its value; null when none
/// reports one.
(String, double)? _worstDisk(
  Map<String, DiskRate>? disks,
  double? Function(DiskRate rate) measure,
) {
  (String, double)? worst;
  for (final MapEntry(key: device, value: rate)
      in (disks ?? const {}).entries) {
    final value = measure(rate);
    if (value == null) continue;
    if (worst == null || value > worst.$2) worst = (device, value);
  }
  return worst;
}
