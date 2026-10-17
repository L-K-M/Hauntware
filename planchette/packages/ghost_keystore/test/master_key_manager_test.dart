import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart';

/// A keystore whose state the test chooses, logging every access as
/// `<op> <entry>` so tests can assert the literal entry names.
class _FakeKeystore extends FlutterSecureStorage {
  _FakeKeystore({Map<String, String>? data, this.readThrows, this.writeThrows})
    : data = {...?data};

  final Map<String, String> data;

  /// Set to model a keystore that cannot answer at all (a locked keyring).
  final Object? readThrows;

  /// Set to model a keystore that refuses to store.
  final Object? writeThrows;

  final List<String> log = [];

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
    final thrown = readThrows;
    if (thrown != null) throw thrown;
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
    final thrown = writeThrows;
    if (thrown != null) throw thrown;
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
    data.remove(key);
  }
}

/// A keystore in the exact state the Ubuntu bug report hit: every access
/// throws the libsecret "KeyringLocked" PlatformException.
class _LockedKeystore extends FlutterSecureStorage {
  _LockedKeystore();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');

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
  }) =>
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
}

/// In-memory keystore that can be "locked" on demand, to test the recovery
/// transition (keyring gets unlocked while the app runs).
class _ToggleableKeystore extends FlutterSecureStorage {
  _ToggleableKeystore();
  final Map<String, String> _map = {};
  bool locked = false;

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
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    return _map[key];
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
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

const _masterKeyEntry = 'poltergeist.vault.masterKey.v1';

MasterKeyManager _manager(FlutterSecureStorage storage) => MasterKeyManager(
  masterKeyEntry: _masterKeyEntry,
  apiKeyPrefix: 'poltergeist.apikey.',
  storage: storage,
);

final _stored = List<int>.generate(32, (i) => i);

/// The keystore states the mint/refuse matrix runs against.
enum _State {
  /// Reachable, holding no master key: a first run, or a keystore that will
  /// not hand the key over.
  empty,

  /// Holding a valid master key.
  holding,

  /// Cannot answer: every read throws.
  locked,

  /// Holding a master-key entry that is not base64.
  corrupt,

  /// Reachable and empty, but every write throws.
  refusesWrites,
}

_FakeKeystore _keystore(_State state) => switch (state) {
  _State.empty => _FakeKeystore(),
  _State.holding => _FakeKeystore(
    data: {_masterKeyEntry: base64.encode(_stored)},
  ),
  _State.locked => _FakeKeystore(
    readThrows: PlatformException(code: 'KeyringLocked'),
  ),
  _State.corrupt => _FakeKeystore(data: {_masterKeyEntry: 'not base64!'}),
  _State.refusesWrites => _FakeKeystore(
    writeThrows: PlatformException(code: 'KeyringLocked'),
  ),
};

/// What a probe must do: return the minted or stored key, return null,
/// or refuse with [MasterKeyUnavailableException].
enum _Outcome { mints, returnsStored, returnsNull, refuses }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the mint/refuse matrix around hasExistingVault', () {
    const up = KeystoreStatus.available;
    const down = KeystoreStatus.unavailable;
    // (state, hasExistingVault, outcome, status after, writes attempted)
    const rows = [
      (_State.empty, false, _Outcome.mints, up, 1),
      (_State.empty, true, _Outcome.refuses, up, 0),
      (_State.holding, false, _Outcome.returnsStored, up, 0),
      (_State.holding, true, _Outcome.returnsStored, up, 0),
      (_State.locked, false, _Outcome.returnsNull, down, 0),
      (_State.locked, true, _Outcome.returnsNull, down, 0),
      (_State.corrupt, false, _Outcome.returnsNull, down, 0),
      (_State.corrupt, true, _Outcome.returnsNull, down, 0),
      (_State.refusesWrites, false, _Outcome.returnsNull, down, 1),
      (_State.refusesWrites, true, _Outcome.refuses, up, 0),
    ];

    for (final (state, hasExistingVault, outcome, status, writes) in rows) {
      test('${state.name}, hasExistingVault: $hasExistingVault: '
          '${outcome.name}', () async {
        final keystore = _keystore(state);
        final before = Map.of(keystore.data);
        final keys = _manager(keystore);

        final probe = keys.probeKeystore(hasExistingVault: hasExistingVault);
        switch (outcome) {
          case _Outcome.mints:
            final key = await probe;
            expect(key, hasLength(32));
            expect(keystore.data, {_masterKeyEntry: base64.encode(key!)});
          case _Outcome.returnsStored:
            expect(await probe, _stored);
          case _Outcome.returnsNull:
            expect(await probe, isNull);
          case _Outcome.refuses:
            await expectLater(
              probe,
              throwsA(isA<MasterKeyUnavailableException>()),
            );
        }

        expect(keys.keystoreStatus, status);
        expect(keys.lastKeystoreError, status == up ? isNull : isNotNull);
        expect(
          keystore.log.where((entry) => entry.startsWith('write ')),
          hasLength(writes),
          reason: 'writes attempted',
        );
        if (outcome != _Outcome.mints) {
          expect(
            keystore.data,
            before,
            reason: 'only a genuine first run may store a key',
          );
        }
      });
    }

