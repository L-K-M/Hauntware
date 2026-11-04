import 'dart:math' as math;

import 'package:seance_core/seance_core.dart';

/// The credential changed after the editor planned its copy-on-write save.
final class RetainedCredentialChanged implements Exception {
  const RetainedCredentialChanged();

  @override
  String toString() =>
      'The saved credential changed while this editor was open. Review it '
      'and try again.';
}

bool _sameSecret(Secret? left, Secret? right) {
  if (left == null || right == null) return left == right;
  return left.id == right.id &&
      left.kind == right.kind &&
      left.value == right.value &&
      left.keyPassphrase == right.keyPassphrase &&
      left.identityPassphrase == right.identityPassphrase &&
      left.credentialVersion == right.credentialVersion &&
      left.updatedAt == right.updatedAt;
}

/// Refuse a plan made from a vault revision that is no longer current.
Future<void> verifyRetainedCredential({
  required SecretVault vault,
  required String? retainedSecretRef,
  required Secret? expected,
}) async {
  final ref = retainedSecretRef;
  if (ref == null) return;
  final latest = await vault.getSecret(ref);
  if (!_sameSecret(latest, expected)) {
    throw const RetainedCredentialChanged();
  }
}

/// Persist the copy-on-write half of a server credential edit.
///
/// The replacement is written first under a fresh id. If the config write
/// fails, the old entry remains usable by the still-current config and the
/// stable replacement id can be adopted by a retry.
Future<void> writeServerWithCredential({
  required SecretVault vault,
  required ConfigStore configStore,
  required ServerConfig config,
  Secret? secret,
}) async {
  if (secret != null) {
    await vault.putLocalSecret(secret, updatedAt: config.updatedAt);
  }
  await configStore.putServer(config);
}

/// Remove the entry replaced by [config], once no server names it.
Future<void> retireReplacedSecret({
  required SecretVault vault,
  required TombstoneStore tombstones,
  required String deviceId,
  required ServerConfig config,
  required String? retiredSecretRef,
  required List<ServerConfig> servers,
}) async {
  final ref = retiredSecretRef;
  if (ref == null || config.secretRef == ref) return;
  if (servers.any((server) => server.secretRef == ref)) return;

  // The sync mirror may still hold the old live `secret:` record. Persist its
  // withdrawal before removing the local material, or the next pull can put
  // that material straight back into the vault. Beat both the config edit and
  // the credential's independent clock.
  final existing = await vault.getSecret(ref);
  final deletedAt = math.max(config.updatedAt, (existing?.updatedAt ?? 0) + 1);
  await tombstones.add(
    EncryptedRecord.tombstone(
      id: 'secret:$ref',
      updatedAt: deletedAt,
      deviceId: deviceId,
    ),
  );
  await vault.deleteSecret(ref);
}
