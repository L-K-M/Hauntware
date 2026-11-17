// Moved from Poltergeist's app test/vault_rekey_journal_test.dart with
// FileVaultStore (docs/design/catalog-library.md section 8); Poltergeist
// ported these cases from Séance's app test of the same name at ded9228.
// The SecureSyncCredentialStore group, which drives the OS keystore, stays
// in the app.
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import '../support/atomic_write_blocker.dart';

Secret secret(String id) =>
    Secret(id: id, kind: SecretKind.password, value: 'value-$id');

void main() {
  late Directory directory;
  late File vaultFile;
  late File journalFile;
  late List<int> oldKey;
  late List<int> newKey;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-rekey-');
    vaultFile = File('${directory.path}/vault.json');
    journalFile = File('${vaultFile.path}.rekey');
    oldKey = secureRandomBytes(32);
    newKey = secureRandomBytes(32);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  /// The state a process leaves behind when it dies inside the re-key: both
  /// generations staged. The key each test then settles with stands for
  /// whatever the OS keystore had got to by then; the store never reads the
  /// keystore, so the keystore half stays in the app's tests.
  Future<void> crashMidRekey() async {
    final store = FileVaultStore(vaultFile);
    await SecretVault(store, oldKey).putSecrets([secret('a'), secret('b')]);
    await store.stageRekey(currentKey: oldKey, newKey: newKey);
  }

  group('FileVaultStore re-key journal', () {
    test(
      'a crash before the keystore write leaves the old key working',
      () async {
        await crashMidRekey();

        // A fresh store is the next launch: it finds the journal and settles it
        // against the key the keystore actually kept.
        final reopened = FileVaultStore(vaultFile);
        expect(await reopened.settleRekey(oldKey), VaultRekeyOutcome.adopted);
        final vault = SecretVault(reopened, oldKey);
        expect((await vault.getSecret('a'))!.value, 'value-a');
        expect((await vault.getSecret('b'))!.value, 'value-b');
        expect(await journalFile.exists(), isFalse);
      },
    );

    test(
      'a crash after the keystore write leaves the new key working',
      () async {
        await crashMidRekey();

        final reopened = FileVaultStore(vaultFile);
        expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
        final vault = SecretVault(reopened, newKey);
        expect((await vault.getSecret('a'))!.value, 'value-a');
        expect((await vault.getSecret('b'))!.value, 'value-b');
        expect(await journalFile.exists(), isFalse);

        // The generation actually committed to the vault file is the new one,
        // so the next launch needs no journal to read it.
        final next = SecretVault(FileVaultStore(vaultFile), newKey);
        expect((await next.getSecret('a'))!.value, 'value-a');
      },
    );

    test('a key matching neither generation drops the journal, not the '
        'vault', () async {
      await crashMidRekey();

      // Neither staged generation can be opened, so neither is recoverable.
      // What matters is that the store does not stay wedged behind a journal
      // nothing can clear.
      final reopened = FileVaultStore(vaultFile);
      expect(
        await reopened.settleRekey(secureRandomBytes(32)),
        VaultRekeyOutcome.discarded,
      );
      expect(await journalFile.exists(), isFalse);
      expect(
        directory.listSync().any((f) => f.path.contains('.corrupt')),
        isTrue,
      );

      // The stored vault is untouched: staging never wrote it.
      expect(
        (await SecretVault(reopened, oldKey).getSecret('a'))!.value,
        'value-a',
      );
      // And ordinary mutations are allowed again.
      await SecretVault(reopened, oldKey).putSecret(secret('c'));
      expect(
        (await SecretVault(reopened, oldKey).getSecret('c'))!.value,
        'value-c',
      );
    });

    test('a stray or damaged journal never blocks a vault read', () async {
      await SecretVault(
        FileVaultStore(vaultFile),
        oldKey,
      ).putSecret(secret('a'));
      // The trap this guards: a journal no code path created and none could
      // clear, failing every read from here on.
      await journalFile.writeAsString('not json at all');

      final vault = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);
      expect(
        directory.listSync().any((f) => f.path.contains('.corrupt')),
        isTrue,
      );
    });

    test('an entry the current key cannot open survives the re-key', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('live'));
      // An orphan left sealed under a key nobody holds any more. Re-keying
      // must not fail on it, and must not delete it either.
      await SecretVault(store, secureRandomBytes(32)).putSecret(secret('lost'));

      final rekey = await store.stageRekey(currentKey: oldKey, newKey: newKey);
      expect(await rekey.settle(newKey), VaultRekeyOutcome.adopted);

      final vault = SecretVault(store, newKey);
      expect((await vault.getSecret('live'))!.value, 'value-live');
      expect(await store.getSecretBlob('lost'), isNotNull);
    });

    test('credentials are not mutable while a re-key is staged', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // A write now would persist the stored generation, which settling may
      // then replace with the staged one, silently undoing it.
      await expectLater(
        () => SecretVault(store, oldKey).putSecret(secret('b')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        () => store.stageRekey(currentKey: oldKey, newKey: newKey),
        throwsA(isA<StateError>()),
      );
    });

    test('the journal stores no plaintext', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      final staged = await journalFile.readAsString();
      expect(staged, isNot(contains('value-a')));
      // Both halves: the journal carries a generation under each key, so a
      // writer that leaked key material would leak either one.
      expect(staged, isNot(contains(base64.encode(newKey))));
      expect(staged, isNot(contains(base64.encode(oldKey))));
    });

    test('a valid journal never blocks a vault read', () async {
      await crashMidRekey();

      // The damaged-journal case is covered above; this is the other half,
      // and the reason staging leaves `vault.json` alone. The unwired code
      // made the sidecar authoritative and refused every read while one
      // existed.
      final vault = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isTrue);
    });

    test('settling again after a crash mid-commit is harmless', () async {
      await crashMidRekey();
      final staged = await journalFile.readAsString();
      expect(
        await FileVaultStore(vaultFile).settleRekey(newKey),
        VaultRekeyOutcome.adopted,
      );
      // settleRekey flushes the vault and *then* clears the sidecar, so a
      // process dying between the two leaves a journal beside a vault that
      // already holds the adopted generation. The next launch settles it
      // again, which has to be a no-op rather than a second rewrite.
      await journalFile.writeAsString(staged);

      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
      expect(
        (await SecretVault(reopened, newKey).getSecret('a'))!.value,
        'value-a',
      );
      expect(await journalFile.exists(), isFalse);
    });

    test('a journal that is not even valid UTF-8 is damage, not a failed '
        'read', () async {
      await crashMidRekey();
      // `readAsString` reports malformed UTF-8 as a FileSystemException, the
      // same type a locked or unreadable file raises. Reading bytes and
      // decoding them here is what keeps the two apart, so this content has
      // to be quarantined like any other damage rather than retried forever.
      await journalFile.writeAsBytes([0xff, 0xfe, 0xfd]);

      final store = FileVaultStore(vaultFile);
      expect(await store.settleRekey(oldKey), VaultRekeyOutcome.none);
      expect(
        (await SecretVault(store, oldKey).getSecret('a'))!.value,
        'value-a',
      );
      expect(await journalFile.exists(), isFalse);
      expect(
        directory.listSync().any((f) => f.path.contains('.corrupt')),
        isTrue,
      );
    });

    test('an existing vault file is tightened when it is opened', () async {
      await SecretVault(
        FileVaultStore(vaultFile),
        oldKey,
      ).putSecret(secret('a'));
      // The state every install created before the store restricted the
      // file is in, and a vault that is only ever read never leaves it on
      // its own.
      await Process.run('chmod', ['644', vaultFile.path]);
      expect((await vaultFile.stat()).mode & 0x1ff, 0x1a4); // 0644

      final store = FileVaultStore(vaultFile);
      expect(
        (await SecretVault(store, oldKey).getSecret('a'))!.value,
        'value-a',
      );

      expect((await vaultFile.stat()).mode & 0x1ff, 0x180); // 0600
    }, skip: !Platform.isLinux && !Platform.isMacOS);

    test(
      'a settle that cannot be written keeps the session generation',
      () async {
        final store = FileVaultStore(vaultFile);
        await SecretVault(store, oldKey).putSecret(secret('a'));
        final rekey = await store.stageRekey(
          currentKey: oldKey,
          newKey: newKey,
        );

        final blocker = await AtomicWriteBlocker(vaultFile).create();
        await expectLater(
          rekey.settle(newKey),
          throwsA(isA<FileSystemException>()),
        );
        // The caller adopts the new key only after a settle succeeds, so the
        // cache has to stay on the generation its current key opens.
        expect(
          (await SecretVault(store, oldKey).getSecret('a'))!.value,
          'value-a',
        );
        await blocker.delete();
        rekey.release();

        // Released to recovery, which finishes against the installed key.
        expect(await store.settleRekey(newKey), VaultRekeyOutcome.adopted);
        expect(
          (await SecretVault(store, newKey).getSecret('a'))!.value,
          'value-a',
        );
        expect(await journalFile.exists(), isFalse);
      },
    );
  });

  group('a re-key this process staged', () {
    test('is not settled by anyone but its owner', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      final rekey = await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // A vault read that settles first, while the keystore still holds the
      // old key. Adopting that generation here would clear the journal, and
      // the new key the keystore takes next would open nothing.
      expect(await store.settleRekey(oldKey), VaultRekeyOutcome.deferred);
      expect(await journalFile.exists(), isTrue);
      expect(
        (await SecretVault(store, oldKey).getSecret('a'))!.value,
        'value-a',
      );

      expect(await rekey.settle(newKey), VaultRekeyOutcome.adopted);
      expect(await journalFile.exists(), isFalse);
      expect(
        (await SecretVault(
          FileVaultStore(vaultFile),
          newKey,
        ).getSecret('a'))!.value,
        'value-a',
      );
      // Settled, so the ordinary path runs again.
      expect(await store.settleRekey(newKey), VaultRekeyOutcome.none);
      await expectLater(rekey.settle(newKey), throwsStateError);
    });

    test('released unsettled is left for recovery to settle', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      final rekey = await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // The keystore could not say which key it kept.
      rekey.release();
      await expectLater(rekey.settle(oldKey), throwsStateError);
      expect(await journalFile.exists(), isTrue);

      expect(await store.settleRekey(oldKey), VaultRekeyOutcome.adopted);
      expect(await journalFile.exists(), isFalse);
      await SecretVault(store, oldKey).putSecret(secret('b'));
    });

    test('belongs to this store only; a reopened store recovers it', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // The next launch: no owner, so the journal settles as usual.
      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
    });
  });
}
