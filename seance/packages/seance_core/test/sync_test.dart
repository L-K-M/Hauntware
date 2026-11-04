import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/src/sync/local_record_store.dart';
import 'package:seance_core/src/sync/sync_engine.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

/// An in-memory stand-in for the sync server: stores the LWW-winning version of
/// each record and hands out monotonic sequence numbers. Two [SyncEngine]s
/// pointed at one instance must converge.
class FakeServer implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;

  /// What one push may carry, enforced exactly as the real server does and
  /// advertised in every pull. Null models a server too old to advertise: it
  /// still enforces the shipped defaults, so a client that guesses them wrong
  /// is caught here rather than in production.
  final PushLimits? advertisedLimits;

  /// The size of each push the engine sent, in order, so a test can assert how
  /// a dirty set was split rather than only that it arrived.
  final List<int> pushedBatchSizes = [];

  FakeServer({this.advertisedLimits});

  PushLimits get _enforced => advertisedLimits ?? const PushLimits();

  @override
  Future<PullResponse> pull({required int since}) async {
    final records = _store.values
        .where((r) => (r.seq ?? 0) > since)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(
        records: records, latestSeq: _seq, limits: advertisedLimits);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushedBatchSizes.add(records.length);
    if (records.length > _enforced.maxRecordsPerPush) {
      throw ApiError(
          code: 'payload_too_large',
          message: 'Too many records in one push '
              '(max ${_enforced.maxRecordsPerPush})');
    }
    // Measured the way the server measures it — the bytes of the encoded body
    // — not with the arithmetic the batcher uses, so a batch sized by a wrong
    // count is rejected here just as it would be over HTTP.
    final bodyBytes =
        utf8.encode(jsonEncode(PushRequest(records: records).toJson())).length;
    if (bodyBytes > _enforced.maxBodyBytes) {
      throw ApiError(
          code: 'payload_too_large',
          message: 'Request body too large ($bodyBytes bytes)');
    }
    for (final incoming in records) {
      if (incoming.blob.length > _enforced.maxBlobBytes) {
        throw ApiError(
            code: 'payload_too_large',
            message: 'A record blob exceeds the '
                '${_enforced.maxBlobBytes}-byte limit');
      }
    }
    final results = <PushResult>[];
    for (final incoming in records) {
      final existing = _store[incoming.id];
      final winner =
          existing == null ? incoming : Lww.resolve(existing, incoming);
      final incomingWon = identical(winner, incoming) || existing == null;
      if (incomingWon) {
        final assigned = incoming.withSeq(++_seq);
        _store[incoming.id] = assigned;
        results.add(
            PushResult(id: incoming.id, seq: assigned.seq!, accepted: true));
      } else {
        results.add(PushResult(
            id: incoming.id, seq: existing.seq ?? 0, accepted: false));
      }
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}

class PushRaceApi implements SyncApi {
  final FakeServer server;
  final EncryptedRecord concurrentRecord;
  final bool concurrentFirst;
  bool _injected = false;

  PushRaceApi(
    this.server,
    this.concurrentRecord, {
    this.concurrentFirst = false,
  });

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    if (_injected) return server.push(records);

    _injected = true;
    if (concurrentFirst) {
      await server.push([concurrentRecord]);
      return server.push(records);
    }

    final response = await server.push(records);
    final concurrentResponse = await server.push([concurrentRecord]);
    return PushResponse(
      results: response.results,
      latestSeq: concurrentResponse.latestSeq,
    );
  }
}

class LocalEditDuringPushApi implements SyncApi {
  LocalEditDuringPushApi(this.store, this.replacement);

  final InMemoryLocalRecordStore store;
  final EncryptedRecord replacement;
  final List<int> sentTags = [];
  int _pushes = 0;

  @override
  Future<PullResponse> pull({required int since}) async =>
      const PullResponse(records: [], latestSeq: 0);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final sent = records.single;
    sentTags.add(sent.blob.single);
    if (_pushes++ == 0) await store.putLocal(replacement);
    return PushResponse(
      results: [PushResult(id: sent.id, seq: _pushes, accepted: true)],
      latestSeq: _pushes,
    );
  }
}

class PullRaceApi implements SyncApi {
  final EncryptedRecord initiallyUnseen;
  final List<int> requestedSince = [];
  bool _returnedRacedSnapshot = false;

