import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

EncryptedRecord _record(String id, {int envelopeVersion = 1, int? seq = 1}) =>
    EncryptedRecord(
      envelopeVersion: envelopeVersion,
      id: id,
      updatedAt: 10,
      deviceId: 'device',
      deleted: false,
      seq: seq,
      blob: Uint8List.fromList([1, 2, 3]),
    );

void main() {
  test('legacy page size exactly matches its JSON encoding', () {
    final page = LegacyRecordPage(
      records: [_record('legacy')],
      nextId: 'legacy',
      hasMore: true,
      recordEnvelopeFloor: 1,
    );

    expect(
      page.encodedSizeBytes(),
      utf8.encode(jsonEncode(page.toJson())).length,
    );
    expect(LegacyRecordPage.fromJson(page.toJson()).nextId, 'legacy');
  });

  test('migration request and response round-trip every checkpoint field', () {
    final request = LegacyMigrationRequest(
      migrations: [
        LegacyRecordMigration(
          expected: _record('legacy'),
          replacement: _record('current', envelopeVersion: 2, seq: null),
        ),
      ],
      finalize: true,
    );
    final decoded = LegacyMigrationRequest.fromJson(request.toJson());
    expect(decoded.protocolVersion, kProtocolVersion);
    expect(decoded.finalize, isTrue);
    expect(decoded.migrations.single.expected.id, 'legacy');
    expect(decoded.migrations.single.replacement.id, 'current');

    const response = LegacyMigrationResponse(
      migrated: 1,
      stale: 2,
      latestSeq: 9,
      recordEnvelopeFloor: 2,
    );
    expect(
      LegacyMigrationResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test('missing login floor decodes conservatively', () {
    expect(
      LoginResponse.fromJson(const {'token': 'token'}).recordEnvelopeFloor,
      kLegacyRecordEnvelopeVersion,
    );
    expect(
      const LoginResponse(token: 'token').recordEnvelopeFloor,
      kCurrentRecordEnvelopeVersion,
    );
    expect(
      PullResponse.fromJson(const {
        'records': <Object>[],
        'latestSeq': 0,
      }).recordEnvelopeFloor,
      kLegacyRecordEnvelopeVersion,
    );
    expect(
      const PullResponse(records: [], latestSeq: 0).recordEnvelopeFloor,
      kCurrentRecordEnvelopeVersion,
    );
  });
}
