import 'package:seance_protocol/seance_protocol.dart';

const String _payloadTooLarge = 'payload_too_large';
const String _accountQuotaExceeded = 'account_quota_exceeded';
const int _maxRecoveryRequests = 32;

final class _PushRecoveryBudget {
  var requests = 0;
  int? firstRecoveryRequest;
  ApiError? lastRecoveryError;

  void beforeRequest() {
    final first = firstRecoveryRequest;
    if (first != null && requests - first >= _maxRecoveryRequests) {
      throw lastRecoveryError!;
    }
    requests++;
  }

  void observeRecoverable(ApiError error) {
    lastRecoveryError = error;
    firstRecoveryRequest ??= requests - 1;
  }
}

/// Splits [records] into pushes that fit [limits], preserving the order of
/// every record that fits a body at all (the rest are deferred to the end, as
/// described below).
///
/// Greedy: records accumulate into a batch until the next one would take the
/// encoded body past [PushLimits.maxBodyBytes] or the batch past
/// [PushLimits.maxRecordsPerPush], at which point the batch is closed and a new
/// one starts. Both bounds matter — record sizes span orders of magnitude, so
/// neither a byte budget nor a record count alone bounds the other.
///
/// A record the server will refuse whatever it is batched with cannot be
/// batched into compliance: one that alone exceeds the body budget, and one
/// whose sealed blob exceeds [PushLimits.maxBlobBytes]. Both are answered with
/// a 413 for the *whole* push, so each is sent alone and last. Sent, because
/// the server is the authority on its own limits (the client may be working
/// from defaults, or from an advertisement an operator has since raised), so
/// refusing to send would risk permanently withholding a record the server
/// would have taken, while dropping it silently would lose data. Alone and
/// last, so its near-certain rejection costs only itself and not the records
/// that do fit — otherwise one record past a cap stops the whole account's
/// sync, identically every round, since the batching is deterministic.
List<List<EncryptedRecord>> batchForPush(
  List<EncryptedRecord> records,
  PushLimits limits,
) {
  final batches = <List<EncryptedRecord>>[];
  final unbatchable = <EncryptedRecord>[];
  var batch = <EncryptedRecord>[];
  var batchRecordBytes = 0;

  for (final record in records) {
    final recordBytes = record.encodedJsonBytes();
    final bodyAlone = PushRequest.bodyBytesFor(
      recordCount: 1,
      recordBytes: recordBytes,
    );
    // The blob cap is measured on the *decoded* blob, which is what the server
    // measures — not on the record's encoded size, which carries the base64
    // expansion and the envelope around it.
    if (bodyAlone > limits.maxBodyBytes ||
        record.blob.length > limits.maxBlobBytes) {
      unbatchable.add(record);
      continue;
    }

    final bodyWithRecord = PushRequest.bodyBytesFor(
      recordCount: batch.length + 1,
      recordBytes: batchRecordBytes + recordBytes,
    );
    final full = bodyWithRecord > limits.maxBodyBytes ||
        batch.length + 1 > limits.maxRecordsPerPush;
    // The emptiness check is what guarantees progress: a batch is never closed
    // empty, so every record lands in exactly one batch however the limits are
    // configured.
    if (full && batch.isNotEmpty) {
      batches.add(batch);
      batch = <EncryptedRecord>[];
      batchRecordBytes = 0;
    }
    batch.add(record);
    batchRecordBytes += recordBytes;
  }
  if (batch.isNotEmpty) batches.add(batch);

  for (final record in unbatchable) {
    batches.add([record]);
  }
  return batches;
}

/// Put likely quota-reclaiming writes first without changing the order of
/// equally likely records. Distinct record ids resolve LWW independently, so
/// tombstones and smaller replacements may safely make room before growth.
List<EncryptedRecord> prioritizeLikelyQuotaReclaimers(
  List<EncryptedRecord> records,
) {
  final ranked = [
    for (final (index, record) in records.indexed)
      (
        index: index,
        record: record,
        encodedBytes: record.encodedJsonBytes(),
      ),
  ]
    ..sort((a, b) {
      final deleted = (a.record.deleted ? 0 : 1)
          .compareTo(b.record.deleted ? 0 : 1);
      if (deleted != 0) return deleted;
      final size = a.encodedBytes.compareTo(b.encodedBytes);
      return size != 0 ? size : a.index.compareTo(b.index);
    });
  return [for (final entry in ranked) entry.record];
}

/// Push batches while isolating record-size failures and allowing a later
/// shrinking replacement to make room for an earlier quota-blocked batch.
///
/// After the first recoverable 413, at most 32 total push requests are
/// attempted. A pass with no accepted server write rethrows instead of
/// spinning.
Future<void> pushBatchesWithRecovery(
  List<List<EncryptedRecord>> batches, {
  required Future<bool> Function(List<EncryptedRecord>) push,
  required Future<void> Function(EncryptedRecord) onRefused,
}) async {
  if (batches.isEmpty) return;
  var pending = batches;
  ApiError? quotaError;
  final budget = _PushRecoveryBudget();
  for (var pass = 0; pass <= batches.length && pending.isNotEmpty; pass++) {
    final deferred = <List<EncryptedRecord>>[];
    var serverProgress = false;
    for (final batch in pending) {
      final result = await _pushRecoveringBatch(
        batch,
        push: push,
        onRefused: onRefused,
        budget: budget,
      );
      serverProgress = result.progress || serverProgress;
      deferred.addAll(result.deferred);
      quotaError = result.quotaError ?? quotaError;
    }
    if (deferred.isEmpty) return;
    if (!serverProgress) throw quotaError!;
    pending = deferred;
  }
  throw quotaError!;
}

Future<({
  bool progress,
  List<List<EncryptedRecord>> deferred,
  ApiError? quotaError,
})> _pushRecoveringBatch(
  List<EncryptedRecord> records, {
  required Future<bool> Function(List<EncryptedRecord>) push,
  required Future<void> Function(EncryptedRecord) onRefused,
  required _PushRecoveryBudget budget,
}) async {
  budget.beforeRequest();
  try {
    return (
      progress: await push(records),
      deferred: const <List<EncryptedRecord>>[],
      quotaError: null,
    );
  } on ApiError catch (error) {
    final quotaFailure = error.code == _accountQuotaExceeded;
    final sizeFailure = error.code == _payloadTooLarge;
    if (!quotaFailure && !sizeFailure) rethrow;
    budget.observeRecoverable(error);
    if (records.length == 1 && quotaFailure) {
      return (progress: false, deferred: [records], quotaError: error);
    }
    if (records.length == 1) {
      await onRefused(records.single);
      return (
        progress: false,
        deferred: const <List<EncryptedRecord>>[],
        quotaError: null,
      );
    }

    final midpoint = records.length ~/ 2;
    final ordered = quotaFailure
        ? prioritizeLikelyQuotaReclaimers(records)
        : records;
    final left = await _pushRecoveringBatch(
      ordered.sublist(0, midpoint),
      push: push,
      onRefused: onRefused,
      budget: budget,
    );
    final right = await _pushRecoveringBatch(
      ordered.sublist(midpoint),
      push: push,
      onRefused: onRefused,
      budget: budget,
    );
    return (
      progress: left.progress || right.progress,
      deferred: [...left.deferred, ...right.deferred],
      quotaError: right.quotaError ?? left.quotaError,
    );
  }
}
