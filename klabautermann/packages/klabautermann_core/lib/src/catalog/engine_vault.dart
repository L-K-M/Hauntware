/// The engine's credential vault (03 §4.5, SYN-02, FL-03): `vault.json`
/// in the support directory, sealed under the keystore's master key,
/// which the app answers over the protocol (D62).
library;

import 'dart:io';
import 'dart:math';

import 'package:seance_core/catalog.dart' show FileVaultStore;
import 'package:seance_core/seance_core.dart' show Secret, SecretVault;

import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'sync_credentials.dart' show SyncKeystore;

/// The vault file's name in the support directory (03 §4.10).
const String vaultFileName = 'vault.json';

/// Bytes in a master key the engine mints: the 256-bit key `VaultCrypto`
/// seals with, the length Séance's and Poltergeist's keystores mint.
const int _masterKeyBytes = 32;

/// Why the vault could not be read or written.
enum VaultUnavailableReason {
  /// Another process may hold the support directory, so the engine writes
  /// none of its files (D63).
  directoryShared,

  /// The keystore holds no master key, or could not answer, while the
  /// vault or the sync account needs the one it held.
  keystoreUnavailable,
}

/// The vault could not be read or written; nothing was changed.
final class VaultUnavailableException implements Exception {
  const VaultUnavailableException(this.reason);

  final VaultUnavailableReason reason;

  @override
  String toString() => 'VaultUnavailableException: ${reason.name}';
}

/// `vault.json` and the master key that opens it. The one
/// [FileVaultStore] over the file for the engine's lifetime: sync re-keys
/// it through [store]'s journal and applies pulled `secret:` records into
/// it, the links read from it, and a second store over the same file
/// would race their writes.
///
/// A device with no vault file and no sync account has no master key
/// either: [save] mints one then. A device that enrolls later re-keys the
/// vault to the account key through the journal, as Séance does.
final class EngineVault {
  /// [enrolled] says whether a sync account is enrolled, whose key the
  /// keystore's master key then is.
  factory EngineVault(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    required SyncKeystore keystore,
    required bool Function() enrolled,
    Random? random,
  }) => EngineVault._(
    File('${supportDirectory.path}${Platform.pathSeparator}$vaultFileName'),
    access,
    keystore,
    enrolled,
    random ?? Random.secure(),
  );

  EngineVault._(
    this._file,
    this._access,
    this._keystore,
    this._enrolled,
    this._random,
  ) : store = FileVaultStore(_file);

  final SupportDirectoryAccess _access;
  final SyncKeystore _keystore;
  final bool Function() _enrolled;
  final Random _random;
  final File _file;

  /// The vault file's store, for sync's re-key journal and coordinator.
  final FileVaultStore store;

  /// Whether the vault file, or a re-key staged for it, exists.
  Future<bool> exists() async =>
      await _file.exists() || await File('${_file.path}.rekey').exists();

  /// The entry [secretRef] names, or null when the vault has none. Throws
  /// [VaultUnavailableException] when a vault exists that the keystore
  /// cannot open.
  Future<Secret?> read(String secretRef) async {
    // An unguarded engine never wrote a vault, and reading one another
    // process may be re-keying could see either key.
    if (_access != SupportDirectoryAccess.exclusive) return null;
    if (!await exists()) return null;

    final key = await _keystore.readMasterKey();
    if (key == null) {
      throw const VaultUnavailableException(
        VaultUnavailableReason.keystoreUnavailable,
      );
    }
    return SecretVault(store, key).getSecret(secretRef);
  }

  /// Saves [secret] as this device's own copy, stamped with the time of
  /// the edit. Throws [VaultUnavailableException] when the directory is
  /// shared or the keystore cannot give the key the vault needs.
  Future<void> save(Secret secret) async {
    if (_access != SupportDirectoryAccess.exclusive) {
      throw const VaultUnavailableException(
        VaultUnavailableReason.directoryShared,
      );
    }
    final key = await _masterKey();
    await SecretVault(
      store,
      key,
    ).putLocalSecret(secret, updatedAt: DateTime.now().millisecondsSinceEpoch);
  }

  /// The keystore's master key, minting one only when nothing is sealed
  /// under the old one: no vault file and no sync account. The keystore
  /// port cannot tell "none" from "could not answer", so a key it failed
  /// to return is replaced only when that loses nothing.
  Future<List<int>> _masterKey() async {
    final key = await _keystore.readMasterKey();
    if (key != null) return key;
    if (await exists() || _enrolled()) {
      throw const VaultUnavailableException(
        VaultUnavailableReason.keystoreUnavailable,
      );
    }

    final minted = List<int>.generate(
      _masterKeyBytes,
      (_) => _random.nextInt(256),
    );
    await _keystore.writeMasterKey(minted);
    return minted;
  }
}
