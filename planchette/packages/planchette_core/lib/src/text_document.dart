import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';

import 'native_file_operations.dart';
import 'text_encoding.dart';

export 'text_encoding.dart' show TextEncoding;

const int textDocumentMaximumBytes = 4 * 1024 * 1024;
const int defaultTextDocumentMaximumBytes = textDocumentMaximumBytes;

/// The dominant on-disk line ending: whichever of LF, CRLF and lone CR
/// occurs most often. A tie prefers LF, then CRLF, then CR, so a file
/// without breaks is LF and CR wins only a strict majority. Normalized
/// saves write every break, whatever it was on disk, as this ending.
enum LineEnding {
  lf('\n', 'LF'),
  crlf('\r\n', 'CRLF'),

  /// Classic Mac OS: a lone carriage return ends each line.
  cr('\r', 'CR');

  const LineEnding(this.separator, this.label);

  /// The characters one line break is written as.
  final String separator;

  /// The conventional abbreviation status bars show. Not localized: the
  /// names are the same in every language.
  final String label;
}

enum Utf8Bom {
  absent,
  present;

  int get byteLength => this == present ? utf8BomLength : 0;
}

/// File-format choices, including for a buffer without a save destination yet.
/// [utf8Bom] applies to UTF-8 only; UTF-16 always writes its own mark.
final class TextDocumentMetadata {
  const TextDocumentMetadata({
    this.lineEnding = LineEnding.lf,
    this.utf8Bom = Utf8Bom.absent,
    this.encoding = TextEncoding.utf8,
  }) : assert(
         utf8Bom == Utf8Bom.absent || encoding == TextEncoding.utf8,
         'Only UTF-8 takes an optional byte order mark.',
       );

  final LineEnding lineEnding;
  final Utf8Bom utf8Bom;
  final TextEncoding encoding;

  /// These choices with only the named ones changed. Prefer it to a fresh
  /// constructor for a partial change: the constructor's defaults would
  /// quietly reset the fields it was not given, such as the encoding.
  TextDocumentMetadata copyWith({
    LineEnding? lineEnding,
    Utf8Bom? utf8Bom,
    TextEncoding? encoding,
  }) => TextDocumentMetadata(
    lineEnding: lineEnding ?? this.lineEnding,
    utf8Bom: utf8Bom ?? this.utf8Bom,
    encoding: encoding ?? this.encoding,
  );

  /// The encoding as status bars name it, with "BOM" for a marked UTF-8 file.
  String get encodingLabel =>
      utf8Bom == Utf8Bom.present ? '${encoding.label} BOM' : encoding.label;

  @override
  bool operator ==(Object other) =>
      other is TextDocumentMetadata &&
      other.lineEnding == lineEnding &&
      other.utf8Bom == utf8Bom &&
      other.encoding == encoding;

  @override
  int get hashCode => Object.hash(lineEnding, utf8Bom, encoding);
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
    this.encoding = TextEncoding.utf8,
  });

  final File file;
  final String text;
  final bool hasUtf8Bom;
  final LineEnding lineEnding;
  final String sha256;

  /// What the file was read in, and what a save writes unless the user
  /// chooses another encoding.
  final TextEncoding encoding;

  TextDocumentMetadata get metadata => TextDocumentMetadata(
    lineEnding: lineEnding,
    utf8Bom: hasUtf8Bom ? Utf8Bom.present : Utf8Bom.absent,
    encoding: encoding,
  );

  TextDocument copyWith({
    File? file,
    String? text,
    bool? hasUtf8Bom,
    LineEnding? lineEnding,
    String? sha256,
    TextEncoding? encoding,
  }) => TextDocument(
    file: file ?? this.file,
    text: text ?? this.text,
    hasUtf8Bom: hasUtf8Bom ?? this.hasUtf8Bom,
    lineEnding: lineEnding ?? this.lineEnding,
    sha256: sha256 ?? this.sha256,
    encoding: encoding ?? this.encoding,
  );
}

