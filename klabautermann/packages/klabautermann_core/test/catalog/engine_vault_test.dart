// The engine's vault (03 §4.5, SYN-02, FL-03): a round trip through
// `vault.json`, the master key it mints only when nothing is sealed under
// another, and the refusals of a shared directory or an absent key.
import 'dart:io';

import 'package:klabautermann_core/src/catalog/engine_vault.dart';
import 'package:klabautermann_core/src/settings/instance_lock.dart';
import 'package:seance_core/catalog.dart' show FileVaultStore;
import 'package:seance_core/seance_core.dart'
    show Secret, SecretKind, SecretVault;
import 'package:test/test.dart';

import '../support/fake_sync_server.dart';

const _secret = Secret(
  id: 'secret-a',
  kind: SecretKind.password,
  value: 'hunter2',
);

void main() {
  late Directory support;
  late MemoryKeystore keystore;
  var enrolled = false;

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-vault-');
    keystore = MemoryKeystore();
    enrolled = false;
  });

  tearDown(() => support.deleteSync(recursive: true));

  EngineVault open({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
  }) => EngineVault(
    support,
    access: access,
    keystore: keystore,
    enrolled: () => enrolled,
  );

  final oldKey = List<int>.filled(32, 1);
  final newKey = List<int>.filled(32, 2);

  /// `vault.json` sealed under [oldKey] with a re-key to [newKey] staged
  /// beside it and the keystore holding [newKey]: a process that died
  /// after the re-key's keystore write, before its settle.
  Future<File> crashAfterKeystoreWrite() async {
    final file = File('${support.path}${Platform.pathSeparator}$vaultFileName');
    final store = FileVaultStore(file);
    await SecretVault(store, oldKey).putLocalSecret(_secret, updatedAt: 1);
    final staged = await store.stageRekey(currentKey: oldKey, newKey: newKey);
    staged.release();
    keystore.masterKey = List.of(newKey);
    return File('${file.path}.rekey');
  }

  test(
    'a first save mints the master key, and a read opens the entry',
    () async {
      final vault = open();
      expect(await vault.exists(), isFalse);

      await vault.save(_secret);

      expect(keystore.masterKey, hasLength(32));
      expect(await vault.exists(), isTrue);
      final read = await open().read('secret-a');
      expect(read?.value, 'hunter2');
      expect(read?.kind, SecretKind.password);
      expect(read!.updatedAt, greaterThan(0), reason: 'a local edit is dated');
      expect(await open().read('secret-b'), isNull);
    },
  );

  test('saving again keeps the key it minted', () async {
    final vault = open();
    await vault.save(_secret);
    final key = List.of(keystore.masterKey!);

    await vault.save(
      const Secret(id: 'secret-b', kind: SecretKind.password, value: 'x'),
    );

    expect(keystore.masterKey, key);
    expect((await vault.read('secret-a'))?.value, 'hunter2');
  });

  test('two first saves at once mint one key and both open', () async {
    final vault = open();
    final minted = <List<int>>[];
    keystore.onWrite = minted.add;

    await Future.wait([
      vault.save(_secret),
      vault.save(
        const Secret(id: 'secret-b', kind: SecretKind.password, value: 'x'),
      ),
    ]);

    expect(minted, hasLength(1));
    expect((await open().read('secret-a'))?.value, 'hunter2');
    expect((await open().read('secret-b'))?.value, 'x');
  });

  test('without a vault file a read asks the keystore nothing', () async {
    keystore.masterKey = null;
    expect(await open().read('secret-a'), isNull);
  });

  test('a vault whose key the keystore lost is never re-keyed', () async {
    await open().save(_secret);
    keystore.masterKey = null;

    await expectLater(
      open().read('secret-a'),
      throwsA(
        isA<VaultUnavailableException>().having(
          (e) => e.reason,
          'reason',
          VaultUnavailableReason.keystoreUnavailable,
        ),
      ),
    );
    await expectLater(
      open().save(_secret),
      throwsA(isA<VaultUnavailableException>()),
    );
    expect(keystore.masterKey, isNull, reason: 'nothing was minted');
  });

  test('an enrolled device never mints over the account key', () async {
    enrolled = true;

    await expectLater(
      open().save(_secret),
      throwsA(isA<VaultUnavailableException>()),
    );
    expect(keystore.masterKey, isNull);
    expect(await open().exists(), isFalse);
  });

  test('a keystore that refuses the minted key saves nothing', () async {
    keystore.refuseWrites = true;

    await expectLater(open().save(_secret), throwsA(anything));
    expect(await open().exists(), isFalse);
  });

  test('a shared support directory is neither read nor written', () async {
    await open().save(_secret);
    final shared = open(access: SupportDirectoryAccess.unguarded);

    expect(await shared.read('secret-a'), isNull);
    await expectLater(
      shared.save(_secret),
      throwsA(
        isA<VaultUnavailableException>().having(
          (e) => e.reason,
          'reason',
          VaultUnavailableReason.directoryShared,
        ),
      ),
    );
  });

  test('a re-key an earlier process left settles before a read', () async {
    final journal = await crashAfterKeystoreWrite();

    expect((await open().read('secret-a'))?.value, 'hunter2');
    expect(journal.existsSync(), isFalse);
  });

  test('a re-key an earlier process left settles before a save', () async {
    final journal = await crashAfterKeystoreWrite();

    await open().save(
      const Secret(id: 'secret-b', kind: SecretKind.password, value: 'x'),
    );

    expect(journal.existsSync(), isFalse);
    expect((await open().read('secret-a'))?.value, 'hunter2');
    expect((await open().read('secret-b'))?.value, 'x');
    expect(keystore.masterKey, newKey, reason: 'nothing was minted');
  });

  test('settling leaves the journal while the keystore gives no key, or '
      'the directory is shared', () async {
    final journal = await crashAfterKeystoreWrite();

    expect(
      await open(access: SupportDirectoryAccess.unguarded).settledMasterKey(),
      newKey,
    );
    expect(journal.existsSync(), isTrue, reason: 'a shared directory');

    keystore.masterKey = null;
    expect(await open().settledMasterKey(), isNull);
    expect(journal.existsSync(), isTrue, reason: 'no key to settle against');

    keystore.masterKey = List.of(newKey);
    final vault = open();
    expect(await vault.settledMasterKey(), newKey);
    expect(journal.existsSync(), isFalse);
    expect(
      (await SecretVault(vault.store, newKey).getSecret('secret-a'))?.value,
      'hunter2',
    );
  });
}
