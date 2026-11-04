import 'dart:developer' as developer;

import 'package:seance_protocol/seance_protocol.dart';

import 'local_record_store.dart';
import 'sync_engine.dart';

/// Optional protocol-v4 capability for replacing legacy record envelopes by
/// exact compare-and-swap, then advancing the account envelope floor.
abstract interface class LegacyMigrationApi implements SyncApi {
  Future<LegacyRecordPage> pullLegacyPage({String? afterId});

  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  });
}

typedef LegacyPayloadOpener =
    Future<LegacyRecordPayload> Function(EncryptedRecord record);
typedef CurrentRecordOpener =
    Future<DecryptedRecord> Function(EncryptedRecord record);
typedef LegacyMigrationEligibility = bool Function(DecryptedRecord record);

/// Remember a server floor before using any records it accompanied.
Future<void> observeRecordEnvelopeFloor(
  LocalRecordStore store,
  int floor,
) async {
  if (floor < kLegacyRecordEnvelopeVersion ||
      floor > kCurrentRecordEnvelopeVersion) {
    throw FormatException('Unsupported record envelope floor $floor');
  }
  final floors = store;
  if (floors is RecordEnvelopeFloorStore) {
    await floors.observeRecordEnvelopeFloor(floor);
  }
}

/// Conservatively migrate every legacy row this device can prove from local
/// authenticated state. Unmatched rows remain untouched and keep the server
/// floor at one for a future capable device.
///
/// Each CAS is deliberately its own request. Besides making interruption
/// resumable at record granularity, this bounds a request containing both the
/// old and replacement ciphertext even when either is near the deployment's
/// single-record limit.
Future<void> migrateLegacyEnvelopes(
  SyncApi api, {
  required LocalRecordStore store,
  required SyncLocalRunner runLocal,
  required LegacyPayloadOpener openLegacy,
  required CurrentRecordOpener openCurrent,
  LegacyMigrationEligibility? isEligible,
  Future<void> Function()? prepareLocal,
}) async {
  if (api is! LegacyMigrationApi) return;

  final knownFloor = await runLocal(() async {
    final floors = store;
    return floors is RecordEnvelopeFloorStore
        ? await floors.recordEnvelopeFloor()
        : kLegacyRecordEnvelopeVersion;
  });
  if (knownFloor >= kCurrentRecordEnvelopeVersion) return;

  String? afterId;
  int? scanFloor;
  var prepared = false;
  while (true) {
    // Network deliberately outside [runLocal].
    final page = await api.pullLegacyPage(afterId: afterId);
    if (page.records.any(
      (record) =>
          record.envelopeVersion != kLegacyRecordEnvelopeVersion ||
          record.seq == null,
    )) {
      throw const FormatException('Legacy migration page contained a non-row');
    }
    final priorScanFloor = scanFloor;
    if (priorScanFloor != null &&
        page.recordEnvelopeFloor != priorScanFloor &&
        !(page.recordEnvelopeFloor == kCurrentRecordEnvelopeVersion &&
            page.records.isEmpty)) {
      throw const FormatException(
        'Legacy migration record envelope floor changed',
      );
    }
    scanFloor ??= page.recordEnvelopeFloor;
    if (page.recordEnvelopeFloor >= kCurrentRecordEnvelopeVersion &&
        page.records.isNotEmpty) {
      throw const FormatException(
        'Authenticated-envelope account returned legacy migration rows',
      );
    }
    await runLocal(
      () => observeRecordEnvelopeFloor(store, page.recordEnvelopeFloor),
    );
    if (page.recordEnvelopeFloor >= kCurrentRecordEnvelopeVersion) {
      return;
    }

    var migrations = const <LegacyRecordMigration>[];
    if (page.records.isNotEmpty) {
      if (!prepared) {
        await runLocal(() async {
          await prepareLocal?.call();
        });
        prepared = true;
      }

      migrations = await runLocal(
        () => buildConservativeLegacyMigrations(
          page.records,
          current: store.allRecords(),
          openLegacy: openLegacy,
          openCurrent: openCurrent,
          isEligible: isEligible,
        ),
      );
    }
    for (final migration in migrations) {
      // Network deliberately outside [runLocal]. An exact-CAS miss is a
      // normal race; the next scan sees the winner.
      final LegacyMigrationResponse response;
      try {
        response = await api.migrateLegacy([migration]);
      } on ApiError catch (error) {
        if (error.code != 'payload_too_large' &&
            error.code != 'account_quota_exceeded') {
          rethrow;
        }
        // A larger authenticated envelope can exceed a deployment limit even
        // when the legacy row fits. Leave it for a future migration attempt,
        // but still pull remote changes and publish other records this round.
        developer.log(
          'Legacy migration deferred by server limit: ${error.code}',
          name: 'seance.sync',
          level: 900,
        );
        continue;
      }
      await runLocal(
        () => observeRecordEnvelopeFloor(store, response.recordEnvelopeFloor),
      );
      if (response.recordEnvelopeFloor >= kCurrentRecordEnvelopeVersion) {
        return;
      }
    }

    if (!page.hasMore) break;
    final next = page.nextId;
    if (next == null ||
        next.isEmpty ||
        (afterId != null && next.compareTo(afterId) <= 0)) {
      throw const FormatException('Legacy migration page made no progress');
    }
    afterId = next;
  }

  // Only the server can advance the floor, and only after atomically proving
  // that no legacy row remains. An unmatched row makes this a harmless no-op.
  final finalized = await api.migrateLegacy(const [], finalize: true);
  await runLocal(
    () => observeRecordEnvelopeFloor(store, finalized.recordEnvelopeFloor),
  );
}

