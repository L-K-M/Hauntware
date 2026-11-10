// CRED-05's export file service for Klabautermann: the platform save and
// open/mobile panels behind file_picker 13 and a path-only desktop
// save panel. The shared writer is the only writer on desktop, keeping
// an earlier export intact until the owner-only replacement commits.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' show getSaveLocation;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
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
  PlatformRecoveryFiles({
    FilePickerPlatform? platform,
    TargetPlatform? targetPlatform,
    this._desktopDestination = _chooseDesktopDestination,
    this._writeExport = _writeOwnerOnlyExport,
  }) : _platform = platform ?? FilePickerPlatform.instance,
       _targetPlatform = targetPlatform ?? defaultTargetPlatform;

  final FilePickerPlatform _platform;
  final TargetPlatform _targetPlatform;
  final Future<String?> Function(String) _desktopDestination;
  final Future<void> Function(File, Uint8List) _writeExport;

  bool get _isDesktop => switch (_targetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  @override
  Future<String?> save(Uint8List bytes, String fileName) async {
    try {
      if (_isDesktop) {
        // file_picker 13 writes before returning, so it cannot choose a
        // destination for an atomic save without first truncating it.
        final path = await _desktopDestination(fileName);
        if (path == null) return null;
        await _writeExport(File(path), bytes);
        return path;
      }
      final saved = await _platform.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/json',
      );
      if (saved == null) return null;
      return saved.isScheme('file') ? saved.toFilePath() : saved.toString();
    } on Object {
      throw const RecoveryFileException(RecoveryFileFailure.saveFailed);
    }
  }

  @override
  Future<Uint8List?> open() async {
    final PlatformFile? picked;
    try {
      if (_targetPlatform == TargetPlatform.macOS) {
        await _platform.skipEntitlementsChecks();
      }
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

Future<String?> _chooseDesktopDestination(String fileName) async {
  final location = await getSaveLocation(suggestedName: fileName);
  return location?.path;
}

Future<void> _writeOwnerOnlyExport(File destination, Uint8List bytes) =>
    const AtomicFileWriter().write(
      destination,
      utf8.decode(bytes),
      privacy: AtomicFilePrivacy.ownerOnly,
    );

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
