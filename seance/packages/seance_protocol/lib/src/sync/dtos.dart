import '../crypto/vault.dart';
import '../json_size.dart';
import '../records/record.dart';
import '../version.dart';

/// POST /v1/register — create an account. The server stores only a salted hash
/// of [authVerifier] plus the (non-secret) Argon2 salt and parameters a new
/// device needs to re-derive keys from the passphrase.
class RegisterRequest {
  final int protocolVersion;
  final String username;
  final String authVerifier; // base64 of the 32-byte HKDF auth verifier
  final String argonSalt; // base64
  final Argon2Params argonParams;
  final String vaultKeyCheck; // opaque XChaCha20-Poly1305 payload, base64

  const RegisterRequest({
    this.protocolVersion = kProtocolVersion,
    required this.username,
    required this.authVerifier,
    required this.argonSalt,
    required this.argonParams,
    this.vaultKeyCheck = '',
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'username': username,
        'authVerifier': authVerifier,
        'argonSalt': argonSalt,
        'argonParams': argonParams.toJson(),
        'vaultKeyCheck': vaultKeyCheck,
      };

  factory RegisterRequest.fromJson(Map<String, dynamic> json) =>
      RegisterRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        username: json['username'] as String,
        authVerifier: json['authVerifier'] as String,
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
        vaultKeyCheck: json['vaultKeyCheck'] as String? ?? '',
      );
}

/// POST /v1/prelogin — returns the KDF salt/params for a username so a fresh
/// device can derive keys from the passphrase before it can authenticate.
/// Deliberately unauthenticated; the salt is not a secret.
class PreloginResponse {
  final String argonSalt;
  final Argon2Params argonParams;

  const PreloginResponse({required this.argonSalt, required this.argonParams});

  Map<String, dynamic> toJson() =>
      {'argonSalt': argonSalt, 'argonParams': argonParams.toJson()};

  factory PreloginResponse.fromJson(Map<String, dynamic> json) =>
      PreloginResponse(
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
      );
}

/// POST /v1/login — exchange the auth verifier for a bearer token.
class LoginRequest {
  final int protocolVersion;
  final String username;
  final String authVerifier;

  const LoginRequest({
    this.protocolVersion = kProtocolVersion,
    required this.username,
    required this.authVerifier,
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'username': username,
        'authVerifier': authVerifier,
      };

  factory LoginRequest.fromJson(Map<String, dynamic> json) => LoginRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        username: json['username'] as String,
        authVerifier: json['authVerifier'] as String,
      );
}

class LoginResponse {
  final String token;
  final String? vaultKeyCheck;
  final int recordEnvelopeFloor;

  const LoginResponse({
    required this.token,
    this.vaultKeyCheck,
    this.recordEnvelopeFloor = kCurrentRecordEnvelopeVersion,
  });

  Map<String, dynamic> toJson() => {
        'token': token,
        if (vaultKeyCheck != null) 'vaultKeyCheck': vaultKeyCheck,
        'recordEnvelopeFloor': recordEnvelopeFloor,
      };
  factory LoginResponse.fromJson(Map<String, dynamic> json) =>
      LoginResponse(
        token: json['token'] as String,
        vaultKeyCheck: json['vaultKeyCheck'] as String?,
        recordEnvelopeFloor:
            (json['recordEnvelopeFloor'] as num?)?.toInt() ??
                kLegacyRecordEnvelopeVersion,
      );
}

/// The shipped server's cap on one push body. Doubles as the client's fallback
/// when a server does not advertise its limits, so an unadvertised batch still
/// fits a default deployment.
const int kDefaultMaxPushBodyBytes = 8 * 1024 * 1024;

/// The shipped server's cap on records in one push. Fallback, as above.
const int kDefaultMaxRecordsPerPush = 1000;

/// The shipped server's cap on one record's sealed blob. Fallback, as above.
const int kDefaultMaxBlobBytes = 1024 * 1024;

/// What a single push may contain. Every cap is enforced server-side and every
/// one is env-tunable per deployment, so the server advertises its own values
/// in every [PullResponse] and the client sizes its batches to them. The
/// defaults only apply to a server too old to advertise, which is why they are
/// the values that server shipped with.
class PushLimits {
  /// Largest accepted request body, in bytes. Exceeding it is refused before
  /// any record is read, so the whole push fails — batching is what keeps a
  /// large dirty set from failing identically every round.
  final int maxBodyBytes;