/// Build exact-CAS replacements without trusting any legacy outer metadata.
///
/// A live v1 row contributes only its authenticated `{kind, data}`. It is
/// replaced only when exactly one current v2 record opens to the same values
/// under the same id. That equality proves the unauthenticated outer id agrees
/// with independently authenticated canonical state; the v2 record supplies
/// the complete tuple. A payload-less v1 tombstone can only match a same-id
/// authenticated local tombstone, which is evidence of an independent durable
/// delete intent.
Future<List<LegacyRecordMigration>> buildConservativeLegacyMigrations(
  List<EncryptedRecord> legacy, {
  required Future<List<EncryptedRecord>> current,
  required LegacyPayloadOpener openLegacy,
  required CurrentRecordOpener openCurrent,
  LegacyMigrationEligibility? isEligible,
}) async {
  final trusted = <({EncryptedRecord encrypted, DecryptedRecord decrypted})>[];
  for (final record in await current) {
    if (record.envelopeVersion != kCurrentRecordEnvelopeVersion) continue;
    try {
      final opened = await openCurrent(record);
      if (isEligible == null || isEligible(opened)) {
        trusted.add((encrypted: record, decrypted: opened));
      }
    } catch (_) {
      // A v2 row that does not authenticate is not trusted migration input.
    }
  }

  final result = <LegacyRecordMigration>[];
  for (final old in legacy) {
    if (old.envelopeVersion != kLegacyRecordEnvelopeVersion ||
        old.seq == null) {
      continue;
    }

    final matches = <EncryptedRecord>[];
    if (old.deleted || old.blob.isEmpty) {
      for (final candidate in trusted) {
        if (candidate.encrypted.id == old.id && candidate.decrypted.deleted) {
          matches.add(candidate.encrypted);
        }
      }
    } else {
      final LegacyRecordPayload payload;
      try {
        payload = await openLegacy(old);
      } catch (_) {
        continue;
      }
      if (payload.kind == RecordKind.unknown) continue;
      for (final candidate in trusted) {
        final opened = candidate.decrypted;
        if (candidate.encrypted.id == old.id &&
            !opened.deleted &&
            opened.kind == payload.kind &&
            _sameJson(opened.data, payload.data)) {
          matches.add(candidate.encrypted);
        }
      }
    }
    if (matches.length != 1) continue;

    final replacement = matches.single;
    result.add(
      LegacyRecordMigration(
        expected: old,
        replacement: EncryptedRecord(
          envelopeVersion: replacement.envelopeVersion,
          id: replacement.id,
          updatedAt: replacement.updatedAt,
          deviceId: replacement.deviceId,
          deleted: replacement.deleted,
          seq: null,
          blob: replacement.blob,
        ),
      ),
    );
  }
  return result;
}

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameJson(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}
