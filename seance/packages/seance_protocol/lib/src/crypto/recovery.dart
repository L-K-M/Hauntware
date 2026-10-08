import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as classic;

import '../models/secret.dart';
import 'hkdf.dart';
import 'recovery_key.dart';
import 'vault.dart';

// Credential recovery (CRED-05): a code the user writes down opens an
// encrypted export of this device's vault on any device.
//
//   recovery code R (shown once) ──HKDF──▶ W (wrap key), C (key check)
//
//   vault.json   "recovery:wrap-key" = seal(K, {W, C})
//                (sealed under the vault key K like every entry, so a re-key
//                re-seals it with the rest and R keeps working)
//
//   export file  C, seal(W, K), the vault's entries sealed under K as they
//                are, HMAC(HKDF(K, export-mac), header and entries)
//
//   restore      code → R → W', C'; C' = C (else wrong code, nothing
//                decrypted); K = open(W', seal(W, K)); verify the HMAC;
//                open each entry with K
//
// R itself is never stored, so the app cannot show the code again. Whoever
// holds K (the OS keystore) and vault.json can read W, and so open exports
// made from this vault; they can already read every secret with K.

/// Vault ids starting with this belong to the app, never to a credential:
/// not exported, not restored, never applied from sync.
const String reservedVaultIdPrefix = 'recovery:';

/// The vault entry holding this device's [RecoveryWrapKey].
const String recoveryWrapKeyId = '${reservedVaultIdPrefix}wrap-key';

/// Whether [id] names one of the app's own vault entries rather than a
/// credential.
bool isReservedVaultId(String id) => id.startsWith(reservedVaultIdPrefix);

const String _kWrapDomain = 'seance/v1/recovery-wrap';
const String _kCheckDomain = 'seance/v1/recovery-check';
const String _kExportMacDomain = 'seance/v1/export-mac';
const int _kKeyLength = 32;
const int _kWrapKeyVersion = 1;

/// What a device keeps of its recovery key: the key that seals the vault key
/// into an export, and the check that lets a restore reject a wrong code
/// before it decrypts anything. Both derive from the recovery key; neither
/// gives it back.
final class RecoveryWrapKey {
  RecoveryWrapKey._(this.wrapKey, this.keyCheck);

  /// HKDF(R, `seance/v1/recovery-wrap`).
  final Uint8List wrapKey;

  /// HMAC-SHA256(HKDF(R, `seance/v1/recovery-check`), the same string).
  final Uint8List keyCheck;

  /// Derives both from the 32-byte [recoveryKey].
  static Future<RecoveryWrapKey> derive(List<int> recoveryKey) async {
    if (recoveryKey.length != _kKeyLength) {
      throw ArgumentError.value(
        recoveryKey.length,
        'recoveryKey',
        'Recovery keys are $_kKeyLength bytes',
      );
    }
    final wrapKey = await hkdfSubkey(recoveryKey, _kWrapDomain);
    final checkKey = await hkdfSubkey(recoveryKey, _kCheckDomain);
    final check = classic.Hmac(
      classic.sha256,
      checkKey,
    ).convert(utf8.encode(_kCheckDomain));
    return RecoveryWrapKey._(wrapKey, Uint8List.fromList(check.bytes));
  }

  Map<String, dynamic> toJson() => {
    'version': _kWrapKeyVersion,
    'wrapKey': base64.encode(wrapKey),
    'keyCheck': base64.encode(keyCheck),
  };

  /// Throws [FormatException] for anything but a version-1 entry holding two
  /// 32-byte keys.
  factory RecoveryWrapKey.fromJson(Map<String, dynamic> json) {
    if (json['version'] != _kWrapKeyVersion) {
      throw const FormatException('Unsupported recovery wrap key version');
    }
    final wrapKey = _canonicalBase64(json['wrapKey']);
    final keyCheck = _canonicalBase64(json['keyCheck']);
    if (wrapKey == null ||
        keyCheck == null ||
        wrapKey.length != _kKeyLength ||
        keyCheck.length != _kKeyLength) {
      throw const FormatException('Malformed recovery wrap key');
    }
    return RecoveryWrapKey._(wrapKey, keyCheck);
  }
}

/// Why an export could not be opened.
enum SecretsExportFailure {
  /// Not a Séance secrets export, or a damaged one.
  malformed,

  /// Written by a newer Séance in a format this one does not read.
  unsupportedVersion,

  /// Larger than [SecretsExport.maxBytes] or [SecretsExport.maxEntries].
  tooLarge,

  /// The text is not a recovery code: wrong length, a character outside
  /// the code's alphabet, or a typo its checksum caught.
  invalidCode,

  /// A well-formed recovery code, but not the one the export was made with.
  wrongCode,

  /// The export was altered after it was made.
  tampered,
}

/// An export that could not be opened, and why.
final class SecretsExportException implements Exception {
  const SecretsExportException(this.failure, this.message);

  final SecretsExportFailure failure;

  /// A diagnostic, not user-facing copy.
  final String message;