  /// Most records accepted in one push.
  final int maxRecordsPerPush;

  /// Largest accepted sealed blob on a single record, in bytes. Refused with
  /// the same 413 as an over-sized body, and — like it — for the *whole* push,
  /// so a record past this cap has to travel alone or it takes the records
  /// batched beside it down with it.
  final int maxBlobBytes;

  const PushLimits({
    this.maxBodyBytes = kDefaultMaxPushBodyBytes,
    this.maxRecordsPerPush = kDefaultMaxRecordsPerPush,
    this.maxBlobBytes = kDefaultMaxBlobBytes,
  });

  Map<String, dynamic> toJson() => {
        'maxBodyBytes': maxBodyBytes,
        'maxRecordsPerPush': maxRecordsPerPush,
        'maxBlobBytes': maxBlobBytes,
      };

  /// Exact UTF-8 byte length of [toJson] after `jsonEncode`.
  int encodedJsonBytes() =>
      jsonObjectFramingBytes(3) +
      jsonKeyBytes('maxBodyBytes') +
      jsonIntBytes(maxBodyBytes) +
      jsonKeyBytes('maxRecordsPerPush') +
      jsonIntBytes(maxRecordsPerPush) +
      jsonKeyBytes('maxBlobBytes') +
      jsonIntBytes(maxBlobBytes);

  /// Strict decoder, for data this process produced — a present field that is
  /// not a number throws. Decode a *server's* advertisement with [tryFromJson],
  /// which answers null instead of taking the response down with it.
  factory PushLimits.fromJson(Map<String, dynamic> json) => PushLimits(
        maxBodyBytes:
            (json['maxBodyBytes'] as num?)?.toInt() ?? kDefaultMaxPushBodyBytes,
        maxRecordsPerPush: (json['maxRecordsPerPush'] as num?)?.toInt() ??
            kDefaultMaxRecordsPerPush,
        maxBlobBytes:
            (json['maxBlobBytes'] as num?)?.toInt() ?? kDefaultMaxBlobBytes,
      );

  /// The largest integer a JSON number is still exact at. `jsonDecode` returns
  /// a double for any number too large to hold as an int, and past 2^53 a
  /// double no longer represents integers exactly.
  static const int _maxAdvertisableLimit = 9007199254740992;

  /// Whether an advertised field is a cap a push could actually satisfy.
  /// Type alone is not enough: the JSON number `1e999` decodes to infinity,
  /// whose `toInt()` throws, and a cap of zero or less accepts nothing — the
  /// same value the server refuses to start on. The last clause is that same
  /// rule applied to the value that will actually be used: [fromJson]
  /// truncates, so a fraction below 1 would arrive as a zero cap. Order
  /// matters — the earlier clauses are what make `toInt()` safe to call.
  static bool _isUsableLimit(Object? field) =>
      field is num &&
      field.isFinite &&
      field > 0 &&
      field <= _maxAdvertisableLimit &&
      field.toInt() > 0;

  /// Decode an advertisement that may be anything at all, or null when it is
  /// not a usable one. Absent fields fall back to the shipped defaults; a
  /// field that is present but unusable voids the whole advertisement, since
  /// a server that got one wrong has not earned trust in the others.
  ///
  /// Lives here, beside the fields, so a caller does not have to restate their
  /// names and types to validate them — and so adding a limit cannot leave a
  /// caller's hand-rolled guard behind.
  static PushLimits? tryFromJson(Object? value) {
    if (value is! Map) return null;
    for (final key in const [
      'maxBodyBytes',
      'maxRecordsPerPush',
      'maxBlobBytes',
    ]) {
      final field = value[key];
      if (field != null && !_isUsableLimit(field)) return null;
    }
    return PushLimits.fromJson(value.cast<String, dynamic>());
  }

  @override
  bool operator ==(Object other) =>
      other is PushLimits &&
      other.maxBodyBytes == maxBodyBytes &&
      other.maxRecordsPerPush == maxRecordsPerPush &&
      other.maxBlobBytes == maxBlobBytes;

