import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/engine_keystore.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

/// A keystore in memory that logs each access as `<op> <entry>`, so the
/// entry names are asserted literally (03 §4.5, 04 §12.3).
class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  final List<String> log = [];
  bool locked = false;

  void _check() {
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('read $key');
    _check();
    return data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('write $key');
    _check();
    data[key] = value!;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('delete $key');
    _check();
    data.remove(key);
  }
}

// The app's half of the engine's keystore port (D62): each KeystoreRequest
// runs on ghost_keystore's MasterKeyManager under Klabautermann's entries
// and goes back as an AnswerKeystore.
void main() {
  late FakeEngineClient engine;
  late _FakeStorage storage;

  setUp(() {
    engine = FakeEngineClient();
    storage = _FakeStorage();
    final responder = EngineKeystoreResponder(
      engine,
      klabautermannMasterKeyManager(storage),
    );
    addTearDown(() async {
      await responder.dispose();
      await engine.close();
    });
  });

  /// Sends [operation] as the engine would and returns the app's answer.
  Future<KeystoreResult> ask(KeystoreOperation operation) async {
    final before = engine.sent.length;
    engine.emit(KeystoreRequest(7, operation));
    await pumpEventQueue();
    final answer = engine.sent.skip(before).single as AnswerKeystore;
    expect(answer.requestId, 7);
    return answer.result;
  }

  test('the sync token lives at klabautermann.apikey.sync.token', () async {
    expect(
      await ask(const KeystorePutApiKey('sync.token', 'token-1')),
      isA<KeystoreDone>(),
    );
    final read = await ask(const KeystoreGetApiKey('sync.token'));
    expect((read as KeystoreApiKey).value, 'token-1');
    expect(
      await ask(const KeystoreDeleteApiKey('sync.token')),
      isA<KeystoreDone>(),
    );

    expect(storage.log, [
      'write klabautermann.apikey.sync.token',
      'read klabautermann.apikey.sync.token',
      'delete klabautermann.apikey.sync.token',
    ]);
  });

  test('the master key lives at klabautermann.vault.masterKey.v1 and a read '
      'never mints one', () async {
    final none = await ask(const KeystoreReadMasterKey());
    expect((none as KeystoreMasterKey).key, isNull);
    expect(storage.log, ['read klabautermann.vault.masterKey.v1']);

    final key = Uint8List.fromList(List.generate(32, (i) => i));
    expect(await ask(KeystoreWriteMasterKey(key)), isA<KeystoreDone>());
    expect(
      storage.data['klabautermann.vault.masterKey.v1'],
      base64.encode(key),
    );
    final read = await ask(const KeystoreReadMasterKey());
    expect((read as KeystoreMasterKey).key, key);
  });

  test('a locked keystore refuses writes and reads as nothing', () async {
    storage.locked = true;

    expect(
      await ask(const KeystorePutApiKey('sync.token', 'token-1')),
      isA<KeystoreRefused>(),
    );
    expect(
      await ask(KeystoreWriteMasterKey(Uint8List(32))),
      isA<KeystoreRefused>(),
    );
    expect(
      ((await ask(const KeystoreGetApiKey('sync.token'))) as KeystoreApiKey)
          .value,
      isNull,
    );
    expect(
      ((await ask(const KeystoreReadMasterKey())) as KeystoreMasterKey).key,
      isNull,
    );
  });
}