  @override
  String toString() => 'SecretsExportException(${failure.name}): $message';
}

/// An export opened with its recovery code.
final class OpenedSecretsExport {
  const OpenedSecretsExport({
    required this.createdAt,
    required this.secrets,
    required this.unreadable,
  });

  final DateTime createdAt;

  /// The credentials it carries, by id.
  final Map<String, Secret> secrets;

  /// Ids of entries the export carries that do not open as credentials:
  /// ones the exporting vault itself could no longer read (an orphan of an
  /// interrupted re-key, say). Authenticated, so not tampering; skipped
  /// rather than failing every other credential with them.
  final List<String> unreadable;
}

/// The encrypted export of a device's vault, format version 1.
///
/// A JSON object with exactly these members:
///
/// - `format`: `"seance-secrets"`; `version`: `1`
/// - `createdAt`: ISO-8601 UTC
/// - `count`: the number of `entries`
/// - `keyCheck`, `wrappedVaultKey`: base64 of [RecoveryWrapKey.keyCheck] and
///   of the vault key sealed under [RecoveryWrapKey.wrapKey]
/// - `entries`: vault id → base64 of the entry sealed under the vault key,
///   exactly as the vault stores it; no reserved ids
/// - `mac`: base64 HMAC-SHA256 under HKDF(vault key,
///   `seance/v1/export-mac`) of the canonical message
///
/// The canonical message is the UTF-8 JSON array `[format, version,
/// createdAt, count, keyCheck, wrappedVaultKey, [[id, entry], …]]`, with the
/// members' file strings and the entries sorted by id
/// ([String.compareTo]), so it does not depend on member order. Base64 must
/// be canonical (padded, re-encoding to the same text): any other spelling
/// of the same bytes is refused rather than authenticated.
abstract final class SecretsExport {
  static const String format = 'seance-secrets';
  static const int version = 1;

  /// Caps checked before anything is parsed or decrypted, so a hostile file
  /// costs a bounded amount of work.
  static const int maxBytes = 16 * 1024 * 1024;
  static const int maxEntries = 10000;

  static const _members = {
    'format',
    'version',
    'createdAt',
    'count',
    'keyCheck',
    'wrappedVaultKey',
    'entries',
    'mac',
  };

  /// The export of [sealedEntries], a vault's entries sealed under
  /// [vaultKey] (reserved ids are left out), openable with the code
  /// [recovery] derives from.
  static Future<Uint8List> build({
    required RecoveryWrapKey recovery,
    required List<int> vaultKey,
    required Map<String, Uint8List> sealedEntries,
    required DateTime createdAt,
  }) async {
    final ids = [
      for (final id in sealedEntries.keys)
        if (!isReservedVaultId(id)) id,
    ]..sort();
    if (ids.length > maxEntries) {
      throw StateError(
        'A vault of ${ids.length} entries is too large to export',
      );
    }
    final entries = {
      for (final id in ids) id: base64.encode(sealedEntries[id]!),
    };
    final created = createdAt.toUtc().toIso8601String();
    final keyCheck = base64.encode(recovery.keyCheck);
    final wrapped = base64.encode(
      await VaultCrypto.seal(recovery.wrapKey, vaultKey),
    );
    final mac = await _mac(
      vaultKey,
      _message(created, ids.length, keyCheck, wrapped, entries),
    );
    final bytes = utf8.encode(
      jsonEncode({
        'format': format,
        'version': version,
        'createdAt': created,
        'count': ids.length,
        'keyCheck': keyCheck,
        'wrappedVaultKey': wrapped,
        'entries': entries,
        'mac': base64.encode(mac),
      }),
    );
    if (bytes.length > maxBytes) {
      throw StateError('The export would exceed $maxBytes bytes');
    }
    return bytes;
  }

  /// Opens an export with the recovery [code] the user typed.
  ///
  /// Checks run cheapest first and decrypt nothing until the code is known
  /// to be the export's: size, shape, the code's own checksum, the key
  /// check, then the wrapped key and the MAC. Throws
  /// [SecretsExportException] for each failure.
  static Future<OpenedSecretsExport> open(List<int> bytes, String code) async {
    if (bytes.length > maxBytes) {
      throw const SecretsExportException(
        SecretsExportFailure.tooLarge,
        'The file exceeds the export size limit',
      );
    }
    final file = _parse(bytes);

    final Uint8List recoveryKey;
    try {
      recoveryKey = RecoveryKey.decode(code);
    } on FormatException catch (error) {
      throw SecretsExportException(
        SecretsExportFailure.invalidCode,
        error.message,
      );
    }
    final recovery = await RecoveryWrapKey.derive(recoveryKey);
    if (!_constantTimeEquals(recovery.keyCheck, file.keyCheck)) {
      throw const SecretsExportException(
        SecretsExportFailure.wrongCode,
        'The code does not match this export',
      );
    }

    final Uint8List vaultKey;
    try {
      vaultKey = await VaultCrypto.open(recovery.wrapKey, file.wrappedVaultKey);
    } catch (_) {
      throw const SecretsExportException(
        SecretsExportFailure.tampered,
        'The wrapped vault key does not open',
      );
    }
    if (vaultKey.length != _kKeyLength) {
      throw const SecretsExportException(
        SecretsExportFailure.tampered,
        'The wrapped vault key has the wrong length',
      );
    }
    final mac = await _mac(vaultKey, file.message);
    if (!_constantTimeEquals(mac, file.mac)) {
      throw const SecretsExportException(
        SecretsExportFailure.tampered,
        'The export fails its integrity check',
      );
    }

    final secrets = <String, Secret>{};
    final unreadable = <String>[];
    for (final MapEntry(key: id, value: sealed) in file.entries.entries) {
      if (isReservedVaultId(id)) continue;
      try {
        final secret = Secret.fromJson(
          await VaultCrypto.openJson(vaultKey, sealed),
        );
        if (secret.id != id) throw const FormatException('Mismatched id');
        secrets[id] = secret;
      } catch (_) {
        unreadable.add(id);
      }
    }
    return OpenedSecretsExport(
      createdAt: file.createdAt,
      secrets: secrets,
      unreadable: unreadable,
    );
  }

