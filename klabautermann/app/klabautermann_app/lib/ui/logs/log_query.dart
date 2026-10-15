import 'package:flutter/foundation.dart' show immutable;
import 'package:klabautermann_core/klabautermann_core.dart';

/// Where the Logs panel reads: the journal (LOG-01), the kernel log
/// (LOG-03) or one file (LOG-22), the [LogSource] variants.
enum LogSourceKind { journal, kernel, file }

/// LOG-01's time range as the panel offers it: a span back from when the
/// stream opens. None has an end, since a follow reads up to the present;
/// a range with a chosen start and end waits for a date and time picker.
enum LogTimeRange {
  any(null),
  last15Minutes(Duration(minutes: 15)),
  lastHour(Duration(hours: 1)),
  last24Hours(Duration(days: 1)),
  last7Days(Duration(days: 7));

  const LogTimeRange(this.span);

  final Duration? span;
}

/// Why LOG-22's path field refuses a path.
enum LogPathProblem { empty, notAbsolute, notNormalized, nul }

/// The engine's rule for a path it tails (03 §8.8,
/// `ArgValidators.absolutePath` in klabautermann_host), mirrored so the
/// field can say what is wrong before anything is sent: absolute, without
/// NUL, and with no `.` or `..` part. The engine checks again and ends a
/// stream it refuses as invalid.
LogPathProblem? logPathProblem(String path) {
  if (path.isEmpty) return LogPathProblem.empty;
  if (path.codeUnits.contains(0)) return LogPathProblem.nul;
  if (!path.startsWith('/')) return LogPathProblem.notAbsolute;
  if (path.split('/').contains('..') ||
      path.endsWith('/.') ||
      path.contains('/./')) {
    return LogPathProblem.notNormalized;
  }
  return null;
}

/// LOG-22's common paths: syslog (Debian, then Red Hat), auth (likewise),
/// nginx, and Apache as Debian's `apache2` and Red Hat's `httpd` name it.
const List<String> kCommonLogPaths = [
  '/var/log/syslog',
  '/var/log/messages',
  '/var/log/auth.log',
  '/var/log/secure',
  '/var/log/nginx/access.log',
  '/var/log/nginx/error.log',
  '/var/log/apache2/access.log',
  '/var/log/apache2/error.log',
  '/var/log/httpd/access_log',
  '/var/log/httpd/error_log',
];

/// What the Logs panel reads: a [source] with LOG-01's journal filters and
/// LOG-22's [path]. Empty text filters match everything; only the
/// [source]'s own filters reach the engine.
@immutable
final class LogQuery {
  const LogQuery({
    this.source = LogSourceKind.journal,
    this.unit = '',
    this.identifier = '',
    this.priority,
    this.currentBootOnly = false,
    this.range = LogTimeRange.any,
    this.path = '',
  });

  final LogSourceKind source;
  final String unit;
  final String identifier;

  /// The least urgent priority shown, or null for every priority.
  final LogPriority? priority;
  final bool currentBootOnly;
  final LogTimeRange range;
  final String path;

  LogQuery withSource(LogSourceKind source) => _copy(source: source);

  LogQuery withPath(String path) => _copy(path: path);

  LogQuery _copy({LogSourceKind? source, String? path}) => LogQuery(
    source: source ?? this.source,
    unit: unit,
    identifier: identifier,
    priority: priority,
    currentBootOnly: currentBootOnly,
    range: range,
    path: path ?? this.path,
  );

  /// Whether a stream can open: a file needs a path the engine accepts.
  bool get ready =>
      source != LogSourceKind.file || logPathProblem(path) == null;

  /// The filters narrowing [source], for the phone's Filters button.
  int get filterCount => switch (source) {
    LogSourceKind.journal => [
      unit.isNotEmpty,
      identifier.isNotEmpty,
      priority != null,
      currentBootOnly,
      range != LogTimeRange.any,
    ].where((set) => set).length,
    LogSourceKind.kernel => 0,
    LogSourceKind.file => ready ? 1 : 0,
  };

  /// The protocol's source, its range starting [range]'s span before
  /// [now].
  LogSource toSource(DateTime now) => switch (source) {
    LogSourceKind.journal => JournalLogSource(
      unit: unit.isEmpty ? null : unit,
      identifier: identifier.isEmpty ? null : identifier,
      priority: priority,
      currentBootOnly: currentBootOnly,
      since: switch (range.span) {
        final span? => now.subtract(span),
        null => null,
      },
    ),
    LogSourceKind.kernel => const KernelLogSource(),
    LogSourceKind.file => FileLogSource(path),
  };
}
