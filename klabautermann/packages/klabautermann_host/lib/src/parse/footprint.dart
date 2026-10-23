/// The footprint manifest and the backup index (SAF-14, 03 §8.11; M5 plan
/// M16): what Klabautermann keeps on a host, and the backups the edit
/// pipeline made, in the formats the edit builders write and these
/// parsers read. The parsers never throw on host input: a malformed row
/// becomes a warning.
///
/// The manifest, `~/.config/klabautermann/manifest.json` or
/// `/etc/klabautermann/manifest.json`, lists the persistent writes once
/// each: a backup directory and its index are listed when the first
/// backup lands, and the backups themselves are verified against the
/// hashes their index records.
///
/// ```json
/// {"v":1,"rows":[
///   {"path":"/var/lib/klabautermann/backups","kind":"backupDirectory"},
///   {"path":"/var/lib/klabautermann/backups/index","kind":"backupIndex"}]}
/// ```
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/edit.dart' show kEditBackupIndexName;
import 'parse_result.dart';

/// The manifest format version in its `v` key.
const int kFootprintManifestVersion = 1;

/// What one manifest row lists (03 §8.11's rows).
enum FootprintKind {
  /// A backup directory, 0700.
  backupDirectory,

  /// The index of a backup directory: one line per backup.
  backupIndex,
}

/// One row of the manifest: a path and what it is.
@immutable
final class FootprintRow {
  const FootprintRow(this.path, this.kind);

  final String path;
  final FootprintKind kind;

  Map<String, Object?> toJson() => {'path': path, 'kind': kind.name};

  @override
  bool operator ==(Object other) =>
      other is FootprintRow && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(path, kind);

  @override
  String toString() => 'FootprintRow($path, ${kind.name})';
}

/// The rows a backup directory adds to the manifest.
List<FootprintRow> backupFootprint(String dir) => [
  FootprintRow(dir, FootprintKind.backupDirectory),
  FootprintRow('$dir/$kEditBackupIndexName', FootprintKind.backupIndex),
];

/// [rows] as the manifest's JSON text, in their order.
String encodeFootprintManifest(List<FootprintRow> rows) => jsonEncode({
  'v': kFootprintManifestVersion,
  'rows': [for (final row in rows) row.toJson()],
});

/// Reads a manifest; an empty text is no manifest (no rows). A row with an
/// unknown kind, a relative path or the wrong shape warns and is skipped;
/// another version warns and yields no rows.
ParseResult<List<FootprintRow>> parseFootprintManifest(String text) {
  if (text.trim().isEmpty) return const ParseResult([], []);
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return ParseResult(const [], ['manifest: not JSON (${e.message})']);
  }
  if (decoded is! Map || decoded['v'] != kFootprintManifestVersion) {
    return const ParseResult([], ['manifest: not version 1']);
  }
  final rows = <FootprintRow>[];
  final warnings = <String>[];
  for (final row in decoded['rows'] is List ? decoded['rows'] as List : []) {
    final path = row is Map ? row['path'] : null;
    final kind = row is Map
        ? FootprintKind.values.asNameMap()[row['kind']]
        : null;
    if (path is! String || !path.startsWith('/') || kind == null) {
      warnings.add('manifest: row skipped');
      continue;
    }
    rows.add(FootprintRow(path, kind));
  }
  return ParseResult(List.unmodifiable(rows), warnings);
}

/// One backup the index records (03 §8.11).
@immutable
final class BackupEntry {
  const BackupEntry({
    required this.savedAt,
    required this.sha256,
    required this.source,
  });

  /// When the backup was made, in UTC seconds.
  final DateTime savedAt;

  /// The backup's content hash, which is also the start of its name.
  final String sha256;

  /// The file it backs up, or `crontab:<user>` for a crontab.
  final String source;

  /// The backup's file name in its directory: `<sha256>-<epoch>`.
  String get name => '$sha256-${savedAt.millisecondsSinceEpoch ~/ 1000}';

  /// The index line that records it.
  String get indexLine =>
      '${savedAt.millisecondsSinceEpoch ~/ 1000}\t$sha256\t$source';

  @override
  bool operator ==(Object other) =>
      other is BackupEntry &&
      other.savedAt == savedAt &&
      other.sha256 == sha256 &&
      other.source == source;

  @override
  int get hashCode => Object.hash(savedAt, sha256, source);

  @override
  String toString() => 'BackupEntry($name, $source)';
}

final _indexLine = RegExp(r'^(\d{1,12})\t([0-9a-f]{64})\t(.+)$');

/// Reads a backup index, oldest line first; a malformed line warns and is
/// skipped.
ParseResult<List<BackupEntry>> parseBackupIndex(String text) {
  final entries = <BackupEntry>[];
  final warnings = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    final m = _indexLine.firstMatch(line);
    if (m == null) {
      warnings.add('backup index: line skipped');
      continue;
    }
    entries.add(
      BackupEntry(
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          int.parse(m[1]!) * 1000,
          isUtc: true,
        ),
        sha256: m[2]!,
        source: m[3]!,
      ),
    );
  }
  return ParseResult(List.unmodifiable(entries), warnings);
}

/// [entries] as an index's text, one line each.
String encodeBackupIndex(Iterable<BackupEntry> entries) =>
    [for (final entry in entries) '${entry.indexLine}\n'].join();
