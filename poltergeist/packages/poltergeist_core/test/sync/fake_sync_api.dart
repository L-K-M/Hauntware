import 'package:poltergeist_core/poltergeist_core.dart';

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

  /// Optional stable-fence page size and one scheduled pull failure.
  int? pullPageSize;
  int? failPullCall;
  Object? scheduledPullError;

  /// When set, the next [push] throws it (transport failure — no results).
  Object? nextPushError;

  /// When true, every pushed record is reported rejected and nothing is
  /// stored — the permanently-losing push that must not spin the round.
  bool rejectPushes = false;

  var pullCalls = 0;
  var pushCalls = 0;

  /// Every `since` cursor a [pull] was called with, in order — lets a test
  /// prove the resync retry pulled from zero.
  final pullCursors = <int>[];
  final pullFences = <int?>[];

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
  Future<PullResponse> pull({required int since, int? through}) async {
    pullCalls++;
    pullCursors.add(since);
    pullFences.add(through);
    if (failPullCall == pullCalls) {
      final error = scheduledPullError ?? const SyncCursorRejectedException();
      failPullCall = null;
      scheduledPullError = null;
      throw error;
    }
    final error = nextPullError;
    if (error != null) {
      nextPullError = null;
      throw error;
    }
    final fence = through ?? _seq;
    final list = records.values
        .where((r) => (r.seq ?? 0) > since && (r.seq ?? 0) <= fence)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    final pageSize = pullPageSize;
    if (pageSize != null && list.length > pageSize) {
      final page = list.take(pageSize).toList();
      final next = page.last.seq!;
      return PullResponse(
        records: page,
        latestSeq: next,
        through: fence,
        nextSince: next,
      );
    }
    return PullResponse(
      records: list,
      latestSeq: pageSize == null ? _seq : fence,
      through: pageSize == null ? null : fence,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> pushed) async {
    pushCalls++;
    final error = nextPushError;
    if (error != null) {
      nextPushError = null;
      throw error;
    }
    final results = <PushResult>[];
    for (final incoming in pushed) {
      final existing = records[incoming.id];
      if (rejectPushes) {
        results.add(
            PushResult(id: incoming.id, seq: existing?.seq ?? 0, accepted: false));
        continue;
      }
      if (existing != null) {
        final winner = Lww.resolve(existing, incoming);
        assert(
          identical(winner, existing) || identical(winner, incoming),
          'Lww.resolve must return one of its arguments',
        );
        if (!identical(winner, incoming)) {
          results.add(PushResult(
              id: incoming.id, seq: existing.seq ?? 0, accepted: false));
          continue;
        }
      }
      _seq++;
      records[incoming.id] = incoming.withSeq(_seq);
      results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}
