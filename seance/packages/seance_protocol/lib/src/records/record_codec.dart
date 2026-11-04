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
      id: record.id,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: record.deleted,
      seq: null,
      blob: blob,
    );
  }

  Future<DecryptedRecord> decrypt(EncryptedRecord record) async {
    if (record.blob.isEmpty) {
      throw RecordIntegrityException(
        'Record ${record.id} has no authenticated payload',
      );
    }
    final payload = await VaultCrypto.openJson(vaultKey, record.blob);
    final version = payload['envelopeVersion'];

    // v1 live records sealed only `{kind, data}`. Continue to read them so an
    // upgraded device can materialize and re-seal existing accounts. A v1
    // tombstone never had a payload at all; accepting either an empty one or a
    // live v1 blob with its outer flag flipped would preserve the forgery.
    if (version == null) {
      if (record.deleted) {
        throw RecordIntegrityException(
          'Legacy tombstone ${record.id} is not authenticated',
        );
      }
      return _decodePayload(record, payload, deleted: false);
    }
    if (version != _envelopeVersion) {
      throw RecordIntegrityException(
        'Record ${record.id} uses unsupported envelope version $version',
      );
    }

    _matches(payload, 'purpose', _purpose, record.id);
    _matches(payload, 'id', record.id, record.id);
    _matches(payload, 'updatedAt', record.updatedAt, record.id);
    _matches(payload, 'deviceId', record.deviceId, record.id);
    _matches(payload, 'deleted', record.deleted, record.id);
    return _decodePayload(record, payload, deleted: record.deleted);
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
