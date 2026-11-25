import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue;
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CpuPercentages,
        CronSnapshot,
        DiskRate,
        FsSnapshot,
        GpuSnapshot,
        JobEntry,
        LoadAvg,
        NetRate,
        ProcsSelection,
        SystemdUnit,
        TempsSnapshot,
        TimersSnapshot,
        UnitsSnapshot;
import 'package:meta/meta.dart';

/// What a [Subscribe] names and each [Sample] carries: the 03 §6.4
/// collectors as surfaces see them. [units] and [failedUnits] both come
/// from the host's `units` collector: [failedUnits] is the health card's
/// list every 60 s, apart from the Services panel's full list every 15 s,
/// so the engine tells the two surfaces apart by stream (D45). The probe
/// is not a stream (see [HostProfileChanged]).
enum SampleStream {
  /// Fleet-row metrics: CPU, memory, load and network ([OverviewResult]).
  overview,

  /// The focused server's metrics: the overview's plus per-core CPU,
  /// disks, pressure and uptime ([CoreResult]).
  core,

  /// Mount usage and inodes ([FsResult]).
  fs,

  /// OS, kernel and host name, read once per session ([IdentityResult]).
  identity,

  /// The process list ([ProcsResult]).
  procs,

  /// Every systemd unit, for the Services panel ([UnitsResult]).
  units,

  /// The failed systemd units, for the health card ([FailedUnitsResult]).
  failedUnits,

  /// systemd timers ([TimersResult]).
  timers,

  /// Cron jobs ([CronResult]).
  cron,

  /// The login user's own systemd units, from its user manager
  /// ([UnitsResult], 7.5, SVC-09).
  userUnits,

  /// The login user's own systemd timers ([TimersResult], 7.7, JOB-08).
  userTimers,

  /// Temperature sensors ([TempsResult], HW-01).
  temps,

  /// GPUs ([GpuResult], HW-03).
  gpu,
}

/// The 03 §6.4 cadence columns [SetCadenceProfile] picks among, from the
/// fastest to the slowest; [SetServerCadenceCap] relies on that order.
enum CadenceProfile {
  /// The Desktop column; the engine starts with it.
  desktop,

  /// The Phone column.
  phone,

  /// The Cellular saver column, which reads `timers`, `cron`, `temps`
  /// and `gpu` on demand: once per [Subscribe] that names them, as soon
  /// as the link is ready and the app is in the foreground (see
  /// [Subscribe]).
  cellularSaver,
}

/// What sampling a server is doing, behind [SamplingState].
enum SamplingPhase {
  /// No subscription names the server, so nothing runs, such as for a
  /// monitored server whose surfaces are all hidden. This is not 03
  /// §9.5's "not watched on this device": the app words that from the
  /// monitor set it owns (FL-21, [SetMonitorSet]).
  unsubscribed,

  /// Subscribed, but the server's link is not ready; [LinkState] says why.
  waitingForLink,

  /// The samplers run the subscribed streams.
  sampling,

  /// Paused while the app is in the background ([SetAppActivity]); the
  /// subscriptions stay and resume on return.
  pausedInBackground,
}

/// Why a [Gap] has no readings; 03 §9.5 labels the band from it.
enum GapCause {
  /// The app was in the background ("in background").
  background,

  /// The server's link was down ("disconnected").
  disconnected,

  /// Sampling ran but a reading was lost: a request missed its deadline,
  /// a framing error lost its reply, or the sampler restarted (03 §6.2).
  readingLost,
}

/// Why a [CollectorUnavailable] has no value: the HWS/1 section statuses
/// other than `ok` (03 §6.2).
enum CollectorUnavailableReason {
  /// A tool the collector needs is absent on the host.
  missing,

  /// The host refused the collector, such as with a permission error.
  denied,

  /// The `timeout` guard stopped the collector.
  timeout,

  /// The collector failed otherwise.
  error,
}

/// The reading behind a [Sample]: one variant per [SampleStream], or
/// [CollectorUnavailable]. Rates arrive as rates (D43), so the app keeps
/// no previous reading to compute them from.
@immutable
sealed class SampleResult {
  const SampleResult();
}

/// The stream's collector produced no value this time (03 §6.2). The app
/// words [reason] through its catalog (D35); [detail] is the collector's
/// error output as the host sent it, control characters stripped and
/// at most its last 4,096 characters kept, or null when there was none.
final class CollectorUnavailable extends SampleResult {
  const CollectorUnavailable(this.reason, {this.detail});

