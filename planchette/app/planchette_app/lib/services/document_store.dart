import 'dart:io';

import 'package:path/path.dart' as paths;
import 'package:planchette_core/planchette_core.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show saveBuiltInTextDocument;

enum DocumentWriteTarget { local, managedRemote }

/// Linux's own limit on links followed while resolving one path.
const _maximumLinkHops = 40;

/// A cheap summary of a file's state, read without opening it. Equal stamps
/// mean the file almost certainly did not change, so the costlier digest is
/// read only when they differ. A same-size rewrite within the file system's
/// timestamp granularity can slip past a check; the digest guard on save
/// still catches it.
typedef FileStamp = ({DateTime modified, int size});

/// A write may have altered the destination. Its recovery instructions must
/// remain visible even when the subsequent disk check also detects a change.
final class DocumentRecoveryException implements Exception {
  const DocumentRecoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Copies of a document's earlier contents that the Android runner keeps
/// when a provider write fails. Each opens at every launch until it is
/// saved elsewhere or deleted here. Desktop stores keep none.
abstract interface class RecoveryCopies {
  bool isRecoveryCopy(String path);

  /// Deletes the copy at [path]; throws when the runner could not.
  Future<void> discardRecovery(String path);
}

/// The shell's filesystem boundary. Tests substitute an in-memory store.
abstract interface class DocumentStore {
  /// Reads [path] as [encoding], or detects UTF-8 or marked UTF-16 when it
  /// is null; see [loadTextDocument].
  Future<TextDocument> load(
    String path, {
    SymlinkPolicy symlinkPolicy = SymlinkPolicy.resolveOnce,
    TextEncoding? encoding,
  });

  /// Null when no regular file exists at [path], as when a directory has
  /// taken its place: for an open document, both mean the file is gone.
  Future<FileStamp?> stamp(String path);
  Future<String> canonicalSavePath(String path);
  Future<String?> existingDigest(String path);

  /// Whether the file at [path] is marked read-only. A save would still
  /// replace it, so the workspace asks first.
  Future<bool> isWriteProtected(String path);
  Future<TextDocument> write({
    required String path,
    required String text,
    required TextDocument? source,
    required String? expectedSha256,
    TextDocumentMetadata? metadata,
    DocumentWriteTarget target = DocumentWriteTarget.local,
  });
}

final class LocalDocumentStore implements DocumentStore {
  @override
  Future<TextDocument> load(
    String path, {
    SymlinkPolicy symlinkPolicy = SymlinkPolicy.resolveOnce,
    TextEncoding? encoding,
  }) => loadTextDocument(
    File(path),
    symlinkPolicy: symlinkPolicy,
    encoding: encoding,
  );

  @override
  Future<FileStamp?> stamp(String path) async {
    // Follows a link, as [load] does, so the stamp describes the file whose
    // text the tab holds.
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return (modified: stat.modified, size: stat.size);
  }

  @override
  Future<String> canonicalSavePath(String path) async {
    final absolute = paths.normalize(paths.absolute(path));
    final type = await FileSystemEntity.type(absolute, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return _resolveSaveLink(absolute);
    }
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

  /// Save As onto a link writes through it, as opening one reads through
  /// it: the destination becomes the regular file the link names, which
  /// then takes the same digest guard and replace question as any existing
  /// file, and the link itself is never replaced. A link that names no
  /// regular file is refused with the reason rather than created or
  /// replaced.
  Future<String> _resolveSaveLink(String link) async {
    // Walk the chain by hand: resolving reports a missing target and a loop
    // with the same platform-specific errors.
    final visited = <String>{};
    var current = link;
    while (await FileSystemEntity.isLink(current)) {
      if (!visited.add(current) || visited.length > _maximumLinkHops) {
        throw FileSystemException(
          'The destination is a symbolic link that loops back on itself, '
          'so it names no file.',
          link,
        );
      }
      final target = await Link(current).target();
      current = paths.normalize(paths.join(paths.dirname(current), target));
    }
    switch (await FileSystemEntity.type(current)) {
      case FileSystemEntityType.notFound:
        throw FileSystemException(
          'The destination is a symbolic link that points to a file that '
          'does not exist: $current. Choose the file itself, or create it '
          'first.',
          link,
        );
      case FileSystemEntityType.directory:
        throw FileSystemException(
          'The destination is a symbolic link to a folder, not a file: '
          '$current.',
          link,
        );
      case FileSystemEntityType.file:
        // Resolving again fixes directory aliases in the target's spelling.
        return File(current).resolveSymbolicLinks();
      default:
        throw FileSystemException(
          'The destination is a symbolic link to something other than a '
          'regular file: $current.',
          link,
        );
    }
  }

  @override
  Future<bool> isWriteProtected(String path) =>
      isTextDocumentWriteProtected(File(path));

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
    TextDocumentMetadata? metadata,
    DocumentWriteTarget target = DocumentWriteTarget.local,
  }) async {
    if (target == DocumentWriteTarget.managedRemote && expectedSha256 == null) {
      throw const TextDocumentException(
        'The managed copy has no verified baseline. Reload it or save a local copy before retrying.',
      );
    }
    final file = File(path);
    final format = metadata ?? source?.metadata ?? const TextDocumentMetadata();
    final bom = format.utf8Bom == Utf8Bom.present;
    final ending = format.lineEnding;
    final encoding = format.encoding;
    // Managed siblings must retain the checkout store's crash-recovery names.
    final digest = target == DocumentWriteTarget.managedRemote
        ? await saveBuiltInTextDocument(
            file,
            text,
            hasUtf8Bom: bom,
            lineEnding: ending,
            encoding: encoding,
            expectedSha256: expectedSha256,
          )
        : expectedSha256 == null
        ? await createTextDocument(
            file,
            text,
            hasUtf8Bom: bom,
            lineEnding: ending,
            encoding: encoding,
          )
        : await saveTextDocument(
            file,
            text,
            expectedSha256: expectedSha256,
            hasUtf8Bom: bom,
            lineEnding: ending,
            encoding: encoding,
          );
    return TextDocument(
      file: file,
      text: text,
      hasUtf8Bom: bom,
      lineEnding: ending,
      sha256: digest,
      encoding: encoding,
    );
  }
}
