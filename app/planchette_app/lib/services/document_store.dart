import 'dart:io';

import 'package:path/path.dart' as paths;
import 'package:planchette_core/planchette_core.dart';

/// A cheap summary of a file's state. Two equal stamps mean the file almost
/// certainly did not change; unequal stamps call for a digest comparison.
/// A same-size rewrite within the file system's timestamp granularity can
/// slip past a check; the digest guard at save time still catches it.
typedef FileStamp = ({DateTime modified, int size});

/// The shell's filesystem boundary. Tests substitute an in-memory store.
abstract interface class DocumentStore {
  Future<TextDocument> load(String path);

  /// Null when no regular file exists at [path], as when a directory has
  /// taken its place.
  Future<FileStamp?> stamp(String path);
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
  Future<FileStamp?> stamp(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return (modified: stat.modified, size: stat.size);
  }

  @override
  Future<String> canonicalSavePath(String path) async {
    final absolute = paths.normalize(paths.absolute(path));
    final type = await FileSystemEntity.type(absolute, followLinks: false);
    if (type == FileSystemEntityType.file) {
      // An existing target's actual spelling matters on case-insensitive
      // volumes: a case variant must retain its open tab and digest identity.
      final canonical = await File(absolute).resolveSymbolicLinks();
      if (await FileSystemEntity.type(absolute, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('The save destination changed.', path);
      }
      return canonical;
    }
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Choose a regular file as the destination.',
        path,
      );
    }
    // New files have no final component to resolve. Retain the chosen name
    // while fixing directory aliases before exclusive creation.
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