  @override
  int get hashCode =>
      Object.hash(maxBodyBytes, maxRecordsPerPush, maxBlobBytes);

  @override
  String toString() =>
      'PushLimits(maxBodyBytes: $maxBodyBytes, '
      'maxRecordsPerPush: $maxRecordsPerPush, '
      'maxBlobBytes: $maxBlobBytes)';
}

/// `GET /v1/sync?since=<seq>` — pull records newer than the client's
/// high-water mark. [latestSeq] is the account's current maximum sequence
/// number.
class PullResponse {
  final List<EncryptedRecord> records;
  final int latestSeq;

  /// Lowest record-envelope generation the account can still contain.
  ///
  /// A value of 2 is an irreversible account checkpoint: clients that have
  /// observed it must reject a later response advertising 1.
  final int recordEnvelopeFloor;

  /// The fixed account watermark this page belongs to. Null is a legacy,
  /// unpaged response.
  final int? throughSeq;

  /// Whether another page exists at [throughSeq]. False for legacy responses.
  final bool hasMore;

  /// The limits the next push must respect, or null from a server that does
  /// not advertise them. Carried here rather than on an endpoint of its own
  /// because every sync round pulls before it pushes: the client learns the
  /// limits of the deployment it is about to push to, on the request it was
  /// making anyway.
  final PushLimits? limits;

  const PullResponse({
    required this.records,
    required this.latestSeq,
    this.recordEnvelopeFloor = kCurrentRecordEnvelopeVersion,
    this.limits,
    this.throughSeq,
    this.hasMore = false,
  });

  Map<String, dynamic> toJson() => {
        'records': records.map((r) => r.toJson()).toList(),
        'latestSeq': latestSeq,
        'recordEnvelopeFloor': recordEnvelopeFloor,
        if (limits != null) 'limits': limits!.toJson(),
        if (throughSeq != null) ...{
          'throughSeq': throughSeq,
          'hasMore': hasMore,
        },
      };

  /// Exact UTF-8 byte length of [toJson], without making a second base64 copy
  /// of every record blob.
  int encodedSizeBytes() => bodyBytesFor(
        recordCount: records.length,
        recordBytes:
            records.fold(0, (sum, record) => sum + record.encodedJsonBytes()),
        latestSeq: latestSeq,
        recordEnvelopeFloor: recordEnvelopeFloor,
        throughSeq: throughSeq,
        hasMore: hasMore,
        limits: limits,
      );

  /// Exact encoded size when the records' encoded sizes are already known.
  static int bodyBytesFor({
    required int recordCount,
    required int recordBytes,
    required int latestSeq,
    int recordEnvelopeFloor = kCurrentRecordEnvelopeVersion,
    int? throughSeq,
    required bool hasMore,
    PushLimits? limits,
  }) {
    final entries =
        3 + (limits == null ? 0 : 1) + (throughSeq == null ? 0 : 2);
    return jsonObjectFramingBytes(entries) +
        jsonKeyBytes('records') +
        jsonArrayFramingBytes(recordCount) +
        recordBytes +
        jsonKeyBytes('latestSeq') +
        jsonIntBytes(latestSeq) +
        jsonKeyBytes('recordEnvelopeFloor') +
        jsonIntBytes(recordEnvelopeFloor) +
        (limits == null
            ? 0
            : jsonKeyBytes('limits') + limits.encodedJsonBytes()) +
        (throughSeq == null
            ? 0
            : jsonKeyBytes('throughSeq') +
                jsonIntBytes(throughSeq) +
                jsonKeyBytes('hasMore') +
                jsonBoolBytes(hasMore));
  }

  factory PullResponse.fromJson(Map<String, dynamic> json) => PullResponse(
        records: (json['records'] as List)
            .map((e) => EncryptedRecord.fromJson((e as Map).cast()))
            .toList(),
        latestSeq: (json['latestSeq'] as num).toInt(),
        recordEnvelopeFloor:
            (json['recordEnvelopeFloor'] as num?)?.toInt() ??
                kLegacyRecordEnvelopeVersion,
        // Anything that is not a well-formed advertisement counts as "not
        // advertised": the field is advisory and has a documented fallback, so
        // a mangled value must not take the records and watermark down with
        // it. The required fields above stay strict on purpose.
        limits: PushLimits.tryFromJson(json['limits']),
        throughSeq: (json['throughSeq'] as num?)?.toInt(),
        hasMore: json['hasMore'] as bool? ?? false,
      );
}

