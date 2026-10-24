/// The server editor's drafts against the protocol's `ServerConfig`, for
/// hosts that may import `seance_protocol` (docs/design/
/// ghost-servers-part2.md, section 2). Not in the package barrel, so no
/// protocol type reaches a host that only imports `ghost_servers`; the
/// Klabautermann app's contract forbids importing this library.
library;

import 'package:seance_protocol/seance_protocol.dart'
    show AuthMethod, ServerColor, ServerConfig, serverIconFromName;

import 'src/server_editor/draft.dart';

/// [method] as the editor offers it.
GhostAuthMethod ghostAuthMethodOf(AuthMethod method) => switch (method) {
  AuthMethod.agent => GhostAuthMethod.agent,
  AuthMethod.password => GhostAuthMethod.password,
  AuthMethod.privateKey => GhostAuthMethod.privateKey,
};

/// The stored method [method] names.
AuthMethod authMethodOfGhost(GhostAuthMethod method) => switch (method) {
  GhostAuthMethod.agent => AuthMethod.agent,
  GhostAuthMethod.password => AuthMethod.password,
  GhostAuthMethod.privateKey => AuthMethod.privateKey,
};

/// [server] as the editor shows it.
GhostServerDraft ghostServerDraftOf(ServerConfig server) => GhostServerDraft(
  id: server.id,
  label: server.label,
  host: server.host,
  port: server.port,
  username: server.username,
  authMethod: ghostAuthMethodOf(server.authMethod),
  syncSecret: server.syncSecret,
  excludeFromSync: server.excludeFromSync,
  identityFilePath: server.identityFilePath,
  group: server.group,
  colorName: server.color?.name,
  customColor: server.customColor,
  iconName: server.icon?.name,
  iconEmoji: server.iconEmoji,
  iconImage: server.iconImage,
  loginScript: server.loginScript,
  startDirectory: server.startDirectory,
);

/// [draft] over [existing], the stored config of the same id or null for a
/// new server, with [secretRef] as its credential's vault entry and [now]
/// as its stamp. What the draft does not carry keeps its stored value: the
/// jump route and the creation time. A colour or icon name this build does
/// not know reads as none, as `ServerConfig.fromJson` reads one.
ServerConfig serverConfigOfGhostDraft(
  GhostServerDraft draft, {
  required ServerConfig? existing,
  required String? secretRef,
  required int now,
}) => ServerConfig(
  id: draft.id,
  label: draft.label,
  host: draft.host,
  port: draft.port,
  username: draft.username,
  authMethod: authMethodOfGhost(draft.authMethod),
  secretRef: secretRef,
  // The editor does not show the route; dropping it here would take it
  // away on every device that reads this record (Séance #131's fix, X-02).
  jumpHostId: existing?.jumpHostId,
  identityFilePath: draft.identityFilePath,
  syncSecret: draft.syncSecret,
  group: draft.group,
  color: ServerColor.values.asNameMap()[draft.colorName],
  customColor: draft.customColor,
  icon: serverIconFromName(draft.iconName),
  iconEmoji: draft.iconEmoji,
  iconImage: draft.iconImage,
  loginScript: draft.loginScript,
  startDirectory: draft.startDirectory,
  excludeFromSync: draft.excludeFromSync,
  createdAt: existing?.createdAt ?? now,
  updatedAt: now,
);
