import '../crypto/vault.dart';
import 'record.dart';

/// A record's sealed identity disagrees with the plaintext routing or
/// conflict metadata supplied by the sync service.
///
/// Treat this like an authentication failure: the record must be preserved
/// for recovery or a corrected peer, but never applied to a local store.
final class RecordIntegrityException implements Exception {
  const RecordIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'RecordIntegrityException: $message';
}

/// The only data a legacy v1 payload authenticated.
///
/// It deliberately omits id, timestamps, device id and deletion state. Those
/// fields lived outside the v1 ciphertext and must come from trusted local
/// canonical state when an application explicitly migrates an old record.
final class LegacyRecordPayload {
  const LegacyRecordPayload({required this.kind, required this.data});

  final RecordKind kind;
  final Map<String, dynamic> data;
}

/// Encrypts [DecryptedRecord]s into [EncryptedRecord]s and back, using the
/// device's vault key. This is the only bridge between plaintext application
/// data and what the sync server ever sees.
///
/// A freshly encrypted record has `seq == null`: the sequence number is
/// assigned by the server on upsert, and the client's sync engine tracks the
/// high-water mark separately from the record itself.
class RecordCodec {
  final List<int> vaultKey;
  const RecordCodec(this.vaultKey);

  static const int _envelopeVersion = 2;
  static const String _purpose = 'seance.sync.record';

  Future<EncryptedRecord> encrypt(DecryptedRecord record) async {
    if (record.kind == RecordKind.unknown) {
      throw ArgumentError.value(
        record.kind,
        'record.kind',
        'Unknown record kinds cannot be encrypted',
      );
    }

    // Keep the server-owned sequence number outside the authenticator: it is
    // assigned only after this device seals the record. Every client-owned
    // routing and conflict field is duplicated inside the ciphertext, so a
    // service can index and compare its plaintext copy but cannot alter it
    // without detection. Keeping `kind` and `data` at their legacy keys lets
    // older clients open live v2 records while upgraded clients enforce the
    // authenticated envelope.
    final blob = await VaultCrypto.sealJson(vaultKey, {
      'envelopeVersion': _envelopeVersion,
      'purpose': _purpose,
      'id': record.id,
      'kind': record.kind.name,
      'updatedAt': record.updatedAt,
      'deviceId': record.deviceId,
      'deleted': record.deleted,
      'data': record.deleted ? const <String, dynamic>{} : record.data,
    });
    return EncryptedRecord(
      envelopeVersion: _envelopeVersion,
      id: record.id,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: record.deleted,
      seq: null,
      blob: blob,
    );
  }

  Future<DecryptedRecord> decrypt(EncryptedRecord record) async {
    if (record.envelopeVersion != _envelopeVersion) {
      throw RecordIntegrityException(
        'Record ${record.id} uses unsupported envelope version '
        '${record.envelopeVersion}',
      );
    }
    if (record.blob.isEmpty) {
      throw RecordIntegrityException(
        'Record ${record.id} has no authenticated payload',
      );
    }
    final payload = await VaultCrypto.openJson(vaultKey, record.blob);
    final version = payload['envelopeVersion'];

    if (version != record.envelopeVersion) {
      throw RecordIntegrityException(
        'Record ${record.id} has mismatched sealed envelope version $version',
      );
    }

    _matches(payload, 'purpose', _purpose, record.id);
    _matches(payload, 'id', record.id, record.id);
    _matches(payload, 'updatedAt', record.updatedAt, record.id);
    _matches(payload, 'deviceId', record.deviceId, record.id);
    _matches(payload, 'deleted', record.deleted, record.id);
    return _decodePayload(record, payload, deleted: record.deleted);
  }

  /// Open a legacy live payload for an explicit, application-owned migration.
  ///
  /// Normal sync must never call this. The returned value excludes every
  /// unauthenticated outer field, so a caller can only re-seal it after finding
  /// matching trusted local state. Legacy tombstones cannot be migrated because
  /// they had no authenticated payload or kind.
  Future<LegacyRecordPayload> decryptLegacyForMigration(
    EncryptedRecord record,
  ) async {
    if (record.envelopeVersion != 1 || record.deleted || record.blob.isEmpty) {
      throw RecordIntegrityException(
        'Record ${record.id} is not an authenticated legacy live payload',
      );
    }
    final payload = await VaultCrypto.openJson(vaultKey, record.blob);
    if (payload.containsKey('envelopeVersion')) {
      throw RecordIntegrityException(
        'Record ${record.id} is not a legacy envelope',
      );
    }
    final kind = payload['kind'];
    final data = payload['data'];
    if (kind is! String || data is! Map) {
      throw RecordIntegrityException(
        'Record ${record.id} has an invalid legacy payload',
      );
    }
    return LegacyRecordPayload(
      kind: recordKindFromName(kind),
      data: data.cast<String, dynamic>(),
    );
  }

  static DecryptedRecord _decodePayload(
    EncryptedRecord record,
    Map<String, dynamic> payload, {
    required bool deleted,
  }) {
    final kind = payload['kind'];
    final data = payload['data'];
    if (kind is! String || data is! Map) {
      throw RecordIntegrityException(
        'Record ${record.id} has an invalid sealed payload',
      );
    }
    final typedData = data.cast<String, dynamic>();
    if (deleted && typedData.isNotEmpty) {
      throw RecordIntegrityException(
        'Tombstone ${record.id} carries unexpected data',
      );
    }
    return DecryptedRecord(
      id: record.id,
      kind: recordKindFromName(kind),
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: deleted,
      data: typedData,
    );
  }

  static void _matches(
    Map<String, dynamic> payload,
    String field,
    Object expected,
    String id,
  ) {
    if (payload[field] == expected) return;
    throw RecordIntegrityException(
      'Record $id has unauthenticated $field metadata',
    );
  }
}
