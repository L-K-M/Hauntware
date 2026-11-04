import 'package:seance_protocol/seance_protocol.dart';

import 'local_record_store.dart';
import 'push_batcher.dart';

/// The authenticated record endpoints the engine needs. Implemented over HTTP
/// by [HttpSyncClient]; faked in tests.
abstract class SyncApi {
  Future<PullResponse> pull({required int since, int? through});
  Future<PushResponse> push(List<EncryptedRecord> records);
}

/// The server rejected a cursor because its sequence stream moved backwards.
final class SyncCursorRejectedException implements Exception {
  const SyncCursorRejectedException([this.message = 'sync cursor rejected']);

  final String message;

  @override
  String toString() => 'SyncCursorRejectedException: $message';
}

/// Aggregate metadata from one stable-fence page walk.
final class PullPagesResult {
  const PullPagesResult({
    required this.records,
    required this.limits,
    required this.recordEnvelopeVersion,
  });

  final int records;
  final PushLimits? limits;
  final int? recordEnvelopeVersion;
}

/// Drain one pull snapshot, validating every cursor before [applyPage].
///
/// The callback receives the cursor that becomes durable only after it stores
/// the page. A legacy response remains one page and advances only through
/// record sequences actually observed. [stopAfterPage] may end a read-only
/// probe after a fully validated page; callers that persist a cursor must omit
/// it and drain the fence.
Future<PullPagesResult> pullAllPages(
  SyncApi api, {
  required int since,
  required Future<void> Function(PullResponse page, int advanceTo) applyPage,
  bool Function(PullResponse page)? stopAfterPage,
  int maxPages = 1000000,
}) async {
  if (since < 0) throw ArgumentError.value(since, 'since');
  if (maxPages <= 0) throw ArgumentError.value(maxPages, 'maxPages');

  var cursor = since;
  int? fence;
  var total = 0;
  PushLimits? limits;
  int? envelopeVersion;
  var sawEnvelopeMetadata = false;

  for (var pageNumber = 1; pageNumber <= maxPages; pageNumber++) {
    final response = await api.pull(since: cursor, through: fence);
    final responseFence = response.through;
    final next = response.nextSince;
    final paginated = responseFence != null;

    if (!paginated) {
      if (fence != null || next != null) {
        throw const FormatException('Pull pagination metadata disappeared');
      }
    } else {
      if (responseFence < since || responseFence < cursor) {
        throw const SyncCursorRejectedException(
          'The server pull watermark is behind the client cursor',
        );
      }
      if (fence != null && responseFence != fence) {
        throw const FormatException(
            'Pull snapshot fence changed between pages');
      }
      fence ??= responseFence;
    }

    var observed = cursor;
    for (final record in response.records) {
      final seq = record.seq;
      if (seq == null || seq <= observed) {
        throw const FormatException(
          'Pulled record sequences must be present and strictly increasing',
        );
      }
      if (responseFence != null && seq > responseFence) {
        throw const FormatException('Pulled record lies beyond its snapshot');
      }
      observed = seq;
    }

    final int advanceTo;
    var finalPage = true;
    if (!paginated) {
      advanceTo = observed;
    } else if (next != null) {
      if (response.records.isEmpty || next != observed) {
        throw const FormatException(
          'Intermediate pull cursor must equal the last record sequence',
        );
      }
      if (next <= cursor || next >= responseFence) {
        throw const FormatException('Intermediate pull cursor cannot progress');
      }
      if (response.latestSeq != next) {
        throw const FormatException(
          'Intermediate pull latestSeq must equal nextSince',
        );
      }
      advanceTo = next;
      finalPage = false;
    } else {
      if (response.latestSeq != responseFence) {
        throw const FormatException(
          'Final pull latestSeq must equal the snapshot fence',
        );
      }
      advanceTo = responseFence;
    }

    limits = _conservativeLimits(
      limits,
      response.limits ?? const PushLimits(),
    );
    final marker = response.recordEnvelopeVersion;
    if (!sawEnvelopeMetadata) {
      envelopeVersion = marker;
      sawEnvelopeMetadata = true;
    } else if (envelopeVersion == null || marker == null) {
      envelopeVersion = null;
    } else if (marker < envelopeVersion) {
      envelopeVersion = marker;
    }

    await applyPage(response, advanceTo);
    total += response.records.length;
    cursor = advanceTo;
    if (finalPage || (stopAfterPage?.call(response) ?? false)) {
      return PullPagesResult(
        records: total,
        limits: limits,
        recordEnvelopeVersion: envelopeVersion,
      );
    }
  }

  throw FormatException('Pull exceeded the $maxPages-page safety limit');
}

