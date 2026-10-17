// Ported from Séance app/seance_app/lib/services/secure_master_key.dart @ 30963c0; see docs/PORTS.md.
// MasterKeyManager, KeystoreException and KeystoreStatus live in
// planchette/packages/ghost_keystore since F3c; this file binds them to
// Poltergeist's keystore entries.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ghost_keystore/ghost_keystore.dart';

export 'package:ghost_keystore/ghost_keystore.dart'
    show KeystoreException, KeystoreStatus, MasterKeyManager;

/// The keystore entry holding Poltergeist's vault master key (07 §3.3), so
/// the app never shares Séance's entry. A persisted identity: renaming it
/// strands the key stored under it.
const String _masterKeyEntry = 'poltergeist.vault.masterKey.v1';

/// The prefix of Poltergeist's API-key entries, for example
/// `poltergeist.apikey.sync.token` (04 §4.5).
const String _apiKeyPrefix = 'poltergeist.apikey.';

/// The [MasterKeyManager] over Poltergeist's entries. [storage] defaults to
/// the package's storage (the legacy login keychain on macOS); tests pass a
/// fake.
MasterKeyManager poltergeistMasterKeyManager([FlutterSecureStorage? storage]) =>
    MasterKeyManager(
      masterKeyEntry: _masterKeyEntry,
      apiKeyPrefix: _apiKeyPrefix,
      storage: storage,
    );

/// The vault has no key this session because the OS keystore is unavailable,
/// so secrets can neither be read nor stored until it comes back.
class VaultLockedException implements Exception {
  final String message;
  const VaultLockedException([
    this.message = 'Saved secrets are unavailable: the OS keyring is locked '
        'or missing. Unlock the login keyring (or install gnome-keyring), '
        'then retry.',
  ]);
  @override
  String toString() => message;
}
