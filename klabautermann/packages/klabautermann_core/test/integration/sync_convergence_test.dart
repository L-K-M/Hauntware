// Two devices on one sync account through the real seance_sync_server
// (M5 plan M08a; X1, X3, X4): a Séance SyncCoordinator and Klabautermann's
// EngineSync, each over HTTP to the fixture's sync service, never a fake.
//
// run.sh starts the service and exports KLABAUTERMANN_SYNC_SERVER. Outside
// it, run a server binary and point the variable at it, as Poltergeist's
// sync_server_convergence_test.dart documents:
//
//   dart compile exe \
//     seance/packages/seance_sync_server/bin/seance_sync_server.dart
//   SEANCE_OPEN_REGISTRATION=1 SEANCE_BIND=127.0.0.1 SEANCE_PORT=8799 \
//     SEANCE_DB_PATH= ./seance_sync_server
//   KLABAUTERMANN_SYNC_SERVER=http://127.0.0.1:8799 dart test \
//     --tags sync test/integration/sync_convergence_test.dart
//
// The previous-release case also needs KLABAUTERMANN_PREVIOUS_RELEASE_HARNESS,
// the harness test/integration/previous_release.sh builds from the latest
// release tag (X2); run.sh builds and exports it.
@Tags(['integration', 'sync'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/engine_sync.dart';
import 'package:klabautermann_core/src/catalog/engine_vault.dart';
import 'package:klabautermann_core/src/catalog/klabautermann_records.dart'
    show removedPayload;
import 'package:seance_core/catalog.dart'
    show InMemoryConflictAwareHostKeyStore, RecordCrypto;
import 'package:seance_core/seance_core.dart'
    show
        Argon2Params,
        ConfigStore,
        DecryptedRecord,
        EncryptedRecord,
        HostKey,
        HttpSyncClient,
        InMemoryLocalRecordStore,
        RecordCodec,
        RecordKind,
        RegisterRequest,
        ServerConfig,
        SyncCoordinator,
        VaultCrypto,
        secureRandomBytes;
import 'package:test/test.dart';

import '../support/fake_sync_server.dart' show MemoryKeystore;

const _serverVariable = 'KLABAUTERMANN_SYNC_SERVER';
const _harnessVariable = 'KLABAUTERMANN_PREVIOUS_RELEASE_HARNESS';
const _password = 'correct horse battery staple';
const _release = '2026.11.0';

void main() {
  final baseUrl = Platform.environment[_serverVariable] ?? '';
  final skip = baseUrl.isEmpty
      ? 'Set $_serverVariable to a running seance_sync_server to enable.'
      : false;
  final harness = Platform.environment[_harnessVariable] ?? '';
  final previousSkip = skip != false
      ? skip
      : harness.isEmpty
      ? 'Set $_harnessVariable to the previous-release harness to enable.'
      : false;

  late Directory support;
  final clients = <HttpSyncClient>[];

  setUp(() => support = Directory.systemTemp.createTempSync('klab-sync-'));

  tearDown(() {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    support.deleteSync(recursive: true);
  });

  HttpSyncClient client() {
    final api = HttpSyncClient(baseUrl: baseUrl);
    clients.add(api);
    return api;
  }

  /// A fresh account, registered as Séance's enrollment registers one,
  /// with Séance signed in to it and holding [servers].
  Future<_Seance> seanceAccount(List<ServerConfig> servers) async {
    final username =
        'klab-${DateTime.now().microsecondsSinceEpoch}-'
        '${secureRandomBytes(4).map((b) => b.toRadixString(16)).join()}';
    final api = client();
    final salt = secureRandomBytes(16);
    const params = Argon2Params();
    final keys = await VaultCrypto.deriveKeys(
      passphrase: _password,
      salt: salt,
      params: params,
    );
    await api.register(
      RegisterRequest(
        username: username,
        authVerifier: base64.encode(keys.authVerifier),
        argonSalt: base64.encode(salt),
        argonParams: params,
      ),
    );
    final seance = _Seance(username, api, keys.vaultKey);
    for (final server in servers) {
      await seance.configs.putServer(server);
    }
    // Séance's first round puts a record on the account, which proves the
    // passphrase to the next device (04 §4.5).
    await seance.round();
    return seance;
  }

  /// Klabautermann's engine sync, signed in to [seance]'s account.
  Future<EngineSync> klabautermann(_Seance seance) async {
    final keystore = MemoryKeystore();
    late final EngineSync sync;
    final vault = EngineVault(
      support,
      access: SupportDirectoryAccess.exclusive,
      keystore: keystore,
      enrolled: () => sync.account != null,
    );
    sync = await EngineSync.open(
      supportDirectory: support,
      access: SupportDirectoryAccess.exclusive,
      deviceId: '6f1c2f0e-3c5e-4d7a-9b1e-0a2b3c4d5e6f',
      hostKeys: InMemoryConflictAwareHostKeyStore(),
      keystore: keystore,
      vault: vault,
    );
    final status = await sync.enroll(
      EnrollSync(
        baseUrl: baseUrl,
        username: seance.username,
        password: _password,
        encryptionPassphrase: _password,
      ),
    );
    expect(status.phase, SyncPhase.succeeded, reason: status.detail);
    return sync;
  }

  Future<void> round(EngineSync sync) async {
    final status = await sync.runRound();
    expect(status.phase, SyncPhase.succeeded, reason: status.detail);
  }

  Future<ServerConfig?> stored(EngineSync sync, String id) async =>
      (await sync.servers()).where((s) => s.id == id).firstOrNull;

  test('server edits converge both ways, through a delete and an '
      'exclusion', () async {
    final seance = await seanceAccount([_server('srv-alpha', 'alpha')]);
    final sync = await klabautermann(seance);
    expect((await stored(sync, 'srv-alpha'))?.label, 'alpha');

    // Klabautermann adds a server and edits Séance's.
    await sync.saveServer(
      const SaveServer(
        requestId: 'r1',
        draft: ServerDraft(
          id: 'srv-bravo',
          label: 'bravo',
          host: 'bravo.example.com',
          port: 2222,
          username: 'deploy',
          auth: ServerDraftAuth.agent,
        ),
      ),
    );
    final alpha = (await sync.serverDraft('srv-alpha'))!;
    await sync.saveServer(
      SaveServer(
        requestId: 'r2',
        draft: ServerDraft(
          id: alpha.id,
          label: 'alpha renamed',
          host: alpha.host,
          port: alpha.port,
          username: alpha.username,
          auth: alpha.auth,
        ),
      ),
    );
    await round(sync);
    await seance.round();
    expect((await seance.configs.getServer('srv-bravo'))?.port, 2222);
    expect(
      (await seance.configs.getServer('srv-alpha'))?.label,
      'alpha renamed',
    );

    // Séance edits Klabautermann's server back.
    final bravo = (await seance.configs.getServer('srv-bravo'))!;
    await seance.configs.putServer(
      bravo.copyWith(port: 2200, updatedAt: _now()),
    );
    await seance.round();
    await round(sync);
    expect((await stored(sync, 'srv-bravo'))?.port, 2200);

    // A delete in Klabautermann reaches Séance as a tombstone.
    await sync.deleteServer(
      const DeleteServer(requestId: 'r3', serverId: 'srv-bravo'),
    );
    await round(sync);
    await seance.round();
    expect(await seance.configs.getServer('srv-bravo'), isNull);

    // Séance's exclusion retracts alpha from Klabautermann's catalog.
    final renamed = (await seance.configs.getServer('srv-alpha'))!;
    await seance.configs.putServer(
      renamed.copyWith(excludeFromSync: true, updatedAt: _now()),
    );
    await seance.round();
    await round(sync);
    expect(await stored(sync, 'srv-alpha'), isNull);
  }, skip: skip);

  test("Klabautermann's preferences and rules pass through Séance "
      'unapplied and never re-pushed', () async {
    final seance = await seanceAccount([_server('srv-alpha', 'alpha')]);
    final sync = await klabautermann(seance);

    await sync.setServerPrefs(
      const SetServerPrefs(
        requestId: 'r1',
        serverId: 'srv-alpha',
        prefs: ServerPrefs(readOnly: true),
      ),
    );
    await sync.putRule(
      const PutRule(
        requestId: 'r2',
        ruleId: 'rule-1',
        rule: ThresholdRule(
          metric: 'cpu.busy',
          op: ThresholdOp.greaterThan,
          raise: ThresholdBound(value: 90, duration: Duration(minutes: 5)),
          clear: ThresholdBound(value: 70, duration: Duration(minutes: 2)),
        ),
        target: 'srv-alpha',
      ),
    );
    await round(sync);
    final before = await seance.serverRecords();
    const ids = ['klabautermann:pref:srv-alpha', 'klabautermann:rule:rule-1'];
    expect(before.keys, containsAll(ids));

    // Séance pulls them, pushes an edit of its own, and runs again: their
    // sequence numbers never move, so Séance re-pushed neither.
    await seance.round();
    final alpha = (await seance.configs.getServer('srv-alpha'))!;
    await seance.configs.putServer(
      alpha.copyWith(label: 'alpha edited', updatedAt: _now()),
    );
    await seance.round();
    await seance.round();
    final after = await seance.serverRecords();
    for (final id in ids) {
      expect(after[id]!.seq, before[id]!.seq, reason: id);
      expect(after[id]!.blob, before[id]!.blob, reason: id);
    }
    expect((await seance.configs.listServers()).map((s) => s.id), [
      'srv-alpha',
    ]);

    // Klabautermann still reads its own settings after Séance's rounds.
    await round(sync);
    expect((await sync.serverPrefs())['srv-alpha']?.readOnly, isTrue);
    expect((await stored(sync, 'srv-alpha'))?.label, 'alpha edited');
  }, skip: skip);

  test("the previous release's Séance and Poltergeist skip "
      "Klabautermann's records (X2)", () async {
    final seance = await seanceAccount([_server('srv-alpha', 'alpha')]);
    final sync = await klabautermann(seance);
    await sync.setServerPrefs(
      const SetServerPrefs(
        requestId: 'r1',
        serverId: 'srv-alpha',
        prefs: ServerPrefs(readOnly: true),
      ),
    );
    await sync.putRule(
      const PutRule(
        requestId: 'r2',
        ruleId: 'rule-1',
        rule: ThresholdRule(
          metric: 'cpu.busy',
          op: ThresholdOp.greaterThan,
          raise: ThresholdBound(value: 90, duration: Duration(minutes: 5)),
          clear: ThresholdBound(value: 70, duration: Duration(minutes: 2)),
        ),
        target: 'srv-alpha',
      ),
    );
    await round(sync);
    final before = await seance.serverRecords();
    final ids = [
      for (final id in before.keys)
        if (id.startsWith('klabautermann:')) id,
    ];
    expect(
      ids,
      containsAll([
        'klabautermann:pref:srv-alpha',
        'klabautermann:rule:rule-1',
      ]),
    );

    // Each device pulls the account, pushes a record of its own and runs
    // again, so a re-push of Klabautermann's records would show.
    final run = await Process.run(harness, [
      '--server',
      baseUrl,
      '--username',
      seance.username,
      '--password',
      _password,
    ]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final pushed = (jsonDecode('${run.stdout}') as Map).cast<String, String>();

    final after = await seance.serverRecords();
    // Names a record the old release dropped before reading its fields.
    expect(after.keys, containsAll([...pushed.values, ...ids]));
    for (final id in ids) {
      expect(after[id]!.seq, before[id]!.seq, reason: id);
      expect(after[id]!.blob, before[id]!.blob, reason: id);
      expect(after[id]!.deleted, isFalse, reason: id);
    }

    // Klabautermann still reads its settings, and the old Séance's server.
    await round(sync);
    expect((await sync.serverPrefs())['srv-alpha']?.readOnly, isTrue);
    expect(await stored(sync, 'previous-seance-server'), isNotNull);
  }, skip: previousSkip);

  test('a forged unsealed tombstone is ignored, and a sealed removal is '
      'applied (X3)', () async {
    final seance = await seanceAccount([_server('srv-alpha', 'alpha')]);
    final sync = await klabautermann(seance);
    await sync.setServerPrefs(
      const SetServerPrefs(
        requestId: 'r1',
        serverId: 'srv-alpha',
        prefs: ServerPrefs(readOnly: true),
      ),
    );
    await round(sync);
    const id = 'klabautermann:pref:srv-alpha';

    // Anyone holding the session can push a tombstone; it carries no seal.
    final forged = await seance.api.push([
      EncryptedRecord(
        id: id,
        updatedAt: _now() + 1000,
        deviceId: 'forger',
        deleted: true,
        seq: null,
        blob: Uint8List(0),
      ),
    ]);
    expect(forged.results.single.accepted, isTrue);
    await round(sync);
    expect((await sync.serverPrefs())['srv-alpha']?.readOnly, isTrue);

    // A removal sealed with the account key, from another device, is.
    final sealed = await RecordCrypto(RecordCodec(seance.vaultKey)).seal(
      DecryptedRecord(
        id: id,
        kind: RecordKind.klabautermann,
        updatedAt: _now() + 2000,
        deviceId: 'other-klabautermann',
        data: removedPayload(id),
      ),
    );
    expect((await seance.api.push([sealed])).results.single.accepted, isTrue);
    await round(sync);
    expect(await sync.serverPrefs(), isEmpty);
  }, skip: skip);

  test('a published pin installs in Séance, and one that conflicts is '
      'reported and left out (X4)', () async {
    final seance = await seanceAccount([
      _server('srv-alpha', 'alpha'),
      _server('srv-bravo', 'bravo'),
    ]);
    // Séance already trusts another key for bravo.
    await seance.hostKeys.put(_pin('bravo.example.com', 'SHA256:seance'));
    final sync = await klabautermann(seance);
    await sync.setPinPublication(_release);

    for (final host in ['alpha.example.com', 'bravo.example.com']) {
      expect(
        await sync.publishPin(
          _pin(host, 'SHA256:klabautermann'),
          release: _release,
        ),
        isTrue,
        reason: host,
      );
    }
    await round(sync);
    await seance.round();

    final alpha = await seance.hostKeys.get('alpha.example.com', 22);
    expect(alpha?.fingerprintSha256, 'SHA256:klabautermann');
    final bravo = await seance.hostKeys.get('bravo.example.com', 22);
    expect(bravo?.fingerprintSha256, 'SHA256:seance');
    expect(
      seance.coordinator.pinConflicts.map((c) => c.pulled.host),
      contains('bravo.example.com'),
    );
  }, skip: skip);
}

int _now() => DateTime.now().millisecondsSinceEpoch;

ServerConfig _server(String id, String label) => ServerConfig(
  id: id,
  label: label,
  host: '$label.example.com',
  port: 22,
  username: 'deploy',
  createdAt: _now(),
  updatedAt: _now(),
);

HostKey _pin(String host, String fingerprint) => HostKey(
  host: host,
  port: 22,
  type: 'ssh-ed25519',
  fingerprintSha256: fingerprint,
  pinnedAt: _now(),
);

/// A Séance device: its catalog, pin store and the pinned seance_core
/// SyncCoordinator over HTTP.
final class _Seance {
  factory _Seance(String username, HttpSyncClient api, List<int> vaultKey) {
    final configs = _ListConfigStore();
    final hostKeys = InMemoryConflictAwareHostKeyStore();
    return _Seance._(
      username,
      api,
      vaultKey,
      configs,
      hostKeys,
      SyncCoordinator(
        configStore: configs,
        hostKeyStore: hostKeys,
        codec: RecordCodec(vaultKey),
        local: InMemoryLocalRecordStore(),
        deviceId: 'seance-device',
      ),
    );
  }

  _Seance._(
    this.username,
    this.api,
    this.vaultKey,
    this.configs,
    this.hostKeys,
    this.coordinator,
  );

  final String username;
  final HttpSyncClient api;
  final List<int> vaultKey;
  final _ListConfigStore configs;
  final InMemoryConflictAwareHostKeyStore hostKeys;
  final SyncCoordinator coordinator;

  Future<void> round() => coordinator.run(api);

  /// The server's record for each id, from a full pull.
  Future<Map<String, EncryptedRecord>> serverRecords() async => {
    for (final record in (await api.pull(since: 0)).records) record.id: record,
  };
}

final class _ListConfigStore extends ConfigStore {
  final _servers = <String, ServerConfig>{};

  @override
  Future<List<ServerConfig>> listServers() async => _servers.values.toList();
  @override
  Future<ServerConfig?> getServer(String id) async => _servers[id];
  @override
  Future<void> putServer(ServerConfig config) async =>
      _servers[config.id] = config;
  @override
  Future<void> deleteServer(String id) async => _servers.remove(id);
}
