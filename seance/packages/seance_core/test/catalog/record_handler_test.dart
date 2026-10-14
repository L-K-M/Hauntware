import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'fake_sync_api.dart';

final _key = List<int>.unmodifiable(List<int>.generate(32, (i) => i));

/// A product handler that claims [prefix] and applies nothing.
final class _StubHandler implements RecordHandler {
  _StubHandler(this.prefix, {this.trialDecryptable = true});

  @override
  final String? prefix;

  @override
  final bool trialDecryptable;

  @override
  ApplyPhase get phase => ApplyPhase.configs;

  @override
  RecordKind get kind => RecordKind.bookmark;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async => ApplyOutcome.skipped;

  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async => ApplyOutcome.skipped;

  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async => 0;

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async =>
      null;
}

/// A server store that holds rows in memory; only what the coordinator's
/// shared mode reads.
final class _MemoryServerStore implements SyncTrackingServerStore {
  final _rows = <String, ServerConfig>{};
  final _tuples = <String, ServerSyncTuple>{};

  @override
  Future<List<ServerConfig>> load() async => _rows.values.toList();

  @override
  Future<ServerConfig?> byId(String id) async => _rows[id];

  @override
  Future<ServerConfig> save(ServerConfig server) async {
    _rows[server.id] = server;
    _tuples[server.id] = ServerSyncTuple(
      updatedAt: server.updatedAt,
      deviceId: 'device-a',
    );
    return server;
  }

  @override
  Future<bool> remove(String id) async => _rows.remove(id) != null;

  @override
  Future<ServerSyncTuple?> syncTupleOf(String id) async => _tuples[id];

  @override
  Future<Map<String, ServerSyncTuple>> syncTuples() async => Map.of(_tuples);

  @override
  Future<void> applySyncedRecord(
    ServerConfig server,
    ServerSyncTuple winner,
  ) async {
    _rows[server.id] = server;
    _tuples[server.id] = winner;
  }

  @override
  Future<void> removeSyncedRecord(String id, ServerSyncTuple tombstone) async {
    _rows.remove(id);
    _tuples[id] = tombstone;
  }
}

ServerConfig _server(String id) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

late Directory _tempDir;
var _storeCount = 0;

/// A fresh record store under the test's temp directory.
SyncRecordStore _records() =>
    PersistentLocalRecordStore(path: '${_tempDir.path}/${_storeCount++}.json');

RecordCoordinator _coordinator({
  required CatalogMode catalogMode,
  List<RecordHandler> handlers = const [],
  SyncTrackingServerStore? servers,
  SecretVault? secrets,
  void Function(List<ServerConfig> snapshot)? onCatalogReplaced,
  RecordCoordinator? inheritCatalogFrom,
  SyncRecordStore? records,
}) => RecordCoordinator(
  records: records ?? _records(),
  handlers: handlers,
  hostKeys: InMemoryConflictAwareHostKeyStore(),
  hostKeyMutations: HostKeyMutationGate(),
  crypto: RecordCrypto(RecordCodec(_key)),
  deviceId: 'device-a',
  pinVerdicts: InMemoryPinVerdictStore(),
  tripwires: InMemorySyncTripwireStore(),
  catalogMode: catalogMode,
  pushPolicy: PushPolicy.normal,
  onCatalogReplaced: onCatalogReplaced,
  inheritCatalogFrom: inheritCatalogFrom,
  servers: servers,
  secrets: secrets,
);