  final CollectorUnavailableReason reason;
  final String? detail;
}

/// A fleet row's reading ([SampleStream.overview], FL-07).
final class OverviewResult extends SampleResult {
  OverviewResult({
    this.cpu,
    this.memory,
    this.load,
    this.loadPerCore,
    Map<String, NetRate>? network,
    Map<MetricField, MetricWithheldReason> withheld = const {},
  }) : network = _unmodifiable(network),
       withheld = Map.unmodifiable(withheld);

  /// CPU occupancy since the previous reading; null without one to compare
  /// with (the first reading, or after a reboot or a counter reset).
  final CpuPercentages? cpu;

  final MemoryUsage? memory;

  /// The load averages as the host reports them.
  final LoadAvg? load;

  /// The one-minute load divided by the number of CPUs (7.1's load with
  /// core context); null while the engine does not know that number.
  final double? loadPerCore;

  /// Byte rates per interface since the previous reading; null without
  /// one, and empty only when the host reported no interface, so unknown
  /// never sums to zero (03 §1.2 principle 6).
  final Map<String, NetRate>? network;

  /// The values the engine left null for a reason the app words (D50):
  /// each field of this result whose `/proc` file shows a container
  /// host's figures, whether or not this reading carried it. Empty
  /// outside containers and while the probe cannot tell whether the
  /// server is one.
  final Map<MetricField, MetricWithheldReason> withheld;
}

/// The focused server's reading ([SampleStream.core], OV-01): the
/// overview's values plus per-core busy shares, disk rates, pressure and
/// uptime.
final class CoreResult extends SampleResult {
  CoreResult({
    this.cpu,
    Map<String, double>? perCpu,
    this.memory,
    this.load,
    this.loadPerCore,
    Map<String, NetRate>? network,
    Map<String, DiskRate>? disks,
    this.cpuPressure,
    this.ioPressure,
    this.memoryPressure,
    this.uptime,
    this.bootedAt,
    Map<MetricField, MetricWithheldReason> withheld = const {},
  }) : perCpu = _unmodifiable(perCpu),
       network = _unmodifiable(network),
       disks = _unmodifiable(disks),
       withheld = Map.unmodifiable(withheld);

  /// As [OverviewResult.cpu].
  final CpuPercentages? cpu;

  /// Busy percent per core (`cpu0`, `cpu1` and so on) since the previous
  /// reading, as CPU-02 shows it; null without one, as
  /// [OverviewResult.network]. The host sends each core's busy and idle
  /// jiffies only, without the per-field breakdown of [cpu] (D48).
  final Map<String, double>? perCpu;

  final MemoryUsage? memory;
  final LoadAvg? load;

  /// As [OverviewResult.loadPerCore].
  final double? loadPerCore;

  /// As [OverviewResult.network].
  final Map<String, NetRate>? network;

  /// Throughput, requests, waits and busy share per block device since
  /// the previous reading; null without one, as [OverviewResult.network].
  final Map<String, DiskRate>? disks;

  /// Pressure stall information; null where the kernel has none, which is
  /// normal (7.1).
  final StallShares? cpuPressure, ioPressure, memoryPressure;

  /// How long the host has been up.
  final Duration? uptime;

  /// When the host booted (`btime`), in UTC.
  final DateTime? bootedAt;

  /// As [OverviewResult.withheld].
  final Map<MetricField, MetricWithheldReason> withheld;
}

/// A value of [OverviewResult] or [CoreResult] that
/// [OverviewResult.withheld] or [CoreResult.withheld] can name, after
/// the `/proc` file it comes from (D50).
enum MetricField {
  /// `cpu`, from `/proc/stat`.
  cpu,

  /// [CoreResult.perCpu], from `/proc/stat`.
  perCpu,

  /// `memory`, from `/proc/meminfo`.
  memory,

  /// `load`, from `/proc/loadavg`.
  load,

  /// `loadPerCore`, from `/proc/loadavg` and the CPU count of
  /// `/proc/stat`.
  loadPerCore,

  /// [CoreResult.disks], from `/proc/diskstats`.
  disks,

  /// [CoreResult.cpuPressure], from `/proc/pressure/cpu`.
  cpuPressure,

  /// [CoreResult.ioPressure], from `/proc/pressure/io`.
  ioPressure,

  /// [CoreResult.memoryPressure], from `/proc/pressure/memory`.
  memoryPressure,

