import 'dart:io';

import 'package:path/path.dart' as paths;
import 'package:planchette_core/planchette_core.dart';

/// The shell's filesystem boundary. Tests substitute an in-memory store.
abstract interface class DocumentStore {
  Future<TextDocument> load(String path);
  Future<String> canonicalSavePath(String path);
  Future<String?> existingDigest(String path);
  Future<TextDocument> write({
    required String path,
    required String text,
    required TextDocument? source,
    required String? expectedSha256,
  });
}

final class LocalDocumentStore implements DocumentStore {
  @override
  Future<TextDocument> load(String path) =>
      loadTextDocument(File(path), symlinkPolicy: SymlinkPolicy.resolveOnce);

  @override
  Future<String> canonicalSavePath(String path) async {
    // Resolve directory aliases without following the final component: the
    // latter still must pass the regular-file/exclusive-create safety checks.
    final absolute = paths.normalize(paths.absolute(path));
    final parent = await Directory(
      paths.dirname(absolute),
    ).resolveSymbolicLinks();
    return paths.join(parent, paths.basename(absolute));
  }

  @override
  Future<String?> existingDigest(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Choose a regular file as the destination.',
        path,
      );
    }
    return textDocumentSha256(File(path));
  }

  @override
  Future<TextDocument> write({
    required String path,
    required String text,
    required TextDocument? source,
    required String? expectedSha256,
  }) async {
    final file = File(path);
    final bom = source?.hasUtf8Bom ?? false;
    final ending = source?.lineEnding ?? LineEnding.lf;
    final digest = expectedSha256 == null
        ? await createTextDocument(
            file,
            text,
            hasUtf8Bom: bom,
            lineEnding: ending,
          )
        : await saveTextDocument(
            file,
            text,
            expectedSha256: expectedSha256,
            hasUtf8Bom: bom,
            lineEnding: ending,
          );
    return TextDocument(
      file: file,
      text: text,
      hasUtf8Bom: bom,
      lineEnding: ending,
      sha256: digest,
    );
  }
}
