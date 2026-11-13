/// CRED-05's recovery-code operations over the engine's vault (03 §4.5,
/// docs/design/cred-05-recovery.md): the standing code, the encrypted
/// export it opens, and the merge a restore performs. The store-level
/// crypto is seance_core's [VaultRecovery]; this binds it to the engine's
/// one [EngineVault], the keystore responder and the vault's exclusive
/// queue, so recovery is serialized with sync and re-key and a locked
/// keystore refuses without minting a key.
library;

import 'dart:typed_data';

import 'package:seance_core/catalog.dart'
    show
        RecoveryDamagedException,
        RecoveryNotSetUpException,
        RestoreConflictPolicy,
        SecretsRestoreSummary,
        VaultRecovery;
import 'package:seance_core/seance_core.dart'
    show
        SecretVault,
        SecretsExport,
        SecretsExportException,
        SecretsExportFailure;

import '../engine/protocol.dart' show VaultRecoveryFailure, VaultRestorePolicy;
import 'engine_vault.dart';
import 'sync_credentials.dart' show SyncKeystore;

/// A recovery operation could not be done. [failure] is a fixed protocol
/// kind; no diagnostic text, code, key material or passphrase is carried.
final class VaultRecoveryException implements Exception {
  const VaultRecoveryException(this.failure);

  final VaultRecoveryFailure failure;

  @override
  String toString() => 'VaultRecoveryException: ${failure.name}';
}

/// The CRED-05 operations over the engine's vault, with the master key
/// resolved through the app's keystore each time.
final class EngineRecovery {
  EngineRecovery(this._vault, this._keystore)
    : _recovery = VaultRecovery(_vault.store);

  final EngineVault _vault;
  final SyncKeystore _keystore;
  final VaultRecovery _recovery;

  /// Whether this device has a recovery code an export can use. With the
  /// keystore locked, whether the entry exists, which is all anyone can
  /// tell.
  Future<bool> configured() => _vault.exclusive(() async {
    _requireExclusive();
    final key = await _keystore.readMasterKey();
    return _recovery.configured(key);
  });

  /// A new recovery code, formatted, to be shown once. Nothing is stored
  /// until [saveCode]: a code the user never confirmed writing down must
  /// not replace one they did.
  String newCode() => _recovery.newCode();

  /// Keeps what an export needs of [code] (never the code itself),
  /// replacing an earlier one; exports made with that one still open
  /// with it. The vault key comes from the keystore and no key is minted.
  Future<void> saveCode(String code) => _vault.exclusive(() async {
    _requireExclusive();
    final key = await _requireKey();
    try {
      await _recovery.saveCode(code, vaultKey: key);
    } on FormatException {
      throw const VaultRecoveryException(VaultRecoveryFailure.invalidCode);
    } on Object {
      throw const VaultRecoveryException(VaultRecoveryFailure.failed);
    }
  });

  /// The vault, encrypted, as an export the recovery code opens anywhere.
  ///
  /// Throws [VaultRecoveryException] with [VaultRecoveryFailure.notSetUp]
  /// without a stored code, [VaultRecoveryFailure.damaged] when the entry
  /// does not open under this device's key, or the export's own failure.
  Future<Uint8List> exportSecrets() => _vault.exclusive(() async {
    _requireExclusive();
    final key = await _requireKey();
    try {
      return await _recovery.exportSecrets(vaultKey: key);
    } on RecoveryNotSetUpException {
      throw const VaultRecoveryException(VaultRecoveryFailure.notSetUp);
    } on RecoveryDamagedException {
      throw const VaultRecoveryException(VaultRecoveryFailure.damaged);
    } on SecretsExportException catch (error) {
      throw VaultRecoveryException(_exportFailure(error.failure));
    } on Object {
      throw const VaultRecoveryException(VaultRecoveryFailure.failed);
    }
  });

  /// Opens [export] with [code] and merges its credentials into this
  /// device's vault, re-sealed under this device's key, in one write.
  ///
  /// The bytes are bounded by [SecretsExport.maxBytes] before anything is
  /// decoded, and nothing is written unless the export opens: a wrong code
  /// or an altered file throws with the vault as it was.
  Future<SecretsRestoreSummary> restoreSecrets(
    Uint8List export,
    String code, {
    required VaultRestorePolicy policy,
  }) async {
    if (export.length > SecretsExport.maxBytes) {
      throw const VaultRecoveryException(VaultRecoveryFailure.tooLarge);
    }
    return _vault.exclusive(() async {
      _requireExclusive();
      final key = await _requireKey();
      final conflictPolicy = switch (policy) {
        VaultRestorePolicy.keepExisting => RestoreConflictPolicy.keepExisting,
        VaultRestorePolicy.replaceExisting =>
          RestoreConflictPolicy.replaceExisting,
      };
      try {
        return await _recovery.restoreSecrets(
          SecretVault(_vault.store, key),
          export,
          code,
          policy: conflictPolicy,
        );
      } on SecretsExportException catch (error) {
        throw VaultRecoveryException(_exportFailure(error.failure));
      } on FormatException {
        throw const VaultRecoveryException(VaultRecoveryFailure.invalidCode);
      } on Object {
        throw const VaultRecoveryException(VaultRecoveryFailure.failed);
      }
    });
  }

  void _requireExclusive() {
    if (!_vault.exclusiveAccess) {
      throw const VaultRecoveryException(VaultRecoveryFailure.directoryShared);
    }
  }

  Future<List<int>> _requireKey() async {
    final key = await _keystore.readMasterKey();
    if (key == null) {
      throw const VaultRecoveryException(
        VaultRecoveryFailure.keystoreUnavailable,
      );
    }
    return key;
  }
}

VaultRecoveryFailure _exportFailure(SecretsExportFailure failure) =>
    switch (failure) {
      SecretsExportFailure.malformed => VaultRecoveryFailure.malformed,
      SecretsExportFailure.unsupportedVersion =>
        VaultRecoveryFailure.unsupportedVersion,
      SecretsExportFailure.tooLarge => VaultRecoveryFailure.tooLarge,
      SecretsExportFailure.invalidCode => VaultRecoveryFailure.invalidCode,
      SecretsExportFailure.wrongCode => VaultRecoveryFailure.wrongCode,
      SecretsExportFailure.tampered => VaultRecoveryFailure.tampered,
    };