  /// [CoreResult.uptime], from `/proc/uptime`.
  uptime,

  /// [CoreResult.bootedAt], from the `btime` line of `/proc/stat`.
  bootedAt,
}

/// Why the engine left a [MetricField] null (D50).
enum MetricWithheldReason {
  /// Inside a container, the field's `/proc` file shows the container
  /// host's figures, not this system's (SYS-04): no lxcfs mount serves
  /// the container's own there, or lxcfs passes the host's through.
  containerHostFigures,
}

/// Memory as MEM-01's breakdown shows it, in bytes, which the engine
/// derives from `/proc/meminfo` with `MemAvailable` semantics (7.1). What
/// the host did not report stays null.
@immutable
final class MemoryUsage {
  const MemoryUsage({
    this.totalBytes,
    this.usedBytes,
    this.availableBytes,
    this.buffersBytes,
    this.cachedBytes,
    this.sharedBytes,
    this.swapTotalBytes,
    this.swapUsedBytes,
    this.zfsArcCountedAsUsed,
  });

  final int? totalBytes, usedBytes, availableBytes;
  final int? buffersBytes, cachedBytes, sharedBytes;
  final int? swapTotalBytes, swapUsedBytes;

  /// Whether the ZFS ARC is part of [usedBytes], and MEM-01's bar says
  /// "ZFS ARC counted as used" (7.1): true where
  /// `/proc/spl/kstat/zfs/arcstats` exists and the `meminfo` shown is the
  /// kernel's own, outside a container or without an lxcfs mount (D48).
  /// Null while the engine does not know.
  final bool? zfsArcCountedAsUsed;
}

/// One `/proc/pressure` file as 7.1 shows it: the shares of time some or
/// all tasks stalled. The host leaves out the kernel's cumulative stall
/// counter (`total`, D48). A line the file lacks stays null.
@immutable
final class StallShares {
  const StallShares({this.some, this.full});

  final StallAverages? some, full;
}

/// Stall shares in percent over the last 10, 60 and 300 seconds.
@immutable
final class StallAverages {
  const StallAverages(this.avg10, this.avg60, this.avg300);

  final double avg10, avg60, avg300;
}

Map<String, V>? _unmodifiable<V>(Map<String, V>? map) =>
    map == null ? null : Map.unmodifiable(map);

/// Mount usage and inodes ([SampleStream.fs], 7.3).
final class FsResult extends SampleResult {
  const FsResult(this.fs);

  final FsSnapshot fs;
}

/// Temperature sensors ([SampleStream.temps], HW-01): empty where the
/// host has none, as VMs and containers usually do.
final class TempsResult extends SampleResult {
  const TempsResult(this.temps);

  final TempsSnapshot temps;
}

/// GPUs ([SampleStream.gpu], HW-03): empty where the host has none the
/// collector reads.
final class GpuResult extends SampleResult {
  const GpuResult(this.gpu);

  final GpuSnapshot gpu;
}

/// SYS-01's identity ([SampleStream.identity]); virtualization comes with
/// [HostProfileChanged]. The engine resolves each value from hostnamectl,
/// then os-release and `uname`, so the host's JSON never crosses (03
/// §6.5); what the host did not report stays null.
final class IdentityResult extends SampleResult {
  const IdentityResult({
    this.hostname,
    this.osPrettyName,
    this.kernelName,
    this.kernelRelease,
    this.arch,
  });

  /// The static host name, which only hostnamectl reports.
  final String? hostname;

  final String? osPrettyName, kernelName, kernelRelease, arch;
}

/// The process list ([SampleStream.procs], 7.2).
final class ProcsResult extends SampleResult {
  ProcsResult(List<ProcessRow> processes, {this.totalProcesses, this.selection})
    : processes = List.unmodifiable(processes);

  final List<ProcessRow> processes;

  /// How many processes the host counted; above 500 it sends only some of
  /// them (D48), so PRC-01 says "showing N of M". Null when the host did
  /// not report it.
  ///
  /// [processes] can hold more: with [ProcsSelection.all], a `ps` fallback
  /// adds the processes it lists that the count missed, such as `ps`
  /// itself and those started after the count. The host left processes
  /// out when [selection] is not [ProcsSelection.all] or this count
  /// exceeds the rows, never merely because the two differ.
  final int? totalProcesses;

  /// How the host chose [processes] (D48); null when it did not report it.
  final ProcsSelection? selection;
}

