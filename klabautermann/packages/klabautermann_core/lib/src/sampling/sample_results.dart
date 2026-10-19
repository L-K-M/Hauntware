/// The sealed [SampleResult]s the engine derives from parsed collector
/// payloads (03 §6.4, §10.1): rates and derived values (D43), values a
/// container host's `/proc` would supply withheld with a reason (D50),
/// and the error output of a collector without a value.
library;

import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';

import '../engine/protocol.dart';
import 'argument_masking.dart';
import 'cron_zone.dart';

/// The collector a [SampleStream] reads (03 §6.4): `units` serves both
/// the Services panel and the health card (D45).
Collector sampleStreamCollector(SampleStream stream) => switch (stream) {
  SampleStream.overview => Collector.overview,
  SampleStream.core => Collector.core,
  SampleStream.fs => Collector.fs,
  SampleStream.identity => Collector.identity,
  SampleStream.procs => Collector.procs,
  SampleStream.units || SampleStream.failedUnits => Collector.units,
  SampleStream.timers => Collector.timers,
  SampleStream.cron => Collector.cron,
};

/// K04's external-monitor rule over a `units` reading (03 §9.5 item 3).
/// The engine makes a [UnitsResult] only from an `ok` section (a failed
/// one is a [CollectorUnavailable]), so the app need not name the HWS/1
/// section status.
ExternalMonitorReport externalMonitorsIn(UnitsResult result) =>
    detectExternalMonitors(result.units, status: SectionStatus.ok);

/// The most a [CollectorUnavailable.detail] keeps of a collector's error
/// output: its end, the latest output, as the sampler's stderr ring
/// keeps. A section may carry up to 1 MiB, which would otherwise cross
/// the isolate on every tick while the collector keeps failing.
const kCollectorDetailMaxChars = 4096;

/// [section]'s status as a [CollectorUnavailable], with its payload (the
/// collector's captured error output) decoded, the program's
/// `hw_timeout=absent` lines dropped and control characters stripped
/// (03 §6.2); null for an `ok` section.
CollectorUnavailable? collectorUnavailable(HwsSection section) {
  final reason = switch (section.status) {
    SectionStatus.ok => null,
    SectionStatus.missing => CollectorUnavailableReason.missing,
    SectionStatus.denied => CollectorUnavailableReason.denied,
    SectionStatus.timeout => CollectorUnavailableReason.timeout,
    SectionStatus.error => CollectorUnavailableReason.error,
  };
  if (reason == null) return null;

  final text = stripControlChars(
    utf8
        .decode(section.payload, allowMalformed: true)
        .split('\n')
        .where((line) => line != kTimeoutAbsentMarker)
        .join('\n'),
  ).trim();
  var cut = max(0, text.length - kCollectorDetailMaxChars);
  // Step past a low surrogate, so the cut never leaves half a pair.
  if (cut > 0 && (text.codeUnitAt(cut) & 0xFC00) == 0xDC00) cut++;
  final detail = text.substring(cut);
  return CollectorUnavailable(reason, detail: detail.isEmpty ? null : detail);
}

/// The fields whose `/proc` file shows a container host's figures on the
/// system [profile] describes (D50), each with that reason. Empty when
/// the probe found no container, when it could not tell (no
/// `systemd-detect-virt` and no lxcfs mount, which would otherwise blank
/// every such host), and before the first probe answer.
Map<MetricField, MetricWithheldReason> withheldMetrics(HostProfile? profile) {
  if (profile == null) return const {};

  bool host(SystemWideProcFile file) => profile.showsHostFigures(file) ?? false;
  final stat = host(SystemWideProcFile.stat);
  final loadavg = host(SystemWideProcFile.loadavg);
  return {
    for (final (field, withheld) in [
      (MetricField.cpu, stat),
      (MetricField.perCpu, stat),
      (MetricField.bootedAt, stat),
      (MetricField.memory, host(SystemWideProcFile.meminfo)),
      (MetricField.load, loadavg),
      (MetricField.loadPerCore, loadavg || stat),
      (MetricField.disks, host(SystemWideProcFile.diskstats)),
      (MetricField.cpuPressure, host(SystemWideProcFile.pressureCpu)),
      (MetricField.ioPressure, host(SystemWideProcFile.pressureIo)),
      (MetricField.memoryPressure, host(SystemWideProcFile.pressureMemory)),
      (MetricField.uptime, host(SystemWideProcFile.uptime)),
    ])
      if (withheld) field: MetricWithheldReason.containerHostFigures,
  };
}

/// The [OverviewResult] fields; [CoreResult] adds its own.
const _overviewFields = {
  MetricField.cpu,
  MetricField.memory,
  MetricField.load,
  MetricField.loadPerCore,
};