    test('a refusal names the backup to restore', () {
      final message = const MasterKeyUnavailableException().toString();
      expect(message, contains('vault'));
      expect(message, contains('keychain backup'));
    });
  });

  group('entry names', () {
    // The persisted identities of 04 section 12.3 and CL section 9. Each
    // product's entries must reach the keystore verbatim: a changed name
    // strands the key stored under the old one.
    const products = {
      'seance': ('seance.vault.masterKey.v1', 'seance.apikey.'),
      'poltergeist': ('poltergeist.vault.masterKey.v1', 'poltergeist.apikey.'),
      'klabautermann': (
        'klabautermann.vault.masterKey.v1',
        'klabautermann.apikey.',
      ),
    };
    const expected = {
      'seance': [
        'read seance.vault.masterKey.v1',
        'write seance.vault.masterKey.v1',
        'write seance.vault.masterKey.v1',
        'write seance.apikey.sync.token',
        'read seance.apikey.sync.token',
        'delete seance.apikey.sync.token',
      ],
      'poltergeist': [
        'read poltergeist.vault.masterKey.v1',
        'write poltergeist.vault.masterKey.v1',
        'write poltergeist.vault.masterKey.v1',
        'write poltergeist.apikey.sync.token',
        'read poltergeist.apikey.sync.token',
        'delete poltergeist.apikey.sync.token',
        'write poltergeist.apikey.sync.token.retained.v1',
      ],
      'klabautermann': [
        'read klabautermann.vault.masterKey.v1',
        'write klabautermann.vault.masterKey.v1',
        'write klabautermann.vault.masterKey.v1',
        'write klabautermann.apikey.sync.token',
        'read klabautermann.apikey.sync.token',
        'delete klabautermann.apikey.sync.token',
      ],
    };

    for (final MapEntry(key: product, value: (entry, prefix))
        in products.entries) {
      test('$product reads and writes its own entries', () async {
        final keystore = _FakeKeystore();
        final keys = MasterKeyManager(
          masterKeyEntry: entry,
          apiKeyPrefix: prefix,
          storage: keystore,
        );

        await keys.probeKeystore();
        await keys.setKeystoreKey(_stored);
        await keys.putApiKey('sync.token', 'token');
        expect(await keys.getApiKey('sync.token'), 'token');
        await keys.deleteApiKey('sync.token');
        if (product == 'poltergeist') {
          await keys.putApiKey('sync.token.retained.v1', 'old');
        }

        expect(keystore.log, expected[product]);
      });
    }

    test('an API-key prefix that could address the master key is rejected', () {
      expect(
        () => MasterKeyManager(
          masterKeyEntry: 'x.apikey.vault',
          apiKeyPrefix: 'x.apikey.',
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('the default storage', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uses the legacy login keychain on macOS', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final keys = MasterKeyManager(
        masterKeyEntry: _masterKeyEntry,
        apiKeyPrefix: 'poltergeist.apikey.',
      );
      await keys.getApiKey('sync.token');

      expect(calls.single.method, 'read');
      expect(calls.single.arguments, {
        'key': 'poltergeist.apikey.sync.token',
        'options': {
          'accountName': 'flutter_secure_storage_service',
          'accessibility': 'unlocked',
          'synchronizable': 'false',
          'usesDataProtectionKeychain': 'false',
          'useSecureEnclave': 'false',
        },
      });
    });
  });

  group(
    'MasterKeyManager on a locked keystore (the Ubuntu KeyringLocked bug)',
    () {
      test(
        'probeKeystore returns null and marks the keystore unavailable',
        () async {
          final keys = _manager(_LockedKeystore());
          final key = await keys.probeKeystore();
          expect(key, isNull);
          expect(keys.keystoreStatus, KeystoreStatus.unavailable);
          expect(keys.lastKeystoreError, contains('KeyringLocked'));
        },
      );

      test('reads degrade to "not set" instead of throwing', () async {
        final keys = _manager(_LockedKeystore());
        expect(await keys.getApiKey('sync.token'), isNull);
        expect(keys.keystoreStatus, KeystoreStatus.unavailable);
      });

      test('writes throw a clear KeystoreException', () async {
        final keys = _manager(_LockedKeystore());
        await expectLater(
          () => keys.setKeystoreKey(List.filled(32, 7)),
          throwsA(
            isA<KeystoreException>().having(
              (e) => e.message,
              'message',
              contains('keyring'),
            ),
          ),
        );
        expect(keys.keystoreStatus, KeystoreStatus.unavailable);
      });

      test('a keystore that comes back is picked up on re-probe', () async {
        final storage = _ToggleableKeystore()..locked = true;
        final keys = _manager(storage);

        expect(await keys.probeKeystore(), isNull);
        expect(keys.keystoreStatus, KeystoreStatus.unavailable);

        storage.locked = false;
        final key = await keys.probeKeystore();
        expect(key, isNotNull);
        expect(key, hasLength(32));
        expect(keys.keystoreStatus, KeystoreStatus.available);
        expect(keys.lastKeystoreError, isNull);

        // The created key persists: a second probe returns the same one.
        expect(await keys.probeKeystore(), equals(key));
      });

      test(
        'probeKeystore never fabricates an ephemeral key while locked',
        () async {
          // Regression guard for the tempting wrong fix: if probeKeystore had
          // returned a fresh random key under a locked keystore, anything saved
          // this session would decrypt to garbage (or appear corrupt) forever
          // after — "unavailable" is the only honest answer.
          final keys = _manager(_LockedKeystore());
          expect(await keys.probeKeystore(), isNull);
          expect(await keys.probeKeystore(), isNull);
        },
      );
    },
  );
}