void main() {
  setUp(() async {
    _tempDir = await Directory.systemTemp.createTemp('record_handler_test');
  });

  tearDown(() async {
    await _tempDir.delete(recursive: true);
  });

  group('SyncTuple.outranks', () {
    const base = SyncTuple(updatedAt: 10, deviceId: 'm');

    test('a later stamp outranks whatever the device ids', () {
      expect(
        const SyncTuple(updatedAt: 11, deviceId: 'a').outranks(base),
        isTrue,
      );
      expect(
        const SyncTuple(updatedAt: 9, deviceId: 'z').outranks(base),
        isFalse,
      );
    });

    test('an equal stamp breaks the tie on device id, and an exact tie '
        'applies', () {
      expect(
        const SyncTuple(updatedAt: 10, deviceId: 'n').outranks(base),
        isTrue,
      );
      expect(
        const SyncTuple(updatedAt: 10, deviceId: 'l').outranks(base),
        isFalse,
      );
      expect(base.outranks(base), isTrue);
    });

    test('the deleted flag takes no part in the order', () {
      const tombstone = SyncTuple(updatedAt: 10, deviceId: 'm', deleted: true);
      expect(tombstone.outranks(base), isTrue);
      expect(base.outranks(tombstone), isTrue);
    });
  });

  group('isDecryptableSyncId is derived from handler registration', () {
    test('the library handlers open prefixless and hostkey: ids, never '
        'secret:', () {
      expect(isDecryptableSyncId('srv-uuid-1', const []), isTrue);
      expect(isDecryptableSyncId('hostkey:[2001:db8::1]:22', const []), isTrue);
      expect(isDecryptableSyncId('secret:s1', const []), isFalse);
    });

    test('a product prefix opens only while a handler registers it', () {
      expect(isDecryptableSyncId('bookmark:b1', const []), isFalse);
      expect(
        isDecryptableSyncId('bookmark:b1', [_StubHandler('bookmark')]),
        isTrue,
      );
      expect(
        isDecryptableSyncId('klabautermann:pref:p1', [
          _StubHandler('klabautermann', trialDecryptable: false),
        ]),
        isFalse,
      );
    });

    test('unregistered prefixes are never opened', () {
      final handlers = [_StubHandler('bookmark')];
      expect(isDecryptableSyncId('snippet:s1', handlers), isFalse);
      expect(isDecryptableSyncId('klabautermann:rule:r1', handlers), isFalse);
    });
  });

  group('RecordCoordinator wiring', () {
    test('shared mode needs a server store, and separate mode refuses one', () {
      expect(
        () => _coordinator(catalogMode: CatalogMode.shared),
        throwsArgumentError,
      );
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.separate,
          servers: _MemoryServerStore(),
        ),
        throwsArgumentError,
      );
    });

    test('separate mode has no vault, no catalog and no catalog callback', () {
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.separate,
          secrets: SecretVault(InMemoryVaultStore(), _key),
        ),
        throwsArgumentError,
      );
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.separate,
          onCatalogReplaced: (_) {},
        ),
        throwsArgumentError,
      );
      expect(_coordinator(catalogMode: CatalogMode.separate).catalog, isNull);
    });

    test('a product handler cannot claim a library prefix or share one', () {
      for (final prefix in [null, 'hostkey', 'secret']) {
        expect(
          () => _coordinator(
            catalogMode: CatalogMode.separate,
            handlers: [_StubHandler(prefix)],
          ),
          throwsArgumentError,
          reason: 'prefix $prefix',
        );
      }
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.separate,
          handlers: [_StubHandler('bookmark'), _StubHandler('bookmark')],
        ),
        throwsArgumentError,
      );
    });

    test(
      'an inherited catalog keeps its identity, contents and callback',
      () async {
        final records = _records();
        final servers = _MemoryServerStore();
        await servers.save(_server('web'));
        final published = <List<String>>[];
        final first = _coordinator(
          catalogMode: CatalogMode.shared,
          servers: servers,
          records: records,
          onCatalogReplaced: (snapshot) =>
              published.add([for (final server in snapshot) server.id]),
        );
        await first.rebuildCatalog();

        final second = _coordinator(
          catalogMode: CatalogMode.shared,
          servers: servers,
          records: records,
          inheritCatalogFrom: first,
        );
        expect(identical(second.catalog, first.catalog), isTrue);
        expect(second.catalog!.byId('web'), isNotNull);

        await servers.save(_server('db'));
        await second.rebuildCatalog();
        expect(published, [
          ['web'],
          ['db', 'web'],
        ]);
      },
    );

    test('only a shared coordinator inherits, and never with a second '
        'callback', () {
      final servers = _MemoryServerStore();
      final shared = _coordinator(
        catalogMode: CatalogMode.shared,
        servers: servers,
      );
      final separate = _coordinator(catalogMode: CatalogMode.separate);
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.shared,
          servers: servers,
          inheritCatalogFrom: separate,
        ),
        throwsArgumentError,
      );
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.separate,
          inheritCatalogFrom: shared,
        ),
        throwsArgumentError,
      );
      expect(
        () => _coordinator(
          catalogMode: CatalogMode.shared,
          servers: servers,
          inheritCatalogFrom: shared,
          onCatalogReplaced: (_) {},
        ),
        throwsArgumentError,
      );
    });

    test('a record no handler claims stays stored, unapplied and '
        'untripped', () async {
      final api = FakeSyncApi()
        ..seed(
          EncryptedRecord(
            id: 'klabautermann:pref:p1',
            updatedAt: 1,
            deviceId: 'foreign',
            deleted: false,
            seq: null,
            blob: await VaultCrypto.sealJson(_key, const {
              'kind': 'klabautermann',
              'data': <String, Object?>{},
            }),
          ),
        );
      final records = _records();
      final tripwires = InMemorySyncTripwireStore();
      final coordinator = RecordCoordinator(
        records: records,
        handlers: const [],
        hostKeys: InMemoryConflictAwareHostKeyStore(),
        hostKeyMutations: HostKeyMutationGate(),
        crypto: RecordCrypto(RecordCodec(_key)),
        deviceId: 'device-a',
        pinVerdicts: InMemoryPinVerdictStore(),
        tripwires: tripwires,
        catalogMode: CatalogMode.separate,
        pushPolicy: PushPolicy.normal,
      );

      final result = await coordinator.runRound(api);
      expect(result.report.appliedIds, isEmpty);
      expect(await tripwires.trippedIds(), isEmpty);
      expect(await records.getRecord('klabautermann:pref:p1'), isNotNull);
    });
  });
}
