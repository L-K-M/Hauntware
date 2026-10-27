import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/src/catalog/sync_credentials.dart';
import 'package:seance_core/catalog.dart'
    show FileVaultStore, VaultRekeyJournal, VaultRekeyOutcome;
import 'package:seance_core/seance_core.dart'
    show Secret, SecretKind, SecretVault, secureRandomBytes;
import 'package:test/test.dart';

/// An OS keystore as `MasterKeyManager` addresses it: the master key under
/// its entry, API keys under the prefix and their name, no separator.
/// Every call is logged with the entry it touches.
final class _FakeKeystore implements SyncKeystore {
  final entries = <String, String>{};
  final log = <String>[];
  bool failWrites = false;

  /// What the keystore keeps of a master-key write that fails.
  bool keepFailedWrite = false;

  /// Whether reads fail, as a locked keyring's do.
  bool unreadable = false;

  @override
  Future<void> putApiKey(String name, String value) async {
    log.add('put $klabautermannApiKeyPrefix$name');
    if (failWrites) throw StateError('keyring locked');
    entries['$klabautermannApiKeyPrefix$name'] = value;
  }

  @override
  Future<String?> getApiKey(String name) async {
    log.add('get $klabautermannApiKeyPrefix$name');
    return unreadable ? null : entries['$klabautermannApiKeyPrefix$name'];
  }

  @override
  Future<void> deleteApiKey(String name) async {
    log.add('delete $klabautermannApiKeyPrefix$name');
    entries.remove('$klabautermannApiKeyPrefix$name');
  }

  @override
  Future<List<int>?> readMasterKey() async {
    log.add('read $klabautermannMasterKeyEntry');
    final value = entries[klabautermannMasterKeyEntry];
    return unreadable || value == null ? null : base64.decode(value);
  }

  @override
  Future<void> writeMasterKey(List<int> key) async {
    log.add('write $klabautermannMasterKeyEntry');
    if (failWrites) {
      if (keepFailedWrite) {
        entries[klabautermannMasterKeyEntry] = base64.encode(key);
      }
      throw StateError('keyring locked');
    }
    entries[klabautermannMasterKeyEntry] = base64.encode(key);
  }

  List<int>? get masterKey => switch (entries[klabautermannMasterKeyEntry]) {
    final String value => base64.decode(value),
    null => null,
  };
}

/// Logs the journal calls, with each key by its first byte.
final class _LoggingJournal implements VaultRekeyJournal {
  final log = <String>[];

  /// Whether settling fails once a re-key is staged.
  bool failSettlesAfterStage = false;
  bool _staged = false;

  @override
  Future<void> stageRekey({
    required List<int> currentKey,
    required List<int> newKey,
  }) async {
    log.add('stage ${currentKey.first}->${newKey.first}');
    _staged = true;
  }

  @override
  Future<VaultRekeyOutcome> settleRekey(List<int> key) async {
    log.add('settle ${key.first}');
    if (failSettlesAfterStage && _staged) {
      throw const FileSystemException('vault unreadable');
    }
    return VaultRekeyOutcome.none;
  }
}

List<int> _key(int first) => [first, ...List.filled(31, 0)];

