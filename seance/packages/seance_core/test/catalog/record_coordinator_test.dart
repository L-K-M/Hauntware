import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/catalog/catalog_controller.dart';
import 'package:test/test.dart';

import 'fake_sync_api.dart';

final _key = List<int>.unmodifiable(List<int>.generate(32, (i) => i));
final _epoch = DateTime.utc(2026, 9, 20, 12);
final _epochMs = _epoch.millisecondsSinceEpoch;
const _raceObservationWindow = Duration(milliseconds: 100);

/// A controllable wall clock shared by a "device"'s store and coordinator.
final class _Clock {
  _Clock(this.ms);
  int ms;
  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// One "device": record store + pin store + server store + coordinator.
final class _Device {
  _Device._();

  late final Directory dir;
  late PersistentLocalRecordStore records;
  late final ConflictAwareHostKeyStore hostKeys;
  late final PinVerdictStore verdicts;
  late final HostKeyMutationGate hostKeyMutations;
  late final InMemorySyncTripwireStore tripwires;
  late final RecordCrypto crypto;
  RecordCoordinator? _coordinator;
  RecordCoordinator get coordinator => _coordinator!;
  set coordinator(RecordCoordinator coordinator) => _coordinator = coordinator;
  late final _Clock clock;
  late final bool shared;
  CatalogSnapshot? get catalog => coordinator.catalog;
  late final FileServerConfigStore? servers;
  late final SecretVault? secrets;
  late final _FlakyVaultStore? vaultStore;
  late final String deviceId;

  /// What the server store's late-bound `syncDeviceId` answers; null
  /// models a store that cannot stamp its own tombstone tuple.
  String? storeDeviceId;

  static Future<_Device> create(
    Directory parent,
    String name, {
    bool shared = false,
    bool syncSecrets = false,
    ConflictAwareHostKeyStore? hostKeys,
    PinVerdictStore? pinVerdicts,
  }) async {
    final device = _Device._()
      ..deviceId = 'device-$name'
      ..storeDeviceId = 'device-$name'
      ..clock = _Clock(_epochMs);
    device.dir = await Directory('${parent.path}/$name').create();
    device.records = PersistentLocalRecordStore(
      path: '${device.dir.path}/sync_records.json',
      now: device.clock.call,
    );
    device.hostKeys = hostKeys ?? InMemoryConflictAwareHostKeyStore();
    device.verdicts = pinVerdicts ?? InMemoryPinVerdictStore();
    device.hostKeyMutations = HostKeyMutationGate();
    device.tripwires = InMemorySyncTripwireStore();
    device.crypto = RecordCrypto(RecordCodec(_key));
    device.shared = shared;
    device.servers = shared
        ? FileServerConfigStore(
            path: '${device.dir.path}/servers.json',
            now: device.clock.call,
            syncDeviceId: () => device.storeDeviceId,
          )
        : null;
    device.vaultStore = shared ? _FlakyVaultStore() : null;
    device.secrets = shared ? SecretVault(device.vaultStore!, _key) : null;
    device.rebind(syncSecrets: syncSecrets);
    return device;
  }

  /// A fresh coordinator over the same stores — what the app does when
  /// the device-level "Sync saved passwords & keys" switch flips.
  void rebind({required bool syncSecrets, SyncEnrollmentState? enrollment}) {
    coordinator = RecordCoordinator(
      records: records,
      handlers: const [],
      hostKeys: hostKeys,
      hostKeyMutations: hostKeyMutations,
      crypto: crypto,
      deviceId: deviceId,
      pinVerdicts: verdicts,
      tripwires: tripwires,
      catalogMode: shared ? CatalogMode.shared : CatalogMode.separate,
      pushPolicy: PushPolicy.normal,
      inheritCatalogFrom: shared ? _coordinator : null,
      servers: servers,
      secrets: secrets,
      syncSecrets: syncSecrets,
      enrollment: enrollment,
      now: clock.call,
    );
  }
}

/// Returns a stale read after a concurrent engine pin lands.
final class _RacingHostKeyStore implements ConflictAwareHostKeyStore {
  final _keys = <String, HostKey>{};
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();
  var _gateNextRead = true;

  @override
  Future<List<HostKey>> all() async => _keys.values.toList();

  @override
  Future<HostKey?> get(String host, int port) async {
    final snapshot = _keys['$host:$port'];
    if (!_gateNextRead) return snapshot;

    _gateNextRead = false;
    readStarted.complete();
    await releaseRead.future;
    return snapshot;
  }

  @override
  Future<void> put(HostKey key) async => _keys[key.locator] = key;

  @override
  Future<HostKeyInstallResult> putIfNoConflict(HostKey key) async {
    final snapshot = _keys[key.locator];
    if (_gateNextRead) {
      _gateNextRead = false;
      readStarted.complete();
      await releaseRead.future;
    }

    final current = _keys[key.locator] ?? snapshot;
    if (current != null && current.conflictsWith(key)) {
      return HostKeyInstallResult.conflict;
    }

    _keys[key.locator] = key;
    return HostKeyInstallResult.installed;
  }

  @override
  Future<HostKeyInstallResult> replaceIfCurrent(
    HostKey expected,
    HostKey replacement,
  ) async {
    if (expected.locator != replacement.locator) {
      throw ArgumentError.value(replacement.locator, 'replacement');
    }

    final current = _keys[expected.locator];
    if (current == null ||
        current.fingerprintSha256 != expected.fingerprintSha256) {
      return HostKeyInstallResult.conflict;
    }

    _keys[replacement.locator] = replacement;
    return HostKeyInstallResult.installed;
  }

