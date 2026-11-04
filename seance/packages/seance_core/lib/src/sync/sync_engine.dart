import 'package:seance_protocol/seance_protocol.dart';

import 'local_record_store.dart';
import 'push_batcher.dart';

/// The authenticated record endpoints the engine needs. Implemented over HTTP
/// by [HttpSyncClient]; faked in tests.
abstract class SyncApi {
  Future<PullResponse> pull({required int since});
  Future<PushResponse> push(List<EncryptedRecord> records);
}

/// A [SyncApi] throws this when the server rejects or has expired a pull
/// cursor. The engine uses it for one bounded reset-to-zero when the local
/// store supports durable cursor recovery.
final class SyncCursorRejectedException implements Exception {
  const SyncCursorRejectedException([this.message = 'sync cursor rejected']);

  final String message;

  @override
  String toString() => 'SyncCursorRejectedException: $message';
}

/// Optional bounded-pull capability, separate so existing [SyncApi] fakes do
/// not gain another required member.
abstract interface class PagedSyncApi {
  Future<PullResponse> pullPage({required int since, int? throughSeq});
}

/// Pull one stable snapshot as pages when [api] supports it, or one legacy
/// full response otherwise. A page is validated before it is yielded so a
/// malformed response cannot advance a caller's durable cursor.
Stream<PullResponse> pullPages(SyncApi api, {required int since}) async* {
  if (api is! PagedSyncApi) {
    yield await api.pull(since: since);
    return;
  }
  final paged = api as PagedSyncApi;

  var cursor = since;
  int? through;
  while (true) {
    final page = await paged.pullPage(since: cursor, throughSeq: through);
    final pageThrough = page.throughSeq;
    if (pageThrough == null) {
      if (through != null || page.hasMore) {
        throw const FormatException(
            'A paged sync response omitted its snapshot watermark');
      }
      yield page;
      return;
    }
    if (page.latestSeq != pageThrough ||
        pageThrough < cursor ||
        (through != null && pageThrough != through)) {
      throw const FormatException('Sync snapshot watermark changed');
    }

    var next = cursor;
    for (final record in page.records) {
      final seq = record.seq;
      if (seq == null || seq <= next || seq > pageThrough) {
        throw const FormatException(
            'Sync page records are not strictly ordered');
      }
      next = seq;
    }
    if (page.hasMore && (next == cursor || next >= pageThrough)) {
      throw const FormatException('Sync page made no progress');
    }

    yield page;
    if (!page.hasMore) return;
    cursor = next;
    through = pageThrough;
  }
}

/// Whether a pulled opaque record is safe to enter the local LWW mirror.
///
/// The record's server-owned sequence has already been observed when this is
/// called. Returning false skips the record without letting unauthenticated
/// conflict metadata displace a pending local edit.
typedef RemoteRecordValidator = Future<bool> Function(EncryptedRecord record);

/// Runs one bounded phase that reads or mutates local sync state.
///
/// Applications can use this to serialize the mirror and its domain stores
/// with other local mutations without holding that serialization primitive
/// across [SyncApi] network I/O.
typedef SyncLocalRunner = Future<T> Function<T>(Future<T> Function() action);

Future<T> _runLocalDirectly<T>(Future<T> Function() action) => action();

/// How a local refresh should interpret domain-store absence.
enum SyncLocalRefreshMode {
  normal,
  cursorRecovery,
}

/// Refreshes the mirror from its domain stores before the engine merges or
/// settles network state. During [SyncLocalRefreshMode.cursorRecovery], absence
/// must not be interpreted as a deletion until strict recovery apply succeeds.
typedef SyncLocalRefresh = Future<void> Function(SyncLocalRefreshMode mode);

/// Outcome of a sync run, for the UI/telemetry.
class SyncOutcome {
  final int pulled;
  final int pushed;
  final int rounds;
  const SyncOutcome(
      {required this.pulled, required this.pushed, required this.rounds});
}

/// The server's error code for a push it refuses as too large to store.
const String _payloadTooLarge = 'payload_too_large';

/// One record the sync server refused to store because it is too large.
class RefusedRecord {
  final String id;

  /// What the record holds. [RecordKind.unknown] when only the sealed record
  /// was at hand, which is all the [SyncEngine] ever sees.
  final RecordKind kind;

  /// The name the user knows the record by (a snippet's title, a server's
  /// label), when the caller could tell.
  final String? name;

