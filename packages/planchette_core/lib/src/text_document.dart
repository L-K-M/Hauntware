import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'native_file_operations.dart';

const int textDocumentMaximumBytes = 4 * 1024 * 1024;
const int defaultTextDocumentMaximumBytes = textDocumentMaximumBytes;

/// The dominant on-disk line ending. Ties and single-line files use LF.
enum LineEnding { lf, crlf }

/// Hosts may preserve raw line endings for compatibility with existing APIs.
/// Normalized editing buffers use LF; normalized saves use [LineEnding].
enum TextNormalization { preserve, normalize }

/// Managed working copies reject links. User-selected local files can resolve
/// a link once, then retain [TextDocument.file] as their save identity.
enum SymlinkPolicy { reject, resolveOnce }

final class TextDocument {
  const TextDocument({
    required this.file,
    required this.text,
    required this.hasUtf8Bom,
    required this.lineEnding,
    required this.sha256,
  });

  final File file;
  final String text;
  final bool hasUtf8Bom;
  final LineEnding lineEnding;
  final String sha256;

  TextDocument copyWith({
    File? file,
    String? text,
    bool? hasUtf8Bom,
    LineEnding? lineEnding,
    String? sha256,
  }) => TextDocument(
    file: file ?? this.file,
    text: text ?? this.text,
    hasUtf8Bom: hasUtf8Bom ?? this.hasUtf8Bom,
    lineEnding: lineEnding ?? this.lineEnding,
    sha256: sha256 ?? this.sha256,
  );
}

/// Stable, bare messages allow hosts to retain their existing error adapters.
final class TextDocumentException implements Exception {
  const TextDocumentException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<String> textDocumentSha256(File file) async {
  await _requireRegularFile(file);
  return (await crypto.sha256.bind(file.openRead()).first).toString();
}

Future<File> resolveTextDocumentTarget(
  File file, {
  SymlinkPolicy symlinkPolicy = SymlinkPolicy.reject,
}) async {
  if (symlinkPolicy == SymlinkPolicy.resolveOnce) {
    // Resolve ancestors as well, so a later retargeted directory link cannot
    // silently move a local document's save identity to another directory.
    file = File(await file.resolveSymbolicLinks());
  }
  await _requireRegularFile(file);
  return file;
}

/// Reads bounded, strict UTF-8, retaining one leading BOM as metadata and
/// every additional U+FEFF as content. Digest checks reject changing snapshots.
Future<TextDocument> loadTextDocument(
  File file, {
  int maximumBytes = textDocumentMaximumBytes,
  TextNormalization normalization = TextNormalization.normalize,
  SymlinkPolicy symlinkPolicy = SymlinkPolicy.reject,
  Future<String> Function(File file)? sha256Of,
}) async {
  _validateMaximumBytes(maximumBytes);
  file = await resolveTextDocumentTarget(file, symlinkPolicy: symlinkPolicy);
  if (await file.length() > maximumBytes) {
    throw TextDocumentException(_tooLargeMessage(maximumBytes));
  }
  final digestOf = sha256Of ?? textDocumentSha256;
  final before = await digestOf(file);
  final bytes = <int>[];
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw TextDocumentException(_tooLargeMessage(maximumBytes));
    }
    bytes.addAll(chunk);
  }
  final after = await digestOf(file);
  await _requireRegularFile(file);
  if (before != after || crypto.sha256.convert(bytes).toString() != after) {
    throw const TextDocumentException(
      'The local copy changed while it was being opened.',
    );
  }

  var leadingBoms = 0;
  while (_utf8BomAt(bytes, leadingBoms * _utf8Bom.length)) {
    leadingBoms++;
  }
  late final String raw;
  try {
    // Utf8Decoder itself drops a leading BOM. Decode only after all leading
    // BOMs, then put back the ones that are document content.
    final content = const Utf8Decoder(
      allowMalformed: false,
    ).convert(bytes, leadingBoms * _utf8Bom.length);
    raw = leadingBoms > 1 ? '\uFEFF' * (leadingBoms - 1) + content : content;
  } on FormatException {
    throw const TextDocumentException('This file is not valid UTF-8 text.');
  }
  if (raw.contains('\u0000')) {
    throw const TextDocumentException(
      'This file appears to be binary, not editable text.',
    );
  }
  final crlfCount = RegExp(r'\r\n').allMatches(raw).length;
  final lfCount = RegExp(r'(?<!\r)\n').allMatches(raw).length;
  return TextDocument(
    file: file,
    text: normalization == TextNormalization.preserve ? raw : _foldToLf(raw),
    hasUtf8Bom: leadingBoms > 0,
    lineEnding: crlfCount > lfCount ? LineEnding.crlf : LineEnding.lf,
    sha256: after,
  );
}

