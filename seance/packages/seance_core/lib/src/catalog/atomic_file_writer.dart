/// The default writer behind the catalog stores' `atomicWriter` seams
/// (docs/design/catalog-library.md section 2.2). It reproduces the write
/// order and permission model of Poltergeist's
/// `TransferJournalIo.atomicRewrite`, which the stores used before they
/// moved here: a `seance_core` file cannot import `poltergeist_core`, and
/// the transfer journal keeps its own writer behind its fault-injection
/// seam.
library;

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

  /// Replaces [file] with [contents], creating missing parent directories.
  Future<void> write(
    File file,
    String contents, {
    AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault,
  }) async {
    final ownerOnly = privacy == AtomicFilePrivacy.ownerOnly;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-${_randomHexSuffix()}');
    try {
      if (ownerOnly) {
        // Restrict before any content lands: the empty temp briefly exists
        // at the umask default, but nothing is written until it is 0600.
        await temporary.create();
        await restrictLocalPathPermissions(temporary.path, '600');
      }
      final raf = await temporary.open(mode: FileMode.writeOnly);
      try {
        await raf.writeString(contents);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await temporary.rename(file.path);
      if (ownerOnly) {
        // Rename carries the temp's mode; the explicit chmod also tightens
        // a destination that outlived an odd rename path.
        await restrictLocalPathPermissions(file.path, '600');
      }
      await syncLocalDirectory(file.parent);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // The original failure is the actionable error.
      }
      rethrow;
    }
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
