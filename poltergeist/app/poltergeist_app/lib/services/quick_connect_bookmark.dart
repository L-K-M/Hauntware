import 'package:poltergeist_core/poltergeist_core.dart';

import 'quick_connect_address.dart';
import 'uuid.dart';

/// Builds the transient bookmark shared by Quick Connect and confirmed
/// host-form deep links. It is never persisted until the user saves it.
Bookmark buildQuickConnectBookmark(QuickConnectTarget target) {
  final id = '$quickConnectAdhocIdPrefix${uuidV4()}';
  final now = DateTime.now();
  final host = target.port == quickConnectDefaultPort
      ? target.host
      : '${target.host}:${target.port}';
  final label = target.username.isEmpty ? host : '${target.username}@$host';
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: target.host,
        port: target.port,
        username: target.username,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: target.remotePath,
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}
