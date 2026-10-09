import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';
import 'file_export_service.dart';
import 'picked_file_bytes.dart';

/// What a restore does with a credential this device already holds.
enum RestoreConflictPolicy {
  /// Keep this device's copy (the default).
  keepExisting,

  /// Take the export's copy.
  replaceExisting,
}

/// What a restore did, for the screen to report.
@immutable
class SecretsRestoreSummary {
  const SecretsRestoreSummary({
    required this.added,
    required this.replaced,
    required this.kept,
    required this.unreadable,
  });

  /// Credentials this device did not have, or held but could not read.
  final int added;

  /// Credentials this device had, replaced by the export's copy.
  final int replaced;

  /// Credentials this device had and kept.
  final int kept;

  /// Entries the export carries that did not open as credentials.
  final int unreadable;

  factory SecretsRestoreSummary.fromJson(Map<String, dynamic> json) =>
      SecretsRestoreSummary(
        added: json['added'] as int,
        replaced: json['replaced'] as int,
        kept: json['kept'] as int,
        unreadable: json['unreadable'] as int,
      );

  Map<String, dynamic> toJson() => {
    'added': added,
    'replaced': replaced,
    'kept': kept,
    'unreadable': unreadable,
  };
}

/// Export was asked for on a device with no recovery code.
class RecoveryNotSetUpException implements Exception {
  const RecoveryNotSetUpException();

  @override
  String toString() =>
      'Set up a recovery code first: an export opens only with it.';
}

/// The recovery entry exists but this vault's key does not open it.
class RecoveryDamagedException implements Exception {
  const RecoveryDamagedException();

  @override
  String toString() =>
      'This device\'s recovery code can no longer be used. Replace it to '
      'export again.';
}

/// What the Settings screen says when this vault is too large to export.
const secretsExportTooLargeMessage =
    'This device has too many saved secrets to export in one file.';

/// The picked file could not be read at all.
class SecretsExportUnreadableException implements Exception {
  const SecretsExportUnreadableException();

  @override
  String toString() => 'That file could not be read.';
}

/// What the Settings screen says when an export will not open.
String secretsExportFailureMessage(SecretsExportFailure failure) =>
    switch (failure) {
      SecretsExportFailure.malformed =>
        'That file is not a Séance secrets export, or it is damaged.',
      SecretsExportFailure.unsupportedVersion =>
        'That export was made by a newer version of Séance. Update Séance '
            'and try again.',
      SecretsExportFailure.tooLarge =>
        'That file is too large to be a Séance secrets export.',
      SecretsExportFailure.invalidCode =>
        'That is not a recovery code. Check it for typos.',
      SecretsExportFailure.wrongCode =>
        'That recovery code does not open this export.',
      SecretsExportFailure.tampered =>
        'That export was changed after it was made, so nothing was restored.',
    };

/// The file name an export is offered under: `seance-secrets-2026-10-08.json`.
String secretsExportFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'seance-secrets-${now.year}-${two(now.month)}-${two(now.day)}.json';
}

/// Where an export is written and read from.
abstract interface class SecretsExportFiles {
  /// Saves [bytes] as [fileName] wherever the user chooses. The saved
  /// location, or null when the user cancelled.
  Future<String?> save(Uint8List bytes, String fileName);

  /// Asks the user for an export file. Its bytes, or null when the user
  /// cancelled. Throws [SecretsExportException] for a file larger than any
  /// export, before reading it.
  Future<Uint8List?> open();
}

/// [SecretsExportFiles] through the platform: Android's document provider
/// (SAF), the platform save and open panels elsewhere.
class PlatformSecretsExportFiles implements SecretsExportFiles {
  const PlatformSecretsExportFiles();

  static const _mimeType = 'application/json';

  @override
  Future<String?> save(Uint8List bytes, String fileName) async {
    if (Platform.isAndroid) return _saveThroughSaf(bytes, fileName);
    if (Platform.isIOS) {
      // The document picker writes the bytes itself.
      return FilePicker.saveFile(fileName: fileName, bytes: bytes);
    }
    final destination = await FilePicker.saveFile(fileName: fileName);
    if (destination == null) return null;
    // Encrypted, but still the whole vault: kept from other local accounts
    // like vault.json itself.
    await writeStringAtomically(
      File(destination),
      utf8.decode(bytes),
      privacy: AtomicFilePrivacy.ownerOnly,
    );
    return destination;
  }

  /// Stages the export in the app's own cache, owner-only, hands it to the
  /// document provider, and deletes the staged copy whatever happens.
  Future<String?> _saveThroughSaf(Uint8List bytes, String fileName) async {
    final service = FileExportService();
    if (!await service.hasExportDirectoryAccess() &&
        !await service.pickExportDirectory()) {
      return null;
    }
    final directory = await (await getTemporaryDirectory()).createTemp(
      'secrets-export-',
    );
    try {
      final staged = File('${directory.path}/$fileName');
      await writeStringAtomically(
        staged,
        utf8.decode(bytes),
        privacy: AtomicFilePrivacy.ownerOnly,
      );
      return await service.exportFile(
        StagedExportFile(file: staged, fileName: fileName, mimeType: _mimeType),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// Stream provider-only files instead of asking the picker to allocate their
  /// entire contents. Metadata can be missing or stale, so bound the read too.
  @override
  Future<Uint8List?> open() async {
    final result = await FilePicker.pickFiles(withReadStream: true);
    if (result == null || result.files.isEmpty) return null;
    try {
      return await readPickedFileBytes(
        result.files.single,
        maxBytes: SecretsExport.maxBytes,
      );
    } on PickedFileTooLargeException {
      throw const SecretsExportException(
        SecretsExportFailure.tooLarge,
        'The file exceeds the export size limit',
      );
    } on FileSystemException {
      throw const SecretsExportUnreadableException();
    }
  }
}
