// DSK-07's whole-tree read (03 §7.3): `ncdu -x -o -` or `gdu -x -o-`
// export a filesystem as one JSON document in ncdu's export format, which
// can run to hundreds of megabytes on a large one. [DiskUsageExportReader]
// reads it as it streams and keeps only what the explorer lists: each
// folder's total and its largest entries, as `HostCommands.diskUsage`
// would have listed them, so every folder under the scan opens without
// another read.
//
// The format (ncdu's "export" document, major version 1):
//
//   [1, 2, {"progname": ...},
//    [{"name": "/srv", "dsize": 4096},          <- a folder: an array whose
//     {"name": "file", "dsize": 8192},          first item describes it,
//     [{"name": "sub", ...}, ...children...]]]  then its entries
//
// Every object is flat, so the reader captures each one whole and decodes
// it alone; the arrays around them give the tree.
import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart' show kDiskUsageEntries;
import 'disk_usage.dart';

/// The most entries a whole-tree read keeps across every folder [E]: past
/// it the export reads as too large, and the explorer reads folder by
/// folder instead, so the engine's memory stays bounded on a filesystem
/// of millions of folders.
const kDiskUsageExportEntries = 1 << 20;

/// The longest object the reader captures [E]: an entry is a name and a
/// few numbers, so a longer one is not an export.
const _maxObjectLength = 64 * 1024;

/// Why a whole-tree read stopped.
final class DiskUsageExportException implements Exception {
  const DiskUsageExportException(this.message);

  final String message;

  @override
  String toString() => 'DiskUsageExportException: $message';
}

/// A filesystem as an export described it, folder by folder; see
/// [listing].
final class DiskUsageTree {
  DiskUsageTree._(this.root, this._top, this._keep);

  /// The folder the export started at.
  final String root;
  final _Folder _top;
  final int _keep;

  /// [path]'s listing, as `HostCommands.diskUsage` would have read it,
  /// or null when [path] is not [root] or a folder under it that the tree
  /// kept: a folder outside the largest entries of its parent is dropped.
  DiskUsageListing? listing(String path) {
    final String rest;
    if (path == root) {
      rest = '';
    } else {
      final prefix = root == '/' ? '/' : '$root/';
      if (!path.startsWith(prefix)) return null;
      rest = path.substring(prefix.length);
    }
    var folder = _top;
    if (rest.isNotEmpty) {
      for (final name in rest.split('/')) {
        final next = folder.entries
            .where((entry) => entry.name == name)
            .map((entry) => entry.folder)
            .firstOrNull;
        if (next == null) return null;
        folder = next;
      }
    }
    return DiskUsageListing(
      path: path,
      totalBytes: folder.total,
      entries: [
        for (final entry in folder.entries)
          DiskUsageEntry(
            name: entry.name,
            bytes: entry.bytes,
            isFolder: entry.folder != null,
          ),
      ],
      truncated: folder.count >= _keep,
      incomplete: folder.incomplete,
    );
  }
}

/// Reads an ncdu export of [root] as it streams: [add] each decoded chunk,
/// then [close] for the tree. Throws [DiskUsageExportException] from
/// either when the text is not an export, or holds more than
/// [maxEntries] across its folders.
final class DiskUsageExportReader {
  DiskUsageExportReader(
    this.root, {
    this.maxEntries = kDiskUsageExportEntries,
    @visibleForTesting this.keep = kDiskUsageEntries,
  });

  final String root;
  final int maxEntries;

  /// The most entries each folder keeps, largest first.
  final int keep;

  /// One per open array: null for the document's own, a folder otherwise.
  final _arrays = <_Folder?>[];
  _Folder? _top;
  bool _done = false;
  bool _sawMetadata = false;

  /// gdu 5.37 and later write a folder's whole usage on its description,
  /// ncdu and older gdu only its own blocks or nothing: a gdu folder's
  /// own size is not read, so its total is what lies under it.
  bool _gdu = false;

  final _object = StringBuffer();
  int _objectDepth = 0;
  bool _inString = false;
  bool _escaped = false;

  /// Inodes of hard-linked files already counted: `du` counts a file
  /// once however many names it has, and so do the totals here.
  final _linked = <int>{};
  int _kept = 0;

  void add(String chunk) {
    for (var index = 0; index < chunk.length; index++) {
      final char = chunk.codeUnitAt(index);
      if (_objectDepth > 0) {
        _capture(char);
        continue;
      }
      switch (char) {
        case _openBracket:
          _openArray();
        case _closeBracket:
          _closeArray();
        case _openBrace:
          if (_done) _fail('text after the export');
          _objectDepth = 1;
          _object
            ..clear()
            ..writeCharCode(char);
        case _comma || _space || _tab || _newline || _return:
          break;
        default:
          // The version numbers at the top; nothing else stands bare.
          if (_arrays.length != 1 || !_isDigit(char)) {
            _fail('unexpected ${String.fromCharCode(char)}');
          }
      }
    }
  }

  DiskUsageTree close() {
    final top = _top;
    if (!_done || top == null) _fail('the export ended early');
    return DiskUsageTree._(root, top, keep);
  }

