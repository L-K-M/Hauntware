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

  /// anacron runs the directory, and the MVP does not model its timing
  /// (JOB-04 is v1). The payload shows anacron installed, and the
  /// directory's `run-parts` lines all defer to it or, for the daily,
  /// weekly and monthly directories, none exists (cronie-anacron).
  anacron,

  /// Neither a cron line nor anacron runs the directory.
  noDriver,
}

/// One row of the unified jobs list (03 §7.7). Only [mergeJobs] builds
/// cron and periodic rows, which keeps their invariants internal.
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
  CronJobEntry._({
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
/// schedules and merged runs of every cron line that runs its directory
/// through `run-parts` without deferring to anacron.
final class PeriodicJobEntry extends JobEntry {
  PeriodicJobEntry._({
    required this.entry,
    List<String> driverIds = const [],
    List<CronSchedule> schedules = const [],
    List<CronRun> nextRuns = const [],
    this.runsUnknown,
  }) : driverIds = List.unmodifiable(driverIds),
       schedules = List.unmodifiable(schedules),
       nextRuns = List.unmodifiable(nextRuns),
       assert(nextRuns.isEmpty != (runsUnknown == null));

  final CronDirEntry entry;

  /// The ids of every cron entry whose `run-parts` line names the
  /// directory, in source order.
  final List<String> driverIds;

  /// The schedules of the lines that run the directory themselves.
  @override
  final List<CronSchedule> schedules;

  /// Those lines' upcoming runs merged in order, one per instant.
  final List<CronRun> nextRuns;

  /// Why [nextRuns] is empty; null when it is not.
  final JobRunsUnknown? runsUnknown;

  /// The directory path, `/etc/cron.<period>`.
  String get directory => _periodDirectory(entry.period);

  @override
  String get id => 'periodic|${entry.period.name}|${entry.name}';

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
    'schedules': schedules.map((s) => s.toJson()).toList(),
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
    List<ScheduleDescription>? triggers,
    this.randomizedDelay,
  }) : triggers = triggers == null ? null : List.unmodifiable(triggers);

  final SystemdTimer timer;

  /// The timer's `OnCalendar=` and monotonic triggers; null until the
  /// timer properties are collected, so an empty list means none.
  final List<ScheduleDescription>? triggers;

  /// `RandomizedDelaySec=`; null until the timer properties are
  /// collected.
  final Duration? randomizedDelay;

  @override
  String get id => 'timer|${timer.unit}';

  @override
  List<ScheduleDescription> get schedules => triggers ?? const [];

  @override
  DateTime? get nextRunUtc => timer.nextUtc;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'timer',
    'id': id,
    'timer': timer.toJson(),
    'triggers': triggers?.map((s) => s.toJson()).toList(),
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

  final dirEntries = cron?.dirEntries ?? const <CronDirEntry>[];
  // Package files that only an installed anacron leaves: the 0anacron
  // hooks (Debian's daily/weekly/monthly, cronie-anacron's hourly) and
  // Debian's /etc/cron.d/anacron.
  final anacron =
      dirEntries.any((e) => e.name == '0anacron') ||
      cronEntries.any((e) => e.job.source == '/etc/cron.d/anacron');
  final periodic = [
    for (final entry in dirEntries)
      _periodicEntry(entry, cronEntries, runCount, anacron: anacron),
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
    return CronJobEntry._(
      id: id,
      job: job,
      runsUnknown: JobRunsUnknown.unparsed,
    );
  }

  // An empty `CRON_TZ=` counts as unset, here and in [_cronZone].
  final cronTz = (job.cronTz?.isEmpty ?? true) ? null : job.cronTz;
  final schedule = CronSchedule(
    text: job.schedule,
    expression: expression,
    timeZone: cronTz,
  );
  if (expression.isReboot) {
    return CronJobEntry._(
      id: id,
      job: job,
      schedule: schedule,
      runsUnknown: JobRunsUnknown.reboot,
    );
  }

  final runZone = _cronZone(cronTz, zone, zoneFor);
  if (runZone == null) {
    return CronJobEntry._(
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
  return CronJobEntry._(
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
/// resolved.
ServerZone? _cronZone(
  String? cronTz,
  ServerZone server,
  CronZoneResolver? zoneFor,
) {
  if (cronTz == null) return server;

  final resolved = zoneFor?.call(cronTz);
  if (resolved != null) return resolved;
  if (cronTz == server.ianaName) return server;
  if (_utcNames.contains(cronTz)) {
    return ServerZone(offset: Duration.zero, ianaName: cronTz);
  }
  return null;
}

/// A periodic script with the schedules of the `run-parts` lines for its
/// directory that do not defer to anacron, and the first [runCount] of
/// their runs. Debian's `test -x /usr/sbin/anacron || run-parts ...`
/// lines do nothing while [anacron] is installed and run the directory
/// otherwise; anacron's own delays are v1 (JOB-04). Without runs, the
/// first direct line's reason stands.
PeriodicJobEntry _periodicEntry(
  CronDirEntry entry,
  List<CronJobEntry> cronEntries,
  int runCount, {
  required bool anacron,
}) {
  final directory = _periodDirectory(entry.period);
  final drivers = cronEntries
      .where((e) => _runsParts(e.job.command, directory))
      .toList();
  final driverIds = [for (final d in drivers) d.id];
  final direct = drivers
      .where((d) => !(anacron && d.job.command.contains('anacron')))
      .toList();

  if (direct.isEmpty) {
    // anacron's default anacrontab runs the daily, weekly and monthly
    // directories, not the hourly one.
    final byAnacron =
        drivers.isNotEmpty || (anacron && entry.period != CronPeriod.hourly);
    return PeriodicJobEntry._(
      entry: entry,
      driverIds: driverIds,
      runsUnknown: byAnacron ? JobRunsUnknown.anacron : JobRunsUnknown.noDriver,
    );
  }
  final instants = <DateTime>{};
  final runs = [for (final d in direct) ...d.nextRuns]
    ..sort((a, b) => a.atUtc.compareTo(b.atUtc));
  final merged = runs
      .where((r) => instants.add(r.atUtc))
      .take(runCount)
      .toList();
  return PeriodicJobEntry._(
    entry: entry,
    driverIds: driverIds,
    schedules: [for (final d in direct) ?d.schedule],
    nextRuns: merged,
    runsUnknown: merged.isEmpty ? direct.first.runsUnknown : null,
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
