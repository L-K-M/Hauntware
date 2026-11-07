import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/credential_retirement.dart';
import 'package:seance_core/seance_core.dart';

class _VaultStore extends InMemoryVaultStore {
  Object? deleteError;
  int deleteCalls = 0;

  @override
  Future<void> deleteSecret(String id) async {
    deleteCalls++;
    if (deleteError case final error?) throw error;
    await super.deleteSecret(id);
  }
}

class _FailingTombstones extends InMemoryTombstoneStore {
  @override
  Future<void> add(EncryptedRecord tombstone) async =>
      throw StateError('disk full');
}

void main() {
  late _VaultStore store;
  late SecretVault vault;
  late InMemoryTombstoneStore tombstones;

  setUp(() async {
    store = _VaultStore();
    vault = SecretVault(store, List.filled(32, 7));
    tombstones = InMemoryTombstoneStore();
    await vault.putSecret(
      const Secret(
        id: 'old',
        kind: SecretKind.password,
        value: 'old password',
        updatedAt: 10,
      ),
    );
  });

  Future<CredentialRetirement> retire({
    int updatedAt = 100,
    Iterable<ServerConfig> servers = const [],
    TombstoneStore? pending,
  }) => retireCredential(
    vault: vault,
    tombstones: pending ?? tombstones,
    credentialId: 'old',
    deviceId: 'device-a',
    servers: servers,
    updatedAt: updatedAt,
  );

  test('an unused credential leaves a durable sync withdrawal', () async {
    expect(await retire(), CredentialRetirement.retired);
    expect(await vault.getSecret('old'), isNull);
    final withdrawal = (await tombstones.all()).single;
    expect(withdrawal.id, 'secret:old');
    expect(withdrawal.deleted, isTrue);
    expect(withdrawal.updatedAt, 100);
  });

  test('a surviving config keeps shared credential material', () async {
    final server = ServerConfig(
      id: 'survivor',
      label: 'survivor',
      host: 'other.example.com',
      username: 'deploy',
      authMethod: AuthMethod.password,
      secretRef: 'old',
      createdAt: 1,
      updatedAt: 1,
    );

    expect(
      await retire(servers: [server]),
      CredentialRetirement.stillReferenced,
    );
    expect((await vault.getSecret('old'))!.value, 'old password');
    expect(await tombstones.all(), isEmpty);
    expect(store.deleteCalls, 0);
  });

  test(
    'the withdrawal outranks a credential ahead of the config clock',
    () async {
      await vault.putSecret(
        const Secret(
          id: 'old',
          kind: SecretKind.password,
          value: 'newer password',
          updatedAt: 500,
        ),
      );

      await retire(updatedAt: 100);

      expect((await tombstones.all()).single.updatedAt, 501);
    },
  );

  test(
    'a failed vault delete retains its withdrawal and retry stamp',
    () async {
      store.deleteError = StateError('keyring locked');
      await expectLater(retire(), throwsStateError);
      expect((await vault.getSecret('old'))!.value, 'old password');
      expect((await tombstones.all()).single.updatedAt, 100);

      store.deleteError = null;
      await retire(updatedAt: 200);

      expect(await vault.getSecret('old'), isNull);
      expect((await tombstones.all()).single.updatedAt, 100);
    },
  );

  test('a failed withdrawal write keeps the old credential intact', () async {
    await expectLater(retire(pending: _FailingTombstones()), throwsStateError);

    expect((await vault.getSecret('old'))!.value, 'old password');
    expect(store.deleteCalls, 0);
  });

  test(
    'an already absent credential still withdraws a stale sync copy',
    () async {
      await vault.deleteSecret('old');

      expect(await retire(), CredentialRetirement.retired);
      expect((await tombstones.all()).single.id, 'secret:old');
    },
  );
}
