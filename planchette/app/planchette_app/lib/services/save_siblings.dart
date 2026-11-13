import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as paths;

import 'document_store.dart';

/// A file a guarded save left beside a document: the previous version it
/// moved aside (`.backup`) or the new text it staged (`.edit`). Either holds
/// plaintext the user may want, so it is never deleted without asking.
typedef SaveSibling = ({String path, FileStamp stamp});

/// What the user chose for a document's leftover save files.
enum SaveSiblingChoice {
  /// Open each one in its own tab, to compare or save elsewhere.
  open,

  /// Delete them.
  delete,

  /// Leave them; the next session asks again.
  keep,
}

/// Why a sibling was not deleted. The message completes "could not delete
/// `name`: ".
final class SaveSiblingException implements Exception {
  const SaveSiblingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds and removes the files an interrupted save left beside a document.
abstract interface class SaveSiblings {
  /// The leftover files of [documentPath], oldest name first. Empty when
  /// there are none, or when the folder cannot be read.
  Future<List<SaveSibling>> find(String documentPath);

  /// Deletes [sibling] of [documentPath], or throws [SaveSiblingException]
  /// when the evidence no longer says it is abandoned. One already gone
  /// counts as deleted.
  Future<void> delete(String documentPath, SaveSibling sibling);
}

/// [SaveSiblings] over the local file system, for the names
/// `planchette_core`'s guarded save gives its files:
/// `<name>.planchette-<uuid>.edit` and `.backup`, with `<name>` shortened
/// (whole characters only) when the result would pass 255 bytes.
final class LocalSaveSiblings implements SaveSiblings {
  LocalSaveSiblings({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// The core's temporary prefix for Planchette's own saves.
  static const _prefix = '.planchette';

  /// The component limit the core shortens names to fit.
  static const _maximumNameBytes = 255;

  /// The longest UTF-8 character, which the core drops whole when it does not
  /// fit, so a shortened name may end up to this much short of the limit.
  static const _maximumCharacterBytes = 4;

  /// A staging file this new may belong to a save that is running right now,
  /// in this or another process: a guarded save writes it in well under
  /// this. A backup keeps the original's time, so only `.edit` is held back
  /// by it; a running save's backup exists only between two renames.
  static const activeSaveWindow = Duration(minutes: 1);

  static final _sibling = RegExp(
    '${RegExp.escape(_prefix)}-'
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    r'\.(edit|backup)$',
  );

  @override
  Future<List<SaveSibling>> find(String documentPath) async {
    final name = paths.basename(documentPath);
    final found = <SaveSibling>[];
    try {
      await for (final entry in Directory(
        paths.dirname(documentPath),
      ).list(followLinks: false)) {
        if (entry is! File) continue;
        final siblingName = paths.basename(entry.path);
        final match = _sibling.firstMatch(siblingName);
        if (match == null) continue;
        final stem = siblingName.substring(0, match.start);
        if (!_belongsTo(stem, siblingName.substring(match.start), name)) {
          continue;
        }
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        if (match.group(1) == 'edit' &&
            _clock().difference(stat.modified) < activeSaveWindow) {
          continue;
        }
        found.add((
          path: entry.path,
          stamp: (modified: stat.modified, size: stat.size),
        ));
      }
    } on FileSystemException {
      // Best effort: a folder that cannot be listed has nothing to offer,
      // and the document itself opened, which is what the user asked for.
      return const [];
    }
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  /// Whether [stem] is [name] as the core spells it beside [suffix]: the
  /// whole name, or a prefix of it only as short as the byte limit forced.
  static bool _belongsTo(String stem, String suffix, String name) {
    if (stem == name) return true;
    if (stem.isEmpty || !name.startsWith(stem)) return false;
    final available = _maximumNameBytes - utf8.encode(suffix).length;
    final used = utf8.encode(stem).length;
    return used <= available && used > available - _maximumCharacterBytes;
  }

  @override
  Future<void> delete(String documentPath, SaveSibling sibling) async {
    final file = File(sibling.path);
    final stat = await file.stat();
    // Gone already, say by a save that finished in another window: what
    // the user asked for has happened.
    if (stat.type == FileSystemEntityType.notFound) return;
    if (stat.type != FileSystemEntityType.file ||
        stat.modified != sibling.stamp.modified ||
        stat.size != sibling.stamp.size) {
      throw const SaveSiblingException(
        'it changed since Planchette found it, so another save may be using '
        'it',
      );
    }
    // With the document gone, either sibling may hold the only copy of a
    // version of its text: a save that stopped between its renames leaves
    // the earlier text in the backup and the newest in the staging file.
    if (await FileSystemEntity.type(documentPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw SaveSiblingException(
        '${paths.basename(documentPath)} is missing, so this may be its only '
        'copy',
      );
    }
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      throw SaveSiblingException(error.osError?.message ?? error.message);
    }
  }
}