/// Stable, bare messages allow hosts to retain their existing error adapters.
final class TextDocumentException implements Exception {
  const TextDocumentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The file's bytes are not text in the encoding it was read in: not UTF-8
/// or marked UTF-16 when detected, or not the encoding the user chose.
/// Hosts can offer to reopen it in another encoding (see
/// [TextEncoding.reopenChoices]); the message names the offending byte.
final class UnsupportedTextEncodingException extends TextDocumentException {
  const UnsupportedTextEncodingException(super.message);
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

/// Reads a bounded file as [encoding], or, when it is null, as UTF-16 if it
/// starts with a UTF-16 byte order mark and as strict UTF-8 otherwise. One
/// leading mark is metadata and every additional U+FEFF is content.
/// [maximumBytes] limits the file's size in bytes, whatever its encoding.
/// Digest checks reject changing snapshots.
Future<TextDocument> loadTextDocument(
  File file, {
  int maximumBytes = textDocumentMaximumBytes,
  TextNormalization normalization = TextNormalization.normalize,
  SymlinkPolicy symlinkPolicy = SymlinkPolicy.reject,
  Future<String> Function(File file)? sha256Of,
  TextEncoding? encoding,
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
      'The file changed while it was being opened.',
    );
  }

  final decoded = decodeTextBytes(bytes, encoding);
  final raw = decoded.text;
  if (_firstNulIndex(raw) >= 0) {
    throw const TextDocumentException(
      'This file appears to be binary, not editable text.',
    );
  }
  return TextDocument(
    file: file,
    text: normalization == TextNormalization.preserve ? raw : _foldToLf(raw),
    hasUtf8Bom: decoded.utf8Bom,
    lineEnding: _dominantLineEnding(raw),
    sha256: after,
    encoding: decoded.encoding,
  );
}

/// Counts each break once (a CRLF is not also a CR and an LF) and applies
/// [LineEnding]'s vote.
LineEnding _dominantLineEnding(String text) {
  var crlf = 0;
  var lf = 0;
  var cr = 0;
  for (var i = 0; i < text.length; i++) {
    switch (text.codeUnitAt(i)) {
      case _lineFeed:
        lf++;
      case _carriageReturn
          when i + 1 < text.length && text.codeUnitAt(i + 1) == _lineFeed:
        crlf++;
        i++;
      case _carriageReturn:
        cr++;
    }
  }
  if (lf >= crlf && lf >= cr) return LineEnding.lf;
  return crlf >= cr ? LineEnding.crlf : LineEnding.cr;
}

const _lineFeed = 0x0a;
const _carriageReturn = 0x0d;

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
  TextEncoding encoding = TextEncoding.utf8,
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
  encoding: encoding,
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
  TextEncoding encoding = TextEncoding.utf8,
  TextNormalization normalization = TextNormalization.normalize,
  String temporaryPrefix = '.planchette',
  int maximumBytes = textDocumentMaximumBytes,
  Future<void> Function(File temporary)? observeTemporary,
}) => _writeTextDocument(
  file,
  text,
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding,
  encoding: encoding,
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
  required TextEncoding encoding,
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
  if (hasUtf8Bom && encoding != TextEncoding.utf8) {
    throw ArgumentError.value(
      hasUtf8Bom,
      'hasUtf8Bom',
      'Only UTF-8 takes an optional byte order mark.',
    );
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
  // An unrepresentable character throws here, before anything is written.
  final bytes = encodeText(normalized, encoding, utf8Bom: hasUtf8Bom);
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
                'The file changed while it was being saved. '
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
          'The file changed in another editor. Reopen it before '
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
          'The file changed while it was being saved. '
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
      'The file is a symbolic link, not a regular file.',
    );
  }
  if (type != FileSystemEntityType.file) {
    throw const TextDocumentException(
      'The file is missing or no longer a regular file.',
    );
  }
}

void _validateMaximumBytes(int maximumBytes) {
  if (maximumBytes < 0) throw ArgumentError.value(maximumBytes, 'maximumBytes');
}

String _tooLargeMessage(int maximumBytes) =>
    'The built-in editor supports text files up to '
    '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB.';

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

/// The load- and write-side binary rule, shared so a save can never emit a
/// file the loader would then reject. Broadening the binary heuristic must
/// update this one place.
int _firstNulIndex(String text) => text.indexOf('\u0000');

String _foldToLf(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// The encoded size of [text] in the metadata's encoding, including EOL
/// conversion and any byte order mark. Save cleanup is separate; guarded
/// writes recheck the cleaned buffer's size.
int textDocumentByteCount(
  String text,
  TextDocumentMetadata metadata, {
  TextNormalization normalization = TextNormalization.normalize,
}) => encodedTextLength(
  normalization == TextNormalization.preserve
      ? text
      : _normalizeLineEndings(text, metadata.lineEnding),
  metadata.encoding,
  utf8Bom: metadata.utf8Bom == Utf8Bom.present,
);

String _normalizeLineEndings(String text, LineEnding lineEnding) {
  final folded = _foldToLf(text);
  return lineEnding == LineEnding.lf
      ? folded
      : folded.replaceAll('\n', lineEnding.separator);
}
