/// Parser for the `fs` slow-collector payload (03 §6.4, §7.3):
/// `df -PT -B1` plus `df -Pi`, with wrapped long device lines joined and
/// pseudo filesystems marked by type, not by device name.
library;

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'package:meta/meta.dart';

import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Pseudo filesystem types hidden by default in the mount view; filtered
/// by type, not device name (03 §7.3).
const kPseudoFsTypes = {'tmpfs', 'devtmpfs', 'overlay', 'squashfs', 'erofs'};

/// One mounted filesystem from `df -PT -B1`, optionally joined with its
/// `df -Pi` inode row (03 §7.3).
@immutable
final class FsMount {
  const FsMount({
    required this.device,
    required this.type,
    required this.mountPoint,
    this.sizeBytes,
    this.usedBytes,
    this.availBytes,
    this.capacityPercent,
    this.inodesTotal,
    this.inodesUsed,
    this.inodesFree,
    this.inodeUsePercent,
  });

  /// The `Filesystem` column: device, image or `host mounts`-style source.
  final String device;

  /// The `Type` column (`ext4`, `tmpfs`, `fuse.sshfs`, ...). Empty when
  /// the row came from the inode table only.
  final String type;

  /// Mount point; may contain spaces, which `df` prints raw under `-P`.
  final String mountPoint;

  /// Byte sizes from `df -B1`.
  final int? sizeBytes, usedBytes, availBytes;

  /// `Capacity` column percent, 0-100.
  final int? capacityPercent;

  /// Inode counters from `df -Pi`, when the join succeeded.
  final int? inodesTotal, inodesUsed, inodesFree, inodeUsePercent;

  /// Whether [type] is a pseudo filesystem (03 §7.3).
  bool get isPseudo => kPseudoFsTypes.contains(type);

  Map<String, Object?> toJson() => {
    'device': device,
    'type': type,
    'mountPoint': mountPoint,
    'sizeBytes': sizeBytes,
    'usedBytes': usedBytes,
    'availBytes': availBytes,
    'capacityPercent': capacityPercent,
    'inodesTotal': inodesTotal,
    'inodesUsed': inodesUsed,
    'inodesFree': inodesFree,
    'inodeUsePercent': inodeUsePercent,
  };
}

/// The `fs` tick (03 §6.4).
@immutable
final class FsSnapshot {
  FsSnapshot(
    List<FsMount> mounts, {
    List<String> errors = const [],
    this.timeoutAbsent = false,
  }) : mounts = List.unmodifiable(mounts),
       errors = List.unmodifiable(errors);

  /// Mounts in `df` order.
  final List<FsMount> mounts;

  /// What `df` said of each mount it could not read, without its `df: `
  /// prefix (`/mnt/dead: Transport endpoint is not connected`). Those
  /// mounts have no row in [mounts]; the list is partial while this is
  /// not empty.
  final List<String> errors;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3).
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'mounts': mounts.map((m) => m.toJson()).toList(),
    if (errors.isNotEmpty) 'errors': errors,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses an `fs` section payload; never throws (03 §6.5). GNU `df` wraps