/// One bounded page of legacy v1 records, ordered by plaintext record id.
///
/// New protocol writers cannot create v1 records, so an id cursor remains
/// stable while concurrent migration requests remove rows from the set.
class LegacyRecordPage {
  final List<EncryptedRecord> records;
  final String? nextId;
  final bool hasMore;
  final int recordEnvelopeFloor;

  const LegacyRecordPage({
    required this.records,
    required this.nextId,
    required this.hasMore,
    required this.recordEnvelopeFloor,
  });

  Map<String, dynamic> toJson() => {
        'records': records.map((record) => record.toJson()).toList(),
        if (nextId != null) 'nextId': nextId,
        'hasMore': hasMore,
        'recordEnvelopeFloor': recordEnvelopeFloor,
      };

  int encodedSizeBytes() => bodyBytesFor(
        recordCount: records.length,
        recordBytes:
            records.fold(0, (sum, record) => sum + record.encodedJsonBytes()),
        nextId: nextId,
        hasMore: hasMore,
        recordEnvelopeFloor: recordEnvelopeFloor,
      );

  static int bodyBytesFor({
    required int recordCount,
    required int recordBytes,
    required String? nextId,
    required bool hasMore,
    required int recordEnvelopeFloor,
  }) {
    final entries = nextId == null ? 3 : 4;
    return jsonObjectFramingBytes(entries) +
        jsonKeyBytes('records') +
        jsonArrayFramingBytes(recordCount) +
        recordBytes +
        (nextId == null
            ? 0
            : jsonKeyBytes('nextId') + jsonStringBytes(nextId)) +
        jsonKeyBytes('hasMore') +
        jsonBoolBytes(hasMore) +
        jsonKeyBytes('recordEnvelopeFloor') +
        jsonIntBytes(recordEnvelopeFloor);
  }

  factory LegacyRecordPage.fromJson(Map<String, dynamic> json) =>
      LegacyRecordPage(
        records: (json['records'] as List)
            .map((entry) =>
                EncryptedRecord.fromJson((entry as Map).cast()))
            .toList(),
        nextId: json['nextId'] as String?,
        hasMore: json['hasMore'] as bool? ?? false,
        recordEnvelopeFloor:
            (json['recordEnvelopeFloor'] as num).toInt(),
      );
}

/// Exact compare-and-swap replacement of one observed legacy row.
///
/// [expected] is never trusted as conflict metadata; it is only the complete
/// row image the server compares. [replacement] is a freshly authenticated v2
/// record derived from canonical local state.
class LegacyRecordMigration {
  final EncryptedRecord expected;
  final EncryptedRecord replacement;

  const LegacyRecordMigration({
    required this.expected,
    required this.replacement,
  });

  Map<String, dynamic> toJson() => {
        'expected': expected.toJson(),
        'replacement': replacement.toJson(),
      };

  factory LegacyRecordMigration.fromJson(Map<String, dynamic> json) =>
      LegacyRecordMigration(
        expected: EncryptedRecord.fromJson(
          (json['expected'] as Map).cast(),
        ),
        replacement: EncryptedRecord.fromJson(
          (json['replacement'] as Map).cast(),
        ),
      );
}

/// Exact-CAS legacy replacements, optionally followed by a floor checkpoint.
class LegacyMigrationRequest {
  final int protocolVersion;
  final List<LegacyRecordMigration> migrations;
  final bool finalize;

  const LegacyMigrationRequest({
    this.protocolVersion = kProtocolVersion,
    required this.migrations,
    this.finalize = false,
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'migrations':
            migrations.map((migration) => migration.toJson()).toList(),
        'finalize': finalize,
      };

  factory LegacyMigrationRequest.fromJson(Map<String, dynamic> json) =>
      LegacyMigrationRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        migrations: (json['migrations'] as List)
            .map((entry) =>
                LegacyRecordMigration.fromJson((entry as Map).cast()))
            .toList(),
        finalize: json['finalize'] as bool? ?? false,
      );
}

