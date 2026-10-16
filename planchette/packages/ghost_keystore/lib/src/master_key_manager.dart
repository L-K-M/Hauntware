// Moved from Poltergeist app/poltergeist_app/lib/services/secure_master_key.dart
// (ported from Séance app/seance_app/lib/services/secure_master_key.dart
// @ 30963c0), with Séance's hasExistingVault guard and
// MasterKeyUnavailableException; see poltergeist/docs/PORTS.md.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:seance_protocol/seance_protocol.dart';

/// Thrown when the OS keystore reports no master key but an encrypted vault is
/// already on disk.
///
/// The two situations are indistinguishable from the keystore alone — a first
/// run and a keystore that will not hand the key over both read as "nothing
/// there" — and the difference is total: minting a fresh key in the second
/// case makes every stored password and private key permanently
/// undecryptable. So the vault itself is the tiebreaker, and
/// [MasterKeyManager.probeKeystore] refuses rather than guess.
///
/// On macOS, missing items return no value; permission and interaction
/// errors reach the locked-vault retry path instead. The plugin can also
/// return no value for an unusable payload, so null alone does not prove
/// why the key is unavailable.
///
/// The text each app shows for this lives in that app; [toString] is the
/// product-neutral diagnostic.
class MasterKeyUnavailableException implements Exception {
  const MasterKeyUnavailableException();

  @override
  String toString() =>
      'The system keystore returned no vault master key, but an encrypted '
      'vault already exists. No new key was created, because it would make '
      'the saved passwords and private keys unreadable. Restore the matching '
      'key from a backup (a keychain backup on macOS) before reopening this '
      'vault.';
}

/// The OS keystore could not be read or written — on Linux that is usually a
/// locked login keyring (auto-login leaves it locked) or a desktop without a
/// Secret Service daemon (gnome-keyring/KWallet) at all. [message] is
/// user-facing.
class KeystoreException implements Exception {
  final String message;
  const KeystoreException(this.message);
  @override
  String toString() => message;
}

/// Whether the OS keystore is reachable right now. Tracked on every access so
/// the app can say "secrets unavailable" and offer a retry instead of dying
/// at bootstrap (the original `KeyringLocked` hard-fail).
enum KeystoreStatus { unknown, available, unavailable }

/// Obtains the 32-byte vault master key using the layered model from the
/// proposal:
///   1. a random key stored in the OS keystore (macOS/iOS Keychain, Windows
///      Credential Manager, Android Keystore, Linux Secret Service), or
///   2. a passphrase-derived key (Argon2id) as the fallback for headless Linux
///      or a lost keystore entry — which is also the sync E2E key.
///
/// Each product passes its own entry names, so the products never share an
/// entry: Séance `seance.vault.masterKey.v1` and `seance.apikey.`,
/// Poltergeist `poltergeist.vault.masterKey.v1` and `poltergeist.apikey.`,
/// Klabautermann `klabautermann.vault.masterKey.v1` and
/// `klabautermann.apikey.` (04 section 12.3). The names are persisted
/// identities: changing one strands the key stored under it.
class MasterKeyManager {
  final FlutterSecureStorage _storage;
  final String _masterKeyEntry;
  final String _apiKeyPrefix;

  /// Last observed keystore health. The bootstrap toast keys off this.
  KeystoreStatus keystoreStatus = KeystoreStatus.unknown;

  /// One-line description of the most recent keystore failure
  /// (e.g. `KeyringLocked`) for display in the retry toast.
  String? lastKeystoreError;