  void pinFromEngine(HostKey key) => _keys[key.locator] = key;
}

/// Holds a forget mutation so a competing pull can enter concurrently.
final class _RacingPinVerdictStore implements PinVerdictStore {
  final _delegate = InMemoryPinVerdictStore();
  final addStarted = Completer<void>();
  final negativeReadStarted = Completer<void>();
  final releaseAdd = Completer<void>();

  @override
  Future<void> addNegativePin(String locator) async {
    addStarted.complete();
    await releaseAdd.future;
    await _delegate.addNegativePin(locator);
  }

  @override
  Future<Set<String>> negativePins() async {
    final snapshot = await _delegate.negativePins();
    if (!negativeReadStarted.isCompleted) negativeReadStarted.complete();
    return snapshot;
  }

  @override
  Future<void> removeNegativePin(String locator) =>
      _delegate.removeNegativePin(locator);

  @override
  Future<void> recordKeptVerdict(String locator, String rejectedFingerprint) =>
      _delegate.recordKeptVerdict(locator, rejectedFingerprint);

  @override
  Future<String?> rejectedFingerprintFor(String locator) =>
      _delegate.rejectedFingerprintFor(locator);
}

/// A vault store that can fail every read and write, like a locked
/// keychain.
final class _FlakyVaultStore extends InMemoryVaultStore {
  bool failing = false;

  @override
  Future<Uint8List?> getSecretBlob(String id) {
    if (failing) throw StateError('vault locked');
    return super.getSecretBlob(id);
  }

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) {
    if (failing) throw StateError('vault locked');
    return super.putSecretBlob(id, blob);
  }
}

EncryptedRecord _enc(
  String id, {
  int updatedAt = 0,
  String deviceId = 'foreign-device',
  bool deleted = false,
  List<int>? blob,
}) => EncryptedRecord(
  id: id,
  updatedAt: updatedAt,
  deviceId: deviceId,
  deleted: deleted,
  seq: null,
  blob: Uint8List.fromList(blob ?? const [9]),
);

ServerConfig _server(
  String id, {
  String? label,
  String? group,
  String? secretRef,
  bool syncSecret = false,
  bool excludeFromSync = false,
}) => ServerConfig(
  id: id,
  label: label ?? id,
  host: '$id.example.com',
  username: 'deploy',
  group: group,
  secretRef: secretRef,
  syncSecret: syncSecret,
  excludeFromSync: excludeFromSync,
  createdAt: _epochMs,
  updatedAt: _epochMs,
);

Future<EncryptedRecord> _sealServer(
  ServerConfig server, {
  int? updatedAt,
  String deviceId = 'foreign-device',
  bool deleted = false,
}) => RecordCrypto(RecordCodec(_key)).seal(
  DecryptedRecord(
    id: server.id,
    kind: RecordKind.serverConfig,
    updatedAt: updatedAt ?? server.updatedAt,
    deviceId: deviceId,
    deleted: deleted,
    // A tombstone carries no payload — `data` stays absent.
    data: deleted ? const {} : server.toJson(),
  ),
);

Secret _secret(String id, {int? updatedAt}) => Secret(
  id: id,
  kind: SecretKind.password,
  value: 'value-$id',
  updatedAt: updatedAt ?? _epochMs,
);

Future<EncryptedRecord> _sealSecret(
  Secret secret, {
  int? updatedAt,
  String deviceId = 'foreign-device',
  bool deleted = false,
}) => RecordCrypto(RecordCodec(_key)).seal(
  DecryptedRecord(
    id: 'secret:${secret.id}',
    kind: RecordKind.secret,
    updatedAt: updatedAt ?? secret.updatedAt,
    deviceId: deviceId,
    deleted: deleted,
    data: deleted ? const {} : secret.toJson(),
  ),
);

/// The shared-mode save pair the app service performs: persist + seal.
Future<ServerConfig> _saveServer(_Device device, ServerConfig server) async {
  await device.coordinator.writer.saveServer(server);
  return (await device.servers!.byId(server.id))!;
}

Future<void> _deleteServer(_Device device, ServerConfig server) =>
    device.coordinator.writer.deleteServer(server);

