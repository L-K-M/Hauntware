/// The unified jobs list (03 §7.7, JOB-01, JOB-02): cron lines, the
/// `cron.{hourly,daily,weekly,monthly}` scripts and systemd timers in
/// one list, each with its schedule description and next runs.
library;

import 'package:meta/meta.dart';

import '../cron/evaluate.dart';
import '../parse/cron.dart';
import '../parse/timers.dart';
import 'schedule.dart';

/// Why a cron line or periodic script lists no next runs (03 §7.7).
/// The app words each reason; none of them carries text.
enum JobRunsUnknown {
  /// `@reboot`: the job runs when the cron daemon starts.
  reboot,

  /// The schedule does not parse.
  unparsed,

  /// `CRON_TZ` names a zone the client cannot resolve.
  timeZoneUnresolved,

  /// No minute within the evaluation horizon matches (`0 0 30 2 *`).
  noRunInHorizon,

  /// Every `run-parts` line for the directory defers to anacron, whose
  /// timing the MVP does not model (JOB-04 is v1).
  anacron,

  /// No cron line runs the directory through `run-parts`.
  noDriver,
}

/// One row of the unified jobs list (03 §7.7).
@immutable
sealed class JobEntry {
  const JobEntry();

  /// A key unique within one merged list and stable while the sources
  /// keep their order.
  String get id;

  /// The triggers that schedule the job; empty when none is known.
  List<ScheduleDescription> get schedules;

  /// The next run, when known.
  DateTime? get nextRunUtc;

  Map<String, Object?> toJson();
}

/// A crontab line (03 §7.7).
final class CronJobEntry extends JobEntry {
  CronJobEntry({
    required this.id,
    required this.job,
    this.schedule,
    List<CronRun> nextRuns = const [],
    this.runsUnknown,
  }) : nextRuns = List.unmodifiable(nextRuns),
       assert(nextRuns.isEmpty != (runsUnknown == null));

  @override
  final String id;

  final CronJob job;

  /// The parsed schedule; null when the line's schedule does not parse.
  final CronSchedule? schedule;

  /// Upcoming runs with their DST annotations, in order.
  final List<CronRun> nextRuns;

  /// Why [nextRuns] is empty; null when it is not.
  final JobRunsUnknown? runsUnknown;

  @override
  List<ScheduleDescription> get schedules => [?schedule];

  @override
  DateTime? get nextRunUtc => nextRuns.firstOrNull?.atUtc;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'cron',
    'id': id,
    'source': job.source,
    'user': job.user,
    'command': job.command,
    'raw': job.raw,
    'schedule': schedule?.toJson(),
    'nextRuns': nextRuns.map((r) => r.toJson()).toList(),
    'runsUnknown': runsUnknown?.name,
  };
}

/// A script in a `cron.<period>` directory (JOB-01). It takes the
/// schedule and runs of the first cron line that runs its directory
/// through `run-parts` without deferring to anacron.
final class PeriodicJobEntry extends JobEntry {
  PeriodicJobEntry({
    required this.entry,
    List<String> driverIds = const [],
    this.schedule,
    List<CronRun> nextRuns = const [],
    this.runsUnknown,
  }) : driverIds = List.unmodifiable(driverIds),
       nextRuns = List.unmodifiable(nextRuns),
       assert(nextRuns.isEmpty != (runsUnknown == null));

  final CronDirEntry entry;

  /// The ids of every cron entry whose `run-parts` line names the
  /// directory, in source order.
  final List<String> driverIds;

  /// The driving line's schedule, when one runs the directory itself.
  final CronSchedule? schedule;

  /// The driving line's upcoming runs.
  final List<CronRun> nextRuns;

  /// Why [nextRuns] is empty; null when it is not.
  final JobRunsUnknown? runsUnknown;

  /// The directory path, `/etc/cron.<period>`.
  String get directory => _periodDirectory(entry.period);

  @override
  String get id => 'periodic|${entry.period.name}|${entry.name}';

  @override
  List<ScheduleDescription> get schedules => [?schedule];

  @override
  DateTime? get nextRunUtc => nextRuns.firstOrNull?.atUtc;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'periodic',
    'id': id,
    'period': entry.period.name,
    'name': entry.name,
    'directory': directory,
    'driverIds': driverIds,
    'schedule': schedule?.toJson(),
    'nextRuns': nextRuns.map((r) => r.toJson()).toList(),
    'runsUnknown': runsUnknown?.name,
  };
}

/// A systemd timer (JOB-01). Its next and last elapse come from
/// `systemctl list-timers`, where systemd has already applied the zone
/// and DST.
final class TimerJobEntry extends JobEntry {
  TimerJobEntry({
    required this.timer,
    List<ScheduleDescription> schedules = const [],
    this.randomizedDelay,
  }) : schedules = List.unmodifiable(schedules);

  final SystemdTimer timer;

  /// The timer's `OnCalendar=` and monotonic triggers; empty until the
  /// timer properties are collected.
  @override
  final List<ScheduleDescription> schedules;

  /// `RandomizedDelaySec=`; null until the timer properties are
  /// collected.
  final Duration? randomizedDelay;

  @override
  String get id => 'timer|${timer.unit}';

  @override
  DateTime? get nextRunUtc => timer.nextUtc;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'timer',
    'id': id,
    'timer': timer.toJson(),
    'schedules': schedules.map((s) => s.toJson()).toList(),
    'randomizedDelayUs': randomizedDelay?.inMicroseconds,
  };
}

