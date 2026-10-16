/// The engine's sync credentials (03 §4.5, D62): the catalog library's
/// `SyncCredentialStore` seam over a narrow OS-keystore port.
///
/// The keystore is `ghost_keystore`'s `MasterKeyManager` over
/// `flutter_secure_storage`, a Flutter plugin this pure-Dart package
/// cannot import, and whose platform channels answer only the app's root
/// isolate, while enrollment and rounds run in the engine isolate (D18).
/// So the engine holds a [SyncKeystore] the app answers: the app binds
/// `MasterKeyManager` with the entry names below, and the port's calls
/// reach it over the engine protocol (K49b).
library;

import 'package:seance_core/catalog.dart'
    show SyncCredentialStore, VaultRekeyJournal;

/// The keystore entry holding the vault master key (03 §4.5, 04 §12.3).
/// A persisted identity: changing it strands the key stored under it.
const String klabautermannMasterKeyEntry = 'klabautermann.vault.masterKey.v1';

/// The prefix of every Klabautermann API-key entry (04 §12.3); a name is
/// appended with no separator, as `MasterKeyManager` does.
const String klabautermannApiKeyPrefix = 'klabautermann.apikey.';

/// The API-key name of the sync bearer token, so its entry is
/// `klabautermann.apikey.sync.token` (03 §4.5).
const String syncTokenKeyName = 'sync.token';

/// The OS-keystore operations the sync credentials need, named after
/// `MasterKeyManager`'s, which the app's binding forwards to with
/// [klabautermannMasterKeyEntry] and [klabautermannApiKeyPrefix].
abstract interface class SyncKeystore {
  /// Stores [value] under the API-key [name]. Throws when the keystore
  /// cannot store it.
  Future<void> putApiKey(String name, String value);

  /// The value under the API-key [name], or null when there is none or
  /// the keystore cannot answer.
  Future<String?> getApiKey(String name);

  /// Forgets the API-key [name]. Completes while the keystore is down: an
  /// orphaned entry is harmless and sign-out must still finish.
  Future<void> deleteApiKey(String name);

  /// The vault master key, or null when the keystore holds none or cannot
  /// answer. Never mints one: the binding reads through
  /// `probeKeystore(hasExistingVault: true)`, since a key minted here
  /// would seal nothing and open nothing the vault holds.
  Future<List<int>?> readMasterKey();

  /// Replaces the vault master key. Throws when the keystore cannot store
  /// it; the keystore may still have kept it.
  Future<void> writeMasterKey(List<int> key);
}

/// [KeystoreSyncCredentialStore.writeVaultKey] found no vault master key
/// to re-seal the vault from, so it staged nothing and changed nothing.
final class SyncVaultKeyUnavailableException implements Exception {
  const SyncVaultKeyUnavailableException();

  @override
  String toString() =>
      'SyncVaultKeyUnavailableException: the OS keystore returned no vault '
      'master key, so the vault was not re-keyed';
}

/// The [SyncCredentialStore] over the OS keystore: the session token and
/// the vault key live only there, never in a file (03 §4.5).
final class KeystoreSyncCredentialStore implements SyncCredentialStore {
  /// [vaultJournal] is the vault file's re-key journal (`FileVaultStore`);
  /// null only where no vault file exists to re-seal (tests).
  KeystoreSyncCredentialStore({required this._keystore, this._vaultJournal});

  final SyncKeystore _keystore;
  final VaultRekeyJournal? _vaultJournal;

  /// Throws when the keystore cannot store the token: enrollment fails
  /// loudly rather than drop the session.
  @override
  Future<void> writeToken(String token) =>
      _keystore.putApiKey(syncTokenKeyName, token);

  /// Null when absent or the keystore cannot answer, which reads as not
  /// enrolled.
  @override
  Future<String?> readToken() => _keystore.getApiKey(syncTokenKeyName);

  /// Sign-out forgets the token locally; the server keeps it valid.
  @override
  Future<void> deleteToken() => _keystore.deleteApiKey(syncTokenKeyName);

  /// The enrollment re-key (03 §4.3 step 1): the passphrase-derived
  /// [vaultKey] replaces the vault master key.
  ///
  /// The vault file and the keystore change in two writes no operation
  /// spans, so the journal stages both sealed generations first. A crash
  /// or a keystore refusal between them then settles to whichever
  /// generation the installed key opens, rather than leaving credentials
  /// sealed under a key nothing holds. A journal an interrupted attempt
  /// left is settled first, since staging over it is refused. The key the
  /// keystore holds is read without minting, here and after a failed
  /// write: a minted key would open neither generation, and settling
  /// against it would set the journal aside with a key installed that
  /// opens nothing the vault holds. A keystore that cannot answer after a
  /// failed write leaves the journal staged for the next attempt or
  /// launch to settle.
  @override
  Future<void> writeVaultKey(List<int> vaultKey) async {
    final journal = _vaultJournal;
    if (journal == null) {
      await _keystore.writeMasterKey(vaultKey);
      return;
    }

    final current = await _keystore.readMasterKey();
    if (current == null) throw const SyncVaultKeyUnavailableException();
    await journal.settleRekey(current);
    await journal.stageRekey(currentKey: current, newKey: vaultKey);

    try {
      await _keystore.writeMasterKey(vaultKey);
    } on Object {
      final installed = await _keystore.readMasterKey();
      if (installed != null) await journal.settleRekey(installed);
      rethrow;
    }
    await journal.settleRekey(vaultKey);
  }
}