  /// [masterKeyEntry] is the keystore entry holding the vault master key;
  /// API keys are stored under [apiKeyPrefix] followed by their name, with
  /// no separator added.
  MasterKeyManager({
    required String masterKeyEntry,
    required String apiKeyPrefix,
    FlutterSecureStorage? storage,
  }) : assert(masterKeyEntry != '' && apiKeyPrefix != ''),
       // An API-key name must never address the master key: putApiKey would
       // overwrite it and strand the vault.
       assert(!masterKeyEntry.startsWith(apiKeyPrefix)),
       _masterKeyEntry = masterKeyEntry,
       _apiKeyPrefix = apiKeyPrefix,
       _storage =
           storage ??
           const FlutterSecureStorage(
             // macOS: use the legacy login keychain, not the iOS-style
             // data-protection keychain. The latter requires a
             // keychain-access-groups entitlement — a *restricted*
             // entitlement that macOS only honors for team-signed builds, so
             // an ad-hoc "sign to run locally" app either throws -34018 at
             // the first read (entitlement absent) or refuses to launch at
             // all (entitlement present but unvalidated).
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  void _markAvailable() {
    keystoreStatus = KeystoreStatus.available;
    lastKeystoreError = null;
  }

  void _markUnavailable(Object e) {
    keystoreStatus = KeystoreStatus.unavailable;
    lastKeystoreError = _describe(e);
  }

  /// A compact description of a keystore failure. flutter_secure_storage on
  /// Linux reports libsecret errors as PlatformException(code: message:), so
  /// for the common case ("KeyringLocked"/"KeyringLocked") the code alone is
  /// the whole story.
  static String _describe(Object e) {
    if (e is PlatformException) {
      final msg = e.message;
      return msg != null && msg != e.code ? '${e.code} — $msg' : e.code;
    }
    return e.toString();
  }

  /// Load the device master key from the OS keystore, creating one on first
  /// run. Returns null when the keystore is unavailable right now —
  /// [keystoreStatus]/[lastKeystoreError] say why. Deliberately does NOT
  /// fabricate an ephemeral key: anything encrypted with a key that dies with
  /// the process would be silently orphaned on the next launch, which is a
  /// far worse failure than "secrets are temporarily unavailable".
  ///
  /// [hasExistingVault] is what makes "first run" distinguishable from "the
  /// keystore said no": when an encrypted vault is already on disk, a keystore
  /// that *answers* — reads fine, holds nothing — is one that will not hand
  /// the key over, and minting a fresh one makes every stored password and
  /// private key permanently undecryptable. The probe then throws
  /// [MasterKeyUnavailableException] rather than guess. A read that throws
  /// instead is a keystore that cannot answer at all — the locked-vault null
  /// above, not a refusal: nothing is minted either way.
  Future<List<int>?> probeKeystore({bool hasExistingVault = false}) async {
    try {
      final existing = await _storage.read(key: _masterKeyEntry);
      if (existing != null) {
        _markAvailable();
        return base64.decode(existing);
      }
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
    if (hasExistingVault) {
      // The keystore answered: reachable, holding nothing.
      _markAvailable();
      throw const MasterKeyUnavailableException();
    }
    try {
      final key = secureRandomBytes(32);
      await _storage.write(key: _masterKeyEntry, value: base64.encode(key));
      _markAvailable();
      return key;
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }

  /// Replace the stored master key (used when sync enrolment switches the
  /// vault to the passphrase-derived key that is shared across devices).
  Future<void> setKeystoreKey(List<int> key) =>
      _write(_masterKeyEntry, base64.encode(key), what: 'the vault master key');

  /// Store an API key (for example a sync bearer token) in the OS keystore
  /// under [name]. Never a plain file. Throws [KeystoreException] when the
  /// keystore is unavailable — a caller saving a live session must be able
  /// to say the save failed rather than drop it silently.
  Future<void> putApiKey(String name, String value) =>
      _write('$_apiKeyPrefix$name', value, what: 'the $name key');

  /// Reads never crash the app on a locked/unavailable keystore; they behave
  /// as "not set" (and update [keystoreStatus] for the UI's retry affordance).
  Future<String?> getApiKey(String name) async {
    try {
      final v = await _storage.read(key: '$_apiKeyPrefix$name');
      _markAvailable();
      return v;
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }

  /// Forget an API key (sign-out). Tolerant like the reads: sign-out must
  /// still complete while the keystore is down — the orphaned entry is
  /// harmless (nothing reads the token without an enrolled account) and
  /// [keystoreStatus] records the failure for the retry affordance.
  Future<void> deleteApiKey(String name) async {
    try {
      await _storage.delete(key: '$_apiKeyPrefix$name');
      _markAvailable();
    } catch (e) {
      _markUnavailable(e);
    }
  }

  Future<void> _write(String key, String value, {required String what}) async {
    try {
      await _storage.write(key: key, value: value);
      _markAvailable();
    } catch (e) {
      _markUnavailable(e);
      throw KeystoreException(
        'Could not save $what to the OS keyring (${_describe(e)}). Unlock '
        'the login keyring or install gnome-keyring, then try again.',
      );
    }
  }
}
