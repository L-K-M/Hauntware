import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../store/stores.dart';

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

/// The recovery-code operations over a vault's blob store (CRED-05): the
/// standing code, the encrypted export it opens, and the merge a restore
/// performs. `seance_protocol`'s [SecretsExport] owns the wire format; this
/// is the store-level half every app performs identically.
///
/// The vault key arrives per operation rather than at construction, because
/// whether the vault currently has a key is the app's own locked-vault
/// state, decided before the call (a keystore that cannot answer, an app
/// lock still engaged). The [SecretVault] a restore writes through is
/// likewise the app's: Séance passes its app-lock wrapper, so every read
/// keeps the lock's generation check.
final class VaultRecovery {
  const VaultRecovery(this._store);

  /// The blob store behind the app's credential vault. Reserved entries
  /// ([isReservedVaultId]) sit beside the credentials in it.
  final VaultStore _store;

  /// Whether this device has a recovery code an export can use.
  ///
  /// With [vaultKey] null — a vault that cannot be opened this session —
  /// whether the entry exists, which is all anyone can tell. With a key,
  /// whether it also opens: an entry sealed under a key the vault no
  /// longer holds (a lost keystore healed with a fresh key) belongs to a
  /// code that exports nothing any more.
  Future<bool> configured(List<int>? vaultKey) async {
    final sealed = await _store.getSecretBlob(recoveryWrapKeyId);
    if (sealed == null) return false;
    final key = vaultKey;
    if (key == null) return true;
    try {
      RecoveryWrapKey.fromJson(await VaultCrypto.openJson(key, sealed));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A new recovery code, formatted, to be shown once. Nothing is stored
  /// until [saveCode]: a code the user never confirmed writing down must
  /// not replace one they did.
  String newCode() => RecoveryKey.encode(secureRandomBytes(32));

  /// Keeps what an export needs of [code] (never the code itself),
  /// replacing an earlier one; exports made with that one still open
  /// with it.
  Future<void> saveCode(String code, {required List<int> vaultKey}) async {
    final wrap = await RecoveryWrapKey.derive(RecoveryKey.decode(code));
    await _store.putSecretBlob(
      recoveryWrapKeyId,
      await VaultCrypto.sealJson(vaultKey, wrap.toJson()),
    );
  }

  /// The vault, encrypted, as an export the recovery code opens anywhere.
  ///
  /// Throws [RecoveryNotSetUpException] without a stored code, and
  /// [RecoveryDamagedException] when the entry does not open under
  /// [vaultKey].
  Future<Uint8List> exportSecrets({required List<int> vaultKey}) async {
    final blobs = await _store.allSecretBlobs();
    final sealedWrap = blobs[recoveryWrapKeyId];
    if (sealedWrap == null) throw const RecoveryNotSetUpException();
    final RecoveryWrapKey wrap;
    try {
      wrap = RecoveryWrapKey.fromJson(
        await VaultCrypto.openJson(vaultKey, sealedWrap),
      );
    } catch (_) {
      throw const RecoveryDamagedException();
    }
    return SecretsExport.build(
      recovery: wrap,
      vaultKey: vaultKey,
      sealedEntries: blobs,
      createdAt: DateTime.now(),
    );
  }

  /// Opens [export] with [code] and merges its credentials into [vault],
  /// re-sealed under the vault's key, in one write.
  ///
  /// Nothing is written unless the export opens: a wrong code or an
  /// altered file throws [SecretsExportException] with the vault as it
  /// was. A credential the vault holds but cannot read counts as absent
  /// and is replaced; one it can read follows [policy].
  Future<SecretsRestoreSummary> restoreSecrets(
    SecretVault vault,
    Uint8List export,
    String code, {
    required RestoreConflictPolicy policy,
  }) async {
    final opened = await SecretsExport.open(export, code);
    final toWrite = <Secret>[];
    var added = 0;
    var replaced = 0;
    var kept = 0;
    for (final secret in opened.secrets.values) {
      if (await vault.readableSecret(secret.id) == null) {
        added++;
      } else if (policy == RestoreConflictPolicy.keepExisting) {
        kept++;
        continue;
      } else {
        replaced++;
      }
      toWrite.add(secret);
    }
    await vault.putSecrets(toWrite);
    return SecretsRestoreSummary(
      added: added,
      replaced: replaced,
      kept: kept,
      unreadable: opened.unreadable.length,
    );
  }
}
