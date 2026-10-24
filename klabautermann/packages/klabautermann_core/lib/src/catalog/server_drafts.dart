/// The server editor's drafts against stored configs (FL-03, 03 §4.4,
/// ghost-servers-part2.md section 3): what [ReadServerDraft] shows and
/// what [SaveServer] stores.
library;

import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        ServerColor,
        ServerConfig,
        nextUpdatedAt,
        normalizeLoginScript,
        normalizeServerGroup,
        normalizeServerStartDirectory,
        serverIconFromName;

import '../engine/protocol.dart'
    show CatalogWriteFailure, ServerDraft, ServerDraftAuth;

/// The highest port a draft may name.
const int _maxPort = 65535;

/// The stored sign-in method a draft's [auth] names.
AuthMethod authMethodOf(ServerDraftAuth auth) => switch (auth) {
  ServerDraftAuth.agent => AuthMethod.agent,
  ServerDraftAuth.password => AuthMethod.password,
  ServerDraftAuth.privateKey => AuthMethod.privateKey,
};

/// [config] as the editor shows it.
ServerDraft serverDraftOf(ServerConfig config) => ServerDraft(
  id: config.id,
  label: config.label,
  host: config.host,
  port: config.port,
  username: config.username,
  auth: switch (config.authMethod) {
    AuthMethod.agent => ServerDraftAuth.agent,
    AuthMethod.password => ServerDraftAuth.password,
    AuthMethod.privateKey => ServerDraftAuth.privateKey,
  },
  syncSecret: config.syncSecret,
  excludeFromSync: config.excludeFromSync,
  identityFilePath: config.identityFilePath,
  group: config.group,
  colorName: config.color?.name,
  customColor: config.customColor,
  iconName: config.icon?.name,
  iconEmoji: config.iconEmoji,
  iconImage: config.iconImage,
  loginScript: config.loginScript,
  startDirectory: config.startDirectory,
);

/// Why [draft] cannot be stored, or null: the editor's own checks (a
/// label, host and user, and a port from 1 to 65535), repeated because
/// the request crosses an isolate boundary.
CatalogWriteFailure? serverDraftProblem(ServerDraft draft) {
  final blank = [
    draft.id,
    draft.label,
    draft.host,
    draft.username,
  ].any((field) => field.trim().isEmpty);
  if (blank || draft.port < 1 || draft.port > _maxPort) {
    return CatalogWriteFailure.invalidDraft;
  }
  return null;
}

/// [draft] over [existing], the stored config of the same id or null for
/// a new server, with [secretRef] as its credential's vault entry. What
/// the draft does not carry keeps its stored value: the jump route and
/// the creation time. The stamp outranks the stored one (03 §4.4); the
/// server store stamps it again as it saves. A colour or icon name this
/// build does not know reads as none, as `ServerConfig.fromJson` does.
ServerConfig serverConfigOfDraft(
  ServerDraft draft, {
  required ServerConfig? existing,
  required String? secretRef,
  required DateTime now,
}) {
  final nowMs = now.toUtc().millisecondsSinceEpoch;
  return ServerConfig(
    id: draft.id,
    label: draft.label.trim(),
    host: draft.host.trim(),
    port: draft.port,
    username: draft.username.trim(),
    authMethod: authMethodOf(draft.auth),
    secretRef: secretRef,
    identityFilePath: draft.identityFilePath,
    jumpHostId: existing?.jumpHostId,
    syncSecret: draft.syncSecret,
    group: normalizeServerGroup(draft.group),
    color: ServerColor.values.asNameMap()[draft.colorName],
    customColor: draft.customColor,
    icon: serverIconFromName(draft.iconName),
    iconEmoji: draft.iconEmoji,
    iconImage: draft.iconImage,
    loginScript: normalizeLoginScript(draft.loginScript),
    startDirectory: normalizeServerStartDirectory(draft.startDirectory),
    excludeFromSync: draft.excludeFromSync,
    createdAt: existing?.createdAt ?? nowMs,
    updatedAt: nextUpdatedAt(existing?.updatedAt, now: nowMs),
  );
}