  const RefusedRecord(this.id, {this.kind = RecordKind.unknown, this.name});

  String get _described {
    final noun = switch (kind) {
      RecordKind.serverConfig => 'server',
      RecordKind.hostKey => 'host key',
      RecordKind.secret => 'credential',
      RecordKind.snippet => 'snippet',
      RecordKind.bookmark => 'bookmark',
      RecordKind.assistantSettings => 'assistant settings',
      RecordKind.inboxApp => 'inbox app',
      RecordKind.inboxStatus => 'inbox status',
      RecordKind.klabautermann => 'Klabautermann setting',
      RecordKind.unknown => 'record',
    };
    final named = name?.trim() ?? '';
    return named.isEmpty ? '$noun ($id)' : '$noun "$named"';
  }
}

/// A sync run finished, except for records the server refused as too large.
///
/// Such a record is pushed alone (see [batchForPush]), so the refusal is its
/// own and nothing else in the run has to pay for it: the run carries on and
/// this is thrown at the end, with [outcome] describing what did happen. Only
/// a refused push of that one record is put down to it: a refused batch of
/// several records names no culprit, and it ends the run where it happens, as
/// every other failure does.
///
/// An [ApiError] with the server's own code, so a caller that handled the
/// refusal before it was isolated still recognises it.
class SyncRecordsRefused extends ApiError {
  /// Every record refused, each still waiting to be pushed: it stays dirty, so
  /// a later run retries it once it has shrunk or the limit has been raised.
  final List<RefusedRecord> records;

  /// What the run achieved around the refused records.
  final SyncOutcome outcome;

  SyncRecordsRefused(this.records, {required this.outcome})
      : assert(records.isNotEmpty),
        super(code: _payloadTooLarge, message: _describe(records));

  List<String> get recordIds => [for (final record in records) record.id];

  static String _describe(List<RefusedRecord> records) {
    const tail = 'Everything else synced.';
    if (records.length == 1) {
      final what = records.single._described;
      return '${what[0].toUpperCase()}${what.substring(1)} is too large for '
          'the sync server, so it stays on this device until you make it '
          'smaller. $tail';
    }
    return '${records.length} records are too large for the sync server, so '
        'they stay on this device until you make them smaller: '
        '${records.map((r) => r._described).join(', ')}. $tail';
  }

  /// The message alone: it is written for the person reading the sync status.
  @override
  String toString() => message;
}

/// Drives synchronization between the local mirror and the server using the
/// last-write-wins rules in [Lww]. Because both sides apply the same rule, a
/// pull that loses is discarded and a push that loses is reconciled on the next
/// pull, so repeated runs converge.
class SyncEngine {
  final LocalRecordStore store;
  final int maxRounds;
  final RemoteRecordValidator? remoteValidator;

  SyncEngine(this.store, {this.maxRounds = 5, this.remoteValidator});

