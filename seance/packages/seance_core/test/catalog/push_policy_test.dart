// The pull-only policy (D14; docs/design/catalog-library.md sections 4,
// 5.1 item 4, 11 and 12(c); 03 §11.2 item 4): a full round under
// PushPolicy.none pulls and applies, marks nothing dirty, sends no push
// and seals nothing, and every CatalogWriter mutation refuses before it
// touches a store.
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'fake_sync_api.dart';

final _key = List<int>.unmodifiable(List<int>.generate(32, (i) => i));
final _epochMs = DateTime.utc(2026, 10, 13, 12).millisecondsSinceEpoch;
const _deviceId = 'device-k';
const _locator = 'h.example.com:22';

/// Counts every seal, so a test can prove pull-only never reaches
/// `crypto.seal` on any path.
final class _CountingCodec extends RecordCodec {
  _CountingCodec(super.vaultKey);

  var seals = 0;

  @override
  Future<EncryptedRecord> encrypt(DecryptedRecord record) {
    seals++;
    return super.encrypt(record);
  }
}

/// Seals the fleet's records: another device's codec, never counted.
final _fleet = RecordCrypto(RecordCodec(_key));

ServerConfig _server(
  String id, {
  String? secretRef,
  bool syncSecret = false,
  int? updatedAt,
}) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: 'deploy',
  secretRef: secretRef,
  syncSecret: syncSecret,
  createdAt: _epochMs,
  updatedAt: updatedAt ?? _epochMs,
);

HostKey _pin(String fingerprint) => HostKey(
  host: 'h.example.com',
  type: 'ssh-ed25519',
  fingerprintSha256: fingerprint,
  pinnedAt: _epochMs,
);

Future<EncryptedRecord> _sealServer(
  ServerConfig server, {
  String deviceId = 'seance-1',
  int? updatedAt,
  bool deleted = false,
}) => _fleet.seal(
  DecryptedRecord(
    id: server.id,
    kind: RecordKind.serverConfig,
    updatedAt: updatedAt ?? server.updatedAt,
    deviceId: deviceId,
    deleted: deleted,
    data: deleted ? const {} : server.toJson(),
  ),
);

Future<EncryptedRecord> _sealPin(HostKey pin) => _fleet.seal(
  DecryptedRecord(
    id: pin.recordId,
    kind: RecordKind.hostKey,
    updatedAt: _epochMs,
    deviceId: 'seance-1',
    data: pin.toJson(),
  ),
);

Future<EncryptedRecord> _sealSecret(Secret secret) => _fleet.seal(
  DecryptedRecord(
    id: 'secret:${secret.id}',
    kind: RecordKind.secret,
    updatedAt: _epochMs,
    deviceId: 'seance-1',
    data: secret.toJson(),
  ),
);

/// One pull-only install: real file stores, so "unchanged" can be checked
/// down to the bytes on disk.
final class _Device {
  _Device(this.dir)
    : records = PersistentLocalRecordStore(
        path: '${dir.path}/sync_records.json',
      ),
      servers = FileServerConfigStore(
        path: '${dir.path}/servers.json',
        syncDeviceId: () => _deviceId,
      );

  final Directory dir;
  final PersistentLocalRecordStore records;
  final FileServerConfigStore servers;
  final codec = _CountingCodec(_key);
  final hostKeys = InMemoryConflictAwareHostKeyStore();
  final verdicts = InMemoryPinVerdictStore();
  final tripwires = InMemorySyncTripwireStore();
  final vault = SecretVault(InMemoryVaultStore(), _key);

  late final coordinator = RecordCoordinator(
    records: records,
    handlers: const [],
    hostKeys: hostKeys,
    hostKeyMutations: HostKeyMutationGate(),
    crypto: RecordCrypto(codec),
    deviceId: _deviceId,
    pinVerdicts: verdicts,
    tripwires: tripwires,
    catalogMode: CatalogMode.shared,
    pushPolicy: PushPolicy.none,
    servers: servers,
    secrets: vault,
    syncSecrets: true,
  );

