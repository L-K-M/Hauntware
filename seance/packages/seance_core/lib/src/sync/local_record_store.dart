import 'package:seance_protocol/seance_protocol.dart';

/// The client's local mirror of synced records plus its sync bookkeeping.
///
/// A record is "dirty" when it has a local change not yet accepted by the
/// server. [putLocal] marks a record dirty (a local edit); [putRemote] stores a
/// record pulled from the server without marking it dirty; [markSynced] clears
/// the dirty flag once the server has assigned a sequence number.
abstract class LocalRecordStore {
  Future<List<EncryptedRecord>> allRecords();
  Future<EncryptedRecord?> getRecord(String id);

  /// Store a locally-originated change and mark it for push.
  Future<void> putLocal(EncryptedRecord record);

  /// Store a server-originated record; not dirty.
  Future<void> putRemote(EncryptedRecord record);

  Future<List<EncryptedRecord>> dirtyRecords();
  Future<void> markSynced(String id, int seq);

  Future<int> highWaterSeq();
  Future<void> setHighWaterSeq(int seq);
}

/// A mirror that can settle the exact operation a push sent.
///
/// A local edit may replace [sent] while the request is in flight. Settling by
/// id alone would clear that newer edit, while a rejected stale write may need
/// to restore a displaced server winner already below the pull cursor. A
/// rejected push restores that copy only when its sequence matches the
/// server's reported winner; otherwise the local edit remains dirty for a
/// later pull to reconcile.
abstract interface class PushSettlingRecordStore implements LocalRecordStore {
  Future<EncryptedRecord?> settlePush(
    EncryptedRecord sent,
    PushResult result,
  );
}

/// A durable mirror that can withdraw an unsent local publication.
///
/// Disabling an opt-in sync kind must not upload a dirty value left by an
/// earlier offline round. Implementations restore the clean server copy the
/// edit displaced, or remove a brand-new local value when there was none.
abstract interface class LocalPublicationStore implements LocalRecordStore {
  Future<void> cancelLocal(String id);
}

/// A mirror that can re-queue server-derived state after a rejected cursor.
///
/// Resetting only the cursor is unsafe after a server rollback: clean records
/// from the lost history would never be offered back when a full pull no
/// longer contains them. Recovery re-queues every mirrored record under its
/// original conflict tuple and persists a pending phase. The owner must first
/// complete a full pull and re-apply its domain policy before any remaining
/// records are pushed. Persisting that phase keeps a crash from reverting to
/// ordinary collection and mistaking an unreadable source for an opt-out.
abstract interface class RecoverableSyncCursorStore
    implements LocalRecordStore {
  Future<void> recoverFromRejectedCursor();
  Future<bool> cursorRecoveryPending();
  Future<void> completeCursorRecovery();
}

/// In-memory implementation used by tests and lightweight embeddings; the
/// Flutter app uses the account-scoped persistent implementation.
class InMemoryLocalRecordStore
    implements
        PushSettlingRecordStore,
        LocalPublicationStore,
        RecoverableSyncCursorStore {
  final Map<String, EncryptedRecord> _records = {};
  final Set<String> _dirty = {};
  final Map<String, EncryptedRecord> _displaced = {};
  int _highWater = 0;
  bool _cursorRecoveryPending = false;

  @override
  Future<List<EncryptedRecord>> allRecords() async => _records.values.toList();

  @override
  Future<EncryptedRecord?> getRecord(String id) async => _records[id];

  @override
  Future<void> putLocal(EncryptedRecord record) async {
    final existing = _records[record.id];
    if (existing != null && !_dirty.contains(record.id)) {
      _displaced[record.id] = existing;
    }
    _records[record.id] = record;
    _dirty.add(record.id);
  }

  @override
  Future<void> putRemote(EncryptedRecord record) async {
    _records[record.id] = record;
    _dirty.remove(record.id);
    _displaced.remove(record.id);
  }

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async =>
      _dirty.map((id) => _records[id]!).toList();

  @override
  Future<void> markSynced(String id, int seq) async {
    final r = _records[id];
    if (r != null) _records[id] = r.withSeq(seq);
    _dirty.remove(id);
    _displaced.remove(id);
  }

  @override
  Future<EncryptedRecord?> settlePush(
    EncryptedRecord sent,
    PushResult result,
  ) async {
    if (result.id != sent.id) {
      throw ArgumentError('push result must identify the sent record');
    }
    if (!identical(_records[sent.id], sent) || !_dirty.contains(sent.id)) {
      return null;
    }
    if (result.accepted) {
      _records[sent.id] = sent.withSeq(result.seq);
      _dirty.remove(sent.id);
      _displaced.remove(sent.id);
    } else {
      final restored = _displaced.remove(sent.id);
      if (restored != null && restored.seq == result.seq) {
        _records[sent.id] = restored;
        _dirty.remove(sent.id);
        return restored;
      }
    }
    return null;
  }

  @override
  Future<void> cancelLocal(String id) async {
    if (!_dirty.remove(id)) return;
    final restored = _displaced.remove(id);
    if (restored == null) {
      _records.remove(id);
    } else {
      _records[id] = restored;
    }
  }

  @override
  Future<int> highWaterSeq() async => _highWater;

  @override
  Future<void> setHighWaterSeq(int seq) async {
    if (seq > _highWater) _highWater = seq;
  }

  @override
  Future<void> recoverFromRejectedCursor() async {
    final cleanIds = <String>[
      for (final entry in _records.entries)
        if (!_dirty.contains(entry.key)) entry.key,
    ];
    for (final id in cleanIds) {
      final record = _records[id]!;
      _records[id] = EncryptedRecord(
        envelopeVersion: record.envelopeVersion,
        id: record.id,
        updatedAt: record.updatedAt,
        deviceId: record.deviceId,
        deleted: record.deleted,
        seq: null,
        blob: record.blob,
      );
    }
    _dirty.addAll(cleanIds);
    _displaced.clear();
    _highWater = 0;
    _cursorRecoveryPending = true;
  }

  @override
  Future<bool> cursorRecoveryPending() async => _cursorRecoveryPending;

  @override
  Future<void> completeCursorRecovery() async {
    _cursorRecoveryPending = false;
  }
}