/// One process as [ProcsResult] lists it (PRC-01).
@immutable
final class ProcessRow {
  const ProcessRow({
    required this.pid,
    this.parentPid,
    this.name,
    this.state,
    this.userName,
    this.uid,
    this.residentBytes,
    this.cpuPercent,
    this.startTicks,
    this.startedAt,
    this.arguments,
    this.argumentsTruncated = false,
  });

  final int pid;
  final int? parentPid;

  /// The kernel's name for it (`comm`), as the host sent it.
  final String? name;

  /// The state letter of `/proc/<pid>/stat`, such as `R` or `S`.
  final String? state;

  final String? userName;
  final int? uid;
  final int? residentBytes;

  /// Its share of one CPU since the previous reading, in percent: above
  /// 100 when it runs on several CPUs, and null on its first reading.
  final double? cpuPercent;

  /// When it started, in clock ticks after boot (field 22 of
  /// `/proc/<pid>/stat`): with [pid], what PRC-02's PID-reuse guard
  /// compares before signalling it.
  final int? startTicks;

  /// When it started by the engine's clock, UTC: the reading's time less
  /// the host's uptime, plus [startTicks] at 100 a second, the USER_HZ the
  /// CPU shares assume too (7.2). Null without either, before the probe
  /// reports its lxcfs mounts, and where lxcfs serves a container's own
  /// age as `/proc/uptime`, since start ticks count from the kernel's
  /// boot (D50).
  final DateTime? startedAt;

  /// The command line, one item per argument (per whitespace token on a
  /// host where only `ps` lists it, 7.2), each masked by 03 §8.9's rules;
  /// null when it could not be read (7.2's "command line unavailable").
  /// Pass an unmodifiable list.
  final List<MaskedValue>? arguments;

  /// Whether the host's read of the command line reached its per-file
  /// byte cap (D48), so the last of [arguments] may be cut and later ones
  /// missing. A command line of exactly the cap counts as cut too.
  final bool argumentsTruncated;
}

/// Every systemd unit and the failed ones ([SampleStream.units], 7.5).
final class UnitsResult extends SampleResult {
  const UnitsResult(this.units);

  final UnitsSnapshot units;
}

/// The failed systemd units ([SampleStream.failedUnits], OV-02).
final class FailedUnitsResult extends SampleResult {
  FailedUnitsResult(List<SystemdUnit> failed)
    : failed = List.unmodifiable(failed);

  final List<SystemdUnit> failed;
}

/// systemd timers ([SampleStream.timers], 7.7).
final class TimersResult extends SampleResult {
  const TimersResult(this.timers);

  final TimersSnapshot timers;
}

/// Cron jobs ([SampleStream.cron], 7.7): the parsed table, and its jobs
/// rows with next runs the engine evaluated at the sample's time in the
/// server's zone (D58), since the zone rules stay in the engine (D52).
final class CronResult extends SampleResult {
  CronResult(
    this.cron, {
    List<JobEntry> jobs = const [],
    this.zoneName,
    this.zoneFallback,
  }) : jobs = List.unmodifiable(jobs),
       assert(
         zoneName == null || zoneFallback == null,
         'zoneName and zoneFallback are mutually exclusive '
         '(both null means the server zone is unknown)',
       );

  final CronSnapshot cron;

  /// The cron lines, then the `cron.<period>` scripts, as jobs rows with
  /// their next runs (7.7); the timers' rows come from [TimersResult].
  final List<JobEntry> jobs;

  /// The IANA zone whose rules the server-zone runs follow; null when
  /// they follow the probe's fixed offset or no server zone is known.
  final String? zoneName;

  /// Why the server-zone runs follow the probe's fixed offset; null when
  /// they follow [zoneName]'s rules or no server zone is known, in which
  /// case those rows give `JobRunsUnknown.serverZoneUnknown`.
  final CronZoneFallback? zoneFallback;
}

/// Why [CronResult]'s server-zone runs follow the probe's fixed offset
/// instead of a zone's rules, so no DST change after now shows in them
/// (7.7, D58).
enum CronZoneFallback {
  /// The probe found no IANA zone name.
  noZoneName,

  /// The client's zone database has no zone of that name.
  unknownZone,

  /// The database's offset for the zone at the probe's clock reading
  /// differs from the offset the server reported: the name is stale or
  /// the two zone databases disagree.
  offsetMismatch,
}
