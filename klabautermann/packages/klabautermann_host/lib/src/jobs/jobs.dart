/// The unified jobs list (03 §7.7, JOB-01, JOB-02): cron lines, the
/// `cron.{hourly,daily,weekly,monthly}` scripts and systemd timers in
/// one list, each with its schedule description and next runs.
library;

import 'package:meta/meta.dart';

import '../commands/commands.dart';
import '../cron/evaluate.dart';
import '../cron/expression.dart';
import '../hws/collector.dart' show ArgValidators;
import '../parse/cron.dart';
import '../parse/oncalendar.dart';
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

  /// The line runs in the server's zone, which is not known, such as
  /// before a probe has reported its offset.
  serverZoneUnknown,

  /// No minute within the evaluation horizon matches (`0 0 30 2 *`).
  noRunInHorizon,

  /// The line lies past [mergeJobs]'s evaluation limit, which bounds the
  /// work a huge crontab costs.
  notEvaluated,

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

  /// This row carrying [shown] in place of its line.
  CronJobEntry _showing(CronJob shown) => CronJobEntry._(
    id: id,
    job: shown,
    schedule: schedule,
    nextRuns: nextRuns,
    runsUnknown: runsUnknown,
  );

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
  /// The scripts of one directory share [drivers]' lists.
  PeriodicJobEntry._(this.entry, _DirectoryDrivers drivers)
    : driverIds = drivers.driverIds,
      schedules = drivers.schedules,
      nextRuns = drivers.nextRuns,
      runsUnknown = drivers.runsUnknown;

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
  /// timer properties are collected, and when a read listed none.
  final List<ScheduleDescription>? triggers;

  /// `RandomizedDelaySec=`; null until the timer properties are
  /// collected, and when `systemctl show` gave no readable value.
  final Duration? randomizedDelay;

  /// This row with [detail]'s triggers and randomized delay (03 §7.7,
  /// D57). Each calendar trigger takes the elapses and normalized form of
  /// its entry in [calendars], the [parseOnCalendar] results of
  /// [timerCalendarCommands]' reads keyed by expression; without one, or
  /// when systemd rejected the expression, its elapses stay unknown.
  ///
  /// A [detail] without a calendar or monotonic trigger leaves triggers
  /// and delay unknown: `systemctl show` prints that for a unit no longer
  /// loaded, with a default delay of 0, and for a timer with only
  /// `OnClockChange=` or `OnTimezoneChange=`, which it does not list.
  TimerJobEntry withDetail(
    TimerDetail detail, {
    Map<String, OnCalendarResult> calendars = const {},
  }) {
    if (detail.calendar.isEmpty && detail.monotonic.isEmpty) {
      return TimerJobEntry(timer: timer);
    }

    return TimerJobEntry(
      timer: timer,
      triggers: [
        for (final expression in detail.calendar)
          _calendarTrigger(expression, calendars[expression]),
        ...detail.monotonic,
      ],
      randomizedDelay: detail.randomizedDelay,
    );
  }

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

CalendarSchedule _calendarTrigger(String expression, OnCalendarResult? result) {
  final evaluated = result == null ? null : CalendarSchedule.fromResult(result);
  return evaluated ?? CalendarSchedule(normalized: expression);
}

/// The `systemd-analyze calendar` reads that give [detail]'s calendar
/// triggers their next runs (03 §7.7, D57): a [HostCommands.onCalendar]
/// argv per expression, for [runCount] runs. Below systemd 242
/// ([systemdMajor]) the command has no `--iterations` and the read
/// yields one run. An expression the host sent that the builder would
/// refuse gets no read, and its elapses stay unknown.
Map<String, List<String>> timerCalendarCommands(
  TimerDetail detail, {
  required int runCount,
  int? systemdMajor,
}) => {
  for (final expression in detail.calendar)
    if (ArgValidators.calendarExpression(expression) == null)
      expression: HostCommands.onCalendar(
        expression,
        iterations: runCount,
        systemdMajor: systemdMajor,
      ),
};

/// Resolves a `CRON_TZ` name to a zone, or null when unknown.
typedef CronZoneResolver = ServerZone? Function(String timeZone);

