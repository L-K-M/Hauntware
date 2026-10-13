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
  FsSnapshot(List<FsMount> mounts, {this.timeoutAbsent = false})
    : mounts = List.unmodifiable(mounts);

  /// Mounts in `df` order.
  final List<FsMount> mounts;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3).
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'mounts': mounts.map((m) => m.toJson()).toList(),
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses an `fs` section payload; never throws (03 §6.5). GNU `df` wraps
/// a device name that outgrows its column onto its own line, so a short
/// row joins the next one; `df` output on a failed run lands in the block
/// as text and is reported, not fatal.
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
  final byMount = <String, FsMount>{};
  if (split.blocks['blocks'] case final lines?) {
    for (final m in _parseDfBlocks(lines, warnings)) {
      mounts.add(m);
      byMount[m.mountPoint] = m;
    }
  } else {
    warnings.add('fs: missing blocks table');
  }

  if (split.blocks['inodes'] case final lines?) {
    for (final row in _parseDfInodes(lines, warnings)) {
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
    FsSnapshot(mounts, timeoutAbsent: split.timeoutAbsent),
    warnings,
  );
}

/// Parses `df -PT -B1` rows: fs, type, blocks, used, avail, `cap%`, mount.
/// Device names that fill their column wrap to the next line.
List<FsMount> _parseDfBlocks(List<String> lines, List<String> warnings) {
  final rows = _dfRows(lines, 7, warnings);
  final out = <FsMount>[];
  for (final t in rows) {
    final cap = int.tryParse(t[5].replaceAll('%', ''));
    out.add(
      FsMount(
        device: t[0],
        type: t[1],
        sizeBytes: int.tryParse(t[2]),
        usedBytes: int.tryParse(t[3]),
        availBytes: int.tryParse(t[4]),
        capacityPercent: cap,
        mountPoint: t.sublist(6).join(' '),
      ),
    );
  }
  return out;
}

/// Parses `df -Pi` rows: `<fs> <inodes> <iused> <ifree> <iuse%> <mount>`.
List<FsMount> _parseDfInodes(List<String> lines, List<String> warnings) {
  final rows = _dfRows(lines, 6, warnings);
  final out = <FsMount>[];
  for (final t in rows) {
    out.add(
      FsMount(
        device: t[0],
        type: '',
        mountPoint: t.sublist(5).join(' '),
        inodesTotal: int.tryParse(t[1]),
        inodesUsed: int.tryParse(t[2]),
        inodesFree: int.tryParse(t[3]),
        inodeUsePercent: int.tryParse(t[4].replaceAll('%', '')),
      ),
    );
  }
  return out;
}

/// Tokenizes `df` output, joins wrapped device lines, and skips the
/// header row. Each returned row has at least [width] fields.
List<List<String>> _dfRows(
  List<String> lines,
  int width,
  List<String> warnings,
) {
  final rows = <List<String>>[];
  final it = lines.map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty);
  String? carry;
  for (final line in it) {
    if (line.startsWith('Filesystem')) continue;
    final tokens = line.trim().split(RegExp(r'\s+'));
    final joined = carry == null ? tokens : [carry, ...tokens];
    carry = null;
    if (joined.length < width) {
      carry = joined.join(' ');
      continue;
    }
    // A data row keeps the numeric columns numeric; otherwise it is a
    // wrapped device prefix waiting for the next line.
    if (int.tryParse(joined[width - 4]) == null) {
      carry = joined.join(' ');
      continue;
    }
    rows.add(joined);
  }
  if (carry != null) {
    warnings.add('df: dropped wrapped device fragment "$carry"');
  }
  return rows;
}
