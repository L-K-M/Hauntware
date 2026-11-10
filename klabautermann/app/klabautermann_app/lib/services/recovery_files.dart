// CRED-05's export file service for Klabautermann: the platform save and
// open panels behind file_picker 13, with a read bounded by the shared
// export size before anything is loaded, and a desktop save rewritten
// through seance_core's AtomicFileWriter so the encrypted export is
// owner-only like the vault itself.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Why a recovery export file could not be read or written. The kind is
/// fixed; no path, exception text or file content crosses.
enum RecoveryFileFailure { tooLarge, unreadable, saveFailed }

/// A recovery export file operation failed. [failure] is the only
/// diagnostic it carries.
final class RecoveryFileException implements Exception {
  const RecoveryFileException(this.failure);

  final RecoveryFileFailure failure;

  @override
  String toString() => 'RecoveryFileException: ${failure.name}';
}

/// Where a recovery export is written and read from. The file panels and
/// the bytes stay in the app's isolate, so the settings window never
/// handles an export.
abstract interface class RecoveryFiles {
  /// Saves [bytes] as [fileName] where the user chooses. The saved
  /// location, or null when the user cancelled.
  Future<String?> save(Uint8List bytes, String fileName);

  /// Asks the user for an export file. Its bytes, or null when the user
  /// cancelled. Throws [RecoveryFileException] for a file larger than
  /// any export or one that cannot be read.
  Future<Uint8List?> open();
}

/// The file name an export is offered under:
/// `klabautermann-secrets-2026-11-10.json`.
String recoveryExportFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'klabautermann-secrets-${now.year}-${two(now.month)}-'
      '${two(now.day)}.json';
}

/// [RecoveryFiles] through the platform's save and open panels.
final class PlatformRecoveryFiles implements RecoveryFiles {
  PlatformRecoveryFiles({FilePickerPlatform? platform})
    : _platform = platform ?? FilePickerPlatform.instance;

  final FilePickerPlatform _platform;

  /// Desktop platforms rewrite the chosen file through the shared
  /// owner-only writer; Android and iOS keep the plugin's own write,
  /// which lands in their per-app or document-provider storage.
  static bool get _rewritesDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  Future<String?> save(Uint8List bytes, String fileName) async {
    if (Platform.isMacOS) await _platform.skipEntitlementsChecks();
    final Uri? saved;
    try {
      saved = await _platform.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/json',
      );
    } on Object {
      throw const RecoveryFileException(RecoveryFileFailure.saveFailed);
    }
    if (saved == null) return null;
    if (saved.isScheme('file') && _rewritesDesktop) {
      try {
        await const AtomicFileWriter().write(
          File(saved.toFilePath()),
          utf8.decode(bytes),
          privacy: AtomicFilePrivacy.ownerOnly,
        );
      } on Object {
        throw const RecoveryFileException(RecoveryFileFailure.saveFailed);
      }
    }
    return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
  }

  @override
  Future<Uint8List?> open() async {
    final PlatformFile? picked;
    try {
      picked = await _platform.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } on Object {
      throw const RecoveryFileException(RecoveryFileFailure.unreadable);
    }
    if (picked == null) return null;
    return readBoundedExport(picked);
  }
}

/// Reads [file] as an export, refusing more than
/// [SecretsExport.maxBytes] before the whole file is loaded. The
/// picker's own length is only a hint; the stream is bounded too, so a
/// stale or missing size cannot load a huge file.
Future<Uint8List> readBoundedExport(PlatformFile file) async {
  int? reported;
  try {
    reported = file.lengthSync();
  } on Object {
    reported = null;
  }
  if (reported != null && reported > SecretsExport.maxBytes) {
    throw const RecoveryFileException(RecoveryFileFailure.tooLarge);
  }

  final contents = BytesBuilder(copy: false);
  try {
    await for (final chunk in file.readAsByteStream()) {
      if (chunk.length > SecretsExport.maxBytes - contents.length) {
        throw const RecoveryFileException(RecoveryFileFailure.tooLarge);
      }
      contents.add(chunk);
    }
  } on RecoveryFileException {
    rethrow;
  } on Object {
    throw const RecoveryFileException(RecoveryFileFailure.unreadable);
  }
  return contents.takeBytes();
}
