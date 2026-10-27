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

/// CTX-03's time range for a container's logs: one of LOG-01's spans back
/// from when the stream opens, or a chosen start and end. Only a range
/// with an end cannot be followed.
@immutable
final class ContainerLogRange {
  const ContainerLogRange([this.span = LogTimeRange.any])
    : since = null,
      until = null;

  const ContainerLogRange.between({
    required DateTime this.since,
    required DateTime this.until,
  }) : span = LogTimeRange.any;

  final LogTimeRange span;

  /// The chosen start and end, both inclusive.
  final DateTime? since, until;

  /// Whether the range was chosen rather than spanned back from now.
  bool get chosen => until != null;

  /// Where the read starts, [span] before [now] for a span.
  DateTime? sinceAt(DateTime now) => switch (span.span) {
    final span? => now.subtract(span),
    null => since,
  };

  @override
  bool operator ==(Object other) =>
      other is ContainerLogRange &&
      other.span == span &&
      other.since == since &&
      other.until == until;

  @override
  int get hashCode => Object.hash(span, since, until);
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

/// Turns LOG-05's search text into the pattern journalctl matches on the
/// server (LOG-06, `-g`, PCRE2): plain text has its metacharacters
/// escaped, and the pattern pins its case rule with `(?i)` or `(?-i)`,
/// since journalctl otherwise ignores case for an all-lower-case pattern
/// and matches it for any other.
String serverLogPattern(
  String query, {
  required bool regex,
  required bool caseSensitive,
}) {
  final pattern = regex ? query : RegExp.escape(query);
  return caseSensitive ? '(?-i)$pattern' : '(?i)$pattern';
}

/// What the Logs panel reads: a [source] with LOG-01's journal filters,
/// LOG-06's server-side [grep], LOG-09's [pastBoot] and LOG-22's [path].
/// Empty text filters match everything; only the [source]'s own filters
/// reach the engine.
@immutable
final class LogQuery {
  const LogQuery({
    this.source = LogSourceKind.journal,
    this.unit = '',
    this.identifier = '',
    this.priority,
    this.currentBootOnly = false,
    this.pastBoot,
    this.range = LogTimeRange.any,
    this.grep = '',
    this.path = '',
  });

  final LogSourceKind source;
  final String unit;
  final String identifier;

  /// The least urgent priority shown, or null for every priority.
  final LogPriority? priority;
  final bool currentBootOnly;

  /// A past boot picked by LOG-09's boot picker, read by the journal and
  /// the kernel log by its ID; null reads every boot (or the current one,
  /// with [currentBootOnly], and always for the kernel log).
  final JournalBootEntry? pastBoot;

  JournalBoot? get _boot => switch (pastBoot) {
    final entry? => JournalBoot.id(entry.id),
    null => null,
  };

  final LogTimeRange range;

  /// The pattern journalctl matches on the server (LOG-06), from
  /// [serverLogPattern]; empty for none. Only the journal reads it.
  final String grep;

  /// The file LOG-22 tails, typed, picked from [kCommonLogPaths] or from
  /// LOG-08's `/var/log` browser.
  final String path;

  /// [path] is a rotated `.gz` or `.xz` file (LOG-08), read as a window.
  bool get _compressed => LogCompression.of(path) != LogCompression.none;

  LogQuery withSource(LogSourceKind source) => _copy(source: source);

  LogQuery withPath(String path) => _copy(path: path);

  LogQuery withGrep(String grep) => _copy(grep: grep);

  /// Every boot ([past] null, [current] false), the current one
  /// ([current] true), or the [past] boot.
  LogQuery withBoot(JournalBootEntry? past, {bool current = false}) => LogQuery(
    source: source,
    unit: unit,
    identifier: identifier,
    priority: priority,
    currentBootOnly: past == null && current,
    pastBoot: past,
    range: range,
    grep: grep,
    path: path,
  );

  LogQuery _copy({LogSourceKind? source, String? path, String? grep}) =>
      LogQuery(
        source: source ?? this.source,
        unit: unit,
        identifier: identifier,
        priority: priority,
        currentBootOnly: currentBootOnly,
        pastBoot: pastBoot,
        range: range,
        grep: grep ?? this.grep,
        path: path ?? this.path,
      );

  /// Whether a stream can open: a file needs a path the engine accepts.
  bool get ready =>
      source != LogSourceKind.file || logPathProblem(path) == null;

  /// Whether the source can be followed: a past boot and a compressed
  /// file only have a window.
  bool get followable =>
      source == LogSourceKind.file ? !_compressed : pastBoot == null;

  /// The filters narrowing [source], for the phone's Filters button.
  int get filterCount => switch (source) {
    LogSourceKind.journal => [
      unit.isNotEmpty,
      identifier.isNotEmpty,
      priority != null,
      currentBootOnly || pastBoot != null,
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
      boot: _boot,
      since: switch (range.span) {
        final span? => now.subtract(span),
        null => null,
      },
      grep: grep.isEmpty ? null : grep,
    ),
    LogSourceKind.kernel => KernelLogSource(boot: _boot),
    LogSourceKind.file => FileLogSource(path, compressed: _compressed),
  };
}