void main() {
  test('entry names match 03 section 4.5 and 04 section 12.3', () {
    expect(klabautermannMasterKeyEntry, 'klabautermann.vault.masterKey.v1');
    expect(klabautermannApiKeyPrefix, 'klabautermann.apikey.');
    expect(syncTokenKeyName, 'sync.token');
    // MasterKeyManager asserts the master key is outside the API-key
    // namespace, where putApiKey could overwrite it.
    expect(
      klabautermannMasterKeyEntry.startsWith(klabautermannApiKeyPrefix),
      isFalse,
    );
  });

  group('the sync token', () {
    test('lives under klabautermann.apikey.sync.token', () async {
      final keystore = _FakeKeystore();
      final store = KeystoreSyncCredentialStore(keystore: keystore);

      await store.writeToken('bearer-1');
      expect(keystore.entries, {'klabautermann.apikey.sync.token': 'bearer-1'});
      expect(await store.readToken(), 'bearer-1');
      await store.deleteToken();
      expect(keystore.entries, isEmpty);
      expect(await store.readToken(), isNull);
      expect(keystore.log, [
        'put klabautermann.apikey.sync.token',
        'get klabautermann.apikey.sync.token',
        'delete klabautermann.apikey.sync.token',
        'get klabautermann.apikey.sync.token',
      ]);
    });

    test('a write the keystore refuses throws', () async {
      final keystore = _FakeKeystore()..failWrites = true;
      final store = KeystoreSyncCredentialStore(keystore: keystore);
      await expectLater(store.writeToken('t'), throwsStateError);
    });

    test('an unreadable keystore reads as no token', () async {
      final keystore = _FakeKeystore()
        ..entries['klabautermann.apikey.sync.token'] = 't'
        ..unreadable = true;
      final store = KeystoreSyncCredentialStore(keystore: keystore);
      expect(await store.readToken(), isNull);
    });
  });

  group('the vault key, against a logging journal', () {
    late _FakeKeystore keystore;
    late _LoggingJournal journal;
    late KeystoreSyncCredentialStore store;

    setUp(() {
      keystore = _FakeKeystore()
        ..entries[klabautermannMasterKeyEntry] = base64.encode(_key(1));
      journal = _LoggingJournal();
      store = KeystoreSyncCredentialStore(
        keystore: keystore,
        vaultJournal: journal,
      );
    });

    test(
      'settles leftovers, stages both generations, then swaps the key',
      () async {
        await store.writeVaultKey(_key(2));
        expect(journal.log, ['settle 1', 'stage 1->2', 'settle 2']);
        expect(keystore.masterKey, _key(2));
        expect(keystore.log, [
          'read klabautermann.vault.masterKey.v1',
          'write klabautermann.vault.masterKey.v1',
        ]);
      },
    );

    test('no installed key stages and writes nothing', () async {
      keystore.entries.clear();
      await expectLater(
        store.writeVaultKey(_key(2)),
        throwsA(isA<SyncVaultKeyUnavailableException>()),
      );
      expect(journal.log, isEmpty);
      expect(keystore.masterKey, isNull, reason: 'nothing minted');
    });

    test(
      'a refused write that the keystore kept settles to the new key',
      () async {
        keystore
          ..failWrites = true
          ..keepFailedWrite = true;
        await expectLater(store.writeVaultKey(_key(2)), throwsStateError);
        expect(journal.log, ['settle 1', 'stage 1->2', 'settle 2']);
      },
    );

    test(
      'a refused write that the keystore dropped settles to the old key',
      () async {
        keystore.failWrites = true;
        await expectLater(store.writeVaultKey(_key(2)), throwsStateError);
        expect(journal.log, ['settle 1', 'stage 1->2', 'settle 1']);
        expect(keystore.masterKey, _key(1));
      },
    );

    test('a keystore that cannot answer after a refused write leaves the '
        'journal staged and mints nothing', () async {
      keystore.failWrites = true;
      final failing = KeystoreSyncCredentialStore(
        keystore: _GoesDarkAfterWrite(keystore),
        vaultJournal: journal,
      );
      await expectLater(failing.writeVaultKey(_key(2)), throwsStateError);
      expect(journal.log, ['settle 1', 'stage 1->2']);
      expect(keystore.masterKey, _key(1));
    });

    test('a recovery that fails after a refused write still reports the '
        'write', () async {
      keystore.failWrites = true;
      journal.failSettlesAfterStage = true;
      await expectLater(store.writeVaultKey(_key(2)), throwsStateError);
      expect(journal.log, ['settle 1', 'stage 1->2', 'settle 1']);
    });

    test('without a journal the key is swapped directly', () async {
      final plain = KeystoreSyncCredentialStore(keystore: keystore);
      await plain.writeVaultKey(_key(3));
      expect(keystore.masterKey, _key(3));
    });
  });

  group('the vault key, against the shared FileVaultStore', () {
    late Directory directory;
    late File vaultFile;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('klab-sync-creds-');
      vaultFile = File('${directory.path}/vault.json');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    Future<(List<int>, List<int>, _FakeKeystore)> seeded() async {
      final oldKey = secureRandomBytes(32);
      final newKey = secureRandomBytes(32);
      await SecretVault(FileVaultStore(vaultFile), oldKey).putSecrets([
        Secret(id: 'a', kind: SecretKind.password, value: 'value-a'),
      ]);
      final keystore = _FakeKeystore()
        ..entries[klabautermannMasterKeyEntry] = base64.encode(oldKey);
      return (oldKey, newKey, keystore);
    }

    Future<String?> readA(List<int> key) async =>
        (await SecretVault(FileVaultStore(vaultFile), key).getSecret('a'))
            ?.value;

    test(
      'an enrollment re-key leaves the vault readable with the new key',
      () async {
        final (_, newKey, keystore) = await seeded();
        final store = KeystoreSyncCredentialStore(
          keystore: keystore,
          vaultJournal: FileVaultStore(vaultFile),
        );
        await store.writeVaultKey(newKey);
        expect(keystore.masterKey, newKey);
        expect(await readA(newKey), 'value-a');
        expect(await File('${vaultFile.path}.rekey').exists(), isFalse);
      },
    );

    test('a refused keystore write leaves the vault readable with the key '
        'the keystore still holds', () async {
      final (oldKey, newKey, keystore) = await seeded();
      keystore.failWrites = true;
      final store = KeystoreSyncCredentialStore(
        keystore: keystore,
        vaultJournal: FileVaultStore(vaultFile),
      );
      await expectLater(store.writeVaultKey(newKey), throwsStateError);
      expect(keystore.masterKey, oldKey);
      expect(await readA(oldKey), 'value-a');
      expect(await File('${vaultFile.path}.rekey').exists(), isFalse);
    });
  });
}

/// A keystore whose reads go dark once a master-key write has failed, as
/// a keyring that locks mid-enrollment.
final class _GoesDarkAfterWrite implements SyncKeystore {
  _GoesDarkAfterWrite(this._inner);

  final _FakeKeystore _inner;

  @override
  Future<void> putApiKey(String name, String value) =>
      _inner.putApiKey(name, value);

  @override
  Future<String?> getApiKey(String name) => _inner.getApiKey(name);

  @override
  Future<void> deleteApiKey(String name) => _inner.deleteApiKey(name);

  @override
  Future<List<int>?> readMasterKey() => _inner.readMasterKey();

  @override
  Future<void> writeMasterKey(List<int> key) async {
    try {
      await _inner.writeMasterKey(key);
    } on Object {
      _inner.unreadable = true;
      rethrow;
    }
  }
}