  /// Throws [SyncRecordsRefused] once the run is otherwise complete if the
  /// server refused any record as too large; any other failure is thrown where
  /// it happens.
  Future<SyncOutcome> sync(
    SyncApi api, {
    SyncLocalRunner? runLocal,
    SyncLocalRefresh? refreshLocal,
    Future<void> Function()? beforeCursorRecoveryPull,
    Future<void> Function()? afterCursorRecovery,
  }) async {
    final locally = runLocal ?? _runLocalDirectly;
    var totalPulled = 0;
    var totalPushed = 0;
    var round = 0;
    var resetRejectedCursor = false;
    final recoverable = store is RecoverableSyncCursorStore
        ? store as RecoverableSyncCursorStore
        : null;
    var recoveryPending = false;
    if (recoverable != null) {
      recoveryPending = await locally(recoverable.cursorRecoveryPending);
    }
    // Ids the server refused as too large during this run. Each is sent once
    // per run, not once per round: nothing between rounds can shrink it, and
    // re-sending a record past the cap every round would upload it up to
    // [maxRounds] times only to be refused each time. Per run rather than on
    // the engine for the reason the limits are (see [_pullOnce]).
    final refused = <String>{};
    while (round < maxRounds) {
      round++;
      final ({int applied, PushLimits limits}) pulled;
      try {
        pulled = await _pullOnce(
          api,
          runLocal: locally,
          refreshLocal: refreshLocal,
          cursorRecoveryPending: recoveryPending,
        );
      } on SyncCursorRejectedException {
        if (resetRejectedCursor || recoverable == null) {
          rethrow;
        }
        // A server restore invalidates both the durable high-water mark and
        // every sequence assigned by the lost history. Re-queue the mirror
        // under its original conflict tuples and persist a recovery phase.
        // The zero pull must finish before the owner applies and recollects:
        // otherwise an unreadable source can look like an opt-out and erase
        // the mirror's only surviving copy. A server that also rejects zero
        // still fails instead of looping forever.
        await locally(() async {
          await recoverable.recoverFromRejectedCursor();
          await beforeCursorRecoveryPull?.call();
        });
        recoveryPending = true;
        resetRejectedCursor = true;
        round--;
        continue;
      }
      if (recoveryPending) {
        // Pulling first lets normal domain policy decide what should be
        // restored, withheld, expired, or cancelled. Complete the durable
        // phase only after that policy and its recollection succeed; a crash
        // or callback failure resumes here on the next run instead of pushing
        // an unreviewed recovered copy.
        await locally(() async {
          await afterCursorRecovery?.call();
          await recoverable!.completeCursorRecovery();
        });
        recoveryPending = false;
      }
      final pushed = await _pushOnce(
        api,
        pulled.limits,
        refused,
        runLocal: locally,
        refreshLocal: refreshLocal,
      );
      totalPulled += pulled.applied;
      totalPushed += pushed.accepted;
      // Converged when nothing new arrived and nothing remains to push.
      final dirty = await locally(() async {
        await refreshLocal?.call(SyncLocalRefreshMode.normal);
        return store.dirtyRecords();
      });
      if (pulled.applied == 0 && dirty.isEmpty) break;
      // Safety: if a push keeps getting rejected with no progress, stop.
      if (pulled.applied == 0 &&
          pushed.accepted == 0 &&
          pushed.rejected == 0) {
        break;
      }
    }
    final outcome = SyncOutcome(
        pulled: totalPulled, pushed: totalPushed, rounds: round);
    if (refused.isEmpty) return outcome;
    // A later round may have adopted another device's winning copy of a
    // refused record, which settles it; only the ones still owed are news.
    final owed = await locally(() async {
      await refreshLocal?.call(SyncLocalRefreshMode.normal);
      return {for (final record in await store.dirtyRecords()) record.id};
    });
    final stillRefused = [
      for (final id in refused)
        if (owed.contains(id)) RefusedRecord(id),
    ];
    if (stillRefused.isEmpty) return outcome;
    throw SyncRecordsRefused(stillRefused, outcome: outcome);
  }

  /// Applies a pull and reports how this round's push may be sized.
  ///
  /// The limits ride along rather than living on the engine: [sync] takes the
  /// endpoint per call, so they belong to one run against one server. As a
  /// field they would outlive the server that advertised them and, with two
  /// runs overlapping, could size one run's push against the other's server.
  /// A pull carrying no advertisement yields the shipped defaults, which is
  /// what such a server enforces by definition.
  Future<({int applied, PushLimits limits})> _pullOnce(
    SyncApi api, {
    required SyncLocalRunner runLocal,
    required SyncLocalRefresh? refreshLocal,
    required bool cursorRecoveryPending,
  }) async {
    final since = await runLocal(store.highWaterSeq);
    var applied = 0;
    var snapshotHighWater = since;
    var limits = const PushLimits();
    await for (final page in pullPages(api, since: since)) {
      limits = page.limits ?? limits;
      await runLocal(() async {
        await refreshLocal?.call(
          cursorRecoveryPending
              ? SyncLocalRefreshMode.cursorRecovery
              : SyncLocalRefreshMode.normal,
        );
        for (final remote in page.records) {
          final remoteSeq = remote.seq;
          if (remoteSeq != null && remoteSeq > snapshotHighWater) {
            snapshotHighWater = remoteSeq;
          }
          final validator = remoteValidator;
          if (validator != null && !await validator(remote)) continue;
          final local = await store.getRecord(remote.id);
          if (local == null) {
            await store.putRemote(remote);
            applied++;
            continue;
          }
          // Lww.resolve returns one of the two objects passed in, so identity
          // tells us which side won.
          final remoteWon = identical(Lww.resolve(local, remote), remote);
          if (remoteWon) {
            await store.putRemote(remote);
            applied++;
          }
        }
        // Advance only through a sequence actually observed on this complete
        // page. A later timeout resumes here, never at the advertised
        // watermark.
        await store.setHighWaterSeq(snapshotHighWater);
      });
    }
    return (applied: applied, limits: limits);
  }