/// Merges one tick of the `cron` and `timers` collectors into the jobs
/// list (03 §7.7): cron lines in payload order, then the periodic
/// scripts, then the timers. Either snapshot may be absent.
///
/// Cron lines run in [zone], the server zone from the probe, unless a
/// `CRON_TZ` applies: [zoneFor] resolves it first, then a name equal to
/// the server zone's or a UTC alias, and the line follows that zone's
/// clock under [zone]'s repeated hours ([CronClock.line]); an empty
/// `CRON_TZ=` keeps [zone] but follows [CronClock.line] too. A null [zone]
/// means the server zone is unknown, and lines without a `CRON_TZ` list
/// no runs. Each lists up to [runCount] runs strictly after [nowUtc];
/// with an [evaluateLimit], only that many lines in payload order get
/// their runs evaluated, and later ones give
/// [JobRunsUnknown.notEvaluated]. [shownJob], when given, is the line
/// each cron row carries, applied after the `run-parts` lines are read
/// from the real commands: the engine masks commands with it (03 §8.9).
/// Pure; throws only for a nonpositive [runCount], a caller error.
List<JobEntry> mergeJobs({
  CronSnapshot? cron,
  TimersSnapshot? timers,
  required DateTime nowUtc,
  required ServerZone? zone,
  CronZoneResolver? zoneFor,
  int runCount = 5,
  int? evaluateLimit,
  CronJob Function(CronJob job)? shownJob,
}) {
  if (runCount <= 0) {
    throw ArgumentError.value(runCount, 'runCount', 'must be positive');
  }

  var evaluated = 0;
  List<CronRun>? evaluate(
    CronExpression expression,
    ServerZone runZone,
    CronClock clock,
  ) {
    if (evaluateLimit != null && evaluated >= evaluateLimit) return null;

    evaluated++;
    return nextCronRuns(
      expression,
      afterUtc: nowUtc,
      zone: runZone,
      clock: clock,
      serverZone: clock == CronClock.line ? zone : null,
      count: runCount,
    );
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
        zone: zone,
        zoneFor: zoneFor,
        evaluate: evaluate,
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
  // Once per directory, not per script: matching every script against
  // every line is quadratic in a large payload.
  final drivers = <CronPeriod, _DirectoryDrivers>{};
  final periodic = [
    for (final entry in dirEntries)
      PeriodicJobEntry._(
        entry,
        drivers[entry.period] ??= _directoryDrivers(
          entry.period,
          cronEntries,
          runCount,
          anacron: anacron,
        ),
      ),
  ];

  return [
    for (final entry in cronEntries)
      shownJob == null ? entry : entry._showing(shownJob(entry.job)),
    ...periodic,
    for (final timer in timers?.timers ?? const <SystemdTimer>[])
      TimerJobEntry(timer: timer),
  ];
}

/// The row of [job]; [evaluate] lists its runs in a zone by a clock, or
/// returns null past the evaluation limit.
CronJobEntry _cronEntry(
  String id,
  CronJob job, {
  required ServerZone? zone,
  required CronZoneResolver? zoneFor,
  required List<CronRun>? Function(CronExpression, ServerZone, CronClock)
  evaluate,
}) {
  final expression = job.expression;
  if (expression == null) {
    return CronJobEntry._(
      id: id,
      job: job,
      runsUnknown: JobRunsUnknown.unparsed,
    );
  }

  // An empty `CRON_TZ=` names no zone, here and in [_cronZone], so the
  // line runs in the server's zone; the clock below reads the raw value.
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
      runsUnknown: cronTz == null
          ? JobRunsUnknown.serverZoneUnknown
          : JobRunsUnknown.timeZoneUnresolved,
    );
  }

  // cronie converts its minutes into any CRON_TZ zone, even one named
  // like its own, and matches the line there. An empty value stays in
  // the line's environment, so cronie skips that line during catch-up
  // like any other CRON_TZ line (D58).
  final clock = job.cronTz == null ? CronClock.server : CronClock.line;
  final runs = evaluate(expression, runZone, clock);
  if (runs == null) {
    return CronJobEntry._(
      id: id,
      job: job,
      schedule: schedule,
      runsUnknown: JobRunsUnknown.notEvaluated,
    );
  }
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
  ServerZone? server,
  CronZoneResolver? zoneFor,
) {
  if (cronTz == null) return server;

  final resolved = zoneFor?.call(cronTz);
  if (resolved != null) return resolved;
  if (server != null && cronTz == server.ianaName) return server;
  if (_utcNames.contains(cronTz)) {
    return ServerZone(offset: Duration.zero, ianaName: cronTz);
  }
  return null;
}

/// What every script in one `cron.<period>` directory takes from the
/// cron lines (see [PeriodicJobEntry]'s fields).
final class _DirectoryDrivers {
  _DirectoryDrivers({
    List<String> driverIds = const [],
    List<CronSchedule> schedules = const [],
    List<CronRun> nextRuns = const [],
    this.runsUnknown,
  }) : driverIds = List.unmodifiable(driverIds),
       schedules = List.unmodifiable(schedules),
       nextRuns = List.unmodifiable(nextRuns),
       assert(nextRuns.isEmpty != (runsUnknown == null));

  final List<String> driverIds;
  final List<CronSchedule> schedules;
  final List<CronRun> nextRuns;
  final JobRunsUnknown? runsUnknown;
}

/// The schedules of the `run-parts` lines for [period]'s directory that
/// do not defer to anacron, and the first [runCount] of their runs.
/// Debian's `test -x /usr/sbin/anacron || run-parts ...` lines do
/// nothing while [anacron] is installed and run the directory otherwise;
/// anacron's own delays are v1 (JOB-04). Without runs, the first direct
/// line's reason stands.
_DirectoryDrivers _directoryDrivers(
  CronPeriod period,
  List<CronJobEntry> cronEntries,
  int runCount, {
  required bool anacron,
}) {
  final directory = _periodDirectory(period);
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
        drivers.isNotEmpty || (anacron && period != CronPeriod.hourly);
    return _DirectoryDrivers(
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
  return _DirectoryDrivers(
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
