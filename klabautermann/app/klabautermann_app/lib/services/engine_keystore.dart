import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ghost_keystore/ghost_keystore.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The [MasterKeyManager] over Klabautermann's keystore entries (03 §4.5,
/// 04 §12.3): the vault master key `klabautermann.vault.masterKey.v1` and
/// API keys under `klabautermann.apikey.`, such as the sync token. On
/// macOS it uses the legacy login keychain, as the siblings do. [storage]
/// defaults to the package's; tests pass a fake.
MasterKeyManager klabautermannMasterKeyManager([
  FlutterSecureStorage? storage,
]) => MasterKeyManager(
  masterKeyEntry: klabautermannMasterKeyEntry,
  apiKeyPrefix: klabautermannApiKeyPrefix,
  storage: storage,
);

/// Answers the engine's keystore requests (03 §10.1, D62). The keystore
/// plugin's channels answer only this isolate, so the engine's sync asks
/// here with a [KeystoreRequest] and waits for the [AnswerKeystore].
///
/// The master key is only ever read through
/// `probeKeystore(hasExistingVault: true)`, which never mints: a key
/// minted for a read would open nothing the vault or the account holds.
final class EngineKeystoreResponder {
  EngineKeystoreResponder(this._engine, this._keys) {
    _events = _engine.events.listen((event) {
      if (event is KeystoreRequest) unawaited(_answer(event));
    });
  }

  final EngineClient _engine;
  final MasterKeyManager _keys;
  late final StreamSubscription<EngineEvent> _events;

  Future<void> _answer(KeystoreRequest request) async {
    KeystoreResult result;
    try {
      result = await _run(request.operation);
    } on Object catch (error) {
      result = KeystoreRefused('$error');
    }
    try {
      _engine.send(AnswerKeystore(request.requestId, result));
    } on StateError {
      // The engine stopped while the keystore answered; nobody waits.
    }
  }

  Future<KeystoreResult> _run(KeystoreOperation operation) async {
    switch (operation) {
      case KeystorePutApiKey(:final name, :final value):
        await _keys.putApiKey(name, value);
        return const KeystoreDone();
      case KeystoreGetApiKey(:final name):
        return KeystoreApiKey(await _keys.getApiKey(name));
      case KeystoreDeleteApiKey(:final name):
        await _keys.deleteApiKey(name);
        return const KeystoreDone();
      case KeystoreReadMasterKey():
        try {
          final key = await _keys.probeKeystore(hasExistingVault: true);
          return KeystoreMasterKey(
            key == null ? null : Uint8List.fromList(key),
          );
        } on MasterKeyUnavailableException {
          return const KeystoreMasterKey(null);
        }
      case KeystoreWriteMasterKey(:final key):
        await _keys.setKeystoreKey(key);
        return const KeystoreDone();
    }
  }

  Future<void> dispose() => _events.cancel();
}
