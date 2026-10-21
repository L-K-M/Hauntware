import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/engine_sync.dart';
import 'package:klabautermann_core/src/catalog/engine_vault.dart';
import 'package:klabautermann_core/src/catalog/klabautermann_records.dart';
import 'package:seance_core/catalog.dart'
    show FileVaultStore, InMemoryConflictAwareHostKeyStore, RecordCrypto;
import 'package:seance_core/seance_core.dart'
    show
        Argon2Params,
        DecryptedRecord,
        EncryptedRecord,
        HostKey,
        RecordCodec,
        Secret,
        SecretKind,
        SecretVault,
        ServerConfig,
        secureRandomBytes;
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

  // The engine's vault; [open] wires it to the sync it returns.
  late EngineVault vault;

  Future<EngineSync> open({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    String? deviceId = _deviceId,
  }) async {
    late final EngineSync sync;
    vault = EngineVault(
      support,
      access: access,
      keystore: keystore,
      enrolled: () => sync.account != null,
    );
    return sync = await EngineSync.open(
      supportDirectory: support,
      access: access,
      deviceId: deviceId,
      hostKeys: InMemoryConflictAwareHostKeyStore(),
      keystore: keystore,
      vault: vault,
      transport: server.transport,
    );
  }

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

  group('synced secrets (03 §4.5, SYN-02)', () {
    const secret = Secret(
      id: 'secret-a',
      kind: SecretKind.password,
      value: 'from-seance',
    );

    Future<void> seed({int updatedAt = 1}) async {
      await server.seedServer(
        fakeServer(
          'srv-a',
          'alpha',
        ).copyWith(secretRef: 'secret-a', syncSecret: true),
      );
      await server.seedSecret(secret, updatedAt: updatedAt);
    }

    test(
      'with the switch off a pulled secret stays out of the vault',
      () async {
        await seed();
        final sync = await open();

        final status = await sync.enroll(_enroll);

        expect(status.phase, SyncPhase.succeeded, reason: status.detail);
        expect(await vault.read('secret-a'), isNull);
      },
    );

    test('with the switch on enrollment applies a pulled secret', () async {
      await seed();
      final sync = await open();
      await sync.setSyncSecrets(enabled: true);

      await sync.enroll(_enroll);

      expect((await vault.read('secret-a'))?.value, 'from-seance');
      expect(server.pushes, 0);
    });

    test('turning the switch on applies what rounds skipped', () async {
      await seed();
      final sync = await open();
      await sync.enroll(_enroll);
      expect(await vault.read('secret-a'), isNull);

      await sync.setSyncSecrets(enabled: true);

      expect(sync.syncSecrets, isTrue);
      expect((await vault.read('secret-a'))?.value, 'from-seance');
    });

    test('a local password is replaced only by a strictly newer one', () async {
      final sync = await open();
      await sync.setSyncSecrets(enabled: true);
      await sync.enroll(_enroll);
      await vault.save(secret.copyWith(value: 'typed-here'));
      final local = (await vault.read('secret-a'))!.updatedAt;

      await seed(updatedAt: local - 1);
      await sync.runRound();
      expect((await vault.read('secret-a'))?.value, 'typed-here');

      await server.seedSecret(secret, updatedAt: local + 1);
      await sync.runRound();
      expect((await vault.read('secret-a'))?.value, 'from-seance');
    });
  });

  test('a save asked for during a round waits for it, so a pulled secret '
      'and a typed one never interleave on the vault file', () async {
    final sync = await open();
    await sync.setSyncSecrets(enabled: true);
    await sync.enroll(_enroll);
    await server.seedServer(
      fakeServer(
        'srv-a',
        'alpha',
      ).copyWith(secretRef: 'secret-a', syncSecret: true),
    );
    await server.seedSecret(
      const Secret(
        id: 'secret-a',
        kind: SecretKind.password,
        value: 'from-seance',
      ),
      updatedAt: 1,
    );

    // The save is asked for while the round waits on its pull, inside
    // the round's turn on the vault.
    final order = <String>[];
    final gate = server.pullGate = Completer<void>();
    final held = server.pullHeld = Completer<void>();
    final round = sync.runRound().then((_) => order.add('round'));
    await held.future;
    final saving = vault
        .save(Secret(id: 'secret-b', kind: SecretKind.password, value: 'typed'))
        .then((_) => order.add('save'));
    await pumpEventQueue();
    expect(order, isEmpty);
    gate.complete();
    await Future.wait([round, saving]);

    expect(order, ['round', 'save']);
    expect((await vault.read('secret-a'))?.value, 'from-seance');
    expect((await vault.read('secret-b'))?.value, 'typed');
  });

  group('catalog writes (03 §4.4, M5 plan M05)', () {
    const draft = ServerDraft(
      id: 'srv-new',
      label: 'web-3',
      host: 'web-3.example.com',
      port: 2222,
      username: 'deploy',
      auth: ServerDraftAuth.password,
    );

    Future<DecryptedRecord> openRecord(EncryptedRecord record) async =>
        await RecordCrypto(RecordCodec(server.keys.vaultKey)).open(record);

    Future<ServerConfig?> stored(EngineSync sync, String id) async =>
        (await sync.servers()).where((s) => s.id == id).firstOrNull;

    // An account holding a server, whose record proves the passphrase:
    // until one does, 04 §4.5 holds every push.
    Future<EngineSync> enrolled() async {
      if (server.record('srv-seed') == null) {
        await server.seedServer(fakeServer('srv-seed', 'seed'));
      }
      final sync = await open();
      await sync.enroll(_enroll);
      return sync;
    }

    test('a save seals the server, and the next round pushes exactly its '
        'record', () async {
      final sync = await enrolled();

      final answer = await sync.saveServer(
        const SaveServer(requestId: 'r1', draft: draft),
      );

      expect(answer, isA<CatalogWritten>());
      expect((answer as CatalogWritten).serverId, 'srv-new');
      expect((await stored(sync, 'srv-new'))?.port, 2222);
      expect(server.pushes, 0);

      final status = await sync.runRound();
      expect(status.phase, SyncPhase.succeeded, reason: status.detail);
      expect([for (final r in server.pushed) r.id], ['srv-new']);
      final sealed = await openRecord(server.record('srv-new')!);
      expect(ServerConfig.fromJson(sealed.data).host, 'web-3.example.com');
      expect(sealed.deviceId, _deviceId);
    });

    test('fields the editor does not show keep their stored values', () async {
      await server.seedServer(
        fakeServer(
          'srv-a',
          'alpha',
          jumpHostId: 'srv-j',
        ).copyWith(secretRef: 'secret-a', startDirectory: '/srv/app'),
      );
      final sync = await enrolled();
      final shown = (await sync.serverDraft('srv-a'))!;
      expect(shown.startDirectory, '/srv/app');

      await sync.saveServer(
        SaveServer(
          requestId: 'r1',
          draft: ServerDraft(
            id: shown.id,
            label: 'alpha-renamed',
            host: shown.host,
            port: shown.port,
            username: shown.username,
            auth: shown.auth,
            startDirectory: shown.startDirectory,
          ),
        ),
      );

      final saved = (await stored(sync, 'srv-a'))!;
      expect(saved.label, 'alpha-renamed');
      expect(saved.jumpHostId, 'srv-j');
      expect(saved.secretRef, 'secret-a');
      expect(saved.createdAt, 1);
      expect(saved.startDirectory, '/srv/app');
    });

    test('a save outranks the stored stamp even from a slow clock', () async {
      final ahead = DateTime.now().millisecondsSinceEpoch + 3600000;
      await server.seedServer(
        fakeServer('srv-a', 'alpha').copyWith(updatedAt: ahead),
        updatedAt: ahead,
      );
      final sync = await enrolled();
      final before = (await stored(sync, 'srv-a'))!.updatedAt;

      await sync.saveServer(
        SaveServer(requestId: 'r1', draft: (await sync.serverDraft('srv-a'))!),
      );

      expect((await stored(sync, 'srv-a'))!.updatedAt, before + 1);
    });

    test("a typed password goes to the vault under the server's entry, and "
        'syncs with it while the server opts in', () async {
      final sync = await enrolled();
      await sync.setSyncSecrets(enabled: true);

      final answer = await sync.saveServer(
        const SaveServer(
          requestId: 'r1',
          draft: ServerDraft(
            id: 'srv-new',
            label: 'web-3',
            host: 'web-3.example.com',
            port: 22,
            username: 'deploy',
            auth: ServerDraftAuth.password,
            syncSecret: true,
          ),
          credential: ServerCredentialEntry(password: 'hunter2'),
        ),
      );

      expect((answer as CatalogWritten).credentialWritten, isTrue);
      final ref = (await stored(sync, 'srv-new'))!.secretRef!;
      expect((await vault.read(ref))?.value, 'hunter2');
      await sync.runRound();
      expect([
        for (final r in server.pushed) r.id,
      ], unorderedEquals(['srv-new', 'secret:$ref']));
    });

    test('blank credential boxes keep the stored entry', () async {
      final sync = await enrolled();
      await sync.saveServer(
        const SaveServer(
          requestId: 'r1',
          draft: draft,
          credential: ServerCredentialEntry(password: 'hunter2'),
        ),
      );
      final ref = (await stored(sync, 'srv-new'))!.secretRef;

      final answer = await sync.saveServer(
        const SaveServer(
          requestId: 'r2',
          draft: draft,
          credential: ServerCredentialEntry(),
        ),
      );

      expect((answer as CatalogWritten).credentialWritten, isFalse);
      expect((await stored(sync, 'srv-new'))!.secretRef, ref);
      expect((await vault.read(ref!))?.value, 'hunter2');
    });

    test('a delete persists its tombstone, past the last edit, and retracts '
        'the credential no other server shares', () async {
      final sync = await enrolled();
      await sync.setSyncSecrets(enabled: true);
      await sync.saveServer(
        const SaveServer(
          requestId: 'r1',
          draft: ServerDraft(
            id: 'srv-new',
            label: 'web-3',
            host: 'web-3.example.com',
            port: 22,
            username: 'deploy',
            auth: ServerDraftAuth.password,
            syncSecret: true,
          ),
          credential: ServerCredentialEntry(password: 'hunter2'),
        ),
      );
      await sync.runRound();
      final saved = (await stored(sync, 'srv-new'))!;
      server.pushed.clear();

      final answer = await sync.deleteServer(
        const DeleteServer(requestId: 'r2', serverId: 'srv-new'),
      );

      expect(answer, isA<CatalogWritten>());
      expect(await stored(sync, 'srv-new'), isNull);
      await sync.runRound();
      final tombstones = {for (final r in server.pushed) r.id: r};
      expect(tombstones['srv-new']!.deleted, isTrue);
      expect(tombstones['srv-new']!.updatedAt, greaterThan(saved.updatedAt));
      expect(tombstones['secret:${saved.secretRef}']!.deleted, isTrue);
    });

    test(
      'excluding a server retracts it with a strictly later stamp',
      () async {
        await server.seedServer(fakeServer('srv-a', 'alpha'), updatedAt: 5);
        final sync = await enrolled();
        final shown = (await sync.serverDraft('srv-a'))!;

        await sync.saveServer(
          SaveServer(
            requestId: 'r1',
            draft: ServerDraft(
              id: shown.id,
              label: shown.label,
              host: shown.host,
              port: shown.port,
              username: shown.username,
              auth: shown.auth,
              excludeFromSync: true,
            ),
          ),
        );
        await sync.runRound();

        final retraction = server.pushed.single;
        expect(retraction.deleted, isTrue);
        expect(retraction.updatedAt, greaterThan(5));
        // The row stays on this device.
        expect((await stored(sync, 'srv-a'))!.excludeFromSync, isTrue);
      },
    );

    test("preferences seal as the server's pref record, and none removes "
        'it', () async {
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      final sync = await enrolled();

      await sync.setServerPrefs(
        const SetServerPrefs(
          requestId: 'r1',
          serverId: 'srv-a',
          prefs: ServerPrefs(readOnly: true, marks: {'nginx'}),
        ),
      );
      expect((await sync.serverPrefs())['srv-a']?.readOnly, isTrue);
      await sync.runRound();
      final sealed = await openRecord(
        server.record('klabautermann:pref:srv-a')!,
      );
      expect(sealed.data['protectedTargets'], ['nginx']);

      await sync.setServerPrefs(
        const SetServerPrefs(requestId: 'r2', serverId: 'srv-a', prefs: null),
      );
      expect(await sync.serverPrefs(), isEmpty);
      await sync.runRound();
      final removal = await openRecord(
        server.record('klabautermann:pref:srv-a')!,
      );
      expect(removal.data['removed'], isTrue);
    });

    test('an alert rule seals as its rule record', () async {
      final sync = await enrolled();

      final answer = await sync.putRule(
        const PutRule(
          requestId: 'r1',
          ruleId: 'rule-1',
          rule: ThresholdRule(
            metric: 'cpu.busy',
            op: ThresholdOp.greaterThan,
            raise: ThresholdBound(value: 90, duration: Duration(minutes: 5)),
            clear: ThresholdBound(value: 70, duration: Duration(minutes: 2)),
          ),
          target: 'srv-a',
        ),
      );

      expect(answer, isA<CatalogWritten>());
      await sync.runRound();
      expect(
        [for (final r in server.pushed) r.id],
        ['klabautermann:rule:rule-1'],
      );
      expect(
        await sync.removeRule(
          const RemoveRule(requestId: 'r2', ruleId: 'rule-1'),
        ),
        isA<CatalogWritten>(),
      );
    });

    test('writes are refused before anything is written', () async {
      final unenrolled = await open();
      expect(
        (await unenrolled.saveServer(
              const SaveServer(requestId: 'r1', draft: draft),
            ))
            as CatalogWriteRefused,
        isA<CatalogWriteRefused>().having(
          (r) => r.failure,
          'failure',
          CatalogWriteFailure.notEnrolled,
        ),
      );

      final sync = await enrolled();
      Future<CatalogWriteFailure> failure(Future<EngineEvent> answer) async =>
          ((await answer) as CatalogWriteRefused).failure;
      expect(
        await failure(
          sync.saveServer(
            const SaveServer(
              requestId: 'r2',
              draft: ServerDraft(
                id: 'srv-new',
                label: 'web-3',
                host: ' ',
                port: 22,
                username: 'deploy',
                auth: ServerDraftAuth.agent,
              ),
            ),
          ),
        ),
        CatalogWriteFailure.invalidDraft,
      );
      expect(
        await failure(
          sync.deleteServer(
            const DeleteServer(requestId: 'r3', serverId: 'srv-none'),
          ),
        ),
        CatalogWriteFailure.unknownTarget,
      );
      expect(
        await failure(
          sync.setServerPrefs(
            const SetServerPrefs(
              requestId: 'r4',
              serverId: 'srv-none',
              prefs: ServerPrefs(),
            ),
          ),
        ),
        CatalogWriteFailure.unknownTarget,
      );
      expect([for (final s in await sync.servers()) s.id], ['srv-seed']);
      await sync.runRound();
      expect(server.pushed, isEmpty);
    });
  });

  group('pin publication (D15, M5 plan M07)', () {
    const release = '2026.11.0';

    HostKey pin(String host) => HostKey(
      host: host,
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:$host',
      pinnedAt: 1000,
    );

    ServerConfig excluded(ServerConfig config) =>
        ServerConfig.fromJson({...config.toJson(), 'excludeFromSync': true});

    /// An account holding alpha, bravo through the hop, and xray through
    /// the jump. The hop, the jump and xray are excluded from sync, so
    /// only bravo's route reaches the hop.
    Future<EngineSync> enrolled() async {
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      await server.seedServer(excluded(fakeServer('srv-h', 'hop')));
      await server.seedServer(
        fakeServer('srv-b', 'bravo', jumpHostId: 'srv-h'),
      );
      await server.seedServer(excluded(fakeServer('srv-j', 'jump')));
      await server.seedServer(
        excluded(fakeServer('srv-x', 'xray', jumpHostId: 'srv-j')),
      );
      final sync = await open();
      await sync.enroll(_enroll);
      return sync;
    }

    test('nothing publishes without the assertion, or with no release '
        'offered', () async {
      final sync = await enrolled();

      expect(
        await sync.publishPin(pin('alpha.example.com'), release: release),
        isFalse,
      );
      await sync.setPinPublication(release);
      expect(
        await sync.publishPin(pin('alpha.example.com'), release: null),
        isFalse,
      );
      expect(
        await sync.publishPin(pin('alpha.example.com'), release: '2027.1.0'),
        isFalse,
        reason: 'an assertion names one release',
      );
      expect((await sync.runRound()).phase, SyncPhase.succeeded);
      expect(server.pushed, isEmpty);
    });

    test('with the assertion a synced server\'s pin and its hop\'s publish, '
        'but not one only an excluded server uses', () async {
      final sync = await enrolled();
      await sync.setPinPublication(release);
      expect(sync.pinPublicationAsserted(release), isTrue);

      for (final (host, published) in [
        ('alpha.example.com', true),
        ('hop.example.com', true),
        ('xray.example.com', false),
        ('jump.example.com', false),
        ('elsewhere.example.com', false),
      ]) {
        expect(
          await sync.publishPin(pin(host), release: release),
          published,
          reason: host,
        );
      }
      expect((await sync.runRound()).phase, SyncPhase.succeeded);
      expect(
        {for (final r in server.pushed) r.id},
        {'hostkey:alpha.example.com:22', 'hostkey:hop.example.com:22'},
      );

      // A withdrawal stops publication; what went stays.
      await sync.setPinPublication(null);
      expect(
        await sync.publishPin(pin('bravo.example.com'), release: release),
        isFalse,
      );
    });

    test('the assertion outlives the engine', () async {
      final sync = await enrolled();
      await sync.setPinPublication(release);

      final reopened = await open();
      expect(reopened.pinPublicationAsserted(release), isTrue);
      expect(
        jsonDecode(file('sync_enrollment.json').readAsStringSync()),
        containsPair('seance56Asserted', release),
      );
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

    test('a pulled pref shows for its server once the server is in the '
        'catalog, and the status carries the prefix budget', () async {
      await server.seedKlabautermann(
        KlabautermannRecordType.pref.idOf('srv-b'),
        encodeServerPrefs('srv-b', const ServerPrefs(readOnly: true)),
      );
      await server.seedServer(fakeServer('srv-a', 'alpha'));
      final sync = await open();

      final enrolled = await sync.enroll(_enroll);
      expect(enrolled.phase, SyncPhase.succeeded, reason: enrolled.detail);
      // srv-b is absent: its pref waits.
      expect(await sync.serverPrefs(), isEmpty);
      expect(enrolled.prefixBudget?.usedBytes, greaterThan(0));
      expect(enrolled.prefixBudget?.warns, isFalse);

      await server.seedServer(fakeServer('srv-b', 'bravo'));
      final round = await sync.runRound();
      expect(round.phase, SyncPhase.succeeded, reason: round.detail);
      expect((await sync.serverPrefs())['srv-b']?.readOnly, isTrue);
      expect(file(klabautermannRecordsFileName).existsSync(), isTrue);

      await server.seedKlabautermann(
        KlabautermannRecordType.pref.idOf('srv-b'),
        removedPayload(KlabautermannRecordType.pref.idOf('srv-b')),
        updatedAt: 2,
      );
      final removal = await sync.runRound();
      expect(removal.phase, SyncPhase.succeeded, reason: removal.detail);
      expect(await sync.serverPrefs(), isEmpty);
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
