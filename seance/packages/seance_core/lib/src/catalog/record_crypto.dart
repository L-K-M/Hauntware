/// 04 §3.2's crypto seam: the one object that turns [EncryptedRecord] blobs
/// into [DecryptedRecord] payloads and back, keyed by the Séance session
/// vault key. The `RecordCoordinator`, its writer and its handlers — and
/// only they — touch this seam; the record store itself stays deliberately
/// opaque so corrupt, unknown, or not-for-us ciphertext survives untouched.
/// Which ids may be opened at all is the coordinator's
/// `isDecryptableSyncId`, derived from handler registration.
library;

import 'package:seance_protocol/seance_protocol.dart';

/// The one crypto consumer the task permits: Séance's own [RecordCodec]
/// (XChaCha20-Poly1305 under the HKDF-SHA256-derived vault key). Current
/// payloads authenticate the routing and conflict envelope as well as kind and
/// data; legacy `{kind, data}` live payloads remain readable during migration.
///
/// [open] is deliberately throw-only: a decrypt or JSON failure surfaces,
/// and the caller decides whether that means "not for our vault key,
/// preserve" or "tripwire". Nothing here retries, re-keys, or mutates.
final class RecordCrypto {
  const RecordCrypto(this._codec);

  final RecordCodec _codec;

  /// Decrypt and validate the sealed record envelope. Throws on any failure —
  /// no unauthenticated fallback decode or defaults.
  Future<DecryptedRecord> open(EncryptedRecord record) =>
      _codec.decrypt(record);

  /// Open only the authenticated `{kind, data}` from a legacy live envelope.
  /// Callers must match it to independent current local state before sealing.
  Future<LegacyRecordPayload> openLegacyForMigration(
    EncryptedRecord record,
  ) =>
      _codec.decryptLegacyForMigration(record);

  /// Wrap and encrypt a [DecryptedRecord] for this vault key.
  Future<EncryptedRecord> seal(DecryptedRecord record) =>
      _codec.encrypt(record);
}
