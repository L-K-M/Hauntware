// The engine's CRED-05 recovery (03 §4.5): a code round-trips across
// devices, a wrong code or altered export writes nothing, a locked
// keystore refuses without minting a key, reserved ids stay out of the
// file, both conflict policies apply, and every protocol response carries
// its requestId.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/engine_recovery.dart';
import 'package:klabautermann_core/src/catalog/engine_vault.dart';
import 'package:seance_core/seance_core.dart'
    show
        RecoveryKey,
        Secret,
        SecretKind,
        SecretsExport,
        VaultCrypto,
        recoveryWrapKeyId;
import 'package:test/test.dart';

import '../support/fake_sync_server.dart' show MemoryKeystore;

Secret _secret(String id, [String value = 'value']) =>
    Secret(id: id, kind: SecretKind.password, value: value);

Matcher _failure(VaultRecoveryFailure failure) => isA<VaultRecoveryException>()
    .having((error) => error.failure, 'failure', failure);

final class _Device {
  _Device._(this.support, this.keystore, this.vault, this.recovery);

  final Directory support;
  final MemoryKeystore keystore;
  final EngineVault vault;
  final EngineRecovery recovery;
}

void main() {
  late Directory support;
  late MemoryKeystore keystore;
  late EngineVault vault;
  late EngineRecovery recovery;

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-recovery-');
    keystore = MemoryKeystore();
    vault = EngineVault(
      support,
      access: SupportDirectoryAccess.exclusive,
      keystore: keystore,
      enrolled: () => false,
    );
    recovery = EngineRecovery(vault, keystore);
  });

  tearDown(() => support.deleteSync(recursive: true));

  _Device otherDevice({List<int>? key}) {
    final other = Directory.systemTemp.createTempSync(
      'klab-engine-recovery-b-',
    );
    addTearDown(() => other.deleteSync(recursive: true));
    final otherKeystore = MemoryKeystore();
    if (key != null) otherKeystore.masterKey = key;
    final otherVault = EngineVault(
      other,
      access: SupportDirectoryAccess.exclusive,
      keystore: otherKeystore,
      enrolled: () => false,
    );
    return _Device._(
      other,
      otherKeystore,
      otherVault,
      EngineRecovery(otherVault, otherKeystore),
    );
  }

  test('a code, an export and a restore round-trip across devices', () async {
    await vault.save(_secret('pw-web', 'value-pw-web'));
    await vault.save(_secret('pw-db', 'value-pw-db'));
    final code = recovery.newCode();
    expect(await recovery.configured(), isFalse, reason: 'not stored yet');
    await recovery.saveCode(code);
    expect(await recovery.configured(), isTrue);

    final export = await recovery.exportSecrets();
    expect(export, isNotEmpty);

    final other = otherDevice(key: Uint8List.fromList(List.filled(32, 9)));
    final summary = await other.recovery.restoreSecrets(
      export,
      code,
      policy: VaultRestorePolicy.keepExisting,
    );
    expect((summary.added, summary.kept, summary.replaced), (2, 0, 0));
    expect((await other.vault.read('pw-web'))?.value, 'value-pw-web');
    expect((await other.vault.read('pw-db'))?.value, 'value-pw-db');
    expect(
      await other.recovery.configured(),
      isFalse,
      reason: 'restoring brings credentials, not the other recovery',
    );
  });

  test('a wrong code or altered export writes nothing', () async {
    await vault.save(_secret('pw-web'));
    final code = recovery.newCode();
    await recovery.saveCode(code);
    final export = await recovery.exportSecrets();

    final other = otherDevice(key: Uint8List.fromList(List.filled(32, 9)));
    await other.vault.save(_secret('mine'));
    final vaultFile = File('${other.support.path}/vault.json');
    final before = await vaultFile.readAsString();

    await expectLater(
      other.recovery.restoreSecrets(
        export,
        RecoveryKey.encode(Uint8List(32)),
        policy: VaultRestorePolicy.replaceExisting,
      ),
      throwsA(_failure(VaultRecoveryFailure.wrongCode)),
    );

    final altered = Uint8List.fromList(export)..[export.length ~/ 2] ^= 0x01;
    await expectLater(
      other.recovery.restoreSecrets(
        altered,
        code,
        policy: VaultRestorePolicy.replaceExisting,
      ),
      throwsA(_failure(VaultRecoveryFailure.tampered)),
    );

    expect(await vaultFile.readAsString(), before);
  });

  test(
    'a locked keystore refuses without minting or replacing a key',
    () async {
      await vault.save(_secret('pw-web'));
      final code = recovery.newCode();
      await recovery.saveCode(code);
      final export = await recovery.exportSecrets();
      final vaultFile = File('${support.path}/vault.json');
      final before = await vaultFile.readAsString();

      keystore.masterKey = null;

      expect(
        await recovery.configured(),
        isTrue,
        reason: 'whether the entry exists needs no key',
      );
      await expectLater(
        recovery.saveCode(recovery.newCode()),
        throwsA(_failure(VaultRecoveryFailure.keystoreUnavailable)),
      );
      await expectLater(
        recovery.exportSecrets(),
        throwsA(_failure(VaultRecoveryFailure.keystoreUnavailable)),
      );
      await expectLater(
        recovery.restoreSecrets(
          export,
          code,
          policy: VaultRestorePolicy.keepExisting,
        ),
        throwsA(_failure(VaultRecoveryFailure.keystoreUnavailable)),
      );

      expect(keystore.masterKey, isNull, reason: 'no key was minted');
      expect(await vaultFile.readAsString(), before);
    },
  );

  test('reserved ids stay out of exports and restores', () async {
    await vault.save(_secret('pw-web'));
    final code = recovery.newCode();
    await recovery.saveCode(code);
    await vault.store.putSecretBlob(
      'recovery:other',
      Uint8List.fromList(const [1, 2, 3]),
    );

    final export = await recovery.exportSecrets();
    final file = jsonDecode(utf8.decode(export)) as Map<String, dynamic>;
    final ids = (file['entries'] as Map<String, dynamic>).keys;
    expect(ids, contains('pw-web'));
    expect(ids, isNot(contains(recoveryWrapKeyId)));
    expect(ids, isNot(anyElement(startsWith('recovery:'))));

    final other = otherDevice(key: Uint8List.fromList(List.filled(32, 9)));
    await other.recovery.restoreSecrets(
      export,
      code,
      policy: VaultRestorePolicy.keepExisting,
    );
    expect(
      (await other.vault.store.allSecretBlobs()).keys,
      isNot(anyElement(startsWith('recovery:'))),
    );
  });

  test('keep and replace policies both apply', () async {
    await vault.save(_secret('pw-web', 'theirs'));
    final code = recovery.newCode();
    await recovery.saveCode(code);
    final export = await recovery.exportSecrets();

    final other = otherDevice(key: Uint8List.fromList(List.filled(32, 9)));
    await other.vault.save(_secret('pw-web', 'mine'));

    final kept = await other.recovery.restoreSecrets(
      export,
      code,
      policy: VaultRestorePolicy.keepExisting,
    );
    expect((kept.added, kept.kept, kept.replaced), (0, 1, 0));
    expect((await other.vault.read('pw-web'))?.value, 'mine');

    final replaced = await other.recovery.restoreSecrets(
      export,
      code,
      policy: VaultRestorePolicy.replaceExisting,
    );
    expect((replaced.added, replaced.kept, replaced.replaced), (0, 0, 1));
    expect((await other.vault.read('pw-web'))?.value, 'theirs');
  });

  test('export needs a code, and a damaged entry says damaged', () async {
    await vault.save(_secret('pw-web'));
    await expectLater(
      recovery.exportSecrets(),
      throwsA(_failure(VaultRecoveryFailure.notSetUp)),
    );

    await vault.store.putSecretBlob(
      recoveryWrapKeyId,
      await VaultCrypto.sealJson(Uint8List(32), {'version': 1}),
    );
    await expectLater(
      recovery.exportSecrets(),
      throwsA(_failure(VaultRecoveryFailure.damaged)),
    );
  });

  test('an invalid code is refused without replacing the stored one', () async {
    await vault.save(_secret('pw-web'));
    final code = recovery.newCode();
    await recovery.saveCode(code);
    await expectLater(
      recovery.saveCode('not a recovery code'),
      throwsA(_failure(VaultRecoveryFailure.invalidCode)),
    );
    expect(await recovery.configured(), isTrue);
  });

  test('an oversized export is refused before decoding', () async {
    await vault.save(_secret('pw-web'));
    final code = recovery.newCode();
    await recovery.saveCode(code);

    await expectLater(
      recovery.restoreSecrets(
        Uint8List(SecretsExport.maxBytes + 1),
        code,
        policy: VaultRestorePolicy.keepExisting,
      ),
      throwsA(_failure(VaultRecoveryFailure.tooLarge)),
    );
  });

  test('a truncated export is malformed and writes nothing', () async {
    await vault.save(_secret('pw-web'));
    final code = recovery.newCode();
    await recovery.saveCode(code);
    final export = await recovery.exportSecrets();

    final other = otherDevice(key: Uint8List.fromList(List.filled(32, 9)));
    await other.vault.save(_secret('mine'));
    final vaultFile = File('${other.support.path}/vault.json');
    final before = await vaultFile.readAsString();

    await expectLater(
      other.recovery.restoreSecrets(
        Uint8List.sublistView(export, 0, export.length - 10),
        code,
        policy: VaultRestorePolicy.keepExisting,
      ),
      throwsA(_failure(VaultRecoveryFailure.malformed)),
    );
    expect(await vaultFile.readAsString(), before);
  });

  group('protocol', () {
    Future<EngineEvent> nextAnswer(
      IsolateEngineClient client,
      StreamIterator<EngineEvent> events,
    ) async {
      while (await events.moveNext()) {
        final event = events.current;
        if (event case KeystoreRequest(:final requestId, :final operation)) {
          final KeystoreResult result = switch (operation) {
            KeystoreReadMasterKey() => KeystoreMasterKey(
              Uint8List.fromList(List.filled(32, 7)),
            ),
            _ => const KeystoreDone(),
          };
          client.send(AnswerKeystore(requestId, result));
          continue;
        }
        return event;
      }
      throw StateError('the engine stopped before answering');
    }

    test('a damaged entry fails safely without stopping the engine', () async {
      final vaultFile = File('${support.path}/vault.json');
      final damaged = jsonEncode({recoveryWrapKeyId: '%%%'});
      await vaultFile.writeAsString(damaged);
      final client = await IsolateEngineClient.spawn(
        supportDirectory: support.path,
        supportDirectoryAccess: SupportDirectoryAccess.exclusive,
      );
      addTearDown(client.shutdown);
      final events = StreamIterator(client.events);
      addTearDown(events.cancel);
      expect(await events.moveNext(), isTrue, reason: 'the startup fleet');

      client.send(const RecoveryStatusRequest(requestId: 'damaged-1'));
      final answer = await nextAnswer(
        client,
        events,
      ).timeout(const Duration(seconds: 3));
      expect(answer, isA<VaultRecoveryFailed>());
      expect((answer as VaultRecoveryFailed).requestId, 'damaged-1');
      expect(answer.failure, VaultRecoveryFailure.failed);
      expect(await vaultFile.readAsString(), damaged);

      client.send(const NewRecoveryCode(requestId: 'still-alive'));
      final next = await nextAnswer(
        client,
        events,
      ).timeout(const Duration(seconds: 3));
      expect(next, isA<RecoveryCodeGenerated>());
      expect((next as RecoveryCodeGenerated).requestId, 'still-alive');
    });

    test('every recovery response carries its requestId', () async {
      final client = await IsolateEngineClient.spawn(
        supportDirectory: support.path,
        supportDirectoryAccess: SupportDirectoryAccess.exclusive,
      );
      addTearDown(client.shutdown);
      final events = StreamIterator(client.events);
      addTearDown(events.cancel);
      expect(await events.moveNext(), isTrue, reason: 'the startup fleet');

      Future<EngineEvent> nextAnsweringKeystore() => nextAnswer(client, events);

      client.send(const NewRecoveryCode(requestId: 'new-1'));
      final generated = await nextAnsweringKeystore();
      expect(generated, isA<RecoveryCodeGenerated>());
      expect((generated as RecoveryCodeGenerated).requestId, 'new-1');
      final code = generated.code;

      client.send(const RecoveryStatusRequest(requestId: 'status-1'));
      final status = await nextAnsweringKeystore();
      expect(status, isA<RecoveryStatus>());
      expect((status as RecoveryStatus).requestId, 'status-1');
      expect(status.configured, isFalse);

      client.send(SetRecoveryCode(requestId: 'set-1', code: code));
      final saved = await nextAnsweringKeystore();
      expect(saved, isA<RecoveryStatus>());
      expect((saved as RecoveryStatus).requestId, 'set-1');
      expect(saved.configured, isTrue);

      client.send(const ExportVault(requestId: 'export-1'));
      final exported = await nextAnsweringKeystore();
      expect(exported, isA<VaultExported>());
      expect((exported as VaultExported).requestId, 'export-1');
      expect(exported.bytes, isNotEmpty);

      client.send(
        RestoreVault(
          requestId: 'restore-1',
          export: Uint8List(SecretsExport.maxBytes + 1),
          code: code,
          policy: VaultRestorePolicy.keepExisting,
        ),
      );
      final oversized = await nextAnsweringKeystore();
      expect(oversized, isA<VaultRecoveryFailed>());
      expect((oversized as VaultRecoveryFailed).requestId, 'restore-1');
      expect(oversized.failure, VaultRecoveryFailure.tooLarge);

      client.send(
        RestoreVault(
          requestId: 'restore-2',
          export: exported.bytes,
          code: 'not a recovery code',
          policy: VaultRestorePolicy.keepExisting,
        ),
      );
      final invalid = await nextAnsweringKeystore();
      expect(invalid, isA<VaultRecoveryFailed>());
      expect((invalid as VaultRecoveryFailed).requestId, 'restore-2');
      expect(invalid.failure, VaultRecoveryFailure.invalidCode);
    });
  });
}
