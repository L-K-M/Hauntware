/// CTX-05's reading of a container log line's own text (03 §10.8): the
/// severity it names of itself, whether it continues a stack trace, and
/// its keys when it is a JSON object. Pure functions over the line's
/// visible text, without SGR escapes.
library;

import 'dart:convert';

import '../engine/protocol.dart' show LogPriority;

/// The longest line read as JSON; a longer one stays plain text.
const _jsonMaxChars = 64 * 1024;

/// The keys that name a structured line's level: logrus, zap, pino,
/// bunyan, Python's `logging`, ECS's `log.level` and Serilog's `@l`.
const _levelKeys = [
  'level',
  'severity',
  'lvl',
  'loglevel',
  'levelname',
  'log.level',
  '@l',
];

final _logfmtLevel = RegExp(
  r'''(?:^|\s)(?:level|lvl|severity)="?([A-Za-z]+)''',
);

/// A level word in capitals, as a bare word, in brackets or before a
/// colon (`ERROR`, `[WARN]`, `FATAL:`), first or after up to four
/// prefix words that each hold a digit or are a time zone's capitals: a
/// timestamp, or PostgreSQL's `2026-10-15 14:30:01.123 UTC [1]`. A level
/// word after words of a message is never read.
final _levelWord = RegExp(
  r'^(?:(?:\S*\d\S*|[A-Z]{2,5})\s+){0,4}?\[?'
  r'(FATAL|PANIC|CRITICAL|CRIT|ERROR|ERR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)'
  r'\]?:?(?=\s|$)',
);

/// An exception's own line, Python's or the JVM's: `ValueError: x`,
/// `java.lang.IllegalStateException`, and Python's traceback header.
final _exception = RegExp(
  r'^(?:Traceback \(most recent call last\)|'
  r'(?:[A-Za-z_][\w$]*\.)*[A-Za-z_][\w$]*(?:Error|Exception)(?::|$))',
);

/// A line that continues the one before it: an indented frame
/// (`    at ...`, `  File "..."`, `\t...`) or a JVM `Caused by:`.
final _continuation = RegExp(r'^(?:\s+\S|Caused by:)');

/// The severity [text] names of itself: a JSON or logfmt level key, a
/// level word in capitals near its start, or an exception's own line;
/// null when it names none. Words in a message are never read as one.
LogPriority? linePriority(String text) {
  final object = _jsonObject(text);
  if (object != null) return _priorityOfJson(object);
  if (_logfmtLevel.firstMatch(text) case final match?) {
    if (_priorityOfWord(match[1]!) case final priority?) return priority;
  }
  if (_levelWord.firstMatch(text) case final match?) {
    return _priorityOfWord(match[1]!);
  }
  return _exception.hasMatch(text) ? LogPriority.error : null;
}

/// Whether [text] continues the line before it, as a stack trace's frame.
bool continuesLine(String text) => _continuation.hasMatch(text);

/// [text]'s keys when it is a JSON object, nested keys joined by dots and
/// other values as JSON; null for any other text.
List<(String, String)>? jsonLineFields(String text) {
  final object = _jsonObject(text);
  return object == null ? null : _flatten(object);
}

Map<String, Object?>? _jsonObject(String text) {
  final trimmed = text.trim();
  if (trimmed.length > _jsonMaxChars ||
      !trimmed.startsWith('{') ||
      !trimmed.endsWith('}')) {
    return null;
  }
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

LogPriority? _priorityOfJson(Map<String, Object?> object) {
  for (final key in _levelKeys) {
    final value = switch (key) {
      'log.level' => object[key] ?? _nested(object, 'log', 'level'),
      _ => object[key],
    };
    final priority = switch (value) {
      final String word => _priorityOfWord(word),
      // pino and bunyan: 10 trace, 20 debug, 30 info, 40 warn, 50 error,
      // 60 fatal.
      final int number when number >= 60 => LogPriority.critical,
      final int number when number >= 50 => LogPriority.error,
      final int number when number >= 40 => LogPriority.warning,
      final int number when number >= 30 => LogPriority.info,
      final int _ => LogPriority.debug,
      _ => null,
    };
    if (priority != null) return priority;
  }
  return null;
}

Object? _nested(Map<String, Object?> object, String outer, String inner) =>
    switch (object[outer]) {
      final Map<String, Object?> map => map[inner],
      _ => null,
    };

LogPriority? _priorityOfWord(String word) => switch (word.toLowerCase()) {
  'emerg' || 'emergency' => LogPriority.emergency,
  'alert' => LogPriority.alert,
  'fatal' || 'panic' || 'crit' || 'critical' => LogPriority.critical,
  'err' || 'error' || 'severe' => LogPriority.error,
  'warn' || 'warning' => LogPriority.warning,
  'notice' => LogPriority.notice,
  'info' || 'information' || 'informational' => LogPriority.info,
  'debug' || 'trace' || 'verbose' => LogPriority.debug,
  _ => null,
};

List<(String, String)> _flatten(Map<String, Object?> object, [String? at]) => [
  for (final MapEntry(:key, :value) in object.entries)
    ...switch (value) {
      final Map<String, Object?> map when map.isNotEmpty => _flatten(
        map,
        at == null ? key : '$at.$key',
      ),
      final String text => [(at == null ? key : '$at.$key', text)],
      _ => [(at == null ? key : '$at.$key', jsonEncode(value))],
    },
];