/// One metric reading as the next one diffs against it: the snapshot
/// and the host's uptime at the reply's start (the `B` marker, 03 §6.2).
typedef _Reading<T> = ({T snapshot, double? uptime});

/// Derives one server's [OverviewResult]s and [CoreResult]s (D43). It
/// keeps the latest counters, so each reading's rates span the time since
/// the reading before, as the host's uptime measures it, also across a
/// lost reading or a sampler restart. A changed `btime` (a reboot), an
/// uptime that went back, or [reset] starts a new series: the next
/// reading has no rates. Both collectors read the same counters, so an
/// `overview` reading after a `core` one diffs against it, and back.
final class MetricDeriver {
  _Reading<OverviewSnapshot>? _last;
  _Reading<CoreSnapshot>? _lastCore;

  // Facts about the host rather than counters, which survive [reset]:
  // the boot time, the CPU count and whether a ZFS ARC exists, all from
  // the latest `core` reading, since `overview` carries none of them.
  int? _btime;
  int? _cpuCount;
  bool? _zfsArc;

  /// Drops the counters, so the next reading starts a new series.
  void reset() {
    _last = null;
    _lastCore = null;
  }

  /// Drops the counters only `core` reads (per-core and disk), so the
  /// next `core` reading starts their series while `overview` goes on.
  void forgetCore() => _lastCore = null;

  /// The results of one reply that carried [overview], [core] or both,
  /// with the host's [uptime] at its start. [profile] supplies the
  /// counter width and the container facts. A reply with neither, such
  /// as a slow sampler's, leaves the series alone: that sampler is
  /// another process, whose request may have started before the latest
  /// fast one, so its older uptime says nothing about a reboot.
  ({OverviewResult? overview, CoreResult? core}) derive({
    OverviewSnapshot? overview,
    CoreSnapshot? core,
    required double? uptime,
    required HostProfile? profile,
  }) {
    if (overview == null && core == null) return (overview: null, core: null);

    final lastUptime = _last?.uptime;
    if (uptime != null && lastUptime != null && uptime < lastUptime) {
      // A reboot that an `overview` reading saw first: the next `core`
      // reading's new `btime` must not start yet another series.
      _btime = null;
      reset();
    } else if (core?.btime != null && _btime != null && core!.btime != _btime) {
      reset();
    }
    if (core != null) {
      _btime = core.btime ?? _btime;
      if (core.perCpu.isNotEmpty) _cpuCount = core.perCpu.length;
      _zfsArc = core.zfsArc != null;
    }

    final width = profile?.counterWidth ?? CounterWidth.bits64;
    final withheld = withheldMetrics(profile);
    T? keep<T>(MetricField field, T? value) =>
        withheld.containsKey(field) ? null : value;
    // An lxcfs meminfo leaves the host's ARC out (D48). Without an lxcfs
    // mount the meminfo shown is the kernel's own, which counts it as
    // used, also while the container question is open.
    final zfsArcCountedAsUsed = switch ((_zfsArc, profile?.inContainer)) {
      (false, _) => false,
      (true, final inContainer?) => !inContainer,
      (true, null) when profile?.lxcfsMounts != null => true,
      _ => null,
    };

    // The values both results hold, against the latest reading.
    OverviewResult shared(OverviewSnapshot next) {
      final last = _last;
      final elapsed = _elapsed(last?.uptime, uptime);
      final (lastCpu, nextCpu, load) = (
        last?.snapshot.cpu,
        next.cpu,
        next.loadavg,
      );
      final cpuCount = _cpuCount;
      return OverviewResult(
        cpu: lastCpu != null && nextCpu != null
            ? keep(MetricField.cpu, cpuDeltaPercent(lastCpu, nextCpu))
            : null,
        memory: keep(
          MetricField.memory,
          _memory(next.meminfo, zfsArcCountedAsUsed),
        ),
        load: keep(MetricField.load, load),
        loadPerCore: load != null && cpuCount != null && cpuCount > 0
            ? keep(MetricField.loadPerCore, load.load1 / cpuCount)
            : null,
        // Namespaced: a container's own interfaces (D50).
        network: last != null && elapsed != null
            ? _known(
                netRates(
                  last.snapshot.netdev,
                  next.netdev,
                  elapsed,
                  width: width,
                ),
                next.netdev.length,
              )
            : null,
        withheld: {
          for (final e in withheld.entries)
            if (_overviewFields.contains(e.key)) e.key: e.value,
        },
      );
    }

    CoreResult? coreResult;
    if (core != null) {
      final o = shared(core);
      final last = _lastCore;
      final elapsed = _elapsed(last?.uptime, uptime);
      final (seconds, btime) = (core.uptimeSeconds, core.btime);
      coreResult = CoreResult(
        cpu: o.cpu,
        perCpu: last == null
            ? null
            : keep(
                MetricField.perCpu,
                _known(
                  perCpuBusyPercent(last.snapshot.perCpu, core.perCpu),
                  core.perCpu.length,
                ),
              ),
        memory: o.memory,
        load: o.load,
        loadPerCore: o.loadPerCore,
        network: o.network,
        disks: last == null || elapsed == null
            ? null
            : keep(
                MetricField.disks,
                _known(
                  diskRates(
                    last.snapshot.diskstats,
                    core.diskstats,
                    elapsed,
                    width: width,
                  ),
                  core.diskstats.length,
                ),
              ),
        cpuPressure: keep(MetricField.cpuPressure, _stall(core.cpuPressure)),
        ioPressure: keep(MetricField.ioPressure, _stall(core.ioPressure)),
        memoryPressure: keep(
          MetricField.memoryPressure,
          _stall(core.memoryPressure),
        ),
        uptime: seconds == null
            ? null
            : keep(
                MetricField.uptime,
                Duration(microseconds: (seconds * 1e6).round()),
              ),
        bootedAt: btime == null
            ? null
            : keep(
                MetricField.bootedAt,
                DateTime.fromMillisecondsSinceEpoch(btime * 1000, isUtc: true),
              ),
        withheld: withheld,
      );
    }
    final overviewResult = overview == null ? null : shared(overview);

    // The latest counters: a core reading follows its reply's overview
    // section, and holds every overview counter too.
    if (core != null) {
      _last = _lastCore = (snapshot: core, uptime: uptime);
    } else if (overview != null) {
      _last = (snapshot: overview, uptime: uptime);
    }
    return (overview: overviewResult, core: coreResult);
  }
}

