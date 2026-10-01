import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';

import 'native_file_operations.dart';
import 'text_metrics.dart';

const int textDocumentMaximumBytes = 4 * 1024 * 1024;
const int defaultTextDocumentMaximumBytes = textDocumentMaximumBytes;

/// The dominant on-disk line ending. Ties and single-line files use LF.
enum LineEnding { lf, crlf }

enum Utf8Bom {
  absent,
  present;

  int get byteLength => this == present ? _utf8Bom.length : 0;
}

/// File-format choices, including for a buffer without a save destination yet.
final class TextDocumentMetadata {
  const TextDocumentMetadata({
    this.lineEnding = LineEnding.lf,
    this.utf8Bom = Utf8Bom.absent,
  });

  final LineEnding lineEnding;
  final Utf8Bom utf8Bom;

  @override
  bool operator ==(Object other) =>
      other is TextDocumentMetadata &&
      other.lineEnding == lineEnding &&
      other.utf8Bom == utf8Bom;

  @override
  int get hashCode => Object.hash(lineEnding, utf8Bom);
}

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

  TextDocumentMetadata get metadata => TextDocumentMetadata(
    lineEnding: lineEnding,
    utf8Bom: hasUtf8Bom ? Utf8Bom.present : Utf8Bom.absent,
  );

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
    try {
      file = File(await file.resolveSymbolicLinks());
    } on FileSystemException catch (error, stackTrace) {
      // dart:io names the call, the path and the errno; say what happened,
      // keeping the OS error code when the cause is not simply a missing file.
      Error.throwWithStackTrace(
        TextDocumentException(
          isVanishedPathError(error)
              ? 'The file no longer exists.'
              : "The file's location could not be read. ${_osDetail(error)}",
        ),
        stackTrace,
      );
    }
  }
  await _requireRegularFile(file);
  return file;
}

/// Whether [file] is marked read-only: no write permission for anyone on
/// POSIX, or the read-only attribute on Windows, which Dart reports the same
/// way. A save replaces the document through a sibling and restores its
/// mode (on Windows, the attribute), so the file's own permission never
/// stops a save; hosts ask this to warn before replacing a file someone
/// deliberately protected. Ownership is not considered: a file only its
/// owner may write reads as unprotected.
Future<bool> isTextDocumentWriteProtected(File file) async {
  final stat = await file.stat();
  return stat.type == FileSystemEntityType.file &&
      stat.mode & _writePermissionBits == 0;
}

