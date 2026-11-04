import '../crypto/vault.dart';
import 'record.dart';

/// One authenticated open, including the format found inside the ciphertext.
///
/// Callers migrating legacy records need the inner version without decrypting
/// a second time. [record] is the same value [RecordCodec.decrypt] returns.
final class OpenedRecordEnvelope {
  final DecryptedRecord record;
  final int version;

  const OpenedRecordEnvelope({required this.record, required this.version});
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

  Future<EncryptedRecord> encrypt(DecryptedRecord record) async {
    if (record.kind == RecordKind.unknown) {
      throw ArgumentError.value(
        record.kind,
        'record.kind',
        'Unknown record kinds cannot be encrypted',
      );
    }

    // The server needs the outer tuple for conflict resolution, but the same
    // tuple is sealed inside the blob so it cannot alter or transplant it.
    // `seq` is absent deliberately: the server assigns it after encryption.
    final blob = await VaultCrypto.sealJson(vaultKey, {
      'version': kRecordEnvelopeVersion,
      'id': record.id,
      'updatedAt': record.updatedAt,
      'deviceId': record.deviceId,
      'deleted': record.deleted,
      'kind': record.kind.name,
      'data': record.deleted ? const <String, dynamic>{} : record.data,
    });
    return EncryptedRecord(
      id: record.id,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: record.deleted,
      seq: null,
      envelopeVersion: kRecordEnvelopeVersion,
      blob: blob,
    );
  }

  Future<DecryptedRecord> decrypt(EncryptedRecord record) async =>
      (await openEnvelope(record)).record;

  Future<OpenedRecordEnvelope> openEnvelope(EncryptedRecord record) async {
    if (record.blob.isEmpty) {
      throw const FormatException('Unsealed record tombstones are not trusted');
    }

    final payload = await VaultCrypto.openJson(vaultKey, record.blob);
    final version = payload['version'];
    if (version == null) {
      final outerVersion = record.envelopeVersion;
      if (outerVersion != null && outerVersion != 1) {
        throw const FormatException('Record envelope version does not match');
      }
      return OpenedRecordEnvelope(
        record: _decryptLegacy(record, payload),
        version: 1,
      );
    }
    if (version != kRecordEnvelopeVersion) {
      throw FormatException('Unsupported record envelope version: $version');
    }
    final outerVersion = record.envelopeVersion;
    if (outerVersion != null && outerVersion != version) {
      throw const FormatException('Record envelope version does not match');
    }

    _verifyEnvelope(record, payload);
    final deleted = payload['deleted'] as bool;
    return OpenedRecordEnvelope(
      version: kRecordEnvelopeVersion,
      record: DecryptedRecord(
        id: payload['id'] as String,
        kind: recordKindFromName(payload['kind'] as String),
        updatedAt: payload['updatedAt'] as int,
        deviceId: payload['deviceId'] as String,
        deleted: deleted,
        data: deleted
            ? const {}
            : (payload['data'] as Map).cast<String, dynamic>(),
      ),
    );
  }

  DecryptedRecord _decryptLegacy(
    EncryptedRecord record,
    Map<String, dynamic> payload,
  ) {
    // V1 live records did not seal their routing tuple. They remain readable
    // during migration, but an outer delete is never trusted: accepting it
    // would let the server strip or replace a v2 blob to forge a tombstone.
    if (record.deleted) {
      throw const FormatException('Legacy record tombstones are not trusted');
    }

    return DecryptedRecord(
      id: record.id,
      kind: recordKindFromName(payload['kind'] as String),
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      data: (payload['data'] as Map).cast<String, dynamic>(),
    );
  }

  void _verifyEnvelope(
    EncryptedRecord record,
    Map<String, dynamic> payload,
  ) {
    final innerUpdatedAt = payload['updatedAt'];
    if (payload['id'] != record.id ||
        innerUpdatedAt is! int ||
        innerUpdatedAt != record.updatedAt ||
        payload['deviceId'] != record.deviceId ||
        payload['deleted'] != record.deleted ||
        payload['kind'] is! String ||
        payload['data'] is! Map) {
      throw const FormatException('Record envelope metadata does not match');
    }
  }
}
