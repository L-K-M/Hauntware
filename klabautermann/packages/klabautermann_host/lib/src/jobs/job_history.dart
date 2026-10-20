/// What the jobs view knows of past runs (03 §7.7 v1): anacron's jobs and
/// the day each last ran (JOB-04), a timer's last trigger with its
/// service's result, and the runs cron logged (JOB-05). Each parser takes
/// the output of a [HostCommands] builder run through `commandLine`,
/// which exports `TZ=UTC`, and never throws on host input.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show HostCommands, kAnacronStampsMarker, kCronJournalIdentifiers;
import '../parse/journal.dart' show JournalEntry;
import '../parse/parse_result.dart';

/// How often an anacron job runs: every [days] days, or once a calendar
/// month, which anacron's `@monthly` counts in calendar months.
@immutable
final class AnacronPeriod {
  const AnacronPeriod.days(int this.days) : monthly = false;
  const AnacronPeriod.monthly() : days = null, monthly = true;

  /// The period in days, or null for [monthly].
  final int? days;

  /// Whether the job runs once a calendar month (`@monthly`).
  final bool monthly;

  @override
  bool operator ==(Object other) =>
      other is AnacronPeriod && other.days == days && other.monthly == monthly;

  @override
  int get hashCode => Object.hash(days, monthly);

  @override
  String toString() => monthly ? '@monthly' : '${days}d';
}

/// One `/etc/anacrontab` job (JOB-04): `period delay identifier command`.
@immutable
final class AnacronJob {
  const AnacronJob({
    required this.period,
    required this.delayMinutes,
    required this.identifier,
    required this.command,
    this.lastRun,
  });

  final AnacronPeriod period;

  /// Minutes anacron waits after starting before it runs the job.
  final int delayMinutes;

  /// The job's name, which is also its stamp file's.
  final String identifier;

  final String command;

  /// The day the job last ran, from its stamp, or null when it has none.
  final DateTime? lastRun;

  Map<String, Object?> toJson() => {
    'period': period.toString(),
    'delayMinutes': delayMinutes,
    'identifier': identifier,
    'command': command,
    'lastRun': lastRun?.toIso8601String(),
  };
}

/// anacron's `@` periods; `@weekly` and `@daily` are 7 and 1 days.
const _namedPeriods = {
  '@daily': AnacronPeriod.days(1),
  '@weekly': AnacronPeriod.days(7),
  '@monthly': AnacronPeriod.monthly(),
};

final _envLine = RegExp(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=');
// A delay of up to nine digits, so it always parses as an int.
final _anacronJob = RegExp(r'^\s*(\S+)\s+(\d{1,9})\s+(\S+)\s+(.+)$');
final _stamp = RegExp(r'^(\S+) (\d{4})(\d\d)(\d\d)\s*$');

/// Reads [HostCommands.anacron]'s output: the table's jobs, each with the
/// day its stamp records. Environment lines and comments are skipped;
/// malformed lines warn.
ParseResult<List<AnacronJob>> parseAnacron(String raw) {
  final warnings = <String>[];
  final lines = const LineSplitter().convert(raw);
  final marker = lines.indexOf(kAnacronStampsMarker);
  final table = marker < 0 ? lines : lines.sublist(0, marker);
  if (marker < 0) warnings.add('anacron: no stamps section');

  final stamps = <String, DateTime>{};
  for (final line in marker < 0 ? const <String>[] : lines.skip(marker + 1)) {
    if (line.isEmpty) continue;
    final m = _stamp.firstMatch(line);
    if (m == null) {
      if (!line.endsWith(' ?')) warnings.add('anacron: stamp "$line"');
      continue;
    }
    final (year, month, day) = (
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
    );
    final date = DateTime.utc(year, month, day);
    // DateTime rolls an impossible date such as 20261340 over silently.
    if (date.month != month || date.day != day) {
      warnings.add('anacron: stamp "$line"');
      continue;
    }
    stamps[m[1]!] = date;
  }

  final jobs = <AnacronJob>[];
  for (final line in table) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#') || _envLine.hasMatch(line)) continue;
    final m = _anacronJob.firstMatch(line);
    final period = m == null ? null : _period(m[1]!);
    if (m == null || period == null) {
      warnings.add('anacron: line "$t"');
      continue;
    }
    jobs.add(
      AnacronJob(
        period: period,
        delayMinutes: int.parse(m[2]!),
        identifier: m[3]!,
        command: m[4]!.trim(),
        lastRun: stamps[m[3]!],
      ),
    );
  }
  return ParseResult(List.unmodifiable(jobs), warnings);
}