/// Result of an atomic legacy migration batch.
class LegacyMigrationResponse {
  final int migrated;
  final int stale;
  final int latestSeq;
  final int recordEnvelopeFloor;

  const LegacyMigrationResponse({
    required this.migrated,
    required this.stale,
    required this.latestSeq,
    required this.recordEnvelopeFloor,
  });

  Map<String, dynamic> toJson() => {
        'migrated': migrated,
        'stale': stale,
        'latestSeq': latestSeq,
        'recordEnvelopeFloor': recordEnvelopeFloor,
      };

  factory LegacyMigrationResponse.fromJson(Map<String, dynamic> json) =>
      LegacyMigrationResponse(
        migrated: (json['migrated'] as num).toInt(),
        stale: (json['stale'] as num).toInt(),
        latestSeq: (json['latestSeq'] as num).toInt(),
        recordEnvelopeFloor:
            (json['recordEnvelopeFloor'] as num).toInt(),
      );
}

/// PUT /v1/records — push a batch of locally-changed records.
class PushRequest {
  final int protocolVersion;
  final List<EncryptedRecord> records;

  const PushRequest({
    this.protocolVersion = kProtocolVersion,
    required this.records,
  });

  /// Keep [bodyBytesFor] in step with this map — see
  /// [EncryptedRecord.toJson] for why.
  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'records': records.map((r) => r.toJson()).toList(),
      };

  /// Byte length of the body [toJson] encodes to, without building it.
  int encodedSizeBytes() => bodyBytesFor(
        recordCount: records.length,
        recordBytes: records.fold(0, (sum, r) => sum + r.encodedJsonBytes()),
        protocolVersion: protocolVersion,
      );

  /// Byte length of a push body holding [recordCount] records whose encoded
  /// sizes sum to [recordBytes].
  ///
  /// Split out from [encodedSizeBytes] so a client filling a batch can test
  /// the next candidate in constant time, instead of re-measuring every record
  /// it has already accepted each time it adds one.
  static int bodyBytesFor({
    required int recordCount,
    required int recordBytes,
    int protocolVersion = kProtocolVersion,
  }) =>
      jsonObjectFramingBytes(2) +
      jsonKeyBytes('protocolVersion') +
      jsonIntBytes(protocolVersion) +
      jsonKeyBytes('records') +
      jsonArrayFramingBytes(recordCount) +
      recordBytes;

  factory PushRequest.fromJson(Map<String, dynamic> json) => PushRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        records: (json['records'] as List)
            .map((e) => EncryptedRecord.fromJson((e as Map).cast()))
            .toList(),
      );
}

/// Result of a push: the sequence number the server assigned each accepted
/// record (a record rejected because the server already held a newer version
/// is reported with `accepted == false`).
class PushResult {
  final String id;
  final int seq;
  final bool accepted;

  const PushResult({
    required this.id,
    required this.seq,
    required this.accepted,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'seq': seq, 'accepted': accepted};

  factory PushResult.fromJson(Map<String, dynamic> json) => PushResult(
        id: json['id'] as String,
        seq: (json['seq'] as num).toInt(),
        accepted: json['accepted'] as bool? ?? true,
      );
}

class PushResponse {
  final List<PushResult> results;
  final int latestSeq;

  const PushResponse({required this.results, required this.latestSeq});

  Map<String, dynamic> toJson() => {
        'results': results.map((r) => r.toJson()).toList(),
        'latestSeq': latestSeq,
      };

  factory PushResponse.fromJson(Map<String, dynamic> json) => PushResponse(
        results: (json['results'] as List)
            .map((e) => PushResult.fromJson((e as Map).cast()))
            .toList(),
        latestSeq: (json['latestSeq'] as num).toInt(),
      );
}

/// Uniform error body returned by the server for non-2xx responses.
class ApiError implements Exception {
  final String code;
  final String message;

  const ApiError({required this.code, required this.message});

  Map<String, dynamic> toJson() => {'error': code, 'message': message};

  factory ApiError.fromJson(Map<String, dynamic> json) => ApiError(
        code: json['error'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
      );

  @override
  String toString() => 'ApiError($code): $message';
}