  static _ParsedExport _parse(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw _malformed('Not JSON');
    }
    if (decoded is! Map<String, dynamic>) throw _malformed('Not an object');
    if (decoded['format'] != format) throw _malformed('Not a secrets export');
    final fileVersion = decoded['version'];
    if (fileVersion is! int) throw _malformed('No version');
    if (fileVersion != version) {
      throw SecretsExportException(
        SecretsExportFailure.unsupportedVersion,
        'Export version $fileVersion',
      );
    }
    if (decoded.length != _members.length ||
        !decoded.keys.every(_members.contains)) {
      throw _malformed('Unexpected members');
    }

    final created = decoded['createdAt'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    if (createdAt == null || !createdAt.isUtc) throw _malformed('createdAt');

    final count = decoded['count'];
    if (count is! int || count < 0) throw _malformed('count');
    if (count > maxEntries) {
      throw const SecretsExportException(
        SecretsExportFailure.tooLarge,
        'Too many entries',
      );
    }

    final keyCheckText = decoded['keyCheck'];
    final wrappedText = decoded['wrappedVaultKey'];
    final macText = decoded['mac'];
    final keyCheck = _canonicalBase64(keyCheckText);
    final wrapped = _canonicalBase64(wrappedText);
    final mac = _canonicalBase64(macText);
    if (keyCheck == null || wrapped == null || mac == null) {
      throw _malformed('Header encoding');
    }

    final rawEntries = decoded['entries'];
    if (rawEntries is! Map<String, dynamic> || rawEntries.length != count) {
      throw _malformed('entries');
    }
    final entryTexts = <String, String>{};
    final entries = <String, Uint8List>{};
    for (final id in rawEntries.keys.toList()..sort()) {
      final text = rawEntries[id];
      final blob = _canonicalBase64(text);
      if (blob == null) throw _malformed('Entry encoding');
      entryTexts[id] = text as String;
      entries[id] = blob;
    }

    return _ParsedExport(
      createdAt: createdAt,
      keyCheck: keyCheck,
      wrappedVaultKey: wrapped,
      mac: mac,
      entries: entries,
      message: _message(
        created as String,
        count,
        keyCheckText as String,
        wrappedText as String,
        entryTexts,
      ),
    );
  }

  /// The canonical message the MAC covers; [entries] must be sorted by id.
  static List<int> _message(
    String createdAt,
    int count,
    String keyCheck,
    String wrapped,
    Map<String, String> entries,
  ) => utf8.encode(
    jsonEncode([
      format,
      version,
      createdAt,
      count,
      keyCheck,
      wrapped,
      [
        for (final MapEntry(:key, :value) in entries.entries) [key, value],
      ],
    ]),
  );

  static Future<List<int>> _mac(List<int> vaultKey, List<int> message) async {
    final key = await hkdfSubkey(vaultKey, _kExportMacDomain);
    return classic.Hmac(classic.sha256, key).convert(message).bytes;
  }

  static SecretsExportException _malformed(String what) =>
      SecretsExportException(SecretsExportFailure.malformed, what);
}

final class _ParsedExport {
  const _ParsedExport({
    required this.createdAt,
    required this.keyCheck,
    required this.wrappedVaultKey,
    required this.mac,
    required this.entries,
    required this.message,
  });

  final DateTime createdAt;
  final Uint8List keyCheck;
  final Uint8List wrappedVaultKey;
  final Uint8List mac;

  /// Sorted by id.
  final Map<String, Uint8List> entries;
  final List<int> message;
}

/// The bytes [value] spells in canonical base64, or null when it is not a
/// string, not base64, or another spelling of the bytes.
Uint8List? _canonicalBase64(Object? value) {
  if (value is! String) return null;
  try {
    final bytes = base64.decode(value);
    return base64.encode(bytes) == value ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Compares without an early exit, so the time taken says nothing about
/// where two secrets first differ.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
