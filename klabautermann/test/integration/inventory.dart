// The host write inventory check (03 §8.11, D27; M4 plan M18): diffs the
// snapshots inventory.sh took before and after a scripted MVP session
// and checks every change against inventory_allowlist.txt, which encodes
// 8.11's MVP rows once. A change no row allows is a defect: the check
// names it and fails. run.sh runs it as
//
//   dart run test/integration/inventory.dart <allowlist> <before> <after>
//
// and keeps its report, every change with the row that allows it, in the
// evidence.
import 'dart:io';

/// What a snapshot path is, from the type bits of its raw mode.
enum EntryType { file, directory, symlink, other }

/// The `S_IFMT` mask and its values (POSIX `sys/stat.h`).
const _typeMask = 0xF000;
const _typeFile = 0x8000;
const _typeDirectory = 0x4000;
const _typeSymlink = 0xA000;

/// One path of a snapshot as inventory.sh recorded it.
final class InventoryEntry {
  const InventoryEntry({
    required this.type,
    required this.mode,
    required this.uid,
    required this.gid,
    required this.size,
    this.sha256,
  });

  final EntryType type;

  /// The permission bits, set-id and sticky bits included.
  final int mode;
  final int uid;
  final int gid;
  final int size;

  /// The content's hash, for a regular file up to 1 MiB.
  final String? sha256;

  /// Whether [other] differs in anything the inventory tracks. A
  /// directory's size only follows its entries, which the diff lists on
  /// their own.
  bool differsFrom(InventoryEntry other) =>
      type != other.type ||
      mode != other.mode ||
      uid != other.uid ||
      gid != other.gid ||
      sha256 != other.sha256 ||
      (type != EntryType.directory && size != other.size);

  String describe() {
    final kind = type.name;
    final perms = mode.toRadixString(8).padLeft(4, '0');
    final hash = sha256 == null ? '' : ' sha256 ${sha256!.substring(0, 12)}';
    return '$kind $perms $uid:$gid $size B$hash';
  }
}

/// The line between inventory.sh's stat lines and its hashes.
const _hashSection = '--- sha256';

/// [text], inventory.sh's output, by path. A line it cannot read is a
/// broken snapshot, not a path to skip.
Map<String, InventoryEntry> parseSnapshot(String text) {
  final stats = <String, InventoryEntry>{};
  final hashes = <String, String>{};
  var inHashes = false;
  for (final line in text.split('\n')) {
    if (line.isEmpty) continue;
    if (line == _hashSection) {
      inHashes = true;
      continue;
    }

    if (inHashes) {
      // sha256sum's "<hash>  <path>".
      final match = RegExp(r'^([0-9a-f]{64}) [ *](.+)$').firstMatch(line);
      if (match == null) throw FormatException('bad hash line', line);
      hashes[match[2]!] = match[1]!;
      continue;
    }

    final fields = line.split('\t');
    if (fields.length < 6 || fields.first != 'S') {
      throw FormatException('bad stat line', line);
    }
    final raw = int.parse(fields[1], radix: 16);
    stats[fields.sublist(5).join('\t')] = InventoryEntry(
      type: switch (raw & _typeMask) {
        _typeFile => EntryType.file,
        _typeDirectory => EntryType.directory,
        _typeSymlink => EntryType.symlink,
        _ => EntryType.other,
      },
      mode: raw & 0xFFF,
      uid: int.parse(fields[2]),
      gid: int.parse(fields[3]),
      size: int.parse(fields[4]),
    );
  }
  return {
    for (final MapEntry(key: path, value: entry) in stats.entries)
      path: InventoryEntry(
        type: entry.type,
        mode: entry.mode,
        uid: entry.uid,
        gid: entry.gid,
        size: entry.size,
        sha256: hashes[path],
      ),
  };
}

enum ChangeKind { added, removed, changed }

/// One path that differs between two snapshots.
final class InventoryChange {
  const InventoryChange(this.path, this.kind, {this.before, this.after});

  final String path;
  final ChangeKind kind;
  final InventoryEntry? before;
  final InventoryEntry? after;

