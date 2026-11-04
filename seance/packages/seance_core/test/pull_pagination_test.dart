import 'dart:typed_data';

import 'package:seance_core/src/sync/local_record_store.dart';
import 'package:seance_core/src/sync/sync_engine.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

final class _ScriptedApi implements SyncApi {
  _ScriptedApi(Iterable<PullResponse> responses)
      : _responses = List.of(responses);

  final List<PullResponse> _responses;
  final List<({int since, int? through})> calls = [];

  @override
  Future<PullResponse> pull({required int since, int? through}) async {
    calls.add((since: since, through: through));
    if (_responses.isEmpty) throw StateError('Unexpected pull');
    return _responses.removeAt(0);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) =>
      throw UnsupportedError('This API only scripts pulls');
}

final class _FailingSecondPageApi implements SyncApi {
  final List<({int since, int? through})> calls = [];

  @override
  Future<PullResponse> pull({required int since, int? through}) async {
    calls.add((since: since, through: through));
    if (since == 0) {
      return PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        through: 2,
        nextSince: 1,
      );
    }
    throw const ApiError(code: 'storage_busy', message: 'try again');
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) =>
      throw UnsupportedError('The pull fails before push');
}

final class _QuotaApi implements SyncApi {
  @override
  Future<PullResponse> pull({required int since, int? through}) async =>
      const PullResponse(records: [], latestSeq: 0, through: 0);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      throw const ApiError(
        code: 'account_quota_exceeded',
        message: 'account full',
      );
}

EncryptedRecord _record(int seq) => EncryptedRecord(
      id: 'record-$seq',
      updatedAt: seq,
      deviceId: 'device',
      deleted: false,
      seq: seq,
      blob: Uint8List.fromList([seq]),
    );

void main() {
  test('drains one stable fence and aggregates metadata conservatively',
      () async {
    final api = _ScriptedApi([
      PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        limits: const PushLimits(
          maxBodyBytes: kDefaultMaxPushBodyBytes * 2,
          maxRecordsPerPush: kDefaultMaxRecordsPerPush * 2,
          maxBlobBytes: kDefaultMaxBlobBytes * 2,
        ),
        recordEnvelopeVersion: kRecordEnvelopeVersion,
        through: 3,
        nextSince: 1,
      ),
      PullResponse(
        records: [_record(2), _record(3)],
        latestSeq: 3,
        through: 3,
      ),
    ]);
    final advances = <int>[];

    final result = await pullAllPages(
      api,
      since: 0,
      applyPage: (page, advanceTo) async => advances.add(advanceTo),
    );

    expect(api.calls, [(since: 0, through: null), (since: 1, through: 3)]);
    expect(advances, [1, 3]);
    expect(result.records, 3);
    expect(result.limits, const PushLimits());
    expect(result.recordEnvelopeVersion, isNull);
  });

  test('legacy response advances only through an observed record', () async {
    final api = _ScriptedApi([
      PullResponse(records: [_record(7)], latestSeq: 99),
    ]);
    var advance = -1;

    await pullAllPages(
      api,
      since: 0,
      applyPage: (page, advanceTo) async => advance = advanceTo,
    );

    expect(advance, 7);
    expect(api.calls, [(since: 0, through: null)]);
  });

  test('rejects a malformed page before applying it', () async {
    final malformed = <String, PullResponse>{
      'empty intermediate': const PullResponse(
        records: [],
        latestSeq: 0,
        through: 2,
        nextSince: 0,
      ),
      'cursor not last record': PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        through: 2,
        nextSince: 2,
      ),
      'intermediate latest mismatch': PullResponse(
        records: [_record(1)],
        latestSeq: 2,
        through: 3,
        nextSince: 1,
      ),
      'record order': PullResponse(
        records: [_record(2), _record(1)],
        latestSeq: 2,
        through: 2,
      ),
      'record beyond fence': PullResponse(
        records: [_record(3)],
        latestSeq: 2,
        through: 2,
      ),
      'final latest mismatch': PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        through: 2,
      ),
      'next cursor without fence': PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        nextSince: 1,
      ),
    };

    for (final entry in malformed.entries) {
      var applied = false;
      await expectLater(
        pullAllPages(
          _ScriptedApi([entry.value]),
          since: 0,
          applyPage: (page, advanceTo) async => applied = true,
        ),
        throwsA(anyOf(isA<FormatException>(),
            isA<SyncCursorRejectedException>())),
        reason: entry.key,
      );
      expect(applied, isFalse, reason: entry.key);
    }
  });

  test('a later page cannot change or remove the fence', () async {
    for (final second in [
      PullResponse(records: [_record(2)], latestSeq: 4, through: 4),
      PullResponse(records: [_record(2)], latestSeq: 2),
    ]) {
      final api = _ScriptedApi([
        PullResponse(
          records: [_record(1)],
          latestSeq: 1,
          through: 3,
          nextSince: 1,
        ),
        second,
      ]);
      final advances = <int>[];

      await expectLater(
        pullAllPages(
          api,
          since: 0,
          applyPage: (page, advanceTo) async => advances.add(advanceTo),
        ),
        throwsFormatException,
      );
      expect(advances, [1]);
    }
  });

  test('the page guard stops a progressing but unbounded walk', () async {
    final api = _ScriptedApi([
      PullResponse(
        records: [_record(1)],
        latestSeq: 1,
        through: 3,
        nextSince: 1,
      ),
      PullResponse(
        records: [_record(2)],
        latestSeq: 2,
        through: 3,
        nextSince: 2,
      ),
    ]);
    final advances = <int>[];

    await expectLater(
      pullAllPages(
        api,
        since: 0,
        maxPages: 1,
        applyPage: (page, advanceTo) async => advances.add(advanceTo),
      ),
      throwsFormatException,
    );
    expect(advances, [1]);
    expect(api.calls, [(since: 0, through: null)]);
  });

  test('SyncEngine commits a page before a later pull fails', () async {
    final store = InMemoryLocalRecordStore();
    final api = _FailingSecondPageApi();

    await expectLater(
      SyncEngine(store).sync(api),
      throwsA(isA<ApiError>().having((error) => error.code, 'code',
          'storage_busy')),
    );

    expect((await store.getRecord('record-1'))?.seq, 1);
    expect(await store.highWaterSeq(), 1);
    expect(api.calls, [(since: 0, through: null), (since: 1, through: 2)]);
  });

  test('SyncEngine does not turn an account quota into a refused record',
      () async {
    final store = InMemoryLocalRecordStore();
    await store.putLocal(EncryptedRecord(
      id: 'local',
      updatedAt: 1,
      deviceId: 'device',
      deleted: false,
      seq: null,
      blob: Uint8List.fromList([1]),
    ));

    await expectLater(
      SyncEngine(store).sync(_QuotaApi()),
      throwsA(
        isA<ApiError>()
            .having((error) => error.code, 'code', 'account_quota_exceeded')
            .having((error) => error, 'type', isNot(isA<SyncRecordsRefused>())),
      ),
    );
    expect((await store.dirtyRecords()).single.id, 'local');
  });
}
