/// The default writer behind the catalog stores' `atomicWriter` seams
/// (docs/design/catalog-library.md section 2.2). It reproduces the write
/// order and permission model of Poltergeist's
/// `TransferJournalIo.atomicRewrite`, which the stores used before they
/// moved here: a `seance_core` file cannot import `poltergeist_core`, and
/// the transfer journal keeps its own writer behind its fault-injection
/// seam.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../store/file_permissions.dart';
import '../store/local_directory_sync.dart';

/// Who may read a file [AtomicFileWriter] replaces.
enum AtomicFilePrivacy {
  /// The process's default file-creation mode. The catalog stores write
  /// `servers.json` and `sync_records.json` this way, as they did before
  /// the move.
  processDefault,

  /// Owner-only mode bits (0600) on Linux and macOS, applied through
  /// [restrictLocalPathPermissions]: a failed or unavailable chmod aborts
  /// the write instead of leaving a lax file. Other platforms keep their
  /// per-user storage ACLs.
  ownerOnly,
}

/// Atomic whole-file replacement (the #110 pattern, hardened per 03 §4.6):
/// a sibling temp with a random-hex name (dart:io has no O_EXCL; the suffix
/// makes collisions vanishingly unlikely rather than impossible) is
/// written, fsynced, renamed over the target, and the containing directory
/// fsynced so the rename itself survives power loss. A failure deletes the
/// temp and rethrows.
final class AtomicFileWriter {
  const AtomicFileWriter();

  static final Map<String, Future<void>> _pendingWrites = {};
  static Future<void> _resolutionTail = Future<void>.value();

  /// Replaces [file] with [contents], creating missing parent directories.
  Future<void> write(
    File file,
    String contents, {
    AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault,
  }) {
    return writeBytes(file, utf8.encode(contents), privacy: privacy);
  }

  /// Replaces [file] with [bytes], creating missing parent directories.
  Future<void> writeBytes(
    File file,
    List<int> bytes, {
    AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault,
  }) {
    final result = Completer<void>();
    // Resolve aliases in request order, not in filesystem-completion order.
    // Only resolution is global; writes to different targets still overlap.
    final enqueue = _resolutionTail.then((_) async {
      final target = await _resolveTarget(file);
      final key = _queueKey(target.path);
      final previous = _pendingWrites[key] ?? Future<void>.value();
      final write = previous.then(
        (_) => _writeResolved(target, bytes, privacy),
      );
      late final Future<void> tail;
      tail = write
          .then<void>((_) {}, onError: (Object _, StackTrace __) {})
          .whenComplete(() {
            if (identical(_pendingWrites[key], tail))
              _pendingWrites.remove(key);
          });
      _pendingWrites[key] = tail;
      result.complete(write);
    });
    _resolutionTail = enqueue.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<void> _writeResolved(
    File target,
    List<int> bytes,
    AtomicFilePrivacy privacy,
  ) async {
    final ownerOnly = privacy == AtomicFilePrivacy.ownerOnly;
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp-${_randomHexSuffix()}');
    try {
      if (ownerOnly) {
        // Restrict before any content lands: the empty temp briefly exists
        // at the umask default, but nothing is written until it is 0600.
        await temporary.create();
        await restrictLocalPathPermissions(temporary.path, '600');
      }
      final raf = await temporary.open(mode: FileMode.writeOnly);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }
      // Never delete a committed file to retry a failed rename. A refused
      // replacement must leave the old snapshot available for recovery.
      await temporary.rename(target.path);
      if (ownerOnly) {
        // Rename carries the temp's mode; the explicit chmod also tightens
        // a destination that outlived an odd rename path.
        await restrictLocalPathPermissions(target.path, '600');
      }
      await syncLocalDirectory(target.parent);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // The original failure is the actionable error.
      }
      rethrow;
    }
  }

  Future<File> _resolveTarget(File file) async {
    var current = file.absolute;
    final visited = <String>{};
    const maxLinkDepth = 40;
    for (var depth = 0; depth < maxLinkDepth; depth++) {
      final type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        if (!visited.add(_queueKey(current.path))) {
          throw FileSystemException('Cyclic symbolic link', file.path);
        }
        final linkTarget = await Link(current.path).target();
        current = File(linkTarget).isAbsolute
            ? File(linkTarget)
            : File.fromUri(current.parent.uri.resolveUri(Uri.file(linkTarget)));
        continue;
      }
      if (type != FileSystemEntityType.notFound) {
        return File(await current.resolveSymbolicLinks());
      }
      // A dangling target may have missing ancestors or a symlinked parent.
      // Resolve the nearest existing parent without treating filename bytes
      // such as '%' or '?' as URI syntax.
      if (current.parent.path == current.path) {
        throw FileSystemException('Cannot resolve filesystem root', file.path);
      }
      final parent = await _resolveTarget(File(current.parent.path));
      final name = current.uri.pathSegments.last;
      return File.fromUri(
        Directory(parent.path).uri.resolveUri(Uri.file(name)),
      );
    }
    throw FileSystemException('Too many symbolic links', file.path);
  }

  String _queueKey(String path) {
    // Folding case only adds serialization on case-sensitive volumes; the
    // actual target spelling is unchanged.
    return File(path).absolute.uri.normalizePath().toFilePath().toLowerCase();
  }
}

String _randomHexSuffix() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}
