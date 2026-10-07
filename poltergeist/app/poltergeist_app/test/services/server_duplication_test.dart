// Ported from Séance app/seance_app/test/server_duplication_test.dart @
// 035b0d8 (tag v0.9.1); see docs/PORTS.md.
// Omissions: the `ServerTile` menu test (Poltergeist's catalog row menu is
// covered in test/ui/sidebar/sidebar_catalog_test.dart), the identity-file
// grant tests (no security-scoped bookmarks — see the ported file), and the
// `secretStillReferenced` group (that helper is not ported: orphaned-secret
// retraction lives in the coordinator).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/dynamic_secret_vault.dart';
import 'package:poltergeist_app/services/secure_master_key.dart'
    show VaultLockedException;
import 'package:poltergeist_app/services/server_duplication.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  group('planServerDuplication', () {
    SecretVault vault() =>
        SecretVault(InMemoryVaultStore(), List.filled(32, 7));

    ServerConfig source({String? secretRef}) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      username: 'deploy',
      authMethod: AuthMethod.privateKey,
      identityFilePath: '/keys/id_ed25519',
      secretRef: secretRef,
      createdAt: 1,
      updatedAt: 2,
    );

    test('planning writes nothing, which is what lets the save be aborted',
        () async {
      final writes = <String>[];
      // The guard runs between the plan and the save, so `SourceServerChanged`
      // can promise nothing was created — but only while planning stays a
      // read. A vault write moved in here would strand an entry no server
      // names, and nothing reference-counts those.
      final store =
          SecretVault(_RecordingVaultStore(writes), List.filled(32, 7));
      await store.putSecret(const Secret(
        id: 'sec-old',
        kind: SecretKind.password,
        value: 'hunter2',
      ));
      // The recorder is proven to record before it is cleared: without this,
      // a `putSecret` that stopped routing through `putSecretBlob` would
      // leave the emptiness assertion below passing for nothing.
      expect(writes, isNotEmpty);
      writes.clear();
      final plan = await planServerDuplication(
        source(secretRef: 'sec-old'),
        vault: store,
        takenLabels: const [],
        id: 'copy-1',
        secretId: 'sec-new',
        now: 100,
      );

      expect(plan.secret?.id, 'sec-new');
      // Every write, not just the one id the plan happens to name: a write
      // under any other id would strand an entry no server references, and
      // nothing reference-counts those.
      expect(writes, isEmpty,
          reason: 'the planned entry is written by the save, not the plan');
      expect((await store.getSecret('sec-old'))?.value, 'hunter2');
    });

    test('copies the credential into a vault entry of its own', () async {
      final store = vault();
      await store.putSecret(const Secret(
        id: 'sec-old',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'phrase',
      ));

      final plan = await planServerDuplication(
        source(secretRef: 'sec-old'),
        vault: store,
        takenLabels: const ['web'],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );

      // Never the original's entry: deleting either server would strip the
      // credential from the other, and edits would rewrite it in place.
      expect(plan.config.secretRef, 'sec-new');
      // Compared as JSON with only the id overridden, like the config's own
      // carryover test — and with the same caveat: a field Secret gains later
      // is only caught here once the fixture above gives it a non-default
      // value, since one left at its default matches on both sides.
      final original = (await store.getSecret('sec-old'))!;
      expect(
        plan.secret!.toJson(),
        {...original.toJson()}..['id'] = 'sec-new',
      );
      // Spelled out as well, because these are the two that stop a copy
      // connecting: the material and the passphrase that opens it.
      expect(plan.secret!.value, 'PEM');
      expect(plan.secret!.keyPassphrase, 'phrase');
      expect(plan.config.label, 'web copy');
      // The plan consults the whole taken set, not just the source's name: a
      // plan that appended " copy" would pass every other test in this group.
      final numbered = await planServerDuplication(
        source(secretRef: 'sec-old'),
        vault: store,
        takenLabels: const ['web', 'web copy'],
        id: 'fresh-2',
        secretId: 'sec-new-2',
        now: 999,
      );
      expect(numbered.config.label, 'web copy 2');
    });

    test('a dangling reference plans as no credential, not as a failure',
        () async {
      // The original is already in this state; the copy is not the place to
      // discover it.
      final plan = await planServerDuplication(
        source(secretRef: 'sec-gone'),
        vault: vault(),
        takenLabels: const [],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );
      expect(plan.secret, isNull);
      expect(plan.config.secretRef, isNull);
    });

    test('a locked vault fails instead of losing the credential', () async {
      // A duplicate that quietly lost its password would look identical in the
      // list and only admit it at connect time.
      await expectLater(
        planServerDuplication(
          source(secretRef: 'sec-old'),
          vault: DynamicSecretVault(InMemoryVaultStore(), () async => null),
          takenLabels: const [],
          id: 'fresh',
          secretId: 'sec-new',
          now: 999,
        ),
        throwsA(isA<VaultLockedException>()),
      );
    });

    test('a server with no credential needs no vault read', () async {
      final plan = await planServerDuplication(
        source(),
        vault: DynamicSecretVault(InMemoryVaultStore(), () async => null),
        takenLabels: const [],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );
      expect(plan.secret, isNull);
    });
  });

  group('duplicationSourceUnchanged', () {
    ServerConfig at(String? ref) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      username: 'deploy',
      secretRef: ref,
      createdAt: 1,
      updatedAt: 2,
    );

    test('only the credential reference decides', () {
      // The vault read a duplicate plans from can wait out a keychain prompt,
      // and a sync round is not behind the same queue the UI's own deletes
      // are: it can withdraw the credential and remove the server first.
      expect(duplicationSourceUnchanged(at('sec-1'), at('sec-1')), isTrue);
      expect(duplicationSourceUnchanged(null, at('sec-1')), isFalse);
      expect(duplicationSourceUnchanged(at('sec-2'), at('sec-1')), isFalse);
      expect(duplicationSourceUnchanged(at(null), at('sec-1')), isFalse);
      // A server that never had one is not "changed" for having none now.
      expect(duplicationSourceUnchanged(at(null), at(null)), isTrue);
      // A rename between the plan and the save costs the copy nothing: it
      // carries its own label, and the credential is what was read early.
      expect(
        duplicationSourceUnchanged(
          at('sec-1').copyWith(label: 'renamed', updatedAt: 9),
          at('sec-1'),
        ),
        isTrue,
      );
    });

    test('the failure says which server and that nothing was created', () {
      // The catalog's toast shows this one verbatim — the "Could not
      // duplicate" prefix belongs to the generic catch, and doubling it up
      // with "Nothing was created." is why this branch exists — so it has to
      // read as a whole sentence rather than a class name.
      final message = const SourceServerChanged('web').toString();
      expect(message, contains('"web"'));
      expect(message, contains('Nothing was created'));
      expect(message, isNot(contains('Exception')));
    });
  });
}

/// Records every mutation so a test can assert a read-only path touched
/// nothing, under any id rather than only the one it expected. `VaultStore`
/// has exactly two mutators; a third would have to be recorded here too, or
/// the emptiness assertion quietly stops covering it.
class _RecordingVaultStore extends InMemoryVaultStore {
  _RecordingVaultStore(this.writes);
  final List<String> writes;

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) async {
    writes.add('put:$id');
    return super.putSecretBlob(id, blob);
  }

  @override
  Future<void> deleteSecret(String id) async {
    writes.add('delete:$id');
    return super.deleteSecret(id);
  }
}