/// POSIX write permission for owner, group and others: 0222.
const _writePermissionBits = 0x92;

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
  // A growable List<int> stores each byte as a full integer; a byte buffer
  // is several times faster to fill, hash and decode.
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length > maximumBytes) {
      throw TextDocumentException(_tooLargeMessage(maximumBytes));
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
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
  if (_firstNulIndex(raw) >= 0) {
    throw const TextDocumentException(
      'This file appears to be binary, not editable text.',
    );
  }
  var crlfCount = 0;
  var lfCount = 0;
  for (var i = raw.indexOf('\n'); i >= 0; i = raw.indexOf('\n', i + 1)) {
    if (i > 0 && raw.codeUnitAt(i - 1) == 0x0d) {
      crlfCount++;
    } else {
      lfCount++;
    }
  }
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
  // Loading rejects NUL as binary; writing it would produce a file this
  // editor can never reopen. Reject before publication, while the original
  // destination is still untouched. Scan the input, not the normalized
  // text: normalization never adds or removes a NUL, and this keeps the
  // reported offset pointing into the text the caller actually edited.
  final nulIndex = _firstNulIndex(text);
  if (nulIndex >= 0) {
    throw TextDocumentException(
      'The edited text contains a NUL character at code unit $nulIndex. '
      'Loading treats that as binary content, so saving it would create a '
      'file the editor cannot reopen.',
    );
  }
  final normalized = normalization == TextNormalization.preserve
      ? text
      : _normalizeLineEndings(text, lineEnding);
  final encoded = utf8.encode(normalized);
  final bytes = hasUtf8Bom
      ? (Uint8List(_utf8Bom.length + encoded.length)
          ..setAll(0, _utf8Bom)
          ..setAll(_utf8Bom.length, encoded))
      : encoded;
  if (bytes.length > maximumBytes) {
    throw TextDocumentException(
      'The edited file exceeds the '
      '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB built-in editor '
      'limit.',
    );
  }
  final temporary = _recoverySibling(file, temporaryPrefix, 'edit');
  final backup = _recoverySibling(file, temporaryPrefix, 'backup');
  RandomAccessFile? handle;
  var retainTemporary = false;
  var windowsReadOnly = false;
  try {
    try {
      await temporary.create(exclusive: true);
    } on FileSystemException catch (error, stackTrace) {
      // The guarded design needs a sibling staging file, so an unwritable
      // folder blocks every save; name the actionable cause, not the syscall.
      // A folder deleted since the document opened is a different cause and
      // needs a different remedy than fixing permissions.
      Error.throwWithStackTrace(
        TextDocumentException(
          isVanishedPathError(error)
              ? 'The folder containing the document no longer exists. '
                    '${_osDetail(error)}'
              : 'A temporary file could not be created beside the document. '
                    'Check that its folder is writable. ${_osDetail(error)}',
        ),
        stackTrace,
      );
    }
    // Owner-only before any plaintext reaches the file.
    setFilePermissions(temporary.path, _ownerReadWriteMode);
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
    } on HardLinkCleanupException {
      // Both names are retained and the exception already identifies them.
      rethrow;
    } on FileSystemException catch (error, stackTrace) {
      // A vanished destination or parent means a mid-save conflict;
      // anything else (permissions, quota) keeps its real OS error
      // instead of being misreported as concurrent modification.
      Error.throwWithStackTrace(
        isVanishedPathError(error)
            ? TextDocumentException(
                'The local copy changed while it was being saved. '
                '${_osDetail(error)}',
              )
            : TextDocumentException(
                'The original file could not be moved aside for '
                'replacement. ${_osDetail(error)}',
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
      setFilePermissions(temporary.path, stat.mode & _posixPermissionMask);
      windowsReadOnly =
          Platform.isWindows && stat.mode & _writePermissionBits == 0;
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
    if (windowsReadOnly) _keepWindowsReadOnly(file, backup);
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

// Common desktop filesystems limit a component to 255 bytes. Counting UTF-8
// is also conservative for filesystems that count UTF-16 code units instead.
const _maximumRecoveryNameBytes = 255;

File _recoverySibling(File file, String prefix, String extension) {
  final suffix = '$prefix-${const Uuid().v4()}.$extension';
  final available = _maximumRecoveryNameBytes - utf8.encode(suffix).length;
  if (available < 0) {
    throw ArgumentError.value(prefix, 'temporaryPrefix', 'Prefix is too long.');
  }

  // Retain recognizable names and host recovery suffixes without splitting
  // Unicode characters when a valid destination nearly fills the limit.
  final originalName = file.uri.pathSegments.last;
  final stem = StringBuffer();
  var used = 0;
  for (final rune in originalName.runes) {
    final character = String.fromCharCode(rune);
    used += utf8.encode(character).length;
    if (used > available) break;
    stem.write(character);
  }
  // Keep the caller's directory spelling, including root and relative paths.
  final parent = file.path.substring(0, file.path.length - originalName.length);
  return File('$parent$stem$suffix');
}

/// Windows has no mode bits to restore, so a read-only original's attribute
/// goes back on the new file, and comes off the backup, which could not be
/// deleted otherwise. The new file is already committed: a failure here
/// leaves the attribute off or the backup in place rather than reporting a
/// failed save.
void _keepWindowsReadOnly(File file, File backup) {
  try {
    setWindowsReadOnly(file.path, readOnly: true);
  } on FileSystemException {
    // The saved text stands; only the attribute is lost.
  }
  try {
    setWindowsReadOnly(backup.path, readOnly: false);
  } on FileSystemException {
    // The backup delete below then fails and keeps the recovery sibling.
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

/// Native operations name the call, not the cause; keep the OS error code so
/// a sharing violation or EPERM stays diagnosable.
String _osDetail(FileSystemException error) {
  final os = error.osError;
  if (os == null) return error.message;
  return '${os.message} (OS error ${os.errorCode}).';
}

/// chmod 0600: temporary plaintext is owner-only until it inherits the
/// destination's mode below.
const int _ownerReadWriteMode = 0x180;

/// chmod 0777 mask: only the portable permission bits survive a save.
const int _posixPermissionMask = 0x1ff;

bool _utf8BomAt(List<int> bytes, int offset) =>
    bytes.length >= offset + _utf8Bom.length &&
    bytes[offset] == _utf8Bom[0] &&
    bytes[offset + 1] == _utf8Bom[1] &&
    bytes[offset + 2] == _utf8Bom[2];

/// The load- and write-side binary rule, shared so a save can never emit a
/// file the loader would then reject. Broadening the binary heuristic must
/// update this one place.
int _firstNulIndex(String text) => text.indexOf('\u0000');

String _foldToLf(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// The saved size, including line-ending conversion and the optional BOM.
/// Tool preflight uses the same encoding policy as guarded file writes.
int textDocumentByteCount(
  String text,
  TextDocumentMetadata metadata, {
  TextNormalization normalization = TextNormalization.normalize,
}) =>
    utf8EncodedLength(
      normalization == TextNormalization.preserve
          ? text
          : _normalizeLineEndings(text, metadata.lineEnding),
    ) +
    metadata.utf8Bom.byteLength;

String _normalizeLineEndings(String text, LineEnding lineEnding) {
  final folded = _foldToLf(text);
  return lineEnding == LineEnding.crlf
      ? folded.replaceAll('\n', '\r\n')
      : folded;
}
