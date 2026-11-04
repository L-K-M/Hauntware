import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../json_size.dart';

const String _recordLoggerName = 'seance_protocol.records';

final Logger _log = Logger(_recordLoggerName);

/// The authenticated record-envelope format written by this build.
const int kRecordEnvelopeVersion = 2;

/// The category of a synced record. The kind travels *inside* the encrypted
/// payload, not in the envelope, so the server cannot even tell a server-config
/// from a stored secret.
/// A build that does not know a kind name resolves it to [unknown] through
/// [recordKindFromName], and every apply path skips such a record rather than
/// deleting or rewriting it — which is what lets a new kind roll out before
/// every device is upgraded. Matched by name, never by `index`: a kind added
/// in the middle renumbers everything after it, so an ordinal persisted
/// anywhere would decode as a different kind.
enum RecordKind {
  serverConfig,
  hostKey,
  secret,
  snippet,
  bookmark,
  assistantSettings,
  inboxApp,
  inboxStatus,

  /// Klabautermann's own settings (`klabautermann:pref:` and
  /// `klabautermann:rule:` records, 03 §4.8). Séance and Poltergeist keep
  /// them without applying them; only Klabautermann reads them.
  klabautermann,
  unknown,
}

RecordKind recordKindFromName(String name) => RecordKind.values.firstWhere(
  (k) => k.name == name,
  orElse: () {
    final message =
        'recordKindFromName: unknown kind "$name" '
        '(legacy or newer-schema record)';

    // Keep the library stream testable and surface it in Séance diagnostics.
    _log.fine(message);
    developer.log(message, name: _recordLoggerName, level: Level.FINE.value);
    return RecordKind.unknown;
  },
);

/// A record after decryption: application-level data the client works with.
class DecryptedRecord {
  final String id;
  final RecordKind kind;
  final int updatedAt;
  final String deviceId;
  final bool deleted;
  final Map<String, dynamic> data;

  const DecryptedRecord({
    required this.id,
    required this.kind,
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
    this.data = const {},
  });

  DecryptedRecord tombstone({required int updatedAt, required String deviceId}) =>
      DecryptedRecord(
        id: id,
        kind: kind,
        updatedAt: updatedAt,
        deviceId: deviceId,
        deleted: true,
        data: const {},
      );
}

/// A record as it lives on the wire and in the server's database: an opaque,
/// end-to-end-encrypted [blob] plus the minimum metadata needed to sync and
/// resolve conflicts. [seq] is assigned by the server on upsert and is null for
/// a record the client has not yet pushed.
class EncryptedRecord {
  final String id;
  final int updatedAt;
  final String deviceId;
  final bool deleted;
  final int? seq;

  /// The authenticated envelope format, or null for legacy v1 wire records.
  ///
  /// This additive outer hint lets clients and servers replace a v1 blob with
  /// its v2 equivalent without changing the record's semantic LWW timestamp.
  /// V2 seals the same value inside [blob], so the hint is never trusted by a
  /// decrypting client on its own. An old server may strip the hint while
  /// retaining the opaque v2 blob, which is why null remains distinct from 1.
  final int? envelopeVersion;

  /// `nonce || ciphertext || mac`. V2 tombstones are sealed too; an empty blob
  /// is only the legacy local-staging shape described by [tombstone].
  final Uint8List blob;

  const EncryptedRecord({
    required this.id,
    required this.updatedAt,
    required this.deviceId,
    required this.deleted,
    required this.seq,
    this.envelopeVersion,
    required this.blob,
  });

  /// An unsealed legacy tombstone for durable local staging only.
  ///
  /// A sync writer must re-seal this through [RecordCodec] before it reaches a
  /// server. Pulled empty tombstones are untrusted because any blob server
  /// could mint one. The shape remains for old on-disk pending-deletion stores,
  /// which must be migrated after the vault is unlocked.
  EncryptedRecord.tombstone({
    required this.id,
    required this.updatedAt,
    required this.deviceId,
  })  : deleted = true,
        seq = null,
        envelopeVersion = null,
        blob = Uint8List(0);

  EncryptedRecord withSeq(int newSeq) => EncryptedRecord(
        id: id,
        updatedAt: updatedAt,
        deviceId: deviceId,
        deleted: deleted,
        seq: newSeq,
        envelopeVersion: envelopeVersion,
        blob: blob,
      );

  /// Keep [encodedJsonBytes] in step with this map: it counts exactly these
  /// entries, and a push batched against a stale count is a push the server
  /// rejects.
  Map<String, dynamic> toJson() => {
        'id': id,
        'updatedAt': updatedAt,
        'deviceId': deviceId,
        'deleted': deleted,
        if (seq != null) 'seq': seq,
        if (envelopeVersion != null) 'envelopeVersion': envelopeVersion,
        'blob': base64.encode(blob),
      };

  /// Byte length of the JSON [toJson] encodes to, without building it.
  ///
  /// Record sizes span orders of magnitude — a host-key pin is a few hundred
  /// bytes, a config carrying an image is a megabyte — so a client batching a
  /// push cannot bound the body by record count alone. See `json_size.dart`
  /// for why this counts rather than encodes.
  int encodedJsonBytes() {
    final seqValue = seq;
    final version = envelopeVersion;
    return jsonObjectFramingBytes(
          5 + (seqValue == null ? 0 : 1) + (version == null ? 0 : 1),
        ) +
        jsonKeyBytes('id') +
        jsonStringBytes(id) +
        jsonKeyBytes('updatedAt') +
        jsonIntBytes(updatedAt) +
        jsonKeyBytes('deviceId') +
        jsonStringBytes(deviceId) +
        jsonKeyBytes('deleted') +
        jsonBoolBytes(deleted) +
        (seqValue == null
            ? 0
            : jsonKeyBytes('seq') + jsonIntBytes(seqValue)) +
        (version == null
            ? 0
            : jsonKeyBytes('envelopeVersion') + jsonIntBytes(version)) +
        jsonKeyBytes('blob') +
        jsonBase64StringBytes(blob.length);
  }

  factory EncryptedRecord.fromJson(Map<String, dynamic> json) {
    final version = json['envelopeVersion'];
    if (version != null &&
        (version is! int ||
            version < 1 ||
            version > kRecordEnvelopeVersion)) {
      throw const FormatException('Invalid record envelope version');
    }
    final seq = json['seq'];
    if (seq != null && (seq is! int || seq < 0)) {
      throw const FormatException('Invalid record sequence');
    }
    return EncryptedRecord(
        id: json['id'] as String,
        updatedAt: (json['updatedAt'] as num).toInt(),
        deviceId: json['deviceId'] as String,
        deleted: json['deleted'] as bool? ?? false,
        seq: seq as int?,
        envelopeVersion: version as int?,
        blob: base64.decode(json['blob'] as String? ?? ''),
      );
  }
}