AnacronPeriod? _period(String field) {
  final named = _namedPeriods[field];
  if (named != null) return named;
  final days = int.tryParse(field);
  return days != null && days > 0 ? AnacronPeriod.days(days) : null;
}

/// A timer's last run (JOB-05): when it last triggered and how the run of
/// the unit it activates ended.
@immutable
final class TimerLastRun {
  const TimerLastRun({
    this.lastTrigger,
    this.result,
    this.exitStatus,
    this.finished,
  });

  /// The timer's `LastTriggerUSec`, null when it never triggered.
  final DateTime? lastTrigger;

  /// The service's `Result`: `success`, `exit-code`, `timeout` and so on.
  final String? result;

  /// The service's `ExecMainStatus`, its main process's exit status.
  final int? exitStatus;

  /// The service's `ExecMainExitTimestamp`, when its main process ended.
  final DateTime? finished;

  Map<String, Object?> toJson() => {
    'lastTrigger': lastTrigger?.toIso8601String(),
    'result': result,
    'exitStatus': exitStatus,
    'finished': finished?.toIso8601String(),
  };
}

final _utcTimestamp = RegExp(
  r'^\w+ (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC$',
);

/// Reads [HostCommands.timerLastRun]'s two `systemctl show` blocks, told
/// apart by their `Id`: the timer's trigger, the service's result.
ParseResult<TimerLastRun> parseTimerLastRun(String raw) {
  final warnings = <String>[];
  final blocks = <Map<String, String>>[{}];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty) {
      if (blocks.last.isNotEmpty) blocks.add({});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq > 0) blocks.last[line.substring(0, eq)] = line.substring(eq + 1);
  }

  final timer = blocks.firstWhere(
    (b) => b['Id']?.endsWith('.timer') ?? false,
    orElse: () => const {},
  );
  final service = blocks.firstWhere(
    (b) => b['Id'] != null && !b['Id']!.endsWith('.timer'),
    orElse: () => const {},
  );
  if (timer.isEmpty) warnings.add('timer last run: no timer block');
  if (service.isEmpty) warnings.add('timer last run: no service block');

  DateTime? stamp(Map<String, String> block, String key) {
    final value = block[key];
    if (value == null || value.isEmpty || value == 'n/a') return null;
    final m = _utcTimestamp.firstMatch(value);
    if (m == null) {
      warnings.add('$key: "$value"');
      return null;
    }
    int g(int i) => int.parse(m[i]!);
    return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  }

  final result = service['Result'];
  return ParseResult(
    TimerLastRun(
      lastTrigger: stamp(timer, 'LastTriggerUSec'),
      result: result == null || result.isEmpty ? null : result,
      exitStatus: int.tryParse(service['ExecMainStatus'] ?? ''),
      finished: stamp(service, 'ExecMainExitTimestamp'),
    ),
    warnings,
  );
}

/// One job start cron logged (JOB-05). cron records when it started a
/// job and as whom, never how the job ended.
@immutable
final class LoggedCronRun {
  const LoggedCronRun({
    required this.at,
    required this.user,
    required this.command,
  });

  /// When cron started the job.
  final DateTime at;

  /// The user the job ran as.
  final String user;

  /// The command, as cron logged it.
  final String command;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'user': user,
    'command': command,
  };
}

/// Debian's cron and cronie: `(root) CMD (command)`.
final _cmdLine = RegExp(r'^\((\S+)\) CMD \((.*)\)$');

/// BusyBox crond: `USER root pid 123 cmd command`.
final _busyboxLine = RegExp(r'^USER (\S+) pid \d+ cmd (.*)$');

/// The job starts among [entries], a [HostCommands.cronRuns] read, in the
/// order given. Other cron records (session opens, `END` lines, errors)
/// are not runs and are skipped.
List<LoggedCronRun> parseCronRuns(Iterable<JournalEntry> entries) => [
  for (final e in entries)
    if (kCronJournalIdentifiers.contains(e.identifier) &&
        e.timestampUtc != null)
      if ((_cmdLine.firstMatch(e.message ?? '') ??
              _busyboxLine.firstMatch(e.message ?? ''))
          case final m?)
        LoggedCronRun(at: e.timestampUtc!, user: m[1]!, command: m[2]!),
];