  /// Pushes everything dirty, in as many requests as the server's limits
  /// require. One oversized request would be refused whole and the next round
  /// would rebuild it identically, so an unbatched push turns a large dirty set
  /// into a sync that never converges rather than one that is merely slow.
  ///
  /// Batches go out in sequence and each response is applied before the next
  /// request leaves, so a batch that fails costs the batches behind it, never
  /// the bookkeeping for the ones already accepted. The counts returned still
  /// cover the whole dirty set but for the records in [refused], which is what
  /// [sync]'s no-progress guard reads.
  ///
  /// Records in [refused] are skipped, and a record the server refuses as too
  /// large is added to it.
  Future<({int accepted, int rejected})> _pushOnce(
    SyncApi api,
    PushLimits limits,
    Set<String> refused, {
    required SyncLocalRunner runLocal,
    required SyncLocalRefresh? refreshLocal,
  }) async {
    List<String>? remainingIds;
    var accepted = 0;
    var rejected = 0;
    while (true) {
      final batch = await runLocal(() async {
        await refreshLocal?.call(SyncLocalRefreshMode.normal);
        final dirty = [
          for (final record in await store.dirtyRecords())
            if (!refused.contains(record.id)) record,
        ];
        remainingIds ??= [for (final record in dirty) record.id];
        final byId = {for (final record in dirty) record.id: record};
        remainingIds!.removeWhere((id) => !byId.containsKey(id));
        if (remainingIds!.isEmpty) return null;
        final current = [for (final id in remainingIds!) byId[id]!];
        return batchForPush(current, limits).first;
      });
      if (batch == null) break;
      // A batch the server refuses whole (413, oversized body or blob) is not
      // the benign per-record rejection below, which the next pull resolves:
      // nothing local can fix it, so it must not pass for a sync that
      // succeeded while a record never leaves the device. The batches already
      // accepted stay marked synced.
      //
      // A refused batch of one record is that record's own failure, though:
      // the batcher sends a record past a cap alone and last for exactly this.
      // So it is set aside and reported at the end of the run, and the pull
      // this run made still reaches its caller. Any other failure, including
      // a refused batch of several, ends the run here as it always has.
      final PushResponse resp;
      try {
        resp = await api.push(batch);
      } on ApiError catch (error) {
        if (error.code != _payloadTooLarge || batch.length != 1) rethrow;
        refused.add(batch.single.id);
        remainingIds!.remove(batch.single.id);
        continue;
      }
      final sentById = {for (final record in batch) record.id: record};
      await runLocal(() async {
        await refreshLocal?.call(SyncLocalRefreshMode.normal);
        for (final result in resp.results) {
          final sent = sentById[result.id];
          if (sent == null) {
            throw StateError(
              'Sync server returned a push result for unsent record '
              '${result.id}',
            );
          }
          final settling = store;
          if (settling is PushSettlingRecordStore) {
            await settling.settlePush(sent, result);
          } else if (result.accepted &&
              _sameRecord(await store.getRecord(result.id), sent)) {
            // A basic store cannot settle an operation atomically. Compare the
            // current value before clearing dirty state so a replacement made
            // while the request was in flight remains queued.
            await store.markSynced(result.id, result.seq);
          }
          if (result.accepted) {
            accepted++;
          } else {
            // A settling store may restore the displaced server winner here. A
            // simpler store keeps the losing version dirty until a pull adopts
            // that winner; assigning its seq to our payload would mislabel it.
            rejected++;
          }
        }
      });
      remainingIds!.removeWhere(sentById.containsKey);
    }
    return (accepted: accepted, rejected: rejected);
  }
}

bool _sameRecord(EncryptedRecord? left, EncryptedRecord right) {
  if (left == null ||
      left.envelopeVersion != right.envelopeVersion ||
      left.id != right.id ||
      left.updatedAt != right.updatedAt ||
      left.deviceId != right.deviceId ||
      left.deleted != right.deleted ||
      left.seq != right.seq ||
      left.blob.length != right.blob.length) {
    return false;
  }
  for (var i = 0; i < left.blob.length; i++) {
    if (left.blob[i] != right.blob[i]) return false;
  }
  return true;
}
