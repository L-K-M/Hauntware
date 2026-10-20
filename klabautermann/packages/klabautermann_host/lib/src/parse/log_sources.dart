/// Parsers for the v1 log sources (03 §7.6): the journal's boot list
/// (LOG-09), the files under `/var/log` (LOG-08) and the failures their
/// reads report. Each takes the output of a [HostCommands] builder run
/// through `commandLine`, which exports `TZ=UTC`, and never throws on
/// host input.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        JournalBootsFormat,
        LogCompression,
        kDecompressFailedMarker;
import 'parse_result.dart';

/// One boot the journal holds (LOG-09, 03 §7.6).
@immutable
final class JournalBootEntry {
  const JournalBootEntry({
    required this.offset,
    required this.id,
    this.firstEntry,
    this.lastEntry,
  });

  /// Boots before the current one: 0 is the current, -1 the one before.
  final int offset;

  /// The boot ID, 32 lower-case hex digits.
  final String id;

  /// The boot's first and last journal records, in UTC.
  final DateTime? firstEntry, lastEntry;

  Map<String, Object?> toJson() => {
    'offset': offset,
    'id': id,
    'firstEntry': firstEntry?.toIso8601String(),
    'lastEntry': lastEntry?.toIso8601String(),
  };
}

final _bootId = RegExp(r'^[0-9a-f]{32}$');

/// A text row: offset, boot ID, then the two timestamps however the
/// version separates them.
final _bootRow = RegExp(r'^\s*(-?\d+)\s+([0-9a-f]{32})\s+(.*)$');

/// A timestamp in the text table under `TZ=UTC`.
final _utcTimestamp = RegExp(
  r'\w+ (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC',
);

/// Reads [HostCommands.journalBoots]' output in the [format] it asked
/// for, oldest boot first as journalctl lists them. Malformed rows warn
/// and are skipped.
ParseResult<List<JournalBootEntry>> parseJournalBoots(
  String raw,
  JournalBootsFormat format,
) {
  final warnings = <String>[];
  final boots = switch (format) {
    JournalBootsFormat.json => _bootsJson(raw, warnings),
    JournalBootsFormat.text => _bootsText(raw, warnings),
  };
  return ParseResult(List.unmodifiable(boots), warnings);
}

/// `-o json`: objects with `index`, `boot_id` and the first and last
/// entries in microseconds since the epoch.
List<JournalBootEntry> _bootsJson(String raw, List<String> warnings) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    warnings.add('list-boots: not JSON (${e.message})');
    return const [];
  }
  if (decoded is! List) {
    warnings.add('list-boots: not a JSON array');
    return const [];
  }

  DateTime? micros(Object? v) =>
      v is int ? DateTime.fromMicrosecondsSinceEpoch(v, isUtc: true) : null;

  final boots = <JournalBootEntry>[];
  for (final entry in decoded) {
    final index = entry is Map ? entry['index'] : null;
    final id = entry is Map ? entry['boot_id'] : null;
    if (index is! int || id is! String || !_bootId.hasMatch(id)) {
      warnings.add('list-boots: malformed row skipped');
      continue;
    }
    boots.add(
      JournalBootEntry(
        offset: index,
        id: id,
        firstEntry: micros(entry['first_entry']),
        lastEntry: micros(entry['last_entry']),
      ),
    );
  }
  return boots;
}

/// The text table, with or without the `IDX BOOT ID ...` header that
/// newer versions print.
List<JournalBootEntry> _bootsText(String raw, List<String> warnings) {
  final boots = <JournalBootEntry>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('IDX')) continue;
    final m = _bootRow.firstMatch(line);
    if (m == null) {
      warnings.add('list-boots: row skipped');
      continue;
    }
    final stamps = [
      for (final t in _utcTimestamp.allMatches(m.group(3)!))
        DateTime.utc(
          int.parse(t.group(1)!),
          int.parse(t.group(2)!),
          int.parse(t.group(3)!),
          int.parse(t.group(4)!),
          int.parse(t.group(5)!),
          int.parse(t.group(6)!),
        ),
    ];
    boots.add(
      JournalBootEntry(
        offset: int.parse(m.group(1)!),
        id: m.group(2)!,
        firstEntry: stamps.isNotEmpty ? stamps.first : null,
        lastEntry: stamps.length > 1 ? stamps[1] : null,
      ),
    );
  }
  return boots;
}

/// One file under `/var/log` (LOG-08, 03 §7.6).
@immutable
final class LogFileEntry {
  const LogFileEntry({
    required this.path,
    required this.bytes,
    required this.modified,
    required this.readable,
  });

  /// The absolute path.
  final String path;

  /// The file's size on disk; a compressed file's compressed size.
  final int bytes;

  /// The last modification, in UTC.
  final DateTime modified;

  /// Whether the login user may read it; one it may not read needs
  /// admin mode.
  final bool readable;

  /// How the file is compressed, from its name.
  LogCompression get compression => LogCompression.of(path);

  Map<String, Object?> toJson() => {
    'path': path,
    'bytes': bytes,
    'modified': modified.toIso8601String(),
    'readable': readable,
  };
}

final _logFileRow = RegExp(r'^([01]) (\d+) (\d+) (/.*)$');

/// Reads [HostCommands.logFiles]' output, sorted by path. Malformed rows
/// warn and are skipped.
ParseResult<List<LogFileEntry>> parseLogFiles(String raw) {
  final warnings = <String>[];
  final files = <LogFileEntry>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.isEmpty) continue;
    final m = _logFileRow.firstMatch(line);
    if (m == null) {
      warnings.add('log files: row skipped');
      continue;
    }
    files.add(
      LogFileEntry(
        path: m.group(4)!,
        bytes: int.parse(m.group(2)!),
        modified: DateTime.fromMillisecondsSinceEpoch(
          int.parse(m.group(3)!) * 1000,
          isUtc: true,
        ),
        readable: m.group(1) == '1',
      ),
    );
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return ParseResult(List.unmodifiable(files), warnings);
}

/// The decompressor's exit status a [HostCommands.rotatedTail] read
/// reported on [stderr], or null when it succeeded. 127 means the tool
/// is not installed.
int? rotatedTailFailure(String stderr) {
  final m = RegExp(
    '${RegExp.escape(kDecompressFailedMarker)} (\\d+)',
  ).firstMatch(stderr);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Whether [stderr] from a `journalctl -g` read says this journalctl
/// cannot match patterns (LOG-06, 03 §7.6): built without PCRE2, or
/// unable to load it.
bool journalGrepUnsupported(String stderr) =>
    stderr.contains('without pattern matching') || stderr.contains('PCRE2');
