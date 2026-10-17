import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/engine_sync.dart';
import 'package:seance_core/catalog.dart'
    show FileVaultStore, InMemoryConflictAwareHostKeyStore;
import 'package:seance_core/seance_core.dart'
    show Argon2Params, Secret, SecretKind, SecretVault, secureRandomBytes;
import 'package:test/test.dart';

import '../support/fake_sync_server.dart';

const _baseUrl = 'https://sync.example.com';
const _deviceId = '6f1c2f0e-3c5e-4d7a-9b1e-0a2b3c4d5e6f';

const _enroll = EnrollSync(
  baseUrl: _baseUrl,
  username: fakeSyncUser,
  password: fakeSyncPassword,
  encryptionPassphrase: fakeSyncPassword,
);

void main() {
  late Directory support;
  late FakeSyncServer server;
  late MemoryKeystore keystore;

  setUpAll(() async => server = await FakeSyncServer.create());

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-sync-');
    keystore = MemoryKeystore();
    server
      ..preloginParams = null
      ..nextPullError = null
      ..unreachable = null
      ..pushes = 0
      ..transports = 0
      ..clearRecords();
  });

  tearDown(() => support.deleteSync(recursive: true));

  Future<EngineSync> open({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    String? deviceId = _deviceId,
  }) => EngineSync.open(
    supportDirectory: support,
    access: access,
    deviceId: deviceId,
    hostKeys: InMemoryConflictAwareHostKeyStore(),
    keystore: keystore,
    transport: server.transport,
  );

  File file(String name) => File('${support.path}/$name');

  group('enrollment (03 §4.3 step 1)', () {
    test('signs in, keeps the token and account key in the keystore, and '
        "lists the account's servers", () async {
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      final sync = await open();

      final status = await sync.enroll(_enroll);

      expect(status.phase, SyncPhase.succeeded, reason: status.detail);
      expect(status.operation, SyncOperation.enroll);
      expect(
        status.account,
        const SyncAccountInfo(baseUrl: _baseUrl, username: fakeSyncUser),
      );
      expect(status.passphraseUnverified, isFalse);
      expect(keystore.apiKeys, {'sync.token': 'token-1'});
      expect(keystore.masterKey, server.keys.vaultKey);
      expect(
        jsonDecode(file('sync_enrollment.json').readAsStringSync())['account'],
        {'baseUrl': _baseUrl, 'username': fakeSyncUser, 'mode': 'shared'},
      );
      expect([for (final s in await sync.servers()) s.label], ['alpha']);
      expect(server.pushes, 0);
    });

    test('a restarted engine shows the account and its servers', () async {
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      await (await open()).enroll(_enroll);

      final restarted = await open();

      expect(restarted.account?.username, fakeSyncUser);
      expect([for (final s in await restarted.servers()) s.id], ['srv-a']);
      expect(restarted.issues, isEmpty);
    });

    test('an existing vault is re-keyed to the account key through its '
        'journal', () async {
      final oldKey = secureRandomBytes(32);
      final vault = File('${support.path}/vault.json');
      await SecretVault(FileVaultStore(vault), oldKey).putSecrets([
        Secret(id: 'a', kind: SecretKind.password, value: 'value-a'),
      ]);
      keystore.masterKey = oldKey;

      final status = await (await open()).enroll(_enroll);

      expect(status.phase, SyncPhase.succeeded, reason: status.detail);
      expect(keystore.masterKey, server.keys.vaultKey);
      final secret = await SecretVault(
        FileVaultStore(vault),
        server.keys.vaultKey,
      ).getSecret('a');
      expect(secret?.value, 'value-a');
      expect(File('${vault.path}.rekey').existsSync(), isFalse);
    });

    test('a wrong password persists nothing', () async {
      final sync = await open();

      final status = await sync.enroll(
        const EnrollSync(
          baseUrl: _baseUrl,
          username: fakeSyncUser,
          password: 'wrong',
          encryptionPassphrase: 'wrong',
        ),
      );

      expect(status.failure, SyncFailure.credentialsRejected);
      expect(status.account, isNull);
      expect(keystore.apiKeys, isEmpty);
      expect(file('sync_enrollment.json').existsSync(), isFalse);
    });

    test('weaker key derivation than the suite accepts is refused', () async {
      server.preloginParams = const Argon2Params.fast();

      final status = await (await open()).enroll(_enroll);

      expect(status.failure, SyncFailure.kdfDowngrade);
      expect(keystore.apiKeys, isEmpty);
    });

    test('a server nobody can reach reads as unreachable', () async {
      server.unreachable = const SocketException('connection refused');

      final status = await (await open()).enroll(_enroll);

      expect(status.failure, SyncFailure.unreachable);
    });

    test('a keystore that refuses the token fails the enrollment', () async {
      keystore.refuseWrites = true;

      final status = await (await open()).enroll(_enroll);

      expect(status.failure, SyncFailure.keystoreUnavailable);
    });

    test('a field the suite rule refuses never reaches the server', () async {
      final status = await (await open()).enroll(
        const EnrollSync(
          baseUrl: 'ftp://sync.example.com',
          username: fakeSyncUser,
          password: fakeSyncPassword,
          encryptionPassphrase: fakeSyncPassword,
        ),
      );

      expect(status.failure, SyncFailure.invalidRequest);
      expect(status.detail, 'invalidServerUrl');
      expect(server.transports, 0);
    });

    test('another account is refused while one is enrolled', () async {
      final sync = await open();
      await sync.enroll(_enroll);

      final status = await sync.enroll(
        const EnrollSync(
          baseUrl: 'https://other.example.com',
          username: fakeSyncUser,
          password: fakeSyncPassword,
          encryptionPassphrase: fakeSyncPassword,
        ),
      );

      expect(status.failure, SyncFailure.otherAccount);
      expect(status.account?.baseUrl, _baseUrl);
    });
  });

  group('rounds (03 §4.4, D14)', () {
    test('a round applies what changed and pushes nothing', () async {
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      final sync = await open();
      await sync.enroll(_enroll);
      await server.seedServer(fakeServer('srv-b', 'bravo'));

      final status = await sync.runRound();

      expect(status.phase, SyncPhase.succeeded, reason: status.detail);
      expect(status.operation, SyncOperation.round);
      expect(
        [for (final s in await sync.servers()) s.label],
        ['alpha', 'bravo'],
      );
      expect(server.pushes, 0);
    });

    test('a session the server rejects fails the round', () async {
      final sync = await open();
      await sync.enroll(_enroll);
      keystore.apiKeys['sync.token'] = 'revoked';

      final status = await sync.runRound();

      expect(status.failure, SyncFailure.sessionRejected);
    });

    test('a round needs an enrollment and the keystore', () async {
      final sync = await open();
      expect((await sync.runRound()).failure, SyncFailure.notEnrolled);

      await sync.enroll(_enroll);
      keystore.masterKey = null;
      final status = await sync.runRound();
      expect(status.failure, SyncFailure.keystoreUnavailable);
      expect(status.detail, 'no vault key');
    });
  });

  group('refusals before anything starts (D63)', () {
    test('without exclusive access nothing is signed in or written', () async {
      final sync = await open(access: SupportDirectoryAccess.unguarded);

      expect((await sync.enroll(_enroll)).failure, SyncFailure.directoryShared);
      expect((await sync.runRound()).failure, SyncFailure.directoryShared);
      expect(server.transports, 0);
      expect(support.listSync(), isEmpty);
    });

    test('without a device id nothing is signed in', () async {
      final sync = await open(deviceId: null);

      expect((await sync.enroll(_enroll)).failure, SyncFailure.noDeviceId);
      expect(server.transports, 0);
    });

    test('a damaged state file is reported by name', () async {
      file('pin_verdicts.json').writeAsStringSync('{');

      final sync = await open();

      expect(
        [for (final issue in sync.issues) (issue.fileName, issue.kind)],
        [('pin_verdicts.json', SyncStoreIssueKind.recovered)],
      );
    });
  });
}