PushLimits _conservativeLimits(PushLimits? a, PushLimits b) {
  if (a == null) return b;
  return PushLimits(
    maxBodyBytes:
        a.maxBodyBytes < b.maxBodyBytes ? a.maxBodyBytes : b.maxBodyBytes,
    maxRecordsPerPush: a.maxRecordsPerPush < b.maxRecordsPerPush
        ? a.maxRecordsPerPush
        : b.maxRecordsPerPush,
    maxBlobBytes:
        a.maxBlobBytes < b.maxBlobBytes ? a.maxBlobBytes : b.maxBlobBytes,
  );
}

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
/// Such a record is isolated (initially by [batchForPush], or by recursively
/// splitting a refused batch), so nothing else in the run has to pay for it:
/// the run carries on and this is thrown at the end, with [outcome] describing
/// what did happen.
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

  SyncEngine(this.store, {this.maxRounds = 5});

  /// Throws [SyncRecordsRefused] once the run is otherwise complete if the
  /// server refused any record as too large; any other failure is thrown where
  /// it happens.
  Future<SyncOutcome> sync(SyncApi api) async {
    var totalPulled = 0;
    var totalPushed = 0;
    var round = 0;
    // Ids the server refused as too large during this run. Each is sent once
    // per run, not once per round: nothing between rounds can shrink it, and
    // re-sending a record past the cap every round would upload it up to
    // [maxRounds] times only to be refused each time. Per run rather than on
    // the engine for the reason the limits are (see [_pullOnce]).
    final refused = <String>{};
    while (round < maxRounds) {
      round++;
      final pulled = await _pullOnce(api);
      if ((pulled.recordEnvelopeVersion ?? 0) < kRecordEnvelopeVersion) {
        await store.restoreLegacyEnvelopeMigrations();
      }
      final pushed = await _pushOnce(api, pulled.limits, refused);
      totalPulled += pulled.applied;
      totalPushed += pushed.accepted;
      // Converged when nothing new arrived and nothing remains to push.
      if (pulled.applied == 0 && (await store.dirtyRecords()).isEmpty) break;
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
    final owed = {for (final record in await store.dirtyRecords()) record.id};
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
  Future<({int applied, PushLimits limits, int? recordEnvelopeVersion})>
      _pullOnce(SyncApi api) async {
    final since = await store.highWaterSeq();
    var applied = 0;
    final pulled = await pullAllPages(
      api,
      since: since,
      applyPage: (resp, advanceTo) async {
        for (final remote in resp.records) {
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
          } else if ((resp.recordEnvelopeVersion ?? 0) <
                  kRecordEnvelopeVersion &&
              isEnvelopeFormatMigration(remote, local)) {
            // An old server resolves this same-tuple migration by its assigned
            // sequence, so restore its clean v1 copy before push.
            await store.putRemote(remote);
          }
        }
        await store.setHighWaterSeq(advanceTo);
      },
    );
    return (
      applied: applied,
      limits: pulled.limits ?? const PushLimits(),
      recordEnvelopeVersion: pulled.recordEnvelopeVersion,
    );
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
    Set<String> refused,
  ) async {
    final dirty = [
      for (final record in await store.dirtyRecords())
        if (!refused.contains(record.id)) record,
    ];
    if (dirty.isEmpty) return (accepted: 0, rejected: 0);
    var accepted = 0;
    var rejected = 0;
    await pushBatchesWithRecovery(
      batchForPush(prioritizeLikelyQuotaReclaimers(dirty), limits),
      push: (batch) async {
        final resp = await api.push(batch);
        var serverProgress = false;
        for (final result in resp.results) {
          if (result.accepted) {
            await store.markSynced(result.id, result.seq);
            accepted++;
            serverProgress = true;
          } else {
            // Keep the losing local version dirty until a pull adopts the
            // server winner; assigning its seq would mislabel our payload.
            rejected++;
          }
        }
        return serverProgress;
      },
      onRefused: (record) async => refused.add(record.id),
    );
    return (accepted: accepted, rejected: rejected);
  }
}
