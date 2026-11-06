import 'package:seance_protocol/seance_protocol.dart';

void validateLegacyMigrationBatch(List<LegacyRecordMigration> migrations) {
  final expectedIds = <String>{};
  final replacementIds = <String>{};
  for (final migration in migrations) {
    if (migration.expected.envelopeVersion != kLegacyRecordEnvelopeVersion ||
        migration.expected.seq == null) {
      throw ArgumentError.value(
        migration.expected,
        'migration.expected',
        'must be a sequenced legacy record',
      );
    }
    if (migration.replacement.envelopeVersion !=
            kCurrentRecordEnvelopeVersion ||
        migration.replacement.seq != null ||
        migration.replacement.blob.isEmpty) {
      throw ArgumentError.value(
        migration.replacement,
        'migration.replacement',
        'must be an unsequenced, sealed current record',
      );
    }
    if (!expectedIds.add(migration.expected.id) ||
        !replacementIds.add(migration.replacement.id)) {
      throw ArgumentError('A migration batch cannot repeat record ids');
    }
  }
  for (final migration in migrations) {
    if (migration.replacement.id != migration.expected.id &&
        expectedIds.contains(migration.replacement.id)) {
      throw ArgumentError(
        'A replacement cannot target another expected row in its batch',
      );
    }
  }
}

bool sameEncryptedRecord(EncryptedRecord a, EncryptedRecord b) {
  if (a.envelopeVersion != b.envelopeVersion ||
      a.id != b.id ||
      a.updatedAt != b.updatedAt ||
      a.deviceId != b.deviceId ||
      a.deleted != b.deleted ||
      a.seq != b.seq ||
      a.blob.length != b.blob.length) {
    return false;
  }
  for (var i = 0; i < a.blob.length; i++) {
    if (a.blob[i] != b.blob[i]) return false;
  }
  return true;
}
