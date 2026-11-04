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

  /// Restore clean v1 server records displaced only by a same-tuple v2
  /// re-encryption. Called after a pull from a server that did not advertise
  /// preservation of the additive envelope marker, before anything is pushed.
  /// Returns the number of dirty migrations settled locally.
  Future<int> restoreLegacyEnvelopeMigrations();

  Future<int> highWaterSeq();
  Future<void> setHighWaterSeq(int seq);
}

/// In-memory implementation used by tests and as a reference; the Flutter app
/// backs the same interface with SQLite.
class InMemoryLocalRecordStore implements LocalRecordStore {
  final Map<String, EncryptedRecord> _records = {};
  final Set<String> _dirty = {};
  final Map<String, EncryptedRecord> _legacyEnvelopeVersions = {};
  int _highWater = 0;

  @override
  Future<List<EncryptedRecord>> allRecords() async => _records.values.toList();

  @override
  Future<EncryptedRecord?> getRecord(String id) async => _records[id];

  @override
  Future<void> putLocal(EncryptedRecord record) async {
    final existing = _records[record.id];
    if (existing != null &&
        !_dirty.contains(record.id) &&
        isEnvelopeFormatMigration(existing, record)) {
      _legacyEnvelopeVersions[record.id] = existing;
    }
    _records[record.id] = record;
    _dirty.add(record.id);
  }

  @override
  Future<void> putRemote(EncryptedRecord record) async {
    _records[record.id] = record;
    _dirty.remove(record.id);
    _legacyEnvelopeVersions.remove(record.id);
  }

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async =>
      _dirty.map((id) => _records[id]!).toList();

  @override
  Future<void> markSynced(String id, int seq) async {
    final r = _records[id];
    if (r != null) _records[id] = r.withSeq(seq);
    _dirty.remove(id);
    _legacyEnvelopeVersions.remove(id);
  }

  @override
  Future<int> restoreLegacyEnvelopeMigrations() async {
    var restored = 0;
    for (final id in _dirty.toList()) {
      final current = _records[id];
      final legacy = _legacyEnvelopeVersions[id];
      if (current == null ||
          legacy == null ||
          !isEnvelopeFormatMigration(legacy, current)) {
        continue;
      }
      _records[id] = legacy;
      _dirty.remove(id);
      _legacyEnvelopeVersions.remove(id);
      restored++;
    }
    return restored;
  }

  @override
  Future<int> highWaterSeq() async => _highWater;

  @override
  Future<void> setHighWaterSeq(int seq) async {
    if (seq > _highWater) _highWater = seq;
  }
}

/// Whether [migrated] is only an authenticated-envelope replacement for
/// [legacy], with the domain LWW tuple unchanged.
bool isEnvelopeFormatMigration(
  EncryptedRecord legacy,
  EncryptedRecord migrated,
) =>
    legacy.id == migrated.id &&
    legacy.updatedAt == migrated.updatedAt &&
    legacy.deviceId == migrated.deviceId &&
    legacy.deleted == migrated.deleted &&
    (legacy.envelopeVersion ?? 1) == 1 &&
    migrated.envelopeVersion == kRecordEnvelopeVersion;
