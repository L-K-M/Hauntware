import 'package:seance_core/seance_core.dart';

/// A SyncApi fake standing in for the Séance sync server: server-side merge
/// is the same [Lww.resolve] both ends share (04 §3.2 pins the server's
/// tie-break identical to the client's), and accepted pushes mint a
/// monotonically increasing `seq` like `pushRecords` in seance_sync_server.
final class FakeSyncApi implements SyncApi {
  /// Server-held records. Prefer [seed] / [seedWithSeq]: inserting directly
  /// skips seq assignment, and a record with a null seq is never returned
  /// by [pull].
  final Map<String, EncryptedRecord> records = {};
  var _seq = 0;

  /// When set, the next [pull] throws it (the cursor-rejected signal that
  /// triggers the full-resync fallback).
  Object? nextPullError;

  /// When set, the next [push] throws it (transport failure — no results).
  Object? nextPushError;

  /// When true, every pushed record is reported rejected and nothing is
  /// stored — the permanently-losing push that must not spin the round.
  bool rejectPushes = false;

  /// The limits every [pull] advertises; null advertises none.
  PushLimits? limits;

  /// Ids the server refuses as too large: a push holding one throws the
  /// 413 `payload_too_large` for the whole push, as the real server does.
  final tooLarge = <String>{};

  /// A cap on live records; null means none. A push that would pass it is
  /// refused whole with 413 `account_quota_exceeded`, as a server without
  /// per-record refusals does, unless [perRecordQuota] is set.
  int? maxLiveRecords;

  /// Answer a push past [maxLiveRecords] as a current server answers a client
  /// that opts in: store what fits, list the rest in [PushResponse.refused],
  /// and offer those a second time after the first pass.
  bool perRecordQuota = false;

  var pullCalls = 0;
  var pushCalls = 0;

  /// The size of every [push], in order.
  final pushSizes = <int>[];

  /// Every `since` cursor a [pull] was called with, in order — lets a test
  /// prove the resync retry pulled from zero.
  final pullCursors = <int>[];

  /// Seed a record the way the server would store an incoming push: LWW
  /// against what is already held, seq assigned on a win, ignored on a loss.
  /// Returns whether the seed won.
  bool seed(EncryptedRecord record) {
    final existing = records[record.id];
    if (existing != null) {
      final winner = Lww.resolve(existing, record);
      assert(
        identical(winner, existing) || identical(winner, record),
        'Lww.resolve must return one of its arguments',
      );
      if (!identical(winner, record)) return false;
    }
    _seq++;
    records[record.id] = record.withSeq(_seq);
    return true;
  }

  /// Place a record with an explicit seq — fixtures that need to control
  /// cursor positions rather than merge semantics.
  void seedWithSeq(EncryptedRecord record, int seq) {
    records[record.id] = record.withSeq(seq);
    if (seq > _seq) _seq = seq;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    pullCalls++;
    pullCursors.add(since);
    final error = nextPullError;
    if (error != null) {
      nextPullError = null;
      throw error;
    }
    final list = records.values.where((r) => (r.seq ?? 0) > since).toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: list, latestSeq: _seq, limits: limits);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> pushed) async {
    pushCalls++;
    pushSizes.add(pushed.length);
    final error = nextPushError;
    if (error != null) {
      nextPushError = null;
      throw error;
    }
    if (pushed.any((record) => tooLarge.contains(record.id))) {
      throw const ApiError(code: 'payload_too_large', message: 'too large');
    }
    final cap = maxLiveRecords;
    if (cap != null && !rejectPushes && _liveAfter(pushed) > cap) {
      if (!perRecordQuota) {
        throw const ApiError(
          code: 'account_quota_exceeded',
          message: 'The account has reached its record storage quota',
        );
      }
      return _pushEachRecord(pushed, cap);
    }
    final results = <PushResult>[];
    for (final incoming in pushed) {
      final existing = records[incoming.id];
      if (rejectPushes) {
        results.add(
          PushResult(id: incoming.id, seq: existing?.seq ?? 0, accepted: false),
        );
        continue;
      }
      if (existing != null) {
        final winner = Lww.resolve(existing, incoming);
        assert(
          identical(winner, existing) || identical(winner, incoming),
          'Lww.resolve must return one of its arguments',
        );
        if (!identical(winner, incoming)) {
          results.add(
            PushResult(
              id: incoming.id,
              seq: existing.seq ?? 0,
              accepted: false,
            ),
          );
          continue;
        }
      }
      _seq++;
      records[incoming.id] = incoming.withSeq(_seq);
      results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _seq);
  }

  bool _wins(EncryptedRecord? existing, EncryptedRecord incoming) =>
      existing == null || identical(Lww.resolve(existing, incoming), incoming);

  int get _live => records.values.where((r) => !r.deleted).length;

  int _liveAfter(List<EncryptedRecord> pushed) {
    final whole = Map.of(records);
    for (final incoming in pushed) {
      if (_wins(whole[incoming.id], incoming)) whole[incoming.id] = incoming;
    }
    return whole.values.where((r) => !r.deleted).length;
  }

  PushResponse _pushEachRecord(List<EncryptedRecord> pushed, int cap) {
    final results = <PushResult>[];
    var pending = pushed;
    for (var pass = 0; pass < 2; pass++) {
      final deferred = <EncryptedRecord>[];
      for (final incoming in pending) {
        final existing = records[incoming.id];
        if (!_wins(existing, incoming)) {
          results.add(
            PushResult(
              id: incoming.id,
              seq: existing!.seq ?? 0,
              accepted: false,
            ),
          );
          continue;
        }
        final grows =
            !incoming.deleted && (existing == null || existing.deleted);
        if (grows && _live >= cap) {
          deferred.add(incoming);
          continue;
        }
        _seq++;
        records[incoming.id] = incoming.withSeq(_seq);
        results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
      }
      pending = deferred;
    }
    return PushResponse(
      results: results,
      refused: [
        for (final record in pending)
          PushRefusal(id: record.id, reason: PushRefusalReason.accountQuota),
      ],
      latestSeq: _seq,
    );
  }
}
