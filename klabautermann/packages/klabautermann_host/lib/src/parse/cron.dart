/// Parser for the `cron` slow-collector payload (03 §6.4, §7.7): the
/// invoking user's `crontab -l`, `/etc/crontab`, every `/etc/cron.d/*`
/// file and the `cron.{hourly,daily,weekly,monthly}` script names.
/// Environment lines are tracked per source because `CRON_TZ` scopes to
/// the file (or its position) it appears in.
library;

import 'package:meta/meta.dart';

import '../cron/expression.dart';
import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// The [CronJob.source] of a line in the invoking user's own crontab
/// (`crontab -l`); system crontab lines carry their file path.
const String kOwnCrontabSource = 'crontab';

/// Which `cron.{hourly,daily,weekly,monthly}` directory a script came
/// from (03 §7.7 JOB-04).
enum CronPeriod { hourly, daily, weekly, monthly }

/// One parsed cron job line (03 §7.7).
@immutable
final class CronJob {
  const CronJob({
    required this.source,
    required this.schedule,
    required this.command,
    required this.raw,
    this.expression,
    this.user,
    this.cronTz,
  });

  /// Where the line came from: `crontab`, `/etc/crontab`, or a
  /// `/etc/cron.d/<name>` path.
  final String source;

  /// The raw schedule text (5 fields or an `@` macro).
  final String schedule;

  /// The parsed schedule, or null when malformed. `@reboot` parses to an
  /// expression with `isReboot`.
  final CronExpression? expression;

  /// The system-crontab user field; null for `crontab -l` jobs.
  final String? user;

  /// The command text, verbatim (a `%` keeps its stdin meaning).
  final String command;

  /// The `CRON_TZ` in effect at this line, when set.
  final String? cronTz;

  /// The original line, for display.
  final String raw;

  Map<String, Object?> toJson() => {
    'source': source,
    'schedule': schedule,
    'command': command,
    'user': user,
    'cronTz': cronTz,
    'expression': expression?.toJson(),
    'raw': raw,
  };
}

/// One executable name inside a `cron.<period>` directory (JOB-04).
@immutable
final class CronDirEntry {
  const CronDirEntry({required this.period, required this.name});

  final CronPeriod period;

  /// The entry name inside the directory.
  final String name;

  Map<String, Object?> toJson() => {'period': period.name, 'name': name};
}

/// One `cron` tick (03 §6.4).
@immutable
final class CronSnapshot {
  CronSnapshot({
    List<CronJob>? jobs,
    List<CronDirEntry>? dirEntries,
    this.ownCrontabPresent,
    this.timeoutAbsent = false,
  }) : jobs = List.unmodifiable(jobs ?? []),
       dirEntries = List.unmodifiable(dirEntries ?? []);

  /// All parsed job lines across every source, in payload order.
  final List<CronJob> jobs;

  /// Script names inside the four periodic directories.
  final List<CronDirEntry> dirEntries;

  /// Whether the invoking user has a crontab: null when `crontab` is not
  /// installed or the result is ambiguous (03 §7.7).
  final bool? ownCrontabPresent;