void main() {
  late Directory tempDir;
  late FakeSyncApi server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('coordinator_test');
    server = FakeSyncApi();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('hostkey records', () {
    HostKey pin(String host, String fp, {int pinnedAt = 1}) => HostKey(
      host: host,
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: fp,
      pinnedAt: pinnedAt,
    );

    Future<EncryptedRecord> pinRecord(
      HostKey key, {
      String deviceId = 'foreign-device',
    }) => RecordCrypto(RecordCodec(_key)).seal(
      DecryptedRecord(
        id: key.recordId,
        kind: RecordKind.hostKey,
        updatedAt: key.pinnedAt,
        deviceId: deviceId,
        data: key.toJson(),
      ),
    );

    test(
      'a pulled pin installs when no local pin or negative verdict exists',
      () async {
        final device = await _Device.create(tempDir, 'a');
        server.seed(await pinRecord(pin('h.example.com', 'SHA256:AAA')));
        await device.coordinator.runRound(server);
        expect(
          (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
          'SHA256:AAA',
        );
      },
    );

    test('a conflicting pin is quarantined, not applied', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      final result = await device.coordinator.runRound(server);
      expect(
        (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
        'SHA256:LOCAL',
      );
      expect(result.report.pinConflicts.single.locator, 'h.example.com:22');
    });

    test('a pin landing during auto-apply is not overwritten', () async {
      final hostKeys = _RacingHostKeyStore();
      final device = await _Device.create(tempDir, 'a', hostKeys: hostKeys);
      final enginePin = pin('h.example.com', 'SHA256:ENGINE');
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      final round = device.coordinator.runRound(server);
      await hostKeys.readStarted.future;
      hostKeys.pinFromEngine(enginePin);
      hostKeys.releaseRead.complete();
      await round;

      expect(
        (await hostKeys.get('h.example.com', 22))!.fingerprintSha256,
        'SHA256:ENGINE',
      );
    });

    test('a pin landing during accept-pulled is not overwritten', () async {
      final hostKeys = _RacingHostKeyStore();
      final device = await _Device.create(tempDir, 'a', hostKeys: hostKeys);
      final local = pin('h.example.com', 'SHA256:LOCAL');
      final pulled = pin('h.example.com', 'SHA256:PULLED', pinnedAt: 2);
      final engine = pin('h.example.com', 'SHA256:ENGINE', pinnedAt: 3);
      await hostKeys.put(local);
      await device.records.putRemote((await pinRecord(pulled)).withSeq(1));

      final resolution = device.coordinator.acceptPulledPin(
        HostKeyConflict(locator: local.locator, local: local, pulled: pulled),
      );
      await hostKeys.readStarted.future;
      hostKeys.pinFromEngine(engine);
      hostKeys.releaseRead.complete();
      await resolution;

      expect(
        (await hostKeys.get('h.example.com', 22))!.fingerprintSha256,
        'SHA256:ENGINE',
      );
    });

    test('a pin landing during keep-local makes the decision stale', () async {
      final hostKeys = _RacingHostKeyStore();
      final device = await _Device.create(tempDir, 'a', hostKeys: hostKeys);
      final local = pin('h.example.com', 'SHA256:LOCAL');
      final pulled = pin('h.example.com', 'SHA256:PULLED', pinnedAt: 2);
      final engine = pin('h.example.com', 'SHA256:ENGINE', pinnedAt: 3);
      await hostKeys.put(local);
      await device.records.putRemote((await pinRecord(pulled)).withSeq(1));

      final resolution = device.coordinator.keepLocalPin(
        HostKeyConflict(locator: local.locator, local: local, pulled: pulled),
      );
      await hostKeys.readStarted.future;
      hostKeys.pinFromEngine(engine);
      hostKeys.releaseRead.complete();
      await resolution;

      expect(
        await device.verdicts.rejectedFingerprintFor(local.locator),
        isNull,
      );
      final record = await device.records.getRecord(pulled.recordId);
      final decoded = await device.crypto.open(record!);
      expect(HostKey.fromJson(decoded.data).fingerprintSha256, 'SHA256:PULLED');
    });

    test('a forget already in progress prevents auto-apply', () async {
      final verdicts = _RacingPinVerdictStore();
      final device = await _Device.create(tempDir, 'a', pinVerdicts: verdicts);
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      final forget = device.coordinator.writer.forgetPin('h.example.com', 22);
      await verdicts.addStarted.future;
      final round = device.coordinator.runRound(server);

      // An unguarded pull reads the old verdict while forget is held.
      await Future.any([
        verdicts.negativeReadStarted.future,
        Future<void>.delayed(_raceObservationWindow),
      ]);
      verdicts.releaseAdd.complete();
      await Future.wait([forget, round]);

      expect(await device.hostKeys.get('h.example.com', 22), isNull);
    });

    test('a negative pin holds the pulled record unapplied', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.verdicts.addNegativePin('h.example.com:22');
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      await device.coordinator.runRound(server);
      expect(await device.hostKeys.get('h.example.com', 22), isNull);
    });

    test(
      'a kept-local verdict resolves a repeating conflict quietly',
      () async {
        final device = await _Device.create(tempDir, 'a');
        await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
        server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));
        final first = await device.coordinator.runRound(server);

        await device.coordinator.keepLocalPin(first.report.pinConflicts.single);
        final result = await device.coordinator.runRound(server);
        expect(result.report.pinConflicts, isEmpty);
        expect(
          (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
          'SHA256:LOCAL',
        );
      },
    );

    test('keep-local re-push outranks a peer clock', () async {
      final device = await _Device.create(tempDir, 'a');
      final local = pin('h.example.com', 'SHA256:LOCAL');
      final pulledStamp =
          device.clock.ms + const Duration(hours: 1).inMilliseconds;
      final pulled = pin(
        'h.example.com',
        'SHA256:PULLED',
        pinnedAt: pulledStamp,
      );
      await device.hostKeys.put(local);
      await device.records.putRemote((await pinRecord(pulled)).withSeq(1));

      await device.coordinator.keepLocalPin(
        HostKeyConflict(locator: local.locator, local: local, pulled: pulled),
      );

      final record = await device.records.getRecord(local.recordId);
      expect(record, isNotNull);
      expect(record!.updatedAt, greaterThan(pulledStamp));
      final decoded = await device.crypto.open(record);
      expect(HostKey.fromJson(decoded.data).fingerprintSha256, 'SHA256:LOCAL');
    });

    test('a hostkey tombstone never deletes a local pin', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
      server.seed(
        EncryptedRecord(
          id: 'hostkey:h.example.com:22',
          updatedAt: 99999,
          deviceId: 'anyone',
          deleted: true,
          seq: null,
          blob: Uint8List(0),
        ),
      );
      await device.coordinator.runRound(server);
      expect(
        (await device.hostKeys.get('h.example.com', 22))!.fingerprintSha256,
        'SHA256:LOCAL',
      );
    });

    test('publishPin pushes the pin and clears a negative verdict', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.verdicts.addNegativePin('h.example.com:22');
      await device.coordinator.writer.publishPin(
        pin('h.example.com', 'SHA256:NEW', pinnedAt: 7),
      );
      expect(await device.verdicts.negativePins(), isEmpty);
      final record = await device.records.getRecord('hostkey:h.example.com:22');
      expect(record, isNotNull);
      expect(record!.deleted, isFalse);
      expect(await device.records.dirtyRecords(), isNotEmpty);
    });
  });

  group('serverConfig catalog (shared mode)', () {
    ServerConfig config(String id, String label) => ServerConfig(
      id: id,
      label: label,
      host: '$id.example.com',
      port: 22,
      username: 'u',
      authMethod: AuthMethod.privateKey,
      syncSecret: false,
      createdAt: 1,
      updatedAt: 1,
    );

    test('catalog publishes its assigned snapshot synchronously', () {
      late CatalogController catalog;
      List<ServerConfig>? published;
      catalog = CatalogController(
        onReplaced: (snapshot) {
          published = snapshot;
          expect(identical(snapshot, catalog.servers), isTrue);
        },
      );

      catalog.replace([config('b', 'Zulu'), config('a', 'alpha')]);

      expect(published?.map((server) => server.id), ['a', 'b']);
      expect(
        () => published!.add(config('c', 'Charlie')),
        throwsUnsupportedError,
      );
    });

    test('pulled serverConfig records materialize the catalog', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      server.seed(
        await RecordCrypto(RecordCodec(_key)).seal(
          DecryptedRecord(
            id: 'srv-uuid-1',
            kind: RecordKind.serverConfig,
            updatedAt: 1,
            deviceId: 'seance-device',
            data: config('srv-uuid-1', 'web').toJson(),
          ),
        ),
      );
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers.single.label, 'web');
    });

    test('a serverConfig tombstone removes the catalog entry', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      server.seed(
        await RecordCrypto(RecordCodec(_key)).seal(
          DecryptedRecord(
            id: 'srv-uuid-1',
            kind: RecordKind.serverConfig,
            updatedAt: 1,
            deviceId: 'seance-device',
            data: config('srv-uuid-1', 'web').toJson(),
          ),
        ),
      );
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers, hasLength(1));

      server.seed(
        EncryptedRecord(
          id: 'srv-uuid-1',
          updatedAt: 2,
          deviceId: 'seance-device',
          deleted: true,
          seq: null,
          blob: Uint8List(0),
        ),
      );
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers, isEmpty);
    });

    test('separate mode never decrypts prefixless ids', () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(_enc('opaque-id', updatedAt: 1, blob: [1, 2, 3]));
      await device.coordinator.runRound(server);
      // The prefixless record is preserved verbatim, never decrypted.
      expect(
        (await device.records.getRecord('opaque-id'))!.blob,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(await device.tripwires.trippedIds(), isEmpty);
    });
  });

  group('serverConfig write path (04 §4.2, amended)', () {
    test('a delete the store could not tombstone still outranks its live '
        'tuple', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      // The envelope is newer than the payload's own stamp: the row keeps
      // the payload's, the store's tuple the envelope's.
      server.seed(
        await _sealServer(_server('web'), updatedAt: _epochMs + 60000),
      );
      await a.coordinator.runRound(server);
      final row = (await a.servers!.byId('web'))!;
      expect(row.updatedAt, lessThan(_epochMs + 60000));

      a.storeDeviceId = null;
      await _deleteServer(a, row);
      final tombstone = (await a.records.getRecord('web'))!;
      expect(tombstone.deleted, isTrue);
      expect(tombstone.updatedAt, greaterThan(_epochMs + 60000));
      // And it wins on the wire over the live copy the account holds.
      await a.coordinator.runRound(server);
      expect(server.records['web']!.deleted, isTrue);
    });

    test('saveServer seals a prefixless record marked dirty and '
        'refreshes the catalog', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(device, _server('web', label: 'Web', group: 'prod'));

      final dirty = await device.records.dirtyRecords();
      expect(dirty.single.id, 'web');
      final dec = await device.crypto.open(dirty.single);
      expect(dec.kind, RecordKind.serverConfig);
      expect(dec.deviceId, device.deviceId);
      expect(ServerConfig.fromJson(dec.data).group, 'prod');
      expect(device.catalog!.byId('web')!.label, 'Web');
    });

    test('a round pushes in batches the pulled limits allow', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      for (final id in ['web', 'db', 'cache']) {
        await _saveServer(device, _server(id, label: id));
      }
      server.limits = const PushLimits(maxRecordsPerPush: 2);

      final result = await device.coordinator.runRound(server);

      expect(server.pushSizes, [2, 1]);
      expect(result.pushed, 3);
      expect(await device.records.dirtyRecords(), isEmpty);
    });

    test(
      'a record refused as too large stays dirty and the rest push',
      () async {
        final device = await _Device.create(tempDir, 'a', shared: true);
        for (final id in ['web', 'db']) {
          await _saveServer(device, _server(id, label: id));
        }
        server
          ..limits = const PushLimits(maxRecordsPerPush: 1)
          ..tooLarge.add('web');

        final result = await device.coordinator.runRound(server);

        expect(result.refusedIds, ['web']);
        expect(server.records.keys, ['db']);
        expect(
          [for (final r in await device.records.dirtyRecords()) r.id],
          ['web'],
        );
      },
    );

    test('create, edit, and delete converge across shared devices', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      final b = await _Device.create(tempDir, 'b', shared: true);

      await _saveServer(a, _server('web', label: 'v1', group: 'prod'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect((await b.servers!.byId('web'))!.label, 'v1');
      expect(b.catalog!.byId('web')!.group, 'prod');

      b.clock.ms += 1000;
      await _saveServer(b, _server('web', label: 'v2'));
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);
      expect((await a.servers!.byId('web'))!.label, 'v2');

      a.clock.ms += 2000;
      await _deleteServer(a, (await a.servers!.byId('web'))!);
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNull);
      expect(b.catalog!.byId('web'), isNull);
    });

    test('a stale pulled copy cannot resurrect a deleted server', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('doomed'));
      await a.coordinator.runRound(server);
      a.clock.ms += 1000;
      await _deleteServer(a, (await a.servers!.byId('doomed'))!);
      await a.coordinator.runRound(server);
      expect(server.records['doomed']!.deleted, isTrue);

      // A device that never saw the delete pushes an older live copy:
      // it loses the same LWW compare server-side and never lands.
      expect(
        server.seed(
          await _sealServer(
            _server('doomed'),
            updatedAt: 5,
            deviceId: 'stale-device',
          ),
        ),
        isFalse,
      );
      final b = await _Device.create(tempDir, 'b', shared: true);
      await b.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('doomed'), isNull);
      // The tombstone tuple itself is retained in the store.
      expect((await b.servers!.syncTupleOf('doomed'))!.deleted, isTrue);
    });

    test('an excluded server seals a retraction, never live payload', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      final b = await _Device.create(tempDir, 'b', shared: true);
      await _saveServer(a, _server('web', label: 'Web'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNotNull);

      // Exclude: the account copy retracts under a tombstone while the
      // local row survives and stays in this device's catalog.
      a.clock.ms += 1000;
      await a.coordinator.writer.saveServer(
        (await a.servers!.byId(
          'web',
        ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
      );
      final retracted = await a.records.getRecord('web');
      expect(retracted!.deleted, isTrue);
      expect((await a.servers!.byId('web'))!.excludeFromSync, isTrue);
      expect(a.catalog!.byId('web'), isNotNull);

      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNull);
    });

    test('a pulled live record never replaces an excluded local row', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('web', label: 'mine'));
      a.clock.ms += 1000;
      await a.coordinator.writer.saveServer(
        (await a.servers!.byId(
          'web',
        ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
      );

      // A pulled live copy newer than the local stamp still loses to
      // the privacy boundary — and the retraction re-dates once to win
      // the fleet's LWW rather than bidding forever.
      server.seed(
        await _sealServer(
          _server('web', label: 'theirs'),
          updatedAt: a.clock.ms + 5000,
        ),
      );
      await a.coordinator.runRound(server);
      final local = await a.servers!.byId('web');
      expect(local!.label, 'mine');
      expect(local.excludeFromSync, isTrue);
      final counter = await a.records.getRecord('web');
      expect(counter!.deleted, isTrue);
      expect(counter.deviceId, a.deviceId);
      // The re-dated tombstone lands on the server, settling the duel.
      await a.coordinator.runRound(server);
      expect(server.records['web']!.deleted, isTrue);
    });

    test('an own-device tombstone over a live row revives rather than '
        'deleting (reversed exclusion)', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('web', label: 'back'));
      // The fleet still holds this device's earlier exclusion
      // tombstone; the user re-included locally, so the live row must
      // win — re-dated past the tombstone and re-sealed for the push.
      server.seed(
        EncryptedRecord(
          id: 'web',
          updatedAt: _epochMs + 500,
          deviceId: a.deviceId,
          deleted: true,
          seq: null,
          blob: Uint8List(0),
        ),
      );
      await a.coordinator.runRound(server);
      final row = await a.servers!.byId('web');
      expect(row, isNotNull);
      expect(row!.updatedAt, greaterThan(_epochMs + 500));
      final resealed = await a.records.getRecord('web');
      expect(resealed!.deleted, isFalse);
      expect(resealed.deviceId, a.deviceId);
    });

    test('a delete outranks a pulled copy stamped by a faster clock', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      // A peer whose clock runs a minute ahead edited the server.
      server.seed(
        await _sealServer(_server('web').copyWith(updatedAt: _epochMs + 60000)),
      );
      await a.coordinator.runRound(server);
      expect((await a.servers!.byId('web'))!.updatedAt, _epochMs + 60000);

      // Deleted five seconds later by this device's clock: a bare "now"
      // would lose LWW to the very copy it deletes.
      a.clock.ms += 5000;
      await _deleteServer(a, (await a.servers!.byId('web'))!);
      final tombstone = await a.records.getRecord('web');
      expect(tombstone!.deleted, isTrue);
      expect(tombstone.updatedAt, greaterThan(_epochMs + 60000));
      expect(
        (await a.servers!.syncTupleOf('web'))!.updatedAt,
        tombstone.updatedAt,
      );

      await a.coordinator.runRound(server);
      await a.coordinator.runRound(server);
      expect(server.records['web']!.deleted, isTrue);
      expect(await a.servers!.byId('web'), isNull);
    });

    test(
      'an own-device tombstone older than the live row is left alone',
      () async {
        final a = await _Device.create(tempDir, 'a', shared: true);
        await _saveServer(a, _server('web'));
        await a.coordinator.runRound(server);
        // A row newer than its sealed record — a crash between the store
        // write and the seal leaves exactly this.
        a.clock.ms += 2000;
        final saved = await a.servers!.save(
          (await a.servers!.byId('web'))!.copyWith(label: 'current'),
        );
        // This device's old retraction, dated between the two: nothing to
        // revive, and re-dating the row to its stamp + 1 would regress it.
        server.seed(
          EncryptedRecord(
            id: 'web',
            updatedAt: _epochMs + 500,
            deviceId: a.deviceId,
            deleted: true,
            seq: null,
            blob: Uint8List(0),
          ),
        );
        await a.coordinator.runRound(server);
        final row = await a.servers!.byId('web');
        expect(row!.updatedAt, saved.updatedAt);
        expect(row.label, 'current');
      },
    );

    test('the store-loss re-seal retracts an excluded server', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('web'));
      a.clock.ms += 1000;
      await a.coordinator.writer.saveServer(
        (await a.servers!.byId(
          'web',
        ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
      );

      await a.coordinator.reSealAfterStoreLoss();
      expect(
        (await a.records.getRecord('web'))!.deleted,
        isTrue,
        reason: 'live payload would un-exclude the server fleet-wide',
      );
    });

    test('server writes are no-ops outside shared mode', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.coordinator.writer.saveServer(_server('web'));
      await device.coordinator.writer.deleteServer(_server('web'));
      await device.coordinator.writer.secretSaved('s1');
      expect(await device.records.allRecords(), isEmpty);
    });

    test(
      'rebuildCatalog repopulates from the store before any round',
      () async {
        final device = await _Device.create(tempDir, 'a', shared: true);
        await _saveServer(device, _server('web', label: 'Web'));
        final restarted = RecordCoordinator(
          records: device.records,
          handlers: const [],
          hostKeys: device.hostKeys,
          hostKeyMutations: device.hostKeyMutations,
          crypto: device.crypto,
          deviceId: device.deviceId,
          pinVerdicts: device.verdicts,
          tripwires: device.tripwires,
          catalogMode: CatalogMode.shared,
          pushPolicy: PushPolicy.normal,
          servers: device.servers,
          secrets: device.secrets,
          now: device.clock.call,
        );
        final fresh = restarted.catalog!;
        await restarted.rebuildCatalog();
        expect(fresh.byId('web')!.label, 'Web');
      },
    );

    test('a prefixless record the apply cursor already passed backfills '
        'under its own tuple', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      // Sealed by a catalog-only build: stored with a seq the apply
      // cursor has long passed, no materialized tuple.
      await device.records.putRemote(
        (await _sealServer(
          _server('old', label: 'Old'),
          updatedAt: 3,
        )).withSeq(1),
      );
      await device.records.setLastAppliedSeq(5);

      await device.coordinator.rebuildCatalog();
      expect(device.catalog!.byId('old')!.label, 'Old');
      expect(
        (await device.servers!.syncTupleOf('old'))!.deviceId,
        'foreign-device',
      );
    });
  });

  group('secret records (04 §4.2, amended)', () {
    test(
      'a syncSecret server publishes its credential with the config',
      () async {
        final a = await _Device.create(
          tempDir,
          'a',
          shared: true,
          syncSecrets: true,
        );
        final b = await _Device.create(
          tempDir,
          'b',
          shared: true,
          syncSecrets: true,
        );
        await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
        await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));

        await a.coordinator.runRound(server);
        expect(server.records.containsKey('secret:s1'), isTrue);
        await b.coordinator.runRound(server);
        expect(await b.servers!.byId('web'), isNotNull);
        expect((await b.secrets!.getSecret('s1'))!.value, 'value-s1');
      },
    );

    test(
      'a credential stays published while a synced sharer remains',
      () async {
        final a = await _Device.create(
          tempDir,
          'a',
          shared: true,
          syncSecrets: true,
        );
        await a.secrets!.putLocalSecret(
          _secret('shared-s'),
          updatedAt: _epochMs,
        );
        await _saveServer(
          a,
          _server('web-a', secretRef: 'shared-s', syncSecret: true),
        );
        await _saveServer(
          a,
          _server('web-b', secretRef: 'shared-s', syncSecret: true),
        );
        await a.coordinator.runRound(server);
        expect(server.records['secret:shared-s']!.deleted, isFalse);

        // Exclude one sharer — the credential must NOT retract while
        // web-b still syncs it.
        a.clock.ms += 1000;
        await a.coordinator.writer.saveServer(
          (await a.servers!.byId(
            'web-a',
          ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
        );
        expect((await a.records.getRecord('web-a'))!.deleted, isTrue);
        expect(
          (await a.records.getRecord('secret:shared-s'))!.deleted,
          isFalse,
        );
      },
    );

    test(
      'excluding the last synced sharer retracts the secret record',
      () async {
        final a = await _Device.create(
          tempDir,
          'a',
          shared: true,
          syncSecrets: true,
        );
        await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
        await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
        a.clock.ms += 1000;
        await a.coordinator.writer.saveServer(
          (await a.servers!.byId(
            'web',
          ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
        );
        expect((await a.records.getRecord('secret:s1'))!.deleted, isTrue);
        // The vault copy itself is local material — untouched.
        expect(await a.secrets!.getSecret('s1'), isNotNull);
      },
    );

    test('deleting the server retracts its orphaned credential', () async {
      final a = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
      await _deleteServer(a, (await a.servers!.byId('web'))!);
      expect((await a.records.getRecord('web'))!.deleted, isTrue);
      expect((await a.records.getRecord('secret:s1'))!.deleted, isTrue);
    });

    for (final staleRef in <String?>[null, 'old']) {
      test('deleting with a stale snapshot retracts the current credential '
          '(original ref: $staleRef)', () async {
        final a = await _Device.create(
          tempDir,
          'a',
          shared: true,
          syncSecrets: true,
        );
        final original = await _saveServer(a, _server('original'));
        await a.secrets!.putLocalSecret(_secret('other'), updatedAt: _epochMs);
        final other = await _saveServer(
          a,
          _server('other', secretRef: 'other', syncSecret: true),
        );
        if (staleRef != null) {
          await a.secrets!.putLocalSecret(
            _secret(staleRef),
            updatedAt: _epochMs,
          );
        }
        final snapshot = await _saveServer(
          a,
          _server('copy', secretRef: staleRef, syncSecret: staleRef != null),
        );
        a.clock.ms += 1000;
        await a.secrets!.putLocalSecret(
          _secret('current'),
          updatedAt: _epochMs + 9000,
        );
        await _saveServer(
          a,
          snapshot.copyWith(secretRef: 'current', syncSecret: true),
        );
        await a.coordinator.runRound(server);
        expect(server.records['secret:current']!.deleted, isFalse);
        final untouched = {
          for (final id in [
            'original',
            'other',
            'secret:other',
            if (staleRef != null) 'secret:$staleRef',
          ])
            id: (await a.records.getRecord(id))!.toJson(),
        };

        // Undo still holds the snapshot from before the credential edit.
        await _deleteServer(a, snapshot);

        expect(await a.servers!.byId('copy'), isNull);
        expect(a.catalog!.byId('copy'), isNull);
        expect((await a.records.getRecord('copy'))!.deleted, isTrue);
        final retraction = (await a.records.getRecord('secret:current'))!;
        expect(retraction.deleted, isTrue);
        expect(retraction.updatedAt, greaterThan(_epochMs + 9000));
        expect(retraction.deviceId, a.deviceId);
        expect(await a.secrets!.getSecret('current'), isNotNull);
        expect(
          (await a.servers!.byId('original'))!.toJson(),
          original.toJson(),
        );
        expect((await a.servers!.byId('other'))!.toJson(), other.toJson());
        for (final entry in untouched.entries) {
          expect((await a.records.getRecord(entry.key))!.toJson(), entry.value);
        }
        await a.coordinator.runRound(server);
        expect(server.records['secret:current']!.deleted, isTrue);
        expect(server.records['original']!.deleted, isFalse);
        expect(server.records['secret:other']!.deleted, isFalse);
        if (staleRef != null) {
          expect(server.records['secret:$staleRef']!.deleted, isFalse);
        }
      });
    }

    test('re-including after a retraction re-dates the credential past '
        'it', () async {
      final a = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
      a.clock.ms += 1000;
      await a.coordinator.writer.saveServer(
        (await a.servers!.byId(
          'web',
        ))!.copyWith(excludeFromSync: true, updatedAt: a.clock.ms),
      );
      final tombstone = await a.records.getRecord('secret:s1');
      expect(tombstone!.deleted, isTrue);

      a.clock.ms += 1000;
      await a.coordinator.writer.saveServer(
        (await a.servers!.byId(
          'web',
        ))!.copyWith(excludeFromSync: false, updatedAt: a.clock.ms),
      );
      final revived = await a.records.getRecord('secret:s1');
      expect(revived!.deleted, isFalse);
      expect(revived.updatedAt, greaterThan(tombstone.updatedAt));
      // The vault copy carries the bumped stamp, so vault and record
      // agree on the credential's version.
      expect(
        (await a.secrets!.getSecret('s1'))!.updatedAt,
        greaterThan(tombstone.updatedAt),
      );
    });

    test(
      'the retraction outranks a credential stamped past its server',
      () async {
        final a = await _Device.create(
          tempDir,
          'a',
          shared: true,
          syncSecrets: true,
        );
        // The credential was edited well after its server: its stamp
        // advances on its own, so the server's delete stamp alone loses.
        await a.secrets!.putLocalSecret(
          _secret('s1', updatedAt: _epochMs + 9000),
          updatedAt: _epochMs + 9000,
        );
        await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
        await a.coordinator.runRound(server);
        expect(server.records['secret:s1']!.updatedAt, _epochMs + 9000);

        a.clock.ms += 1000;
        await _deleteServer(a, (await a.servers!.byId('web'))!);
        final retraction = await a.records.getRecord('secret:s1');
        expect(retraction!.deleted, isTrue);
        expect(retraction.updatedAt, greaterThan(_epochMs + 9000));
        await a.coordinator.runRound(server);
        expect(server.records['secret:s1']!.deleted, isTrue);
      },
    );

    test("another device's retraction is not re-dated past", () async {
      final a = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      server.seed(
        EncryptedRecord(
          id: 'secret:s1',
          updatedAt: _epochMs + 5000,
          deviceId: 'other-device',
          deleted: true,
          seq: null,
          blob: Uint8List(0),
        ),
      );
      await a.coordinator.runRound(server);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
      // Séance's `_reviveSecrets` only overrules this device's own
      // retraction; the credential stays withdrawn until it is edited.
      expect((await a.secrets!.getSecret('s1'))!.updatedAt, _epochMs);
      expect((await a.records.getRecord('secret:s1'))!.updatedAt, _epochMs);
    });

    test('an excluded-only credential is shielded from pulled '
        'application', () async {
      final device = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      await device.servers!.save(
        _server('priv', secretRef: 's1', excludeFromSync: true),
      );
      server.seed(await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      expect(await device.secrets!.getSecret('s1'), isNull);
    });

    test('a newer local credential is never overwritten by a stale '
        'pull', () async {
      final device = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      await device.secrets!.putLocalSecret(
        _secret('s1', updatedAt: _epochMs + 9000),
        updatedAt: _epochMs + 9000,
      );
      // A non-excluded sharer exists so the shield does not hide the
      // record — the freshness floor is what protects the edit.
      await _saveServer(device, _server('web', secretRef: 's1'));
      server.seed(await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      expect(
        (await device.secrets!.getSecret('s1'))!.updatedAt,
        _epochMs + 9000,
      );
    });

    test('secret tombstones are no-ops — vault material survives', () async {
      final device = await _Device.create(
        tempDir,
        'a',
        shared: true,
        syncSecrets: true,
      );
      await device.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      server.seed(
        EncryptedRecord(
          id: 'secret:s1',
          updatedAt: _epochMs + 99999,
          deviceId: 'anyone',
          deleted: true,
          seq: null,
          blob: Uint8List(0),
        ),
      );
      await device.coordinator.runRound(server);
      expect(await device.secrets!.getSecret('s1'), isNotNull);
    });

    test('a pulled secret never lands on a device without a vault', () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      // Preserved verbatim, never decrypted, never tripped.
      expect(await device.tripwires.trippedIds(), isEmpty);
      expect((await device.records.getRecord('secret:s1'))!.blob, isNotEmpty);
    });
  });

  group('device-level secret switch (Séance syncSecrets)', () {
    test(
      'while off, nothing publishes and no pulled credential lands',
      () async {
        final a = await _Device.create(tempDir, 'a', shared: true);
        await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
        await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
        await a.coordinator.writer.secretSaved('s1');
        expect(await a.records.getRecord('secret:s1'), isNull);

        // A synced sharer exists, so neither the shield nor the freshness
        // floor keeps the pulled credential out — the switch does.
        await _saveServer(
          a,
          _server('web2', secretRef: 's2', syncSecret: true),
        );
        server.seed(await _sealSecret(_secret('s2'), updatedAt: _epochMs + 1));
        await a.coordinator.runRound(server);
        expect(await a.secrets!.getSecret('s2'), isNull);
        expect(server.records.containsKey('secret:s1'), isFalse);
        // Stored, not dropped: turning the switch on later can apply it.
        expect(await a.records.getRecord('secret:s2'), isNotNull);
      },
    );

    test(
      'while off, deleting the server still retracts its credential',
      () async {
        // An earlier session with the switch on may have published it.
        final a = await _Device.create(tempDir, 'a', shared: true);
        await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
        await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
        await _deleteServer(a, (await a.servers!.byId('web'))!);
        expect((await a.records.getRecord('secret:s1'))!.deleted, isTrue);
      },
    );

    test('turning it on publishes opted-in credentials and applies the '
        'pulls it skipped', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(a, _server('web', secretRef: 's1', syncSecret: true));
      await a.secrets!.putLocalSecret(_secret('s3'), updatedAt: _epochMs);
      await _saveServer(a, _server('opted-out', secretRef: 's3'));
      await _saveServer(a, _server('web2', secretRef: 's2', syncSecret: true));
      server.seed(await _sealSecret(_secret('s2'), updatedAt: _epochMs + 1));
      await a.coordinator.runRound(server);
      expect(await a.secrets!.getSecret('s2'), isNull);

      a.rebind(syncSecrets: true);
      await a.coordinator.catchUpSecrets();
      // The skipped pull sits behind the cursor; catch-up applies it.
      expect((await a.secrets!.getSecret('s2'))!.value, 'value-s2');
      await a.coordinator.runRound(server);
      expect(server.records['secret:s1']!.deleted, isFalse);
      // A server's own switch still governs its credential.
      expect(server.records.containsKey('secret:s3'), isFalse);

      // Idempotent: a second pass has nothing left to publish.
      await a.coordinator.catchUpSecrets();
      expect(await a.records.dirtyRecords(), isEmpty);
    });
  });
}
