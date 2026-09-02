import 'package:path/path.dart' as p;

import 'uuid.dart';

abstract interface class AtomicFileSystem {
  Future<void> write(String path, String contents);

  Future<void> rename(String source, String destination);

  Future<bool> exists(String path);

  Future<void> delete(String path);
}

/// Replaces [targetPath] without exposing partially written contents.
Future<void> writeStringAtomically({
  required AtomicFileSystem fileSystem,
  required String targetPath,
  required String contents,
}) async {
  final temporaryPath = p.join(
    p.dirname(targetPath),
    '.poltergeist-${uuidV4()}.tmp',
  );

  try {
    // The filesystem implementation flushes before this same-volume rename.
    await fileSystem.write(temporaryPath, contents);
    await fileSystem.rename(temporaryPath, targetPath);
  } on Object {
    // Cleanup is best-effort so it cannot hide the persistence failure.
    try {
      if (await fileSystem.exists(temporaryPath)) {
        await fileSystem.delete(temporaryPath);
      }
    } on Object {
      // The original write or rename failure is the actionable error.
    }
    rethrow;
  }
}
