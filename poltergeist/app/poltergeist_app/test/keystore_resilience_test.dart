// Ported from Séance app/seance_app/test/keystore_resilience_test.dart @ 30963c0; see docs/PORTS.md.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// In-memory keystore that can be "locked" on demand, to test the recovery
/// transition (keyring gets unlocked while the app runs).
class _ToggleableKeystore extends FlutterSecureStorage {
  _ToggleableKeystore();
  final Map<String, String> _map = {};
  bool locked = false;

  /// Every write that reached the keystore, accepted or not.
  int writes = 0;

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
    writes++;
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

void main() {
  // The locked-keystore group moved to
  // planchette/packages/ghost_keystore/test/master_key_manager_test.dart
  // with MasterKeyManager (F3c); this binding keeps its entry name here.
  group("Poltergeist's MasterKeyManager binding", () {
    test('the master key is stored under the Poltergeist entry name',
        () async {
      final storage = _ToggleableKeystore();
      final keys = poltergeistMasterKeyManager(storage);

      await keys.probeKeystore();
      expect(storage._map.keys, contains('poltergeist.vault.masterKey.v1'));
    });
  });

  group('probeVaultKey never mints over a vault that holds secrets', () {
    late Directory directory;
    late File vaultFile;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('poltergeist-key-');
      vaultFile = File('${directory.path}/vault.json');
    });

    tearDown(() => directory.delete(recursive: true));

    test('a keystore that lost its entry beside a sealed vault is refused',
        () async {
      // The vault was sealed under a key the keystore no longer holds: a
      // Windows password reset, a reset Secret Service collection, a
      // support directory restored onto a new machine.
      final oldKey = secureRandomBytes(32);
      await SecretVault(FileVaultStore(vaultFile), oldKey).putSecret(
        const Secret(id: 'a', kind: SecretKind.password, value: 'pw'),
      );
      final storage = _ToggleableKeystore();
      final keys = poltergeistMasterKeyManager(storage);

      await expectLater(
        probeVaultKey(keys, vaultFile),
        throwsA(isA<MasterKeyUnavailableException>()),
      );

      expect(storage.writes, 0, reason: 'no replacement key may be stored');
      expect(storage._map, isEmpty);
      // The saved secret still opens once the original key comes back.
      final reopened = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await reopened.getSecret('a'))!.value, 'pw');
    });

    test('an unparseable vault file counts as holding secrets', () async {
      await vaultFile.writeAsString('');
      final storage = _ToggleableKeystore();

      await expectLater(
        probeVaultKey(poltergeistMasterKeyManager(storage), vaultFile),
        throwsA(isA<MasterKeyUnavailableException>()),
      );
      expect(storage.writes, 0);
    });

    test('a first run, with no vault file, mints and stores a key', () async {
      final storage = _ToggleableKeystore();
      final keys = poltergeistMasterKeyManager(storage);

      expect(await probeVaultKey(keys, vaultFile), hasLength(32));
      expect(storage._map.keys, ['poltergeist.vault.masterKey.v1']);
    });

    test('an empty vault has nothing to strand, so a key is minted',
        () async {
      await vaultFile.writeAsString('{}');
      final keys = poltergeistMasterKeyManager(_ToggleableKeystore());

      expect(await probeVaultKey(keys, vaultFile), hasLength(32));
    });

    test('a stored key is returned beside a sealed vault', () async {
      await vaultFile.writeAsString('{"a": "sealed"}');
      final keys = poltergeistMasterKeyManager(_ToggleableKeystore());
      final stored = secureRandomBytes(32);
      await keys.setKeystoreKey(stored);

      expect(await probeVaultKey(keys, vaultFile), stored);
    });
  });

  group('VaultLockedException', () {
    test('the locked message tells the user what to do', () {
      expect(
        const VaultLockedException().toString(),
        allOf(contains('keyring'), contains('gnome-keyring')),
      );
    });
  });
}
