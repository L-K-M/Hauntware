// Ported from Séance app/seance_app/test/keystore_resilience_test.dart @ 30963c0; see docs/PORTS.md.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/secure_master_key.dart';

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

  group('VaultLockedException', () {
    test('the locked message tells the user what to do', () {
      expect(
        const VaultLockedException().toString(),
        allOf(contains('keyring'), contains('gnome-keyring')),
      );
    });
  });
}