  /// True when the payload reports the collector ran without `timeout`.
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'jobs': jobs.map((j) => j.toJson()).toList(),
    'dirEntries': dirEntries.map((e) => e.toJson()).toList(),
    'ownCrontabPresent': ownCrontabPresent,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses a `cron` section payload; never throws (03 §6.5).
ParseResult<CronSnapshot> parseCron(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('cron ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }
  final blocks = split.blocks;

  final jobs = <CronJob>[];
  final dirEntries = <CronDirEntry>[];

  final ownPresent = _crontabMeta(
    blocks['crontab_meta'],
    blocks['crontab'] ?? const [],
    warnings,
  );
  // Only a successful `crontab -l` (rc 0) carries job lines; a failure
  // payload holds the diagnostic ("no crontab for root"), not jobs
  // (03 §7.7).
  if (ownPresent == true) {
    _parseCrontab(
      blocks['crontab'] ?? const [],
      source: kOwnCrontabSource,
      system: false,
      jobs: jobs,
      warnings: warnings,
    );
  }
  _parseCrontab(
    blocks['etc_crontab'] ?? const [],
    source: '/etc/crontab',
    system: true,
    jobs: jobs,
    warnings: warnings,
  );
  _parseCronD(blocks['cron_d'] ?? const [], jobs, warnings);
  _parseCronDirs(blocks['cron_dirs'] ?? const [], dirEntries, warnings);

  return ParseResult(
    CronSnapshot(
      jobs: jobs,
      dirEntries: dirEntries,
      ownCrontabPresent: ownPresent,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}

/// The `crontab_meta` block: `tool=missing` or `rc=<n>`. rc 0 means a
/// crontab exists; a nonzero rc with a "no crontab" note in the output
/// means the user simply has none (03 §7.7); anything else is ambiguous.
bool? _crontabMeta(
  List<String>? lines,
  List<String> crontabLines,
  List<String> warnings,
) {
  if (lines == null || lines.isEmpty) {
    warnings.add('cron: no crontab_meta block');
    return null;
  }
  var missing = false;
  int? rc;
  for (final line in lines) {
    final t = line.trim();
    if (t == 'tool=missing') missing = true;
    if (t.startsWith('rc=')) rc = int.tryParse(t.substring(3));
  }
  if (missing) return null;
  if (rc == null) {
    warnings.add('cron: crontab_meta has no rc');
    return null;
  }
  if (rc == 0) return true;
  if (crontabLines.any((l) => l.toLowerCase().contains('no crontab'))) {
    return false;
  }
  warnings.add('cron: crontab -l exited rc=$rc');
  return null;
}

/// A `name = value` environment assignment at line start (crontab(5);
/// spaces around `=` are optional).
final _envLine = RegExp(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$');

/// Parses crontab-formatted lines into [jobs]. [system] selects the
/// extra user column of `/etc/crontab` and `/etc/cron.d` (03 §7.7).
void _parseCrontab(
  List<String> lines, {
  required String source,
  required bool system,
  required List<CronJob> jobs,
  required List<String> warnings,
}) {
  final env = <String, String>{};
  for (final line in lines) {
    _cronLine(line, source, system, env, jobs, warnings);
  }
}

/// The `/etc/cron.d/*` concatenation: every line is `<name>\t<line>`,
/// where `<name>` is the file basename; a new file resets the
/// environment scope because `CRON_TZ` does not cross files (03 §7.7).
void _parseCronD(
  List<String> lines,
  List<CronJob> jobs,
  List<String> warnings,
) {
  final env = <String, String>{};
  var file = '';
  for (final line in lines) {
    final tab = line.indexOf('\t');
    if (tab < 0) {
      if (line.trim().isNotEmpty) {
        warnings.add('cron: cron_d line without a file prefix "$line"');
      }
      continue;
    }
    final name = line.substring(0, tab);
    if (name != file) {
      file = name;
      env.clear();
    }
    _cronLine(
      line.substring(tab + 1),
      '/etc/cron.d/$name',
      true,
      env,
      jobs,
      warnings,
    );
  }
}

/// One crontab line: skip blank/comments, record env assignments
/// (`CRON_TZ` scopes the jobs after it), else parse the job.
void _cronLine(
  String line,
  String source,
  bool system,
  Map<String, String> env,
  List<CronJob> jobs,
  List<String> warnings,
) {
  final t = line.trim();
  if (t.isEmpty || t.startsWith('#')) return;
  final envMatch = _envLine.firstMatch(line);
  if (envMatch != null) {
    var value = envMatch[2]!.trim();
    // cronie strips one matching pair of quotes.
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    env[envMatch[1]!] = value;
    return;
  }
  _cronJob(t, line, source, system, env['CRON_TZ'], jobs, warnings);
}

/// A job line: `@macro command`, or five fields plus (system: user plus)
/// the command.
void _cronJob(
  String t,
  String raw,
  String source,
  bool system,
  String? cronTz,
  List<CronJob> jobs,
  List<String> warnings,
) {
  String schedule;
  String? user;
  String command;
  if (t.startsWith('@')) {
    final sp = t.indexOf(RegExp(r'\s'));
    if (sp < 0) {
      warnings.add('cron $source: macro without command "$t"');
      return;
    }
    schedule = t.substring(0, sp);
    command = t.substring(sp).trim();
  } else {
    final parts = t.split(RegExp(r'\s+'));
    final need = system ? 7 : 6;
    if (parts.length < need) {
      warnings.add('cron $source: short line "$t"');
      return;
    }
    schedule = parts.sublist(0, 5).join(' ');
    if (system) {
      user = parts[5];
      command = parts.sublist(6).join(' ');
    } else {
      command = parts.sublist(5).join(' ');
    }
  }
  final expression = CronExpression.parse(schedule);
  if (expression == null) {
    warnings.add('cron $source: unparseable schedule "$schedule"');
  }
  jobs.add(
    CronJob(
      source: source,
      schedule: schedule,
      command: command,
      raw: raw,
      expression: expression,
      user: user,
      cronTz: cronTz,
    ),
  );
}

/// The `cron_dirs` block: one `<period> <name>` line per entry, where
/// `<period>` is hourly, daily, weekly or monthly.
void _parseCronDirs(
  List<String> lines,
  List<CronDirEntry> out,
  List<String> warnings,
) {
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final sp = t.indexOf(' ');
    final p = sp < 0 ? t : t.substring(0, sp);
    final period = switch (p) {
      'hourly' => CronPeriod.hourly,
      'daily' => CronPeriod.daily,
      'weekly' => CronPeriod.weekly,
      'monthly' => CronPeriod.monthly,
      _ => null,
    };
    if (period == null || sp < 0 || t.substring(sp + 1).trim().isEmpty) {
      warnings.add('cron: malformed dir entry "$t"');
      continue;
    }
    out.add(CronDirEntry(period: period, name: t.substring(sp + 1).trim()));
  }
}