  /// Everything a refused write could have touched: the server store, the
  /// record store (both as read back and as bytes on disk), the verdicts,
  /// the vault entry and the pins.
  Future<String> state() async {
    String bytes(String name) {
      final file = File('${dir.path}/$name');
      return file.existsSync() ? file.readAsStringSync() : '<absent>';
    }

    return jsonEncode({
      'servers': [for (final s in await servers.load()) s.toJson()],
      'tuples': {
        for (final entry in (await servers.syncTuples()).entries)
          entry.key: entry.value.toJson(),
      },
      'servers.json': bytes('servers.json'),
      'records': [
        for (final r in await records.allRecords())
          [r.id, r.updatedAt, r.deviceId, r.deleted, base64.encode(r.blob)],
      ],
      'dirty': [for (final r in await records.dirtyRecords()) r.id],
      'sync_records.json': bytes('sync_records.json'),
      'negative': (await verdicts.negativePins()).toList()..sort(),
      'kept': await verdicts.rejectedFingerprintFor(_locator),
      'secret': (await vault.getSecret('s1'))?.toJson(),
      'pins': [for (final k in await hostKeys.all()) k.toJson()],
    });
  }
}

void main() {
  late Directory tempDir;
  late FakeSyncApi api;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('push_policy_test');
    api = FakeSyncApi();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test(
    'a pull-only round materializes pulled records and seals nothing',
    () async {
      final device = _Device(tempDir);
      final web = _server('srv-web', secretRef: 's1', syncSecret: true);
      api
        ..seed(await _sealServer(web))
        ..seed(await _sealServer(_server('srv-db')))
        ..seed(await _sealServer(_server('srv-old')))
        ..seed(
          await _sealServer(
            _server('srv-old'),
            updatedAt: _epochMs + 1,
            deleted: true,
          ),
        )
        ..seed(await _sealPin(_pin('SHA256:fleet')))
        ..seed(
          await _sealSecret(
            const Secret(id: 's1', kind: SecretKind.password, value: 'hunter2'),
          ),
        );

      final result = await device.coordinator.runRound(api);

      expect(result.pulled, greaterThan(0));
      expect(result.pushed, 0);
      expect(api.pushCalls, 0);
      expect(await device.records.dirtyRecords(), isEmpty);
      expect(device.codec.seals, 0);
      // The pulled configs still materialize in the catalog, the tombstoned
      // one stays gone, and the pin and the credential land.
      expect(
        [for (final server in device.coordinator.catalog!.servers) server.id],
        ['srv-db', 'srv-web'],
      );
      expect(await device.servers.byId('srv-old'), isNull);
      expect(
        (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
        'SHA256:fleet',
      );
      expect((await device.vault.getSecret('s1'))!.value, 'hunter2');

      // A second round has nothing to push either.
      await device.coordinator.runRound(api);
      expect(api.pushCalls, 0);
      expect(device.codec.seals, 0);
    },
  );

  test('every CatalogWriter mutation refuses with the stores and verdicts '
      'unchanged', () async {
    final device = _Device(tempDir);
    final web = _server('srv-web', secretRef: 's1', syncSecret: true);
    api
      ..seed(await _sealServer(web))
      ..seed(await _sealPin(_pin('SHA256:fleet')))
      ..seed(
        await _sealSecret(
          const Secret(id: 's1', kind: SecretKind.password, value: 'hunter2'),
        ),
      );
    await device.coordinator.runRound(api);
    await device.verdicts.addNegativePin('other.example.com:22');
    final catalog = device.coordinator.catalog!.servers;
    final before = await device.state();
    final writer = device.coordinator.writer;

    expect(
      await writer.saveServer(_server('srv-new')),
      WriteOutcome.refusedPullOnly,
    );
    expect(
      await writer.saveServer(_server('srv-web', updatedAt: _epochMs + 5)),
      WriteOutcome.refusedPullOnly,
    );
    expect(await writer.deleteServer(web), WriteOutcome.refusedPullOnly);
    expect(await writer.secretSaved('s1'), WriteOutcome.refusedPullOnly);
    expect(
      await writer.publishPin(_pin('SHA256:local')),
      WriteOutcome.refusedPullOnly,
    );
    expect(
      await writer.forgetPin('h.example.com', 22),
      WriteOutcome.refusedPullOnly,
    );
    expect(
      await writer.sealLocal(
        DecryptedRecord(
          id: 'srv-web',
          kind: RecordKind.serverConfig,
          updatedAt: _epochMs + 9,
          deviceId: _deviceId,
          data: web.toJson(),
        ),
      ),
      WriteOutcome.refusedPullOnly,
    );

    expect(await device.state(), before);
    expect(identical(device.coordinator.catalog!.servers, catalog), isTrue);
    expect(device.codec.seals, 0);
  });

  test('the re-seal paths and keep-local seal nothing; conflict resolution '
      'still changes the local pin and verdicts', () async {
    final device = _Device(tempDir);
    await device.hostKeys.put(_pin('SHA256:local'));
    api
      ..seed(await _sealServer(_server('srv-web')))
      ..seed(await _sealPin(_pin('SHA256:fleet')));
    final result = await device.coordinator.runRound(api);
    final conflict = result.report.pinConflicts.single;

    expect(await device.coordinator.reSealAfterStoreLoss(), 0);
    expect(await device.coordinator.reSealPendingWrites(), 0);
    await device.coordinator.catchUpSecrets();
    await device.coordinator.keepLocalPin(conflict);

    expect(
      await device.verdicts.rejectedFingerprintFor(_locator),
      'SHA256:fleet',
    );
    expect(await device.coordinator.pinConflicts(), isEmpty);
    expect(await device.records.dirtyRecords(), isEmpty);
    expect(device.codec.seals, 0);

    await device.coordinator.acceptPulledPin(
      HostKeyConflict(
        locator: _locator,
        local: _pin('SHA256:local'),
        pulled: _pin('SHA256:fleet'),
      ),
    );
    expect(
      (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
      'SHA256:fleet',
    );
    expect(device.codec.seals, 0);
  });

  test('an own-device tombstone applies instead of reviving the row', () async {
    final device = _Device(tempDir);
    api.seed(await _sealServer(_server('srv-web')));
    await device.coordinator.runRound(api);
    // A tombstone under this install's id, as an earlier normal-policy
    // life of the device id would have left it.
    api.seed(
      await _sealServer(
        _server('srv-web'),
        deviceId: _deviceId,
        updatedAt: _epochMs + 1,
        deleted: true,
      ),
    );

    await device.coordinator.runRound(api);

    expect(await device.servers.byId('srv-web'), isNull);
    expect(device.coordinator.catalog!.servers, isEmpty);
    expect(await device.records.dirtyRecords(), isEmpty);
    expect(api.pushCalls, 0);
    expect(device.codec.seals, 0);
  });

  test('a record already dirty is never pushed', () async {
    final device = _Device(tempDir);
    // Left dirty by some earlier life of the store: the round's push half
    // is skipped outright, not merely given nothing to send.
    await device.records.putLocal(await _sealServer(_server('srv-left')));
    api.seed(await _sealServer(_server('srv-web')));

    await device.coordinator.runRound(api);

    expect(api.pushCalls, 0);
    expect(api.records.containsKey('srv-left'), isFalse);
    expect(
      [for (final record in await device.records.dirtyRecords()) record.id],
      ['srv-left'],
    );
    expect(device.codec.seals, 0);
  });

  test('a catch-up publishes nothing and never bumps the vault', () async {
    final device = _Device(tempDir);
    // An own-device retraction past the vault's copy: a normal-policy
    // catch-up would re-date the credential in the vault, then seal it.
    api
      ..seed(
        await _sealServer(
          _server('srv-web', secretRef: 's1', syncSecret: true),
        ),
      )
      ..seed(
        await _fleet.seal(
          DecryptedRecord(
            id: 'secret:s1',
            kind: RecordKind.secret,
            updatedAt: _epochMs + 5,
            deviceId: _deviceId,
            deleted: true,
          ),
        ),
      );
    await device.coordinator.runRound(api);
    await device.vault.putSecret(
      Secret(
        id: 's1',
        kind: SecretKind.password,
        value: 'hunter2',
        updatedAt: _epochMs + 1,
      ),
    );

    await device.coordinator.catchUpSecrets();

    expect((await device.vault.getSecret('s1'))!.updatedAt, _epochMs + 1);
    expect(await device.records.dirtyRecords(), isEmpty);
    expect(device.codec.seals, 0);
  });
}
