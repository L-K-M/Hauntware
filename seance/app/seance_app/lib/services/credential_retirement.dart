import 'dart:math' show max;

import 'package:seance_core/seance_core.dart';

enum CredentialRetirement { retired, stillReferenced }

/// Withdraw an unused credential from sync before removing its local material.
///
/// The tombstone is a durable local intent. Sync seals it under the account
/// key before transmission. A failed vault delete leaves that intent intact,
/// and retries retain its stamp instead of continually outbidding peers.
Future<CredentialRetirement> retireCredential({
  required SecretVault vault,
  required TombstoneStore tombstones,
  required String credentialId,
  required String deviceId,
  required Iterable<ServerConfig> servers,
  required int updatedAt,
}) async {
  if (servers.any((server) => server.secretRef == credentialId)) {
    return CredentialRetirement.stillReferenced;
  }

  final secret = await vault.getSecret(credentialId);
  final minimumStamp = (secret?.updatedAt ?? 0) + 1;
  final recordId = 'secret:$credentialId';
  EncryptedRecord? withdrawal;
  for (final pending in await tombstones.all()) {
    if (pending.id == recordId &&
        pending.deleted &&
        pending.updatedAt >= minimumStamp) {
      withdrawal = pending;
      break;
    }
  }
  withdrawal ??= EncryptedRecord.tombstone(
    id: recordId,
    updatedAt: max(updatedAt, minimumStamp),
    deviceId: deviceId,
  );
  await tombstones.add(withdrawal);
  await vault.deleteSecret(credentialId);
  return CredentialRetirement.retired;
}
