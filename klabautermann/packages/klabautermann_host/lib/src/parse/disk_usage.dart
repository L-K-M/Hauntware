// DSK-07's folder read (03 §7.3): what `HostCommands.diskUsage` prints,
// the folder's total and its entries with their sizes, largest first.
import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show kDiskUsageEntries, kDiskUsageErrorsMarker;

/// One entry of a folder: a file, a folder, or anything else `du`
/// counts (a symlink, a socket), with the space it takes on disk.
@immutable
final class DiskUsageEntry {
  const DiskUsageEntry({
    required this.name,
    required this.bytes,
    required this.isFolder,
  });

  /// The entry's name inside its folder.
  final String name;

  /// The space it takes, in bytes (`du` counts KiB blocks).
  final int bytes;

  /// A folder the explorer can open; a symlink to one is not.
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is DiskUsageEntry &&
      other.name == name &&
      other.bytes == bytes &&
      other.isFolder == isFolder;

  @override
  int get hashCode => Object.hash(name, bytes, isFolder);

  @override
  String toString() => 'DiskUsageEntry($name, $bytes, folder: $isFolder)';
}

/// One folder as `du` read it.
@immutable
final class DiskUsageListing {
  DiskUsageListing({
    required this.path,
    required this.totalBytes,
    required Iterable<DiskUsageEntry> entries,
    required this.truncated,
    required this.incomplete,
  }) : entries = List.unmodifiable(entries);

  final String path;

  /// The folder's own total, its entries and itself.
  final int totalBytes;

  /// Largest first.
  final List<DiskUsageEntry> entries;

  /// The list reached [kDiskUsageEntries], the folder's largest; a folder
  /// with exactly that many entries reads as truncated too.
  final bool truncated;

  /// `du` could not read something under the folder, so the sizes are a
  /// lower bound; reading as root reads it all.
  final bool incomplete;
}

/// Why a folder read listed nothing.
enum DiskUsageProblem {
  /// The folder is not there.
  notFound,

  /// The login user may not read the folder itself.
  denied,

  /// `du` is not installed, or printed something else.
  unreadable,
}

/// [parseDiskUsage]'s answer: a listing or why there is none.
@immutable
final class DiskUsageParse {
  const DiskUsageParse.listing(DiskUsageListing this.listing) : problem = null;

  const DiskUsageParse.problem(DiskUsageProblem this.problem) : listing = null;

  final DiskUsageListing? listing;
  final DiskUsageProblem? problem;
}

const _kib = 1024;

/// Reads `HostCommands.diskUsage(path)`'s output for [path]. A line that
/// does not parse, or names something outside [path] (a name with a
/// newline in it, which `du` cannot quote), is dropped. Without the
/// folder's own total line, `du` failed: the errors it printed say why.
DiskUsageParse parseDiskUsage(String stdout, String path) {
  final lines = stdout.split('\n');
  final marker = lines.indexOf(kDiskUsageErrorsMarker);
  final listing = marker < 0 ? lines : lines.sublist(0, marker);
  final errors = marker < 0
      ? const <String>[]
      : [
          for (final line in lines.skip(marker + 1))
            if (line.trim().isNotEmpty) line,
        ];

  final prefix = path == '/' ? '/' : '$path/';
  int? total;
  final entries = <DiskUsageEntry>[];
  for (final line in listing) {
    final fields = line.split('\t');
    if (fields.length < 3) continue;
    final kib = int.tryParse(fields[1]);
    if (kib == null || kib < 0) continue;
    final entryPath = fields.sublist(2).join('\t');
    if (entryPath == path) {
      total = kib * _kib;
      continue;
    }
    if (!entryPath.startsWith(prefix)) continue;
    final name = entryPath.substring(prefix.length);
    if (name.isEmpty || name.contains('/')) continue;
    entries.add(
      DiskUsageEntry(name: name, bytes: kib * _kib, isFolder: fields[0] == 'd'),
    );
  }

  if (total == null) {
    final said = errors.join('\n');
    if (said.contains('No such file')) {
      return const DiskUsageParse.problem(DiskUsageProblem.notFound);
    }
    if (said.contains('Permission denied')) {
      return const DiskUsageParse.problem(DiskUsageProblem.denied);
    }
    return const DiskUsageParse.problem(DiskUsageProblem.unreadable);
  }

  // `sort -rn` already listed them largest first, which the list keeps.
  return DiskUsageParse.listing(
    DiskUsageListing(
      path: path,
      totalBytes: total,
      entries: entries,
      truncated: entries.length >= kDiskUsageEntries,
      incomplete: errors.isNotEmpty,
    ),
  );
}
