/// Parser for `dmesg --json --decode` output, the kernel log's fallback
/// (LOG-03, 03 §7.6): one JSON document whose `dmesg` array holds an
/// object per ring-buffer record with `fac` and `pri` (the facility and
/// level by name), `time` (seconds since boot) and `msg`.
///
/// Without `--decode`, util-linux prints facility and level as one `pri`
/// number whose layout changed in 2.40: 2.38 and 2.39 OR the unshifted
/// facility into the level (`LOG_MAKEPRI(rec->facility, rec->level)`, so
/// daemon.info is 7, like kern.debug), and 2.40 shifts it
/// (`(fac << 3) | pri`). Nothing in the output says which version wrote
/// it, so a number reads as unknown; the names are the same in every
/// version with `--json` (2.38 and later).
///
/// The document is read record by record rather than in one decode, so
/// output cut short by a byte cap or a closed channel keeps every complete
/// record, and a malformed record costs only itself (03 §6.5).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'parse_result.dart';

/// One kernel ring-buffer record (03 §7.6).
@immutable
final class DmesgRecord {
  const DmesgRecord({
    required this.message,
    this.sinceBoot,
    this.level,
    this.facility,
  });

  /// `msg`, as dmesg printed it.
  final String message;

  /// `time`: how long after boot the record was logged; null when absent
  /// or not a non-negative number.
  final Duration? sinceBoot;

  /// The syslog level (0 to 7) that `pri` names; null when absent or not
  /// a util-linux level name.
  final int? level;

  /// The syslog facility that `fac` names (0 for the kernel's own
  /// records); null when absent or not a util-linux facility name.
  /// util-linux 2.38 and 2.39 name facilities up to `ftp` (11) and print
  /// neither field for a record with a later one.
  final int? facility;

  Map<String, Object?> toJson() => {
    'message': message,
    'sinceBootUs': sinceBoot?.inMicroseconds,
    'level': level,
    'facility': facility,
  };
}

/// Parses `dmesg --json --decode` output; never throws. Each balanced
/// object in the record array decodes on its own: one that is not valid
/// JSON or has no string `msg` warns and is skipped, and an object still
/// open at the end warns as truncated.
ParseResult<List<DmesgRecord>> parseDmesgJson(String raw) {
  final warnings = <String>[];
  final out = <DmesgRecord>[];
  final start = raw.indexOf('[');
  if (start < 0) {
    if (raw.trim().isNotEmpty) warnings.add('dmesg: no record array');
    return ParseResult(out, warnings);
  }

  var depth = 0;
  var objectStart = -1;
  var inString = false;
  var escaped = false;
  var index = 0;
  for (var i = start + 1; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == _backslash) {
        escaped = true;
      } else if (c == _quote) {
        inString = false;
      }
      continue;
    }

    if (c == _quote) {
      inString = true;
    } else if (c == _openBrace) {
      if (depth++ == 0) objectStart = i;
    } else if (c == _closeBrace && depth > 0) {
      if (--depth > 0) continue;
      index++;
      final record = _record(raw.substring(objectStart, i + 1));
      if (record == null) {
        warnings.add('dmesg: malformed record $index');
      } else {
        out.add(record);
      }
    } else if (c == _closeBracket && depth == 0) {
      break;
    }
  }
  if (depth > 0) warnings.add('dmesg: truncated record at the end');
  return ParseResult(out, warnings);
}

const _quote = 0x22, _backslash = 0x5c, _openBrace = 0x7b;
const _closeBrace = 0x7d, _closeBracket = 0x5d;

DmesgRecord? _record(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final message = decoded['msg'];
  if (message is! String) return null;

  return DmesgRecord(
    message: message,
    sinceBoot: _sinceBoot(decoded['time']),
    level: _syslogNumber(_levelNames, decoded['pri']),
    facility: _syslogNumber(_facilityNames, decoded['fac']),
  );
}

/// The index of [name] in [names], which is its syslog number; null for
/// anything else, a number included.
int? _syslogNumber(List<String> names, Object? name) {
  if (name is! String) return null;
  final i = names.indexOf(name);
  return i < 0 ? null : i;
}

/// util-linux's `level_names`, indexed by syslog level.
const _levelNames = [
  'emerg',
  'alert',
  'crit',
  'err',
  'warn',
  'notice',
  'info',
  'debug',
];

/// util-linux's `facility_names`, indexed by syslog facility (2.40 and
/// later; 2.38 and 2.39 end at `ftp`).
const _facilityNames = [
  'kern',
  'user',
  'mail',
  'daemon',
  'auth',
  'syslog',
  'lpr',
  'news',
  'uucp',
  'cron',
  'authpriv',
  'ftp',
  'res0',
  'res1',
  'res2',
  'res3',
  'local0',
  'local1',
  'local2',
  'local3',
  'local4',
  'local5',
  'local6',
  'local7',
];

/// The furthest `time` read, in seconds: about 31,700 years of uptime,
/// far past any kernel and well inside a [Duration].
const _maxSinceBootSeconds = 1e12;

Duration? _sinceBoot(Object? time) {
  final seconds = switch (time) {
    final num t => t.toDouble(),
    final String t => double.tryParse(t.trim()),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite) return null;
  if (seconds < 0 || seconds > _maxSinceBootSeconds) return null;
  return Duration(microseconds: (seconds * 1e6).round());
}
