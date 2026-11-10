// CRED-05's recovery-code operations over Poltergeist's credential vault
// (docs/design/cred-05-recovery.md): a standing code, the encrypted export it
// opens, and the merge a restore performs. The store-level crypto lives in
// seance_core's VaultRecovery; this file binds it to Poltergeist's vault and
// its app-lock-guarded key resolve, and owns the file panels and copy.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'atomic_file.dart';
import 'file_export_service.dart';
import 'picked_file_bytes.dart';
import 'secure_master_key.dart';

/// Recovery status could not be read. No underlying diagnostic crosses
/// the settings link or reaches the optional setup offer.
final class RecoveryStatusException implements Exception {
  const RecoveryStatusException();

  @override
  String toString() => 'Could not read recovery status.';
}

/// The picked file could not be read at all.
class SecretsExportUnreadableException implements Exception {
  const SecretsExportUnreadableException();

  @override
  String toString() => 'That file could not be read.';
}

/// What the Settings screen says when an export will not open.
String secretsExportFailureMessage(
  SecretsExportFailure failure,
  AppLocalizations l10n,
) => switch (failure) {
  SecretsExportFailure.malformed => l10n.secretsExportMalformed,
  SecretsExportFailure.unsupportedVersion =>
    l10n.secretsExportUnsupportedVersion,
  SecretsExportFailure.tooLarge => l10n.secretsExportFileTooLarge,
  SecretsExportFailure.invalidCode => l10n.secretsExportInvalidCode,
  SecretsExportFailure.wrongCode => l10n.secretsExportWrongCode,
  SecretsExportFailure.tampered => l10n.secretsExportTampered,
};

/// The file name an export is offered under:
/// `poltergeist-secrets-2026-11-10.json`.
String secretsExportFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'poltergeist-secrets-${now.year}-${two(now.month)}-${two(now.day)}'
      '.json';
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
  PlatformSecretsExportFiles({FileExportPlatform? platform})
    : _platform = platform ?? MethodChannelFileExportPlatform();

  final FileExportPlatform _platform;

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
    final service = FileExportService(platform: _platform);
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

/// The CRED-05 operations over the app's vault, with the vault key resolved
/// through the app lock each time.
///
/// The key resolver is the app's own: it returns null while the vault is
/// locked (a keystore that cannot answer, an app lock still engaged), which
/// is why [configured] can report an existing entry without a key and every
/// other operation refuses through [VaultLockedException].
final class SecretsRecovery {
  SecretsRecovery(this._store, this._vault);

  final VaultStore _store;
  final Future<SecretVault?> Function() _vault;

  VaultRecovery get _recovery => VaultRecovery(_store);

  /// Whether this device has a recovery code an export can use. With the
  /// vault locked, whether the entry exists, which is all anyone can tell.
  Future<bool> configured() async {
    final vault = await _vault();
    return _recovery.configured(vault?.vaultKey);
  }

  /// A new recovery code, formatted, to be shown once. Nothing is stored
  /// until [saveCode]: a code the user never confirmed writing down must
  /// not replace one they did.
  String newCode() => _recovery.newCode();

  /// Keeps what an export needs of [code] (never the code itself),
  /// replacing an earlier one; exports made with that one still open
  /// with it.
  Future<void> saveCode(String code) async =>
      _recovery.saveCode(code, vaultKey: (await _requireVault()).vaultKey);

  /// The vault, encrypted, as an export the recovery code opens anywhere.
  ///
  /// Throws [RecoveryNotSetUpException] without a stored code, and
  /// [RecoveryDamagedException] when the entry does not open under this
  /// device's key.
  Future<Uint8List> exportSecrets() async =>
      _recovery.exportSecrets(vaultKey: (await _requireVault()).vaultKey);

  /// Opens [export] with [code] and merges its credentials into this
  /// device's vault, re-sealed under this device's key, in one write.
  ///
  /// Nothing is written unless the export opens: a wrong code or an
  /// altered file throws [SecretsExportException] with the vault as it
  /// was. A credential this device holds but cannot read counts as absent
  /// and is replaced; one it can read follows [policy].
  Future<SecretsRestoreSummary> restoreSecrets(
    Uint8List export,
    String code, {
    required RestoreConflictPolicy policy,
  }) async => _recovery.restoreSecrets(
    await _requireVault(),
    export,
    code,
    policy: policy,
  );

  Future<SecretVault> _requireVault() async {
    final vault = await _vault();
    if (vault == null) throw const VaultLockedException();
    return vault;
  }
}
