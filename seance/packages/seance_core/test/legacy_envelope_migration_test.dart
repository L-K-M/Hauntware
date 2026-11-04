import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _key = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

Future<EncryptedRecord> _legacyLive({
  required String id,
  required String kind,
  required Map<String, dynamic> data,
  int updatedAt = 999999,
  String deviceId = 'untrusted-device',
  int seq = 7,
}) async => EncryptedRecord(
  envelopeVersion: 1,
  id: id,
  updatedAt: updatedAt,
  deviceId: deviceId,
  deleted: false,
  seq: seq,
  blob: await VaultCrypto.sealJson(_key, {'kind': kind, 'data': data}),
);

void main() {
  final codec = RecordCodec(_key);

  test(
    'migration uses only the matching authenticated current tuple',
    () async {
      final data = <String, dynamic>{'id': 'server-a', 'label': 'A'};
      final old = await _legacyLive(
        id: 'server-a',
        kind: RecordKind.serverConfig.name,
        data: data,
      );
      final current = await codec.encrypt(
        DecryptedRecord(
          id: 'server-a',
          kind: RecordKind.serverConfig,
          updatedAt: 40,
          deviceId: 'trusted-device',
          data: data,
        ),
      );

      final migrations = await buildConservativeLegacyMigrations(
        [old],
        current: Future.value([current]),
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      );

      expect(migrations, hasLength(1));
      final replacement = migrations.single.replacement;
      expect(replacement.id, 'server-a');
      expect(replacement.updatedAt, 40);
      expect(replacement.deviceId, 'trusted-device');
      expect(replacement.seq, isNull);
      expect(replacement.blob, orderedEquals(current.blob));
    },
  );

  test('transplanted ids and unknown kinds remain held', () async {
    final data = <String, dynamic>{'id': 'canonical', 'label': 'A'};
    final transplanted = await _legacyLive(
      id: 'other-id',
      kind: RecordKind.serverConfig.name,
      data: data,
    );
    final unknown = await _legacyLive(
      id: 'canonical',
      kind: 'futureKind',
      data: data,
    );
    final current = await codec.encrypt(
      DecryptedRecord(
        id: 'canonical',
        kind: RecordKind.serverConfig,
        updatedAt: 40,
        deviceId: 'trusted-device',
        data: data,
      ),
    );

    final migrations = await buildConservativeLegacyMigrations(
      [transplanted, unknown],
      current: Future.value([current]),
      openLegacy: codec.decryptLegacyForMigration,
      openCurrent: codec.decrypt,
    );

    expect(migrations, isEmpty);
  });

  test('different local content and ambiguous matches remain held', () async {
    final old = await _legacyLive(
      id: 'server-a',
      kind: RecordKind.serverConfig.name,
      data: const {'id': 'server-a', 'label': 'Old'},
    );
    final different = await codec.encrypt(
      const DecryptedRecord(
        id: 'server-a',
        kind: RecordKind.serverConfig,
        updatedAt: 40,
        deviceId: 'trusted-device',
        data: {'id': 'server-a', 'label': 'New'},
      ),
    );
    expect(
      await buildConservativeLegacyMigrations(
        [old],
        current: Future.value([different]),
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      ),
      isEmpty,
    );

    final first = await codec.encrypt(
      const DecryptedRecord(
        id: 'server-a',
        kind: RecordKind.serverConfig,
        updatedAt: 41,
        deviceId: 'trusted-a',
        data: {'id': 'server-a', 'label': 'Old'},
      ),
    );
    final second = await codec.encrypt(
      const DecryptedRecord(
        id: 'server-a',
        kind: RecordKind.serverConfig,
        updatedAt: 42,
        deviceId: 'trusted-b',
        data: {'id': 'server-a', 'label': 'Old'},
      ),
    );
    expect(
      await buildConservativeLegacyMigrations(
        [old],
        current: Future.value([first, second]),
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      ),
      isEmpty,
    );
  });

  test(
    'legacy tombstone needs an authenticated same-id delete intent',
    () async {
      final old = EncryptedRecord.tombstone(
        id: 'server-a',
        updatedAt: 999999,
        deviceId: 'untrusted-device',
      ).withSeq(8);
      final trusted = await codec.encrypt(
        const DecryptedRecord(
          id: 'server-a',
          kind: RecordKind.serverConfig,
          updatedAt: 50,
          deviceId: 'trusted-device',
          deleted: true,
        ),
      );

      expect(
        await buildConservativeLegacyMigrations(
          [old],
          current: Future.value(const []),
          openLegacy: codec.decryptLegacyForMigration,
          openCurrent: codec.decrypt,
        ),
        isEmpty,
      );
      final migrations = await buildConservativeLegacyMigrations(
        [old],
        current: Future.value([trusted]),
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      );
      expect(migrations.single.replacement.deleted, isTrue);
      expect(migrations.single.replacement.updatedAt, 50);
      expect(migrations.single.replacement.deviceId, 'trusted-device');
    },
  );

  test(
    'migration network runs outside local phases and resumes after failure',
    () async {
      final data = <String, dynamic>{'id': 'server-a', 'label': 'A'};
      final old = await _legacyLive(
        id: 'server-a',
        kind: RecordKind.serverConfig.name,
        data: data,
      );
      final current = await codec.encrypt(
        DecryptedRecord(
          id: 'server-a',
          kind: RecordKind.serverConfig,
          updatedAt: 40,
          deviceId: 'trusted-device',
          data: data,
        ),
      );
      final store = InMemoryLocalRecordStore();
      await store.putLocal(current);
      var inLocal = false;
      Future<T> locally<T>(Future<T> Function() action) async {
        expect(inLocal, isFalse);
        inLocal = true;
        try {
          return await action();
        } finally {
          inLocal = false;
        }
      }

      final api = _MigrationApi(old, () => inLocal)..failNextMigration = true;
      await expectLater(
        migrateLegacyEnvelopes(
          api,
          store: store,
          runLocal: locally,
          openLegacy: codec.decryptLegacyForMigration,
          openCurrent: codec.decrypt,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await store.recordEnvelopeFloor(), 1);

      await migrateLegacyEnvelopes(
        api,
        store: store,
        runLocal: locally,
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      );
      expect(api.migrated, 1);
      expect(await store.recordEnvelopeFloor(), 2);
    },
  );

  test('paged pulls reject a floor change inside one snapshot', () async {
    final api = _FloorChangingApi();
    await expectLater(
      pullPages(api, since: 0).toList(),
      throwsA(isA<FormatException>()),
    );
  });

  for (final code in ['payload_too_large', 'account_quota_exceeded']) {
    test('a $code migration refusal still permits ordinary sync', () async {
      const config = ServerConfig(
        id: 'server-a',
        label: 'A',
        host: 'a.test',
        username: 'user',
        createdAt: 1,
        updatedAt: 40,
      );
      final configs = InMemoryConfigStore();
      await configs.putServer(config);
      final old = await _legacyLive(
        id: config.id,
        kind: RecordKind.serverConfig.name,
        data: config.toJson(),
      );
      final store = InMemoryLocalRecordStore();
      final api = _RefusedMigrationApi(old, code);
      final coordinator = SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: store,
        deviceId: 'trusted-device',
      );

      await coordinator.run(api);

      expect(api.migrationAttempts, 1);
      expect(api.finalizeCalls, 1);
      expect(api.pulls, greaterThan(0));
      expect(api.pushes, 1);
      expect(await store.recordEnvelopeFloor(), 1);
    });
  }

  test('legacy migration rejects a backward page cursor', () async {
    final api = _RegressingCursorApi();
    await expectLater(
      migrateLegacyEnvelopes(
        api,
        store: InMemoryLocalRecordStore(),
        runLocal: <T>(action) => action(),
        openLegacy: codec.decryptLegacyForMigration,
        openCurrent: codec.decrypt,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(api.calls, 2);
  });

  for (final id in ['unclaimed:a', 'prefixless', 'secret:a', 'hostkey:a']) {
    test('a legacy $id row cannot enter an opaque or held mirror', () async {
      final directory = await Directory.systemTemp.createTemp('legacy_mirror');
      try {
        final records = PersistentLocalRecordStore(
          path: '${directory.path}/records.json',
        );
        final coordinator = RecordCoordinator(
          records: records,
          handlers: const [],
          hostKeys: InMemoryConflictAwareHostKeyStore(),
          hostKeyMutations: HostKeyMutationGate(),
          crypto: RecordCrypto(codec),
          deviceId: 'device-a',
          pinVerdicts: InMemoryPinVerdictStore(),
          tripwires: InMemorySyncTripwireStore(),
          catalogMode: CatalogMode.separate,
          pushPolicy: PushPolicy.none,
          enrollment: _HeldEnrollment(),
        );
        final legacy = await _legacyLive(
          id: id,
          kind: RecordKind.hostKey.name,
          data: const {},
        );
        await coordinator.runRound(_RowsApi([legacy]));
        expect(await records.getRecord(id), isNull);

        final migrated = await codec.encrypt(
          DecryptedRecord(
            id: id,
            kind: RecordKind.hostKey,
            updatedAt: 1,
            deviceId: 'trusted',
          ),
        );
        await coordinator.runRound(_RowsApi([migrated.withSeq(8)]));
        expect((await records.getRecord(id))?.envelopeVersion, 2);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }

  test('another device may finalize between legacy pages', () async {
    final old = await _legacyLive(
      id: 'server-a',
      kind: RecordKind.serverConfig.name,
      data: const {'id': 'server-a', 'label': 'A'},
    );
    final store = InMemoryLocalRecordStore();
    final api = _ConcurrentFinalizeApi(old);

    await migrateLegacyEnvelopes(
      api,
      store: store,
      runLocal: <T>(action) => action(),
      openLegacy: codec.decryptLegacyForMigration,
      openCurrent: codec.decrypt,
    );

    expect(api.calls, 2);
    expect(api.migrationCalls, 0);
    expect(await store.recordEnvelopeFloor(), 2);
  });

  test('an empty legacy scan finalizes without local preparation', () async {
    final store = InMemoryLocalRecordStore();
    final api = _EmptyLegacyApi();
    var preparations = 0;

    await migrateLegacyEnvelopes(
      api,
      store: store,
      runLocal: <T>(action) => action(),
      openLegacy: (_) => throw StateError('no legacy row to open'),
      openCurrent: (_) => throw StateError('no current row to open'),
      prepareLocal: () async {
        preparations++;
      },
    );

    expect(preparations, 0);
    expect(api.finalizeCalls, 1);
    expect(await store.recordEnvelopeFloor(), 2);
  });

  test(
    'a migration response cannot roll back a concurrently observed floor',
    () async {
      final data = <String, dynamic>{'id': 'server-a', 'label': 'A'};
      final old = await _legacyLive(
        id: 'server-a',
        kind: RecordKind.serverConfig.name,
        data: data,
      );
      final current = await codec.encrypt(
        DecryptedRecord(
          id: 'server-a',
          kind: RecordKind.serverConfig,
          updatedAt: 40,
          deviceId: 'trusted-device',
          data: data,
        ),
      );
      final store = InMemoryLocalRecordStore();
      await store.putLocal(current);
      final api = _DowngradeResponseApi(old, store);

      await expectLater(
        migrateLegacyEnvelopes(
          api,
          store: store,
          runLocal: <T>(action) => action(),
          openLegacy: codec.decryptLegacyForMigration,
          openCurrent: codec.decrypt,
        ),
        throwsA(isA<RecordEnvelopeFloorDowngradeException>()),
      );
      expect(await store.recordEnvelopeFloor(), 2);
    },
  );

  test('a floor-two pull cannot carry a legacy row', () async {
    final api = _FloorTwoLegacyApi();
    await expectLater(
      pullPages(api, since: 0).toList(),
      throwsA(isA<FormatException>()),
    );
  });

  test('an empty final page advances across a floor checkpoint', () async {
    final store = InMemoryLocalRecordStore();
    final outcome = await SyncEngine(store).sync(_CheckpointApi());

    expect(outcome.pulled, 0);
    expect(await store.highWaterSeq(), 1);
  });

  test('record coordinator also advances across a floor checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp('floor_checkpoint');
    try {
      final records = PersistentLocalRecordStore(
        path: '${directory.path}/records.json',
      );
      final coordinator = RecordCoordinator(
        records: records,
        handlers: const [],
        hostKeys: InMemoryConflictAwareHostKeyStore(),
        hostKeyMutations: HostKeyMutationGate(),
        crypto: RecordCrypto(RecordCodec(_key)),
        deviceId: 'device-a',
        pinVerdicts: InMemoryPinVerdictStore(),
        tripwires: InMemorySyncTripwireStore(),
        catalogMode: CatalogMode.separate,
        pushPolicy: PushPolicy.normal,
      );

      await coordinator.runRound(_CheckpointApi());
      expect(await records.highWaterSeq(), 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

final class _MigrationApi implements SyncApi, LegacyMigrationApi {
  _MigrationApi(this.legacy, this.inLocal);

  final EncryptedRecord legacy;
  final bool Function() inLocal;
  bool failNextMigration = false;
  int migrated = 0;
  bool finalized = false;

  void _networkBoundary() => expect(inLocal(), isFalse);

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async {
    _networkBoundary();
    return LegacyRecordPage(
      records: finalized ? const [] : [legacy],
      nextId: null,
      hasMore: false,
      recordEnvelopeFloor: finalized ? 2 : 1,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    _networkBoundary();
    if (failNextMigration) {
      failNextMigration = false;
      throw StateError('interrupted');
    }
    if (migrations.isNotEmpty) migrated += migrations.length;
    if (finalize) finalized = true;
    return LegacyMigrationResponse(
      migrated: migrations.length,
      stale: 0,
      latestSeq: migrated,
      recordEnvelopeFloor: finalized ? 2 : 1,
    );
  }

  @override
  Future<PullResponse> pull({required int since}) async =>
      PullResponse(records: const [], latestSeq: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _FloorChangingApi implements SyncApi, PagedSyncApi {
  var calls = 0;

  @override
  Future<PullResponse> pull({required int since}) => throw UnimplementedError();

  @override
  Future<PullResponse> pullPage({required int since, int? throughSeq}) async {
    calls++;
    return PullResponse(
      records: calls == 1
          ? [
              EncryptedRecord(
                id: 'a',
                updatedAt: 1,
                deviceId: 'd',
                deleted: false,
                seq: 1,
                blob: Uint8List(1),
              ),
            ]
          : const [],
      latestSeq: 2,
      throughSeq: 2,
      hasMore: calls == 1,
      recordEnvelopeFloor: calls == 1 ? 1 : 2,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _ConcurrentFinalizeApi implements LegacyMigrationApi {
  _ConcurrentFinalizeApi(this.legacy);

  final EncryptedRecord legacy;
  int calls = 0;
  int migrationCalls = 0;

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async {
    calls++;
    if (calls == 1) {
      return LegacyRecordPage(
        records: [legacy],
        nextId: legacy.id,
        hasMore: true,
        recordEnvelopeFloor: 1,
      );
    }
    return const LegacyRecordPage(
      records: [],
      nextId: null,
      hasMore: false,
      recordEnvelopeFloor: 2,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    migrationCalls++;
    throw StateError('no migration request expected');
  }

  @override
  Future<PullResponse> pull({required int since}) async =>
      PullResponse(records: const [], latestSeq: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _DowngradeResponseApi implements LegacyMigrationApi {
  _DowngradeResponseApi(this.legacy, this.store);

  final EncryptedRecord legacy;
  final InMemoryLocalRecordStore store;

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async =>
      LegacyRecordPage(
        records: [legacy],
        nextId: null,
        hasMore: false,
        recordEnvelopeFloor: 1,
      );

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    await store.observeRecordEnvelopeFloor(2);
    return const LegacyMigrationResponse(
      migrated: 1,
      stale: 0,
      latestSeq: 8,
      recordEnvelopeFloor: 1,
    );
  }

  @override
  Future<PullResponse> pull({required int since}) async =>
      PullResponse(records: const [], latestSeq: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _EmptyLegacyApi implements LegacyMigrationApi {
  var finalizeCalls = 0;

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async =>
      const LegacyRecordPage(
        records: [],
        nextId: null,
        hasMore: false,
        recordEnvelopeFloor: 1,
      );

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    expect(migrations, isEmpty);
    expect(finalize, isTrue);
    finalizeCalls++;
    return const LegacyMigrationResponse(
      migrated: 0,
      stale: 0,
      latestSeq: 1,
      recordEnvelopeFloor: 2,
    );
  }

  @override
  Future<PullResponse> pull({required int since}) async =>
      PullResponse(records: const [], latestSeq: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _FloorTwoLegacyApi implements SyncApi {
  @override
  Future<PullResponse> pull({required int since}) async => PullResponse(
    records: [
      EncryptedRecord(
        envelopeVersion: 1,
        id: 'legacy',
        updatedAt: 1,
        deviceId: 'd',
        deleted: true,
        seq: 1,
        blob: Uint8List(0),
      ),
    ],
    latestSeq: 1,
    recordEnvelopeFloor: 2,
  );

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

final class _CheckpointApi implements SyncApi, PagedSyncApi {
  @override
  Future<PullResponse> pull({required int since}) => throw UnimplementedError();

  @override
  Future<PullResponse> pullPage({required int since, int? throughSeq}) async =>
      const PullResponse(
        records: [],
        latestSeq: 1,
        throughSeq: 1,
        recordEnvelopeFloor: 2,
      );

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 1);
}

final class _RefusedMigrationApi implements LegacyMigrationApi {
  _RefusedMigrationApi(this.legacy, this.code);
  final EncryptedRecord legacy;
  final String code;
  var migrationAttempts = 0;
  var finalizeCalls = 0;
  var pulls = 0;
  var pushes = 0;
  var sequence = 7;

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async =>
      LegacyRecordPage(
        records: [legacy],
        nextId: null,
        hasMore: false,
        recordEnvelopeFloor: 1,
      );

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    if (!finalize) {
      migrationAttempts++;
      throw ApiError(code: code, message: 'Deployment limit');
    }
    finalizeCalls++;
    return LegacyMigrationResponse(
      migrated: 0,
      stale: 0,
      latestSeq: sequence,
      recordEnvelopeFloor: 1,
    );
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    pulls++;
    return PullResponse(
      records: const [],
      latestSeq: sequence,
      recordEnvelopeFloor: 1,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushes++;
    return PushResponse(
      results: [
        for (final record in records)
          PushResult(id: record.id, seq: ++sequence, accepted: true),
      ],
      latestSeq: sequence,
    );
  }
}

final class _RegressingCursorApi extends _EmptyLegacyApi {
  var calls = 0;
  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async {
    calls++;
    if (calls > 2) throw StateError('backward cursor was accepted');
    return LegacyRecordPage(
      records: const [],
      nextId: calls == 1 ? 'b' : 'a',
      hasMore: true,
      recordEnvelopeFloor: 1,
    );
  }
}

final class _RowsApi implements SyncApi {
  _RowsApi(this.records);
  final List<EncryptedRecord> records;
  @override
  Future<PullResponse> pull({required int since}) async => PullResponse(
    records: records.where((record) => record.seq! > since).toList(),
    latestSeq: records.last.seq!,
    recordEnvelopeFloor: 1,
  );
  @override
  Future<PushResponse> push(List<EncryptedRecord> records) =>
      throw StateError('pull-only');
}

final class _HeldEnrollment implements SyncEnrollmentState {
  @override
  Future<String> deviceId() async => 'device-a';
  @override
  Future<bool> passphraseUnverified() async => true;
  @override
  Future<void> setPassphraseUnverified(bool value) async {}
  @override
  Future<Set<String>> notices() async => {};
  @override
  Future<void> setNotice(String notice, bool active) async {}
  @override
  Future<SyncAccount?> account() async => null;
  @override
  Future<void> setAccount(SyncAccount? account) async {}
}