/// Resolves a `CRON_TZ` name to a zone, or null when unknown.
typedef CronZoneResolver = ServerZone? Function(String timeZone);

/// Merges one tick of the `cron` and `timers` collectors into the jobs
/// list (03 §7.7): cron lines in payload order, then the periodic
/// scripts, then the timers. Either snapshot may be absent.
///
/// Cron lines run in [zone], the server zone from the probe, unless a
/// `CRON_TZ` applies: [zoneFor] resolves it first, then a name equal to
/// the server zone's or a UTC alias. Each lists up to [runCount] runs
/// strictly after [nowUtc]. Pure; throws only for a nonpositive
/// [runCount], a caller error.
List<JobEntry> mergeJobs({
  CronSnapshot? cron,
  TimersSnapshot? timers,
  required DateTime nowUtc,
  required ServerZone zone,
  CronZoneResolver? zoneFor,
  int runCount = 5,
}) {
  if (runCount <= 0) {
    throw ArgumentError.value(runCount, 'runCount', 'must be positive');
  }

  final cronEntries = <CronJobEntry>[];
  final ordinals = <String, int>{};
  for (final job in cron?.jobs ?? const <CronJob>[]) {
    final ordinal = ordinals[job.source] ?? 0;
    ordinals[job.source] = ordinal + 1;
    cronEntries.add(
      _cronEntry(
        'cron|${job.source}|$ordinal',
        job,
        nowUtc: nowUtc,
        zone: zone,
        zoneFor: zoneFor,
        runCount: runCount,
      ),
    );
  }

  final periodic = [
    for (final entry in cron?.dirEntries ?? const <CronDirEntry>[])
      _periodicEntry(entry, cronEntries),
  ];

  return [
    ...cronEntries,
    ...periodic,
    for (final timer in timers?.timers ?? const <SystemdTimer>[])
      TimerJobEntry(timer: timer),
  ];
}

CronJobEntry _cronEntry(
  String id,
  CronJob job, {
  required DateTime nowUtc,
  required ServerZone zone,
  required CronZoneResolver? zoneFor,
  required int runCount,
}) {
  final expression = job.expression;
  if (expression == null) {
    return CronJobEntry(id: id, job: job, runsUnknown: JobRunsUnknown.unparsed);
  }

  final schedule = CronSchedule(
    text: job.schedule,
    expression: expression,
    timeZone: job.cronTz,
  );
  if (expression.isReboot) {
    return CronJobEntry(
      id: id,
      job: job,
      schedule: schedule,
      runsUnknown: JobRunsUnknown.reboot,
    );
  }

  final runZone = _cronZone(job.cronTz, zone, zoneFor);
  if (runZone == null) {
    return CronJobEntry(
      id: id,
      job: job,
      schedule: schedule,
      runsUnknown: JobRunsUnknown.timeZoneUnresolved,
    );
  }

  final runs = nextCronRuns(
    expression,
    afterUtc: nowUtc,
    zone: runZone,
    count: runCount,
  );
  return CronJobEntry(
    id: id,
    job: job,
    schedule: schedule,
    nextRuns: runs,
    runsUnknown: runs.isEmpty ? JobRunsUnknown.noRunInHorizon : null,
  );
}

/// UTC spellings a `CRON_TZ` may use that need no zone database.
const _utcNames = {'UTC', 'Etc/UTC', 'GMT', 'Etc/GMT'};

/// The zone a line with [cronTz] runs in, or null when it cannot be
/// resolved. An empty `CRON_TZ=` counts as unset.
ServerZone? _cronZone(
  String? cronTz,
  ServerZone server,
  CronZoneResolver? zoneFor,
) {
  if (cronTz == null || cronTz.isEmpty) return server;

  final resolved = zoneFor?.call(cronTz);
  if (resolved != null) return resolved;
  if (cronTz == server.ianaName) return server;
  if (_utcNames.contains(cronTz)) {
    return ServerZone(offset: Duration.zero, ianaName: cronTz);
  }
  return null;
}

/// A periodic script with the schedule of the first `run-parts` line for
/// its directory that does not defer to anacron. Debian's
/// `test -x /usr/sbin/anacron || run-parts ...` lines do nothing while
/// anacron is installed, and anacron's own delays are v1 (JOB-04).
PeriodicJobEntry _periodicEntry(
  CronDirEntry entry,
  List<CronJobEntry> cronEntries,
) {
  final directory = _periodDirectory(entry.period);
  final drivers = cronEntries
      .where((e) => _runsParts(e.job.command, directory))
      .toList();
  final driverIds = [for (final d in drivers) d.id];
  final direct = drivers
      .where((d) => !d.job.command.contains('anacron'))
      .firstOrNull;

  if (direct == null) {
    return PeriodicJobEntry(
      entry: entry,
      driverIds: driverIds,
      runsUnknown: drivers.isEmpty
          ? JobRunsUnknown.noDriver
          : JobRunsUnknown.anacron,
    );
  }
  return PeriodicJobEntry(
    entry: entry,
    driverIds: driverIds,
    schedule: direct.schedule,
    nextRuns: direct.nextRuns,
    runsUnknown: direct.runsUnknown,
  );
}

String _periodDirectory(CronPeriod period) => '/etc/cron.${period.name}';

/// Whether [command] runs `run-parts` over [directory].
bool _runsParts(String command, String directory) {
  final words = command.split(RegExp(r'[\s;]+'));
  final runParts = words.any(
    (w) => w == 'run-parts' || w.endsWith('/run-parts'),
  );
  return runParts && words.any((w) => w == directory || w == '$directory/');
}