  String describe() => switch (kind) {
    ChangeKind.added => 'added ${after!.describe()}',
    ChangeKind.removed => 'removed ${before!.describe()}',
    ChangeKind.changed =>
      'changed ${before!.describe()} -> ${after!.describe()}',
  };
}

/// Every path added, removed or changed from [before] to [after], by path.
List<InventoryChange> diffSnapshots(
  Map<String, InventoryEntry> before,
  Map<String, InventoryEntry> after,
) {
  final changes = <InventoryChange>[];
  for (final MapEntry(key: path, value: entry) in after.entries) {
    final old = before[path];
    if (old == null) {
      changes.add(InventoryChange(path, ChangeKind.added, after: entry));
    } else if (old.differsFrom(entry)) {
      changes.add(
        InventoryChange(path, ChangeKind.changed, before: old, after: entry),
      );
    }
  }
  for (final MapEntry(key: path, value: entry) in before.entries) {
    if (!after.containsKey(path)) {
      changes.add(InventoryChange(path, ChangeKind.removed, before: entry));
    }
  }
  changes.sort((a, b) => a.path.compareTo(b.path));
  return changes;
}

/// One allowlist line: an 8.11 row and the paths it covers.
final class AllowRule {
  AllowRule(this.row, this.glob) : _pattern = globPattern(glob);

  final String row;
  final String glob;
  final RegExp _pattern;

  bool covers(String path) => _pattern.hasMatch(path);
}

/// [glob] as a whole-path pattern: `**` crosses path segments, `*` and
/// `?` stay within one, and everything else is literal.
RegExp globPattern(String glob) {
  final pattern = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*' && i + 1 < glob.length && glob[i + 1] == '*') {
      pattern.write('.*');
      i++;
    } else if (char == '*') {
      pattern.write('[^/]*');
    } else if (char == '?') {
      pattern.write('[^/]');
    } else {
      pattern.write(RegExp.escape(char));
    }
  }
  pattern.write(r'$');
  return RegExp(pattern.toString());
}

/// inventory_allowlist.txt: per line an 8.11 row and an absolute path
/// glob; `#` starts a comment.
final class InventoryAllowlist {
  InventoryAllowlist(this.rules);

  factory InventoryAllowlist.parse(String text) {
    final rules = <AllowRule>[];
    for (final (index, raw) in text.split('\n').indexed) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;

      final fields = line.split(RegExp(r'\s+'));
      if (fields.length != 2 || !fields[1].startsWith('/')) {
        throw FormatException(
          'line ${index + 1}: expected "<row> <absolute glob>"',
          raw,
        );
      }
      rules.add(AllowRule(fields[0], fields[1]));
    }
    return InventoryAllowlist(rules);
  }

  final List<AllowRule> rules;

  /// The row of the first rule that covers [path], or null for a defect.
  String? rowFor(String path) {
    for (final rule in rules) {
      if (rule.covers(path)) return rule.row;
    }
    return null;
  }
}

/// [changes] one per line, each with its row or `NOT ALLOWED`.
String inventoryReport(
  List<InventoryChange> changes,
  InventoryAllowlist allowlist,
) {
  if (changes.isEmpty) return 'no change\n';
  final lines = [
    for (final change in changes)
      '${allowlist.rowFor(change.path) ?? 'NOT ALLOWED'}\t'
          '${change.path}\t${change.describe()}',
  ];
  return '${lines.join('\n')}\n';
}

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: inventory.dart <allowlist> <before> <after>');
    exitCode = 64;
    return;
  }

  final allowlist = InventoryAllowlist.parse(
    await File(args[0]).readAsString(),
  );
  final changes = diffSnapshots(
    parseSnapshot(await File(args[1]).readAsString()),
    parseSnapshot(await File(args[2]).readAsString()),
  );
  stdout.write(inventoryReport(changes, allowlist));

  final defects = [
    for (final change in changes)
      if (allowlist.rowFor(change.path) == null) change,
  ];
  if (defects.isEmpty) return;
  stderr.writeln(
    '${defects.length} host write(s) outside 03 §8.11, the first '
    '${defects.first.path}',
  );
  exitCode = 1;
}