/// Replaces an existing regular file only when its digest still matches.
/// Temporary plaintext is owner-only on POSIX before the first write. The
/// original mode is restored before publication; a failed publication restores
/// the backup only if no other writer has recreated the destination.
///
/// This is a best-effort conflict guard, not a cross-process lock. Replacement
/// briefly removes the original path while checking its backup. Hosts retain
/// their temp prefix so their existing crash-recovery sweeps keep working.
Future<String> saveTextDocument(
  File file,
  String text, {
  required String expectedSha256,
  bool hasUtf8Bom = false,
  LineEnding lineEnding = LineEnding.lf,
  TextNormalization normalization = TextNormalization.normalize,
  String temporaryPrefix = '.planchette',
  int maximumBytes = textDocumentMaximumBytes,
  Future<void> Function(File temporary)? observeTemporary,
  Future<void> Function(File backup)? observeBackup,
}) => _writeTextDocument(
  file,
  text,
  expectedSha256: expectedSha256,
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding,
  normalization: normalization,
  temporaryPrefix: temporaryPrefix,
  maximumBytes: maximumBytes,
  observeTemporary: observeTemporary,
  observeBackup: observeBackup,
);

/// Publishes a fully written new file only if the destination does not exist.
/// Never precreates an empty destination and never follows or replaces a link.
Future<String> createTextDocument(
  File file,
  String text, {
  bool hasUtf8Bom = false,
  LineEnding lineEnding = LineEnding.lf,
  TextNormalization normalization = TextNormalization.normalize,
  String temporaryPrefix = '.planchette',
  int maximumBytes = textDocumentMaximumBytes,
  Future<void> Function(File temporary)? observeTemporary,
}) => _writeTextDocument(
  file,
  text,
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding,
  normalization: normalization,
  temporaryPrefix: temporaryPrefix,
  maximumBytes: maximumBytes,
  observeTemporary: observeTemporary,
);