  void _capture(int char) {
    _object.writeCharCode(char);
    if (_object.length > _maxObjectLength) _fail('an object is too long');
    if (_inString) {
      if (_escaped) {
        _escaped = false;
      } else if (char == _backslash) {
        _escaped = true;
      } else if (char == _quote) {
        _inString = false;
      }
      return;
    }
    switch (char) {
      case _quote:
        _inString = true;
      case _openBrace:
        _objectDepth++;
      case _closeBrace:
        if (--_objectDepth == 0) _onObject(_object.toString());
    }
  }

  void _openArray() {
    if (_done) _fail('text after the export');
    if (_arrays.isEmpty) {
      _arrays.add(null);
      return;
    }
    if (!_sawMetadata) _fail('a folder before the metadata');
    // A folder: its first object describes it.
    _arrays.add(_Folder());
  }

  void _closeArray() {
    if (_arrays.isEmpty) _fail('an unmatched ]');
    final folder = _arrays.removeLast();
    if (folder == null) {
      if (_top == null) _fail('no folder in the export');
      _done = true;
      return;
    }
    if (folder.name == null) _fail('a folder without its description');
    _kept -= folder.finish(keep);
    final parent = _arrays.last;
    // Another filesystem mounted here, which ncdu writes as a folder: `du
    // -x` does not list it either.
    if (folder.excluded && parent != null) return;
    if (parent == null) {
      if (_top != null) _fail('a second top folder');
      _top = folder;
      return;
    }
    _keep(parent, _Entry(folder.name!, folder.total, folder));
    if (folder.incomplete) parent.incomplete = true;
  }

  void _onObject(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      _fail('an object is not JSON');
    }
    if (decoded is! Map<String, Object?>) _fail('an object is not a map');

    final current = _arrays.isEmpty ? null : _arrays.last;
    if (current == null) {
      if (_arrays.length != 1 || _sawMetadata) _fail('a stray object');
      _sawMetadata = true;
      _gdu = decoded['progname'] == 'gdu';
      return;
    }

    final name = decoded['name'];
    if (name is! String || name.isEmpty) _fail('an entry without a name');
    final bytes = switch (decoded['dsize']) {
      final int size when size >= 0 => size,
      _ => 0,
    };
    final readError = decoded['read_error'] == true;

    if (current.name == null) {
      // The folder's own description: its name and its own blocks.
      current
        ..name = name
        ..total = _gdu ? 0 : bytes
        ..incomplete = readError
        ..excluded = decoded['excluded'] != null;
      return;
    }

    // Another filesystem's mount point or an excluded path: `du -x` does
    // not list it either.
    if (decoded['excluded'] != null) return;
    if (readError) current.incomplete = true;
    var counted = bytes;
    if (decoded['hlnkc'] == true) {
      if (decoded['ino'] case final int inode) {
        if (_linked.add(inode)) {
          // The set grows with the hard links, so it counts toward the
          // bound as kept entries do.
          if (++_kept > maxEntries) _fail('more than $maxEntries entries');
        } else {
          counted = 0;
        }
      }
    }
    _keep(current, _Entry(name, counted, null));
  }

  void _keep(_Folder folder, _Entry entry) {
    folder.total += entry.bytes;
    folder.count++;
    folder.entries.add(entry);
    folder.retained += 1 + (entry.folder?.retained ?? 0);
    _kept++;
    // Trim to the largest now and then, not on every entry, so a folder
    // of a million files costs a sort per [keep] of them.
    if (folder.entries.length >= keep * 2) _kept -= folder.trim(keep);
    if (_kept > maxEntries) _fail('more than $maxEntries entries');
  }

  static bool _isDigit(int char) => char >= 0x30 && char <= 0x39;

  static Never _fail(String message) => throw DiskUsageExportException(message);

  static const _openBracket = 0x5B;
  static const _closeBracket = 0x5D;
  static const _openBrace = 0x7B;
  static const _closeBrace = 0x7D;
  static const _quote = 0x22;
  static const _backslash = 0x5C;
  static const _comma = 0x2C;
  static const _space = 0x20;
  static const _tab = 0x09;
  static const _newline = 0x0A;
  static const _return = 0x0D;
}

final class _Folder {
  String? name;
  int total = 0;

  /// Every entry the export listed in this folder, kept or not.
  int count = 0;
  bool incomplete = false;

  /// Another filesystem's mount point or an excluded path.
  bool excluded = false;
  List<_Entry> entries = [];

  /// The entries this folder holds, its kept folders' included.
  int retained = 0;

  /// Keeps the [keep] largest entries, largest first, and says how many
  /// entries that freed, a dropped folder's own included.
  int trim(int keep) {
    entries.sort((a, b) => b.bytes.compareTo(a.bytes));
    if (entries.length <= keep) return 0;
    var freed = 0;
    for (final entry in entries.skip(keep)) {
      freed += 1 + (entry.folder?.retained ?? 0);
    }
    entries = entries.sublist(0, keep);
    retained -= freed;
    return freed;
  }

  /// Trims for good; says how many entries that freed.
  int finish(int keep) {
    final freed = trim(keep);
    entries = List.unmodifiable(entries);
    return freed;
  }
}

final class _Entry {
  const _Entry(this.name, this.bytes, this.folder);

  final String name;
  final int bytes;

  /// The folder this entry is, when it is one.
  final _Folder? folder;
}
