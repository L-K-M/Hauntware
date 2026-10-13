/// Parser for `journalctl -o json` output (03 §7.6): one JSON object per
/// line carrying journald's `__CURSOR`, `__REALTIME_TIMESTAMP`,
/// `PRIORITY`, `_SYSTEMD_UNIT`, `SYSLOG_IDENTIFIER` and `MESSAGE` fields.
/// A field may be a string or a byte array (binary-safe MESSAGE values);
/// both decode leniently and malformed lines warn and skip.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'parse_result.dart';

/// One journal entry (03 §7.6). [fields] keeps every field decoded
/// leniently; the typed getters expose the columns the log view shows.
@immutable
final class JournalEntry {
  JournalEntry(Map<String, String?> fields) : fields = Map.unmodifiable(fields);

  /// All fields of the JSON object, strings or leniently decoded byte
  /// arrays; null marks a JSON null.
  final Map<String, String?> fields;

  /// `__CURSOR`: the seek key for the next page (--after-cursor).
  String? get cursor => fields['__CURSOR'];

  /// `__REALTIME_TIMESTAMP` in microseconds since the epoch.
  int? get realtimeUs => int.tryParse(fields['__REALTIME_TIMESTAMP'] ?? '');

  /// `__MONOTONIC_TIMESTAMP` in microseconds since boot.
  int? get monotonicUs => int.tryParse(fields['__MONOTONIC_TIMESTAMP'] ?? '');

  /// The wall-clock instant, when `__REALTIME_TIMESTAMP` parsed.
  DateTime? get timestampUtc => realtimeUs == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(realtimeUs!, isUtc: true);

  /// `PRIORITY`: syslog severity 0-7.
  int? get priority => int.tryParse(fields['PRIORITY'] ?? '');

  /// `_SYSTEMD_UNIT`, falling back to `UNIT`/`OBJECT_SYSTEMD_UNIT` for
  /// user units and kernel rows.
  String? get unit =>
      fields['_SYSTEMD_UNIT'] ?? fields['_SYSTEMD_USER_UNIT'] ?? fields['UNIT'];

  /// `SYSLOG_IDENTIFIER` (the syslog tag).
  String? get identifier => fields['SYSLOG_IDENTIFIER'];

  /// `MESSAGE`, decoded leniently when the field was a byte array.
  String? get message => fields['MESSAGE'];

  /// `_PID`, for correlating with the process table.
  int? get pid => int.tryParse(fields['_PID'] ?? '');

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'realtimeUs': realtimeUs,
    'priority': priority,
    'unit': unit,
    'identifier': identifier,
    'message': message,
  };
}

/// Parses the lines of a `journalctl -o json` stream; never throws.
/// Blank lines skip, malformed JSON warns per line.
ParseResult<List<JournalEntry>> parseJournalLines(String raw) {
  final warnings = <String>[];
  final out = <JournalEntry>[];
  var n = 0;
  for (final line in raw.split('\n')) {
    n++;
    if (line.trim().isEmpty) continue;
    final e = _decodeLine(line);
    if (e == null) {
      warnings.add('journal: malformed JSON at line $n');
      continue;
    }
    out.add(e);
  }
  return ParseResult(out, warnings);
}

/// Parses one `journalctl -o json` line; null when it is not a JSON
/// object.
JournalEntry? parseJournalLine(String line) => _decodeLine(line);

JournalEntry? _decodeLine(String line) {
  Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final fields = <String, String?>{};
  for (final e in decoded.entries) {
    fields['${e.key}'] = _fieldValue(e.value);
  }
  return JournalEntry(fields);
}

/// One field value: a string stays a string, a byte array decodes
/// leniently, and any other JSON scalar stringifies (journald's cursor
/// and timestamps arrive as decimal strings either way).
String? _fieldValue(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is List) {
    return utf8.decode(
      v.map((b) => b is int ? b & 0xff : 0).toList(),
      allowMalformed: true,
    );
  }
  return '$v';
}