Future<String> _writeTextDocument(
  File file,
  String text, {
  String? expectedSha256,
  required bool hasUtf8Bom,
  required LineEnding lineEnding,
  required TextNormalization normalization,
  required String temporaryPrefix,
  required int maximumBytes,
  Future<void> Function(File temporary)? observeTemporary,
  Future<void> Function(File backup)? observeBackup,
}) async {
  _validateMaximumBytes(maximumBytes);
  if (!RegExp(r'^\.[a-zA-Z0-9_-]+$').hasMatch(temporaryPrefix)) {
    throw ArgumentError.value(temporaryPrefix, 'temporaryPrefix');
  }
  final normalized = normalization == TextNormalization.preserve
      ? text
      : _normalizeLineEndings(text, lineEnding);
  final bytes = <int>[if (hasUtf8Bom) ..._utf8Bom, ...utf8.encode(normalized)];
  if (bytes.length > maximumBytes) {
    throw TextDocumentException(
      'The edited file exceeds the '
      '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB built-in editor '
      'limit.',
    );
  }
  final temporary = File(
    '${file.path}$temporaryPrefix-${const Uuid().v4()}.edit',
  );
  final backup = File(
    '${file.path}$temporaryPrefix-${const Uuid().v4()}.backup',
  );
  RandomAccessFile? handle;
  var retainTemporary = false;
  try {
    try {
      await temporary.create(exclusive: true);
    } on FileSystemException catch (error, stackTrace) {
      // The guarded design needs a sibling staging file, so an unwritable
      // folder blocks every save; name the actionable cause, not the syscall.
      Error.throwWithStackTrace(
        TextDocumentException(
          'A temporary file could not be created beside the document. '
          'Check that its folder is writable. '
          '${error.osError?.message ?? error.message}',
        ),
        stackTrace,
      );
    }
    setFilePermissions(temporary.path, 0x180); // 0600, before any plaintext.
    handle = await temporary.open(mode: FileMode.writeOnly);
    await handle.writeFrom(bytes);
    await handle.flush();
    await handle.close();
    handle = null;
    final savedSha256 = await textDocumentSha256(temporary);
    await observeTemporary?.call(temporary);

    if (expectedSha256 == null) {
      try {
        renameFileWithoutReplacing(temporary.path, file.path);
      } on FileSystemException catch (error) {
        retainTemporary = error is HardLinkCleanupException;
        throw TextDocumentException(
          'The destination already exists or could not be created safely. '
          '${error.message}',
        );
      }
      return savedSha256;
    }

    await _requireRegularFile(file);
    try {
      renameFileWithoutReplacing(file.path, backup.path);
    } on FileSystemException catch (error, stackTrace) {
      // A vanished destination or parent means a mid-save conflict;
      // anything else (permissions, quota) keeps its real OS error
      // instead of being misreported as concurrent modification.
      Error.throwWithStackTrace(
        isVanishedPathError(error)
            ? TextDocumentException(
                'The local copy changed while it was being saved. '
                '${error.osError?.message ?? error.message}',
              )
            : TextDocumentException(
                'The original file could not be moved aside for '
                'replacement. ${error.osError?.message ?? error.message}',
              ),
        stackTrace,
      );
    }
    try {
      await observeBackup?.call(backup);
      await _requireRegularFile(backup);
      if (await textDocumentSha256(backup) != expectedSha256) {
        throw const TextDocumentException(
          'The local copy changed in another editor. Reopen it before '
          'saving to avoid losing those changes.',
        );
      }
      final stat = await backup.stat();
      setFilePermissions(temporary.path, stat.mode & 0x1ff);
      renameFileWithoutReplacing(temporary.path, file.path);
    } catch (error) {
      if (error is HardLinkCleanupException) retainTemporary = true;
      // A no-replace rollback preserves another writer's newly created file.
      // Keep the backup for manual or host-managed recovery in that case.
      try {
        renameFileWithoutReplacing(backup.path, file.path);
      } on FileSystemException {
        throw TextDocumentException(
          'The local copy changed while it was being saved. '
          'The previous copy is preserved at ${backup.path}.',
        );
      }
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // The new file is committed. A recovery sibling is preferable to a
      // false save failure, which would leave the caller's baseline stale.
    }
    return savedSha256;
  } finally {
    await handle?.close();
    if (!retainTemporary && await temporary.exists()) await temporary.delete();
  }
}

Future<void> _requireRegularFile(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw const TextDocumentException(
      'The local copy is a symbolic link, not a regular file.',
    );
  }
  if (type != FileSystemEntityType.file) {
    throw const TextDocumentException(
      'The local copy is missing or no longer a regular file.',
    );
  }
}

void _validateMaximumBytes(int maximumBytes) {
  if (maximumBytes < 0) throw ArgumentError.value(maximumBytes, 'maximumBytes');
}

String _tooLargeMessage(int maximumBytes) =>
    'The built-in editor supports text files up to '
    '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB.';

const _utf8Bom = [0xef, 0xbb, 0xbf];

/// ENOENT on POSIX; ERROR_FILE_NOT_FOUND on Windows. Coincidentally 2 on
/// both — the destination file itself vanished mid-save, not a permission
/// or quota failure.
const int _errorNoSuchFile = 2;

/// Windows ERROR_PATH_NOT_FOUND: a parent directory in the path vanished.
/// POSIX reports the same situation as ENOENT ([_errorNoSuchFile]).
const int _errorPathNotFound = 3;

/// Whether [error] means a path vanished mid-operation — the destination
/// file itself ([_errorNoSuchFile]) or, on Windows, a parent directory
/// ([_errorPathNotFound]). Everything else (permissions, quota) is a real
/// failure, not a concurrent-modification signal.
@visibleForTesting
bool isVanishedPathError(FileSystemException error, {bool? isWindows}) {
  final code = error.osError?.errorCode;
  return code == _errorNoSuchFile ||
      ((isWindows ?? Platform.isWindows) && code == _errorPathNotFound);
}

bool _utf8BomAt(List<int> bytes, int offset) =>
    bytes.length >= offset + _utf8Bom.length &&
    bytes[offset] == _utf8Bom[0] &&
    bytes[offset + 1] == _utf8Bom[1] &&
    bytes[offset + 2] == _utf8Bom[2];

String _foldToLf(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _normalizeLineEndings(String text, LineEnding lineEnding) {
  final folded = _foldToLf(text);
  return lineEnding == LineEnding.crlf
      ? folded.replaceAll('\n', '\r\n')
      : folded;
}