/// a device name that outgrows its column onto its own line, so a line
/// that is no row joins the next one. `df` exits 1 and still prints the
/// other rows when it cannot read one mount: its `df: ` lines become
/// [FsSnapshot.errors] and warnings, never part of a row.
ParseResult<FsSnapshot> parseFs(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('fs ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }

  final mounts = <FsMount>[];
  final errors = <String>[];
  final byMount = <String, FsMount>{};
  if (split.blocks['blocks'] case final lines?) {
    for (final m in _parseDfBlocks(lines, errors, warnings)) {
      mounts.add(m);
      byMount[m.mountPoint] = m;
    }
  } else {
    warnings.add('fs: missing blocks table');
  }

  if (split.blocks['inodes'] case final lines?) {
    for (final row in _parseDfInodes(lines, errors, warnings)) {
      final prev = byMount[row.mountPoint];
      if (prev == null) {
        warnings.add('fs: inode row for unmounted ${row.mountPoint}');
        mounts.add(row);
        continue;
      }
      final joined = FsMount(
        device: prev.device,
        type: prev.type,
        mountPoint: prev.mountPoint,
        sizeBytes: prev.sizeBytes,
        usedBytes: prev.usedBytes,
        availBytes: prev.availBytes,
        capacityPercent: prev.capacityPercent,
        inodesTotal: row.inodesTotal,
        inodesUsed: row.inodesUsed,
        inodesFree: row.inodesFree,
        inodeUsePercent: row.inodeUsePercent,
      );
      mounts[mounts.indexOf(prev)] = joined;
      byMount[row.mountPoint] = joined;
    }
  }

  return ParseResult(
    FsSnapshot(mounts, errors: errors, timeoutAbsent: split.timeoutAbsent),
    [...warnings, for (final e in errors) 'df: $e'],
  );
}

/// A `df -PT -B1` row, read from its fixed columns on the right: the
/// source and the mount point are the only columns that hold blanks
/// (`gdrive:My Drive`, `//nas/Shared Docs`), and the first run of type,
/// three counts, capacity and an absolute path ends the source.
final _blocksRow = RegExp(
  r'^(.*?\S)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%|-)\s+(/.*)$',
);

/// A `df -Pi` row, as [_blocksRow] without the type column.
final _inodesRow = RegExp(
  r'^(.*?\S)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+%|-)\s+(/.*)$',
);

/// What `df` says of a mount it could not read, on stderr, which the
/// fragment captures with the table.
final _dfComplaint = RegExp(r'^df: (.+)$');

/// Parses `df -PT -B1` rows: fs, type, blocks, used, avail, `cap%`, mount.
List<FsMount> _parseDfBlocks(
  List<String> lines,
  List<String> errors,
  List<String> warnings,
) => [
  for (final m in _dfRows(lines, _blocksRow, errors, warnings))
    FsMount(
      device: m[1]!,
      type: m[2]!,
      sizeBytes: int.tryParse(m[3]!),
      usedBytes: int.tryParse(m[4]!),
      availBytes: int.tryParse(m[5]!),
      capacityPercent: int.tryParse(m[6]!.replaceAll('%', '')),
      mountPoint: m[7]!,
    ),
];

/// Parses `df -Pi` rows: `<fs> <inodes> <iused> <ifree> <iuse%> <mount>`.
List<FsMount> _parseDfInodes(
  List<String> lines,
  List<String> errors,
  List<String> warnings,
) => [
  for (final m in _dfRows(lines, _inodesRow, errors, warnings))
    FsMount(
      device: m[1]!,
      type: '',
      mountPoint: m[6]!,
      inodesTotal: int.tryParse(m[2]!),
      inodesUsed: int.tryParse(m[3]!),
      inodesFree: int.tryParse(m[4]!),
      inodeUsePercent: int.tryParse(m[5]!.replaceAll('%', '')),
    ),
];

/// Matches `df` output against [row], skipping the header. A line that
/// is a row by itself is one; only a line that is not may be a device
/// name wrapped onto its own line, which joins the next line when the
/// two make a row. `df`'s complaints go to [errors], once each.
List<RegExpMatch> _dfRows(
  List<String> lines,
  RegExp row,
  List<String> errors,
  List<String> warnings,
) {
  final rows = <RegExpMatch>[];
  String? carry;
  void dropCarry() {
    if (carry != null) {
      warnings.add('df: dropped wrapped device fragment "$carry"');
    }
    carry = null;
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('Filesystem')) continue;

    final whole = row.firstMatch(line);
    if (whole != null) {
      dropCarry();
      rows.add(whole);
      continue;
    }
    if (_dfComplaint.firstMatch(line) case final complaint?) {
      if (!errors.contains(complaint[1])) errors.add(complaint[1]!);
      continue;
    }
    final joined = carry == null ? null : row.firstMatch('$carry $line');
    if (joined != null) {
      carry = null;
      rows.add(joined);
      continue;
    }
    dropCarry();
    carry = line;
  }
  dropCarry();
  return rows;
}