/// Seconds between two uptimes; null when either is unknown or time did
/// not advance, since no rate spans that.
double? _elapsed(double? previous, double? next) {
  if (previous == null || next == null || next <= previous) return null;
  return next - previous;
}

/// [rates] unless every one of the [reported] entries reset: an empty map
/// means the host reported none (03 §1.2 principle 6), not that none
/// could be computed.
Map<String, V>? _known<V>(Map<String, V> rates, int reported) =>
    rates.isEmpty && reported > 0 ? null : rates;

/// MEM-01's breakdown in bytes from `/proc/meminfo`'s kB (7.1): used is
/// total less `MemAvailable`, and cache counts reclaimable slab as
/// procps' `free` does (`Cached` plus `SReclaimable`).
MemoryUsage? _memory(MemInfo m, bool? zfsArcCountedAsUsed) {
  if (m.fields.isEmpty) return null;

  int? bytes(int? kb) => kb == null ? null : kb * 1024;
  final cached = m.cachedKb;
  final swapTotal = m.swapTotalKb;
  final swapFree = m.swapFreeKb;
  return MemoryUsage(
    totalBytes: bytes(m.totalKb),
    usedBytes: bytes(m.usedKb),
    availableBytes: bytes(m.availableKb),
    buffersBytes: bytes(m.buffersKb),
    cachedBytes: bytes(
      cached == null ? null : cached + (m.sReclaimableKb ?? 0),
    ),
    sharedBytes: bytes(m.shmemKb),
    swapTotalBytes: bytes(swapTotal),
    swapUsedBytes: swapTotal != null && swapFree != null
        ? bytes(max(0, swapTotal - swapFree))
        : null,
    zfsArcCountedAsUsed: zfsArcCountedAsUsed,
  );
}

StallShares? _stall(Pressure? p) {
  if (p == null) return null;

  StallAverages? averages(PressureLine? line) =>
      line == null ? null : StallAverages(line.avg10, line.avg60, line.avg300);
  return StallShares(some: averages(p.some), full: averages(p.full));
}

/// `/proc/<pid>/stat`'s clock ticks per second: Linux's USER_HZ, which
/// [procCpuPercent] assumes too.
const _ticksPerSecond = 100;

