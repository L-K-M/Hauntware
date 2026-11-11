import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

final _keyA = Uint8List.fromList(List.generate(32, (i) => i));
final _keyB = Uint8List.fromList(List.generate(32, (i) => 0xff - i));

Secret _secret(String id, [String? value]) =>
    Secret(id: id, kind: SecretKind.password, value: value ?? 'value-$id');

/// Re-seals every stored entry under [to], the way a vault re-key does:
/// the wrap entry rides along, so the standing code keeps working.
Future<void> _rekey(
  InMemoryVaultStore store,
  List<int> from,
  List<int> to,
) async {
  final resealed = <String, Uint8List>{};
  for (final MapEntry(:key, :value) in (await store.allSecretBlobs()).entries) {
    resealed[key] = await VaultCrypto.sealJson(
      to,
      await VaultCrypto.openJson(from, value),
    );
  }
  await store.putSecretBlobs(resealed);
}

/// The export decoded to its members, for tampering.
Map<String, dynamic> _decoded(Uint8List export) =>
    jsonDecode(utf8.decode(export)) as Map<String, dynamic>;

Uint8List _encoded(Map<String, dynamic> file) =>
    Uint8List.fromList(utf8.encode(jsonEncode(file)));

void main() {
  late InMemoryVaultStore storeA;
  late SecretVault vaultA;
  late VaultRecovery recoveryA;

  setUp(() {
    storeA = InMemoryVaultStore();
    vaultA = SecretVault(storeA, _keyA);
    recoveryA = VaultRecovery(storeA);
  });

  Future<(InMemoryVaultStore, SecretVault, VaultRecovery)> otherDevice() async {
    final storeB = InMemoryVaultStore();
    return (storeB, SecretVault(storeB, _keyB), VaultRecovery(storeB));
  }

  group('configured', () {
    test('is false without a code, true after saveCode', () async {
      expect(await recoveryA.configured(_keyA), isFalse);
      await recoveryA.saveCode(recoveryA.newCode(), vaultKey: _keyA);
      expect(await recoveryA.configured(_keyA), isTrue);
    });

    test('cannot tell more than "entry exists" without a key', () async {
      await recoveryA.saveCode(recoveryA.newCode(), vaultKey: _keyA);
      expect(await recoveryA.configured(null), isTrue);
    });

    test('is false when the entry no longer opens under the key', () async {
      await recoveryA.saveCode(recoveryA.newCode(), vaultKey: _keyA);
      // A lost keystore healed with a fresh key: the entry exists but the
      // code it belonged to exports nothing any more.
      expect(await recoveryA.configured(_keyB), isFalse);
    });
  });

  group('saveCode', () {
    test('rejects a mistyped code without touching the stored one', () async {
      final code = recoveryA.newCode();
      await recoveryA.saveCode(code, vaultKey: _keyA);
      await expectLater(
        recoveryA.saveCode('not a recovery code', vaultKey: _keyA),
        throwsA(isA<FormatException>()),
      );
      expect(await recoveryA.configured(_keyA), isTrue);
    });

    test('a code not saved leaves the previous one in force', () async {
      final first = recoveryA.newCode();
      await recoveryA.saveCode(first, vaultKey: _keyA);
      // Generated but never confirmed: nothing changes.
      recoveryA.newCode();
      await vaultA.putSecret(_secret('pw-web'));
      final export = await recoveryA.exportSecrets(vaultKey: _keyA);

      final (_, vaultB, recoveryB) = await otherDevice();
      final summary = await recoveryB.restoreSecrets(
        vaultB,
        export,
        first,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect(summary.added, 1);
    });
  });

  group('exportSecrets', () {
    test('needs a stored code', () async {
      await expectLater(
        recoveryA.exportSecrets(vaultKey: _keyA),
        throwsA(isA<RecoveryNotSetUpException>()),
      );
    });

    test('a damaged wrap entry is its own failure', () async {
      // An entry shaped like the wrap key that this key cannot open, as a
      // healed keystore leaves behind.
      await storeA.putSecretBlob(
        recoveryWrapKeyId,
        await VaultCrypto.sealJson(_keyB, {'version': 1}),
      );
      await expectLater(
        recoveryA.exportSecrets(vaultKey: _keyA),
        throwsA(isA<RecoveryDamagedException>()),
      );
      await expectLater(
        recoveryA.exportSecrets(vaultKey: _keyB),
        throwsA(isA<RecoveryDamagedException>()),
      );
    });

    test('leaves every reserved id out of the file', () async {
      await vaultA.putSecret(_secret('pw-web'));
      await recoveryA.saveCode(recoveryA.newCode(), vaultKey: _keyA);
      await storeA.putSecretBlob(
        'recovery:other',
        await VaultCrypto.sealJson(_keyA, {'version': 1}),
      );

      final file = _decoded(await recoveryA.exportSecrets(vaultKey: _keyA));
      final ids = (file['entries'] as Map<String, dynamic>).keys;
      expect(ids, contains('pw-web'));
      expect(ids, isNot(anyElement(startsWith('recovery:'))));
    });

    test('the code survives a re-key of the vault', () async {
      final code = recoveryA.newCode();
      await recoveryA.saveCode(code, vaultKey: _keyA);
      await vaultA.putSecret(_secret('pw-web'));
      await _rekey(storeA, _keyA, _keyB);

      final export = await recoveryA.exportSecrets(vaultKey: _keyB);
      final (_, vaultB, recoveryB) = await otherDevice();
      final summary = await recoveryB.restoreSecrets(
        vaultB,
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect(summary.added, 1);
      expect((await vaultB.getSecret('pw-web'))!.value, 'value-pw-web');
    });
  });

  group('restoreSecrets', () {
    late String code;
    late Uint8List export;

    setUp(() async {
      await vaultA.putSecrets([_secret('pw-web'), _secret('pw-db')]);
      code = recoveryA.newCode();
      await recoveryA.saveCode(code, vaultKey: _keyA);
      export = await recoveryA.exportSecrets(vaultKey: _keyA);
    });

    Future<(SecretVault, InMemoryVaultStore)> deviceWith(
      Iterable<Secret> secrets,
    ) async {
      final (storeB, vaultB, _) = await otherDevice();
      await vaultB.putSecrets(secrets);
      return (vaultB, storeB);
    }

    test('opens on another device with another key', () async {
      final (vaultB, storeB) = await deviceWith(const []);
      final recoveryB = VaultRecovery(storeB);
      final summary = await recoveryB.restoreSecrets(
        vaultB,
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );

      expect((summary.added, summary.kept, summary.replaced), (2, 0, 0));
      expect((await vaultB.getSecret('pw-web'))!.value, 'value-pw-web');
      expect((await vaultB.getSecret('pw-db'))!.value, 'value-pw-db');
      // Restoring brings credentials, not the other device's recovery.
      expect(await recoveryB.configured(_keyB), isFalse);
    });

    test('a credential already here is kept or replaced as asked', () async {
      final (vaultB, storeB) = await deviceWith([_secret('pw-web', 'mine')]);
      final recoveryB = VaultRecovery(storeB);

      final kept = await recoveryB.restoreSecrets(
        vaultB,
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect((kept.added, kept.kept, kept.replaced), (1, 1, 0));
      expect((await vaultB.getSecret('pw-web'))!.value, 'mine');

      final replaced = await recoveryB.restoreSecrets(
        vaultB,
        export,
        code,
        policy: RestoreConflictPolicy.replaceExisting,
      );
      expect((replaced.added, replaced.kept, replaced.replaced), (0, 0, 2));
      expect((await vaultB.getSecret('pw-web'))!.value, 'value-pw-web');
    });

    test(
      'a credential here that will not open is replaced, even when keeping',
      () async {
        final (vaultB, storeB) = await deviceWith(const []);
        await storeB.putSecretBlob(
          'pw-web',
          await VaultCrypto.sealJson(
            Uint8List(32),
            _secret('pw-web', 'lost').toJson(),
          ),
        );

        final summary = await VaultRecovery(storeB).restoreSecrets(
          vaultB,
          export,
          code,
          policy: RestoreConflictPolicy.keepExisting,
        );
        expect(summary.added, 2);
        expect((await vaultB.getSecret('pw-web'))!.value, 'value-pw-web');
      },
    );

    test('an entry the export cannot open counts as unreadable', () async {
      await storeA.putSecretBlob(
        'pw-broken',
        await VaultCrypto.sealJson(
          Uint8List(32),
          _secret('pw-broken').toJson(),
        ),
      );
      final damaged = await recoveryA.exportSecrets(vaultKey: _keyA);

      final (vaultB, storeB) = await deviceWith(const []);
      final summary = await VaultRecovery(storeB).restoreSecrets(
        vaultB,
        damaged,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect(summary.added, 2);
      expect(summary.unreadable, 1);
      expect(await vaultB.getSecret('pw-broken'), isNull);
    });

    test('a wrong or mistyped code throws and writes nothing', () async {
      final (vaultB, storeB) = await deviceWith([_secret('mine')]);
      final recoveryB = VaultRecovery(storeB);
      final before = await storeB.allSecretBlobs();

      await expectLater(
        recoveryB.restoreSecrets(
          vaultB,
          export,
          RecoveryKey.encode(Uint8List(32)),
          policy: RestoreConflictPolicy.replaceExisting,
        ),
        throwsA(
          isA<SecretsExportException>().having(
            (e) => e.failure,
            'failure',
            SecretsExportFailure.wrongCode,
          ),
        ),
      );
      await expectLater(
        recoveryB.restoreSecrets(
          vaultB,
          export,
          'not a recovery code',
          policy: RestoreConflictPolicy.replaceExisting,
        ),
        throwsA(
          isA<SecretsExportException>().having(
            (e) => e.failure,
            'failure',
            SecretsExportFailure.invalidCode,
          ),
        ),
      );
      expect(await storeB.allSecretBlobs(), before);
    });

    test('a newer file version is refused', () async {
      final tampered = _decoded(export)..['version'] = 2;
      final (vaultB, _) = await deviceWith(const []);
      await expectLater(
        VaultRecovery(vaultB.store).restoreSecrets(
          vaultB,
          _encoded(tampered),
          code,
          policy: RestoreConflictPolicy.keepExisting,
        ),
        throwsA(
          isA<SecretsExportException>().having(
            (e) => e.failure,
            'failure',
            SecretsExportFailure.unsupportedVersion,
          ),
        ),
      );
    });

    test('an altered header, entry or MAC throws and writes nothing', () async {
      final (vaultB, storeB) = await deviceWith(const []);
      final before = await storeB.allSecretBlobs();

      final alteredCreated = _decoded(export)
        ..['createdAt'] = '2000-01-01T00:00:00.000Z';
      final alteredEntry = _decoded(export);
      final entries = alteredEntry['entries'] as Map<String, dynamic>;
      final id = entries.keys.first;
      final blob = base64.decode(entries[id] as String);
      blob[0] ^= 0x01;
      entries[id] = base64.encode(blob);
      final alteredMac = _decoded(export)
        ..['mac'] = base64.encode(Uint8List(32));

      for (final file in [alteredCreated, alteredEntry, alteredMac]) {
        await expectLater(
          VaultRecovery(vaultB.store).restoreSecrets(
            vaultB,
            _encoded(file),
            code,
            policy: RestoreConflictPolicy.replaceExisting,
          ),
          throwsA(
            isA<SecretsExportException>().having(
              (e) => e.failure,
              'failure',
              SecretsExportFailure.tampered,
            ),
          ),
        );
      }
      expect(await storeB.allSecretBlobs(), before);
    });

    test('a truncated file is malformed', () async {
      final (vaultB, _) = await deviceWith(const []);
      await expectLater(
        VaultRecovery(vaultB.store).restoreSecrets(
          vaultB,
          Uint8List.sublistView(export, 0, export.length - 10),
          code,
          policy: RestoreConflictPolicy.keepExisting,
        ),
        throwsA(
          isA<SecretsExportException>().having(
            (e) => e.failure,
            'failure',
            SecretsExportFailure.malformed,
          ),
        ),
      );
    });
  });

  test('SecretsRestoreSummary round-trips its link JSON', () {
    const summary = SecretsRestoreSummary(
      added: 1,
      replaced: 2,
      kept: 3,
      unreadable: 4,
    );
    final decoded = SecretsRestoreSummary.fromJson(summary.toJson());
    expect(
      (decoded.added, decoded.replaced, decoded.kept, decoded.unreadable),
      (1, 2, 3, 4),
    );
  });
}
