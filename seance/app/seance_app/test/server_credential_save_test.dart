import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/server_credential_save.dart';
import 'package:seance_core/seance_core.dart';

/// The ordering one credential-editing save follows: the replacement entry
/// first (under a fresh id, so the old one stays usable), the config second,
/// and the old entry retired only once the config points elsewhere and no
/// other server names it.
void main() {
  SecretVault emptyVault() {
    final store = InMemoryVaultStore();
    return SecretVault(store, List.filled(32, 7));
  }

  ServerConfig config(String secretRef, {int updatedAt = 100}) => ServerConfig(
    id: 's1',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    authMethod: AuthMethod.password,
    secretRef: secretRef,
    createdAt: 1,
    updatedAt: updatedAt,
  );

  test('a config-save failure leaves the old credential usable', () async {
    final vault = emptyVault();
    await vault.putSecret(
      const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'old-pw',
        updatedAt: 10,
      ),
    );
    final failing = _FailingConfigStore();

    await expectLater(
      writeServerWithCredential(
        vault: vault,
        configStore: failing,
        config: config('sec-2'),
        secret: const Secret(
          id: 'sec-2',
          kind: SecretKind.password,
          value: 'new-pw',
        ),
      ),
      throwsStateError,
    );

    // The config still names sec-1, and sec-1 still holds what it did: the
    // failed save cost nothing the saved server depends on.
    final old = await vault.getSecret('sec-1');
    expect(old!.value, 'old-pw');
    // The replacement sits under the id a retried save reuses, so the
    // orphan is adopted rather than accumulated.
    final orphan = await vault.getSecret('sec-2');
    expect(orphan!.value, 'new-pw');
  });

  test('the old entry is retired once the config points elsewhere', () async {
    final vault = emptyVault();
    final tombstones = InMemoryTombstoneStore();
    await vault.putSecret(
      const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'old-pw',
        updatedAt: 10,
      ),
    );
    final saved = config('sec-2');

    await retireReplacedSecret(
      vault: vault,
      tombstones: tombstones,
      deviceId: 'device-a',
      config: saved,
      retiredSecretRef: 'sec-1',
      servers: [saved],
    );

    expect(await vault.getSecret('sec-1'), isNull);
    final tombstone = (await tombstones.all()).single;
    expect(tombstone.id, 'secret:sec-1');
    expect(tombstone.deleted, isTrue);
    expect(tombstone.updatedAt, 100);
  });

  test('a sharer keeps the retired entry', () async {
    final vault = emptyVault();
    await vault.putSecret(
      const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'old-pw',
        updatedAt: 10,
      ),
    );
    final saved = config('sec-2');
    final other = ServerConfig(
      id: 's2',
      label: 'other',
      host: 'other.example.com',
      username: 'deploy',
      authMethod: AuthMethod.password,
      secretRef: 'sec-1',
      createdAt: 1,
      updatedAt: 1,
    );

    await retireReplacedSecret(
      vault: vault,
      tombstones: InMemoryTombstoneStore(),
      deviceId: 'device-a',
      config: saved,
      retiredSecretRef: 'sec-1',
      servers: [saved, other],
    );

    expect((await vault.getSecret('sec-1'))!.value, 'old-pw');
  });

  test('an entry the config still names is never retired', () async {
    final vault = emptyVault();
    await vault.putSecret(
      const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'old-pw',
        updatedAt: 10,
      ),
    );

    await retireReplacedSecret(
      vault: vault,
      tombstones: InMemoryTombstoneStore(),
      deviceId: 'device-a',
      config: config('sec-1'),
      retiredSecretRef: 'sec-1',
      servers: [],
    );

    expect((await vault.getSecret('sec-1'))!.value, 'old-pw');
  });

  test('retirement outranks the credential clock', () async {
    final vault = emptyVault();
    final tombstones = InMemoryTombstoneStore();
    await vault.putSecret(
      const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'old-pw',
        updatedAt: 500,
      ),
    );
    final saved = config('sec-2', updatedAt: 100);

    await retireReplacedSecret(
      vault: vault,
      tombstones: tombstones,
      deviceId: 'device-a',
      config: saved,
      retiredSecretRef: 'sec-1',
      servers: [saved],
    );

    expect((await tombstones.all()).single.updatedAt, 501);
  });

  test('a changed retained revision aborts before any write', () async {
    final vault = emptyVault();
    const expected = Secret(
      id: 'sec-1',
      kind: SecretKind.password,
      value: 'old-pw',
      updatedAt: 10,
    );
    await vault.putSecret(expected.copyWith(value: 'pulled-pw', updatedAt: 11));

    await expectLater(
      verifyRetainedCredential(
        vault: vault,
        retainedSecretRef: 'sec-1',
        expected: expected,
      ),
      throwsA(isA<RetainedCredentialChanged>()),
    );
  });
}

class _FailingConfigStore implements ConfigStore {
  @override
  Future<void> putServer(ServerConfig config) async =>
      throw StateError('disk full');

  @override
  Future<List<ServerConfig>> listServers() async => [];

  @override
  Future<ServerConfig?> getServer(String id) async => null;

  @override
  Future<void> deleteServer(String id) async {}
}