/// The process list with each process's CPU share since [previous], a
/// reading [elapsed] seconds earlier (7.2, PRC-03); shares are null
/// without one. Starts count from [bootedAt], and are unknown without
/// it. The host's process count and how it chose the rows pass
/// through, so a truncated list can say "showing N of M" (D48).
ProcsResult procsResult(
  ProcsSnapshot next, {
  ProcsSnapshot? previous,
  double? elapsed,
  DateTime? bootedAt,
}) {
  final cpu = previous != null && elapsed != null
      ? procCpuPercent(previous, next, elapsed)
      : const <int, double>{};
  // One budget for every row, so that many processes cannot multiply
  // the masking's work.
  final masking = ArgumentMaskingBudget();
  return ProcsResult(
    [
      for (final p in next.processes)
        ProcessRow(
          pid: p.pid,
          parentPid: p.ppid,
          name: p.comm,
          state: p.state,
          userName: p.userName,
          uid: p.uid,
          residentBytes: p.rssKb == null ? null : p.rssKb! * 1024,
          cpuPercent: cpu[p.pid],
          startTicks: p.startTicks,
          startedAt: switch ((bootedAt, p.startTicks)) {
            (final booted?, final ticks?) => booted.add(
              Duration(
                microseconds:
                    ticks * Duration.microsecondsPerSecond ~/ _ticksPerSecond,
              ),
            ),
            _ => null,
          },
          // A `ps` fallback row joined its arguments with spaces, so their
          // boundaries are lost; it lists the whitespace tokens, so 8.9's
          // per-argument masking works on those (7.2). Masked here, so no
          // argument crosses to the app as plain text.
          arguments: switch (p.argv ?? _tokens(p.argsJoined, p.comm)) {
            null => null,
            final argv => List.unmodifiable(
              maskCommandLine(argv, budget: masking),
            ),
          },
        ),
    ],
    totalProcesses: next.totalProcesses,
    selection: next.selection,
  );
}

/// The tokens of a `ps` command line, which the host parser joins with
/// single spaces; none for an empty one, or for the bracketed [comm] that
/// GNU and BusyBox `ps` print in place of an empty `cmdline`, as for a
/// kernel thread, and that GNU `ps` follows with `<defunct>` for a zombie.
List<String>? _tokens(String? joined, String? comm) {
  if (joined == null) return null;
  if (joined.isEmpty) return const [];
  if (comm != null && (joined == '[$comm]' || joined == '[$comm] <defunct>')) {
    return const [];
  }

  return joined.split(' ');
}

/// The most cron lines whose next runs one `cron` reading evaluates.
/// A line can cost about 2 ms in the engine isolate, which every server
/// shares, and a 1 MiB section holds some 75,000 lines; later lines give
/// `JobRunsUnknown.notEvaluated`.
const kCronLinesEvaluated = 200;

/// [cron] with its jobs rows (7.7): each line's next runs after [at] in
/// the server zone of [profile] or the line's `CRON_TZ` (D58), for the
/// first [kCronLinesEvaluated] lines. Commands cross masked (8.9).
CronResult cronResult(CronSnapshot cron, HostProfile? profile, DateTime at) {
  final server = serverCronZone(profile, at);
  final shown = maskedCronJobs(cron.jobs);
  return CronResult(
    CronSnapshot(
      jobs: [for (final job in cron.jobs) shown[job]!],
      dirEntries: cron.dirEntries,
      ownCrontabPresent: cron.ownCrontabPresent,
      timeoutAbsent: cron.timeoutAbsent,
    ),
    jobs: mergeJobs(
      cron: cron,
      nowUtc: at,
      zone: server.zone,
      zoneFor: (name) => cronTzZone(name, at),
      evaluateLimit: kCronLinesEvaluated,
      shownJob: (job) => shown[job]!,
    ),
    zoneName: server.zoneName,
    zoneFallback: server.fallback,
  );
}

/// Each of [jobs] with its command and line masked by 8.9's rules, each
/// read as one command line, so a secret in a cron line reaches the app
/// only as the mask. The masker never reads the program's slot as a
/// value, so an empty program stands in front: a command that starts
/// with `NAME=secret` or `--password=…` is masked from its first word,
/// and a line's schedule is read as ordinary words. One budget covers
/// the reading, as for a procs reading. There is no reveal for cron
/// lines yet.
Map<CronJob, CronJob> maskedCronJobs(List<CronJob> jobs) {
  final budget = ArgumentMaskingBudget();
  String mask(String text) =>
      maskCommandLine(['', text], budget: budget)[1].display;
  return Map.identity()..addEntries([
    for (final job in jobs)
      MapEntry(
        job,
        CronJob(
          source: job.source,
          schedule: job.schedule,
          command: mask(job.command),
          raw: mask(job.raw),
          expression: job.expression,
          user: job.user,
          cronTz: job.cronTz,
        ),
      ),
  ]);
}

/// SYS-01's identity, resolved from hostnamectl, then os-release and
/// `uname` (03 §6.5).
IdentityResult identityResult(IdentitySnapshot s) => IdentityResult(
  hostname: s.hostname,
  osPrettyName: s.effectiveOsPrettyName,
  kernelName: s.effectiveKernelName,
  kernelRelease: s.effectiveKernelRelease,
  arch: s.effectiveArch,
);
