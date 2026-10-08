import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';

import 'app_lock.dart';

/// Guard blobs too: recovery and sync sometimes open entries themselves.
class AppLockVaultStore implements VaultStore {
  AppLockVaultStore(this._store, this._lock);

  final VaultStore _store;
  final AppLock _lock;

  @override
  Future<Uint8List?> getSecretBlob(String id) =>
      _lock.read(() => _store.getSecretBlob(id));

  @override
  Future<Map<String, Uint8List>> allSecretBlobs() =>
      _lock.read(_store.allSecretBlobs);

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) =>
      _store.putSecretBlob(id, blob);

  @override
  Future<void> putSecretBlobs(Map<String, Uint8List> blobs) =>
      _store.putSecretBlobs(blobs);

  @override
  Future<void> deleteSecret(String id) => _store.deleteSecret(id);
}

/// Resolve the keystore lazily on locked launches, then check after opening.
/// The store read stays outside SecretVault's damaged-entry recovery catch.
class AppLockSecretVault extends SecretVault {
  AppLockSecretVault(super.store, super.vaultKey, this._lock, this._resolve);

  final AppLock _lock;
  final Future<SecretVault> Function() _resolve;

  @override
  Future<Secret?> getSecret(String id) =>
      _lock.read(() async => (await _resolve()).getSecret(id));

  @override
  Future<Secret?> readableSecret(String id) =>
      _lock.read(() async => (await _resolve()).readableSecret(id));

  @override
  Future<void> putSecret(Secret secret) async =>
      (await _resolve()).putSecret(secret);

  @override
  Future<void> putSecrets(Iterable<Secret> secrets) async =>
      (await _resolve()).putSecrets(secrets);
}