  PullRaceApi(this.initiallyUnseen);

  @override
  Future<PullResponse> pull({required int since}) async {
    requestedSince.add(since);
    if (!_returnedRacedSnapshot) {
      _returnedRacedSnapshot = true;
      return PullResponse(records: const [], latestSeq: initiallyUnseen.seq!);
    }

    final records = initiallyUnseen.seq! > since
        ? [initiallyUnseen]
        : const <EncryptedRecord>[];
    return PullResponse(records: records, latestSeq: initiallyUnseen.seq!);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) =>
      throw UnsupportedError('PullRaceApi does not accept pushes');
}

class RejectCursorOnceApi implements SyncApi {
  RejectCursorOnceApi({
    this.alwaysReject = false,
    this.recordsAfterReset = const [],
  }) {
    for (final record in recordsAfterReset) {
      final seq = record.seq ?? 0;
      if (seq > _seq) _seq = seq;
    }
  }

  final bool alwaysReject;
  final List<EncryptedRecord> recordsAfterReset;
  final List<int> requestedSince = [];
  final List<EncryptedRecord> pushed = [];
  bool _rejected = false;
  int _seq = 0;

  @override
  Future<PullResponse> pull({required int since}) async {
    requestedSince.add(since);
    if (alwaysReject || !_rejected) {
      _rejected = true;
      throw const SyncCursorRejectedException('cursor is ahead of the server');
    }
    return PullResponse(
      records: [
        for (final record in recordsAfterReset)
          if ((record.seq ?? 0) > since) record,
      ],
      latestSeq: _seq,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushed.addAll(records);
    final results = <PushResult>[];
    for (final record in records) {
      results.add(PushResult(id: record.id, seq: ++_seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}

class InvalidWinnerRaceApi implements SyncApi {
  InvalidWinnerRaceApi(this.invalidWinner);

  final EncryptedRecord invalidWinner;

  @override
  Future<PullResponse> pull({required int since}) async => PullResponse(
        records: since < invalidWinner.seq! ? [invalidWinner] : const [],
        latestSeq: invalidWinner.seq!,
      );

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      PushResponse(
        results: [
          for (final record in records)
            PushResult(
              id: record.id,
              seq: invalidWinner.seq!,
              accepted: false,
            ),
        ],
        latestSeq: invalidWinner.seq!,
      );
}

/// Fails from the [failFromPush]th push onwards, so a test can observe what the
/// engine has already committed when a later batch dies.
class FailingBatchApi implements SyncApi {
  final FakeServer server;
  final int failFromPush;
  int _pushes = 0;

  FailingBatchApi(this.server, {required this.failFromPush});

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    _pushes++;
    if (_pushes >= failFromPush) {
      throw const ApiError(code: 'storage_busy', message: 'Storage is busy');
    }
    return server.push(records);
  }
}

/// Refuses every push as too large, the way a server whose real limits are
/// tighter than the ones it advertised would: a batch the client sized to fit
/// is refused whole, and no one record in it is to blame.
class RefuseAsTooLargeApi implements SyncApi {
  @override
  Future<PullResponse> pull({required int since}) async =>
      const PullResponse(records: [], latestSeq: 0);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      throw const ApiError(
          code: 'payload_too_large', message: 'Request body too large');
}

/// Lands another device's copy of [newer]'s record on [server] the first time
/// this device pushes its own, as if the two raced.
class SupersedeOnPushApi implements SyncApi {
  final FakeServer server;
  final EncryptedRecord newer;
  bool _landed = false;

  SupersedeOnPushApi(this.server, this.newer);

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    if (!_landed && records.any((r) => r.id == newer.id)) {
      _landed = true;
      await server.push([newer]);
    }
    return server.push(records);
  }
}

/// Accepts nothing, ever: the standing-rejection case the round cap exists for.
class RejectEverythingApi implements SyncApi {
  @override
  Future<PullResponse> pull({required int since}) async =>
      const PullResponse(records: [], latestSeq: 0);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      PushResponse(
        results: [
          for (final r in records)
            PushResult(id: r.id, seq: 0, accepted: false),
        ],
        latestSeq: 0,
      );
}

class PagedFakeApi implements SyncApi, PagedSyncApi {
  final List<EncryptedRecord> records;
  final int pageSize;
  final List<(int, int?)> requests = [];
  final List<List<EncryptedRecord>> pushes = [];
  int? failRequest;
  int? rejectRequest;

  PagedFakeApi(
    this.records, {
    this.pageSize = 1,
    this.failRequest,
    this.rejectRequest,
  });

  @override
  Future<PullResponse> pull({required int since}) =>
      throw UnsupportedError('the paged capability must be used');

  @override
  Future<PullResponse> pullPage({required int since, int? throughSeq}) async {
    requests.add((since, throughSeq));
    if (rejectRequest == requests.length) {
      rejectRequest = null;
      throw const SyncCursorRejectedException('server history rolled back');
    }
    if (failRequest == requests.length) {
      failRequest = null;
      throw const ApiError(code: 'storage_busy', message: 'retry');
    }
    final through = throughSeq ?? records.fold<int>(0, (value, record) {
      final seq = record.seq ?? 0;
      return seq > value ? seq : value;
    });
    final remaining = [
      for (final record in records)
        if (record.seq! > since && record.seq! <= through) record,
    ];
    final page = remaining.take(pageSize).toList();
    return PullResponse(
      records: page,
      latestSeq: through,
      throughSeq: through,
      hasMore: remaining.length > page.length,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushes.add(records);
    return PushResponse(
      results: [
        for (var i = 0; i < records.length; i++)
          PushResult(id: records[i].id, seq: 100 + i, accepted: true),
      ],
      latestSeq: 100 + records.length,
    );
  }
}

class NonProgressingPagedApi implements SyncApi, PagedSyncApi {
  @override
  Future<PullResponse> pull({required int since}) =>
      throw UnsupportedError('the paged capability must be used');

  @override
  Future<PullResponse> pullPage({required int since, int? throughSeq}) async =>
      const PullResponse(
        records: [],
        latestSeq: 2,
        throughSeq: 2,
        hasMore: true,
      );

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      const PushResponse(results: [], latestSeq: 0);
}

EncryptedRecord rec(String id, int updatedAt, String device,
        {bool deleted = false, int tag = 0}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: device,
      deleted: deleted,
      seq: null,
      blob: Uint8List.fromList([tag]),
    );

void main() {
  group('SyncEngine', () {
    test('pushes local records to an empty server', () async {
      final server = FakeServer();
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('a', 10, 'dev1'));
      await store.putLocal(rec('b', 11, 'dev1'));
      final engine = SyncEngine(store);

      final outcome = await engine.sync(server);
      expect(outcome.pushed, 2);
      expect((await store.dirtyRecords()), isEmpty);

      final onServer = await server.pull(since: 0);
      expect(onServer.records.map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('push latest sequence cannot skip another device record', () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('local', 10, 'A'));
      final api = PushRaceApi(FakeServer(), rec('concurrent', 11, 'B'));
      final engine = SyncEngine(store);

      await engine.sync(api);

      expect(await store.highWaterSeq(), 0);

      await engine.sync(api);

      expect(await store.getRecord('concurrent'), isNotNull);
      expect(await store.highWaterSeq(), 2);
    });

    test('an accepted push never clears a newer in-flight local edit',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      final api = LocalEditDuringPushApi(
        store,
        rec('shared', 20, 'A', tag: 2),
      );

      await SyncEngine(store).sync(api);

      expect(api.sentTags, [1, 2]);
      expect((await store.getRecord('shared'))!.updatedAt, 20);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('rejected push adopts lexicographically larger device ID on a tie',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      final api = PushRaceApi(
        FakeServer(),
        rec('shared', 10, 'B', tag: 2),
        concurrentFirst: true,
      );

      final outcome = await SyncEngine(store).sync(api);

      final adopted = await store.getRecord('shared');
      expect(outcome.pulled, 1);
      expect(outcome.pushed, 0);
      expect(adopted!.updatedAt, 10);
      expect(adopted.deviceId, 'B');
      expect(adopted.blob, equals(Uint8List.fromList([2])));
      expect(await store.dirtyRecords(), isEmpty);
      expect(await store.highWaterSeq(), 1);
    });

    test('rejected equal-metadata payload adopts the sequenced blob', () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      final api = PushRaceApi(
        FakeServer(),
        rec('shared', 10, 'A', tag: 2),
        concurrentFirst: true,
      );

      await SyncEngine(store).sync(api);

      final adopted = await store.getRecord('shared');
      expect(adopted!.seq, 1);
      expect(adopted.blob, equals(Uint8List.fromList([2])));
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('an invalid future record cannot displace a dirty local edit',
        () async {
      final server = FakeServer();
      await server.push([rec('shared', 1 << 50, 'forged', tag: 9)]);
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      var validated = 0;

      await SyncEngine(
        store,
        remoteValidator: (record) async {
          validated++;
          return false;
        },
      ).sync(server);

      final local = await store.getRecord('shared');
      expect(validated, 1);
      expect(local!.updatedAt, 10);
      expect(local.blob, equals(Uint8List.fromList([1])));
      expect(await store.dirtyRecords(), [same(local)]);
      expect(await store.highWaterSeq(), 1);
    });

    test('a rejected push cannot restore an older displaced winner',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putRemote(rec('shared', 20, 'remote', tag: 2).withSeq(5));
      await store.putLocal(rec('shared', 30, 'local', tag: 3));
      final api = InvalidWinnerRaceApi(
        rec('shared', 40, 'invalid', tag: 4).withSeq(6),
      );

      await SyncEngine(
        store,
        maxRounds: 1,
        remoteValidator: (record) async => false,
      ).sync(api);

      final local = await store.getRecord('shared');
      expect(local!.updatedAt, 30);
      expect(local.deviceId, 'local');
      expect(local.blob, equals(Uint8List.fromList([3])));
      expect(await store.dirtyRecords(), [same(local)]);
      expect(await store.highWaterSeq(), 6);
    });

    test(
      'pull latest sequence cannot skip an unseen snapshot record',
      () async {
        final store = InMemoryLocalRecordStore();
        // Sequence 1 was superseded by the current seq-2 version before the
        // second snapshot, as happens with the server's upsert storage.
        final api = PullRaceApi(rec('remote', 10, 'B').withSeq(2));
        final engine = SyncEngine(store);

        await engine.sync(api);

        expect(await store.highWaterSeq(), 0);

        await engine.sync(api);

        expect(
          api.requestedSince.take(2),
          [0, 0],
          reason: 'an unobserved latestSeq must not advance the next pull',
        );
        expect(await store.getRecord('remote'), isNotNull);
        expect(await store.highWaterSeq(), 2);
      },
    );

    test('a rejected cursor re-queues mirror and re-sources domain data',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putRemote(rec('lost-history', 10, 'peer').withSeq(42));
      await store.setHighWaterSeq(42);
      final api = RejectCursorOnceApi();
      var recoveryCalls = 0;

      await SyncEngine(store).sync(
        api,
        afterCursorRecovery: () async {
          recoveryCalls++;
          await store.putLocal(rec('current-domain-row', 20, 'local'));
        },
      );

      expect(api.requestedSince, [42, 0]);
      expect(recoveryCalls, 1);
      expect((await store.getRecord('lost-history'))!.seq, isNotNull);
      expect((await store.getRecord('current-domain-row'))!.seq, isNotNull);
      expect(api.pushed.map((record) => record.id).toSet(),
          {'lost-history', 'current-domain-row'});
      expect(await store.dirtyRecords(), isEmpty);
      expect(await store.highWaterSeq(), 0);
      expect(await store.cursorRecoveryPending(), isFalse);
    });

    test('a failed recovery callback leaves the phase pending and pushes none',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putRemote(rec('mirror-only', 10, 'peer').withSeq(42));
      await store.setHighWaterSeq(42);
      final api = RejectCursorOnceApi();
      final engine = SyncEngine(store);

      await expectLater(
        engine.sync(
          api,
          afterCursorRecovery: () async {
            throw const FileSystemException('domain store unavailable');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(api.requestedSince, [42, 0]);
      expect(api.pushed, isEmpty);
      expect(await store.cursorRecoveryPending(), isTrue);
      expect((await store.getRecord('mirror-only'))!.seq, isNull);

      await engine.sync(api, afterCursorRecovery: () async {});

      expect(api.pushed.map((record) => record.id), ['mirror-only']);
      expect(await store.cursorRecoveryPending(), isFalse);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('cursor recovery republishes a confirmed tombstone', () async {
      final store = InMemoryLocalRecordStore();
      final tombstone = rec(
        'deleted-server',
        20,
        'local',
        deleted: true,
      ).withSeq(42);
      await store.putRemote(tombstone);
      await store.setHighWaterSeq(42);
      final api = RejectCursorOnceApi(
        recordsAfterReset: [rec('deleted-server', 10, 'peer').withSeq(1)],
      );

      await SyncEngine(store).sync(api);

      expect(api.requestedSince.take(2), [42, 0]);
      expect(api.pushed, hasLength(1));
      expect(api.pushed.single.deleted, isTrue);
      final recovered = await store.getRecord('deleted-server');
      expect(recovered!.deleted, isTrue);
      expect(recovered.updatedAt, 20);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('cursor recovery adopts an identical sequenced tombstone', () async {
      final store = InMemoryLocalRecordStore();
      final tombstone = rec(
        'deleted-server',
        20,
        'local',
        deleted: true,
      ).withSeq(42);
      await store.putRemote(tombstone);
      await store.setHighWaterSeq(100);
      final api = RejectCursorOnceApi(recordsAfterReset: [tombstone]);

      await SyncEngine(store).sync(api);

      expect(api.pushed, isEmpty,
          reason: 'the server already has the confirmed deletion');
      expect((await store.getRecord('deleted-server'))!.seq, 42);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('cursor recovery preserves a peer-authored equal-stamp winner',
        () async {
      final store = InMemoryLocalRecordStore();
      final winner = rec('shared', 100, 'Z', tag: 9).withSeq(42);
      await store.putRemote(winner);
      await store.setHighWaterSeq(42);
      final api = RejectCursorOnceApi(
        recordsAfterReset: [rec('shared', 100, 'M', tag: 1).withSeq(1)],
      );

      await SyncEngine(store).sync(api);

      expect(api.pushed, hasLength(1));
      expect(api.pushed.single.deviceId, 'Z');
      expect(api.pushed.single.blob, orderedEquals([9]));
      final recovered = await store.getRecord('shared');
      expect(recovered!.deviceId, 'Z');
      expect(recovered.blob, orderedEquals([9]));
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('a server that rejects zero does not start a reset loop', () async {
      final store = InMemoryLocalRecordStore();
      await store.setHighWaterSeq(42);
      final api = RejectCursorOnceApi(alwaysReject: true);

      await expectLater(
        SyncEngine(store).sync(api),
        throwsA(isA<SyncCursorRejectedException>()),
      );

      expect(api.requestedSince, [42, 0]);
      expect(await store.cursorRecoveryPending(), isTrue);
    });

    test('recovery waits for every pull page and resumes partial progress',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('local', 10, 'A'));
      await store.setHighWaterSeq(42);
      final api = PagedFakeApi(
        [
          rec('one', 1, 'B').withSeq(1),
          rec('two', 2, 'B').withSeq(2),
        ],
        rejectRequest: 1,
        failRequest: 3,
      );
      var recoveryCalls = 0;

      await expectLater(
        SyncEngine(store).sync(
          api,
          afterCursorRecovery: () async => recoveryCalls++,
        ),
        throwsA(isA<ApiError>()),
      );

      expect(api.requests, [(42, null), (0, null), (1, 2)]);
      expect(await store.highWaterSeq(), 1);
      expect(await store.cursorRecoveryPending(), isTrue);
      expect(recoveryCalls, 0);
      expect(api.pushes, isEmpty);

      await SyncEngine(store).sync(
        api,
        afterCursorRecovery: () async {
          recoveryCalls++;
          expect((await store.allRecords()).map((record) => record.id),
              containsAll(['one', 'two']));
          expect(api.pushes, isEmpty,
              reason: 'the recovery callback must precede every push');
        },
      );

      expect(api.requests[3], (1, null));
      expect(recoveryCalls, 1);
      expect(await store.cursorRecoveryPending(), isFalse);
      expect(api.pushes, hasLength(1));
      expect(api.pushes.single.map((record) => record.id), ['local']);
    });

    test('bounded pages share a watermark and advance by observed seq',
        () async {
      final api = PagedFakeApi([
        rec('one', 1, 'B').withSeq(1),
        rec('two', 2, 'B').withSeq(2),
      ]);
      final store = InMemoryLocalRecordStore();

      await SyncEngine(store).sync(api);

      expect((await store.allRecords()).map((r) => r.id), ['one', 'two']);
      expect(await store.highWaterSeq(), 2);
      expect(api.requests.take(2), [(0, null), (1, 2)]);
    });

    test('a later page failure persists only completed page progress',
        () async {
      final api = PagedFakeApi([
        rec('one', 1, 'B').withSeq(1),
        rec('two', 2, 'B').withSeq(2),
      ], failRequest: 2);
      final store = InMemoryLocalRecordStore();
      final engine = SyncEngine(store);

      await expectLater(engine.sync(api), throwsA(isA<ApiError>()));
      expect(await store.highWaterSeq(), 1);

      await engine.sync(api);
      expect(api.requests[2].$1, 1);
      expect(await store.highWaterSeq(), 2);
      expect((await store.allRecords()).map((r) => r.id), ['one', 'two']);
    });

    test('a non-progressing page fails before moving the cursor', () async {
      final store = InMemoryLocalRecordStore();

      await expectLater(
        SyncEngine(store).sync(NonProgressingPagedApi()),
        throwsFormatException,
      );

      expect(await store.highWaterSeq(), 0);
    });

    test('two devices converge on the same records', () async {
      final server = FakeServer();

      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();
      final devA = SyncEngine(storeA);
      final devB = SyncEngine(storeB);

      // Device A creates two servers; device B creates one.
      await storeA.putLocal(rec('a', 10, 'A', tag: 1));
      await storeA.putLocal(rec('b', 10, 'A', tag: 2));
      await storeB.putLocal(rec('c', 10, 'B', tag: 3));

      await devA.sync(server);
      await devB.sync(server);
      await devA.sync(server); // A pulls B's record

      Future<Set<String>> liveIds(InMemoryLocalRecordStore s) async =>
          (await s.allRecords())
              .where((r) => !r.deleted)
              .map((r) => r.id)
              .toSet();

      expect(await liveIds(storeA), {'a', 'b', 'c'});
      expect(await liveIds(storeB), {'a', 'b', 'c'});
    });

    test('concurrent edit to one record resolves by last-write-wins', () async {
      final server = FakeServer();
      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();

      // Both start from a shared record.
      await storeA.putLocal(rec('x', 5, 'A', tag: 1));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B pulls x

      // Both edit x concurrently; B's edit is later (higher updatedAt).
      await storeA.putLocal(rec('x', 20, 'A', tag: 10));
      await storeB.putLocal(rec('x', 30, 'B', tag: 20));

      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server);
      await SyncEngine(storeA).sync(server); // A reconciles

      final a = await storeA.getRecord('x');
      final b = await storeB.getRecord('x');
      // B's later write (updatedAt 30) wins on both devices.
      expect(a!.updatedAt, 30);
      expect(a.deviceId, 'B');
      expect(b!.updatedAt, 30);
      expect(a.blob, equals(b.blob));
    });

    group('push batching', () {
      /// A record of roughly [blobBytes] sealed bytes.
      EncryptedRecord bulky(String id, int blobBytes) => EncryptedRecord(
            id: id,
            updatedAt: 10,
            deviceId: 'A',
            deleted: false,
            seq: null,
            blob: Uint8List(blobBytes),
          );

      test('splits a dirty set too large for one body', () async {
        const limits = PushLimits(maxBodyBytes: 8 * 1024);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        // ~40 KiB of records against an 8 KiB body limit: unbatched this is
        // rejected whole, and the next round rebuilds the same request.
        for (var i = 0; i < 20; i++) {
          await store.putLocal(bulky('r$i', 1500));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, 20);
        expect(await store.dirtyRecords(), isEmpty);
        expect(server.pushedBatchSizes.length, greaterThan(1),
            reason: 'the dirty set cannot fit in one body');
        expect((await server.pull(since: 0)).records, hasLength(20));
      });

      test('splits a dirty set with more records than one push allows',
          () async {
        const limits = PushLimits(maxRecordsPerPush: 3);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 10; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, 10);
        expect(await store.dirtyRecords(), isEmpty);
        expect(server.pushedBatchSizes, [3, 3, 3, 1]);
      });

      test('falls back to the shipped limits when none are advertised',
          () async {
        final server = FakeServer();
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < kDefaultMaxRecordsPerPush + 1; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, kDefaultMaxRecordsPerPush + 1);
        expect(server.pushedBatchSizes, [kDefaultMaxRecordsPerPush, 1],
            reason: 'an unadvertised server still enforces what it shipped '
                'with, so the fallback has to match it');
      });

      test('a failing batch keeps the earlier batches marked synced', () async {
        const limits = PushLimits(maxRecordsPerPush: 2);
        final server = FakeServer(advertisedLimits: limits);
        final api = FailingBatchApi(server, failFromPush: 2);
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 6; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        await expectLater(SyncEngine(store).sync(api), throwsA(isA<ApiError>()));

        // The first batch was accepted and recorded before the second left, so
        // its records are clean and the retry only carries what is still owed.
        final stillDirty =
            (await store.dirtyRecords()).map((r) => r.id).toSet();
        expect(stillDirty, hasLength(4));
        expect((await server.pull(since: 0)).records, hasLength(2));
      });

      test('an advertisement does not outlive the server that made it',
          () async {
        final tight = FakeServer(
            advertisedLimits: const PushLimits(maxRecordsPerPush: 2));
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 5; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }
        final engine = SyncEngine(store);
        await engine.sync(tight);
        expect(tight.pushedBatchSizes, [2, 2, 1]);

        // The same engine, now pointed at a server that advertises nothing:
        // it enforces the shipped defaults, so sizing to what the previous
        // deployment allowed would batch for the wrong server.
        final silent = FakeServer();
        for (var i = 0; i < 5; i++) {
          await store.putLocal(rec('s$i', 20, 'A'));
        }
        await engine.sync(silent);

        expect(silent.pushedBatchSizes, [5]);
      });

      test('a record no single body can carry surfaces the server error',
          () async {
        const limits = PushLimits(maxBodyBytes: 2048);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        // Put the unbatchable record first, so its move to the back of the
        // queue is what lets the record behind it through.
        await store.putLocal(bulky('huge', 8192));
        await store.putLocal(bulky('small', 100));

        await expectLater(
          SyncEngine(store).sync(server),
          throwsA(isA<SyncRecordsRefused>()
              .having((e) => e.recordIds, 'recordIds', ['huge'])
              .having((e) => e.code, 'code', 'payload_too_large')),
        );

        // The refusal is reported rather than counted as a benign rejection:
        // nothing local can make this record fit, so a sync that returned
        // normally would claim success while the record never leaves. What
        // did fit is already pushed and clean, so the error costs only itself.
        expect((await server.pull(since: 0)).records.map((r) => r.id),
            ['small']);
        expect((await store.dirtyRecords()).map((r) => r.id), ['huge']);
        expect(server.pushedBatchSizes, [1, 1]);
      });

      test('records refused as too large are each reported once, at the end',
          () async {
        const limits = PushLimits(maxBlobBytes: 1024);
        final server = FakeServer(advertisedLimits: limits);
        final other = InMemoryLocalRecordStore();
        await other.putLocal(rec('theirs', 5, 'B'));
        await SyncEngine(other).sync(server);
        server.pushedBatchSizes.clear();
        final store = InMemoryLocalRecordStore();
        await store.putLocal(bulky('fat-1', 4096));
        await store.putLocal(bulky('fat-2', 4096));
        await store.putLocal(rec('mine', 10, 'A'));

        await expectLater(
          SyncEngine(store).sync(server),
          throwsA(isA<SyncRecordsRefused>()
              .having((e) => e.recordIds, 'recordIds',
                  unorderedEquals(['fat-1', 'fat-2']))
              .having((e) => e.outcome.pushed, 'pushed', 1)
              .having((e) => e.outcome.rounds, 'rounds', greaterThan(1))),
        );

        // The first refusal used to end the run: the second record past the
        // cap was never tried, and the rounds after it never ran.
        expect(await store.getRecord('theirs'), isNotNull);
        expect(
            (await server.pull(since: 0)).records.map((r) => r.id).toSet(),
            {'theirs', 'mine'});
        expect((await store.dirtyRecords()).map((r) => r.id).toSet(),
            {'fat-1', 'fat-2'},
            reason: 'a refused record stays dirty, so a later run retries it '
                'in case it shrank or the limit was raised');
        expect(server.pushedBatchSizes, [1, 1, 1],
            reason: 'each refused record is sent once per run, not once per '
                'round: nothing between rounds can make it fit');
      });

      test('a refused record a pulled copy settles is not reported', () async {
        const limits = PushLimits(maxBlobBytes: 1024);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        await store.putLocal(bulky('shared', 4096));
        await store.putLocal(rec('mine', 10, 'A'));
        final newer = rec('shared', 20, 'B');

        await SyncEngine(store).sync(SupersedeOnPushApi(server, newer));

        // Another device's later copy won last-write-wins, so the refused
        // version was going to be replaced anyway: nothing stays behind.
        expect((await store.getRecord('shared'))!.updatedAt, 20);
        expect(await store.dirtyRecords(), isEmpty);
      });

      test('a refusal reads as a sentence naming each record', () {
        const outcome = SyncOutcome(pulled: 0, pushed: 0, rounds: 1);
        final blank = SyncRecordsRefused([
          const RefusedRecord('snippet:x', kind: RecordKind.snippet, name: ' '),
        ], outcome: outcome);
        expect(blank.toString(), startsWith('Snippet (snippet:x) is too large'),
            reason: 'a blank title falls back to the id, not to ""');

        final two = SyncRecordsRefused([
          const RefusedRecord('s1', kind: RecordKind.serverConfig, name: 'prod'),
          const RefusedRecord('secret:k'),
        ], outcome: outcome);
        expect(two.toString(), startsWith('2 records are too large'));
        expect(two.toString(), contains(': server "prod", record (secret:k).'));

        final setting = SyncRecordsRefused([
          const RefusedRecord('klabautermann:pref:p',
              kind: RecordKind.klabautermann),
        ], outcome: outcome);
        expect(setting.toString(),
            startsWith('Klabautermann setting (klabautermann:pref:p) is too'));
      });

      test('a batch refused whole still ends the run', () async {
        final store = InMemoryLocalRecordStore();
        await store.putLocal(rec('a', 10, 'A'));
        await store.putLocal(rec('b', 10, 'A'));

        await expectLater(
          SyncEngine(store).sync(RefuseAsTooLargeApi()),
          throwsA(isA<ApiError>()
              .having((e) => e.code, 'code', 'payload_too_large')
              .having((e) => e, 'error', isNot(isA<SyncRecordsRefused>()))),
          reason: 'a refused batch of several names no culprit, so it is not '
              'set aside as one record\'s failure',
        );
        expect(await store.dirtyRecords(), hasLength(2));
      });

      test('any other failure of a one-record push still ends the run',
          () async {
        const limits = PushLimits(maxRecordsPerPush: 1);
        final server = FakeServer(advertisedLimits: limits);
        final api = FailingBatchApi(server, failFromPush: 2);
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 3; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        await expectLater(
          SyncEngine(store).sync(api),
          throwsA(isA<ApiError>()
              .having((e) => e.code, 'code', 'storage_busy')
              .having((e) => e, 'error', isNot(isA<SyncRecordsRefused>()))),
        );
        expect(server.pushedBatchSizes, [1],
            reason: 'nothing is pushed after the failure');
        expect(await store.dirtyRecords(), hasLength(2));
      });

      test('a server that rejects every batch still terminates', () async {
        final api = RejectEverythingApi();
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 5; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final engine = SyncEngine(store, maxRounds: 3);
        final outcome = await engine.sync(api);

        // Nothing converges, but the round cap ends it: batching must not turn
        // a standing rejection into an unbounded retry loop.
        expect(outcome.pushed, 0);
        expect(outcome.rounds, 3);
        expect(await store.dirtyRecords(), hasLength(5));
      });
    });

    test('a delete propagates as a tombstone', () async {
      final server = FakeServer();
      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();

      await storeA.putLocal(rec('y', 5, 'A', tag: 1));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B has y

      // A deletes y (later timestamp).
      await storeA.putLocal(rec('y', 50, 'A', deleted: true));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B pulls the tombstone

      final onB = await storeB.getRecord('y');
      expect(onB!.deleted, isTrue);
    });
  });
}
