/// The server editor's neutral models (docs/design/ghost-servers-part2.md,
/// sections 3 and 5): what the form shows and sends, with no `seance_*`
/// type a host would have to name. `server_config_draft.dart` maps them to
/// the protocol's types for hosts that may import it.
library;

/// How a server signs in, as the editor offers it.
enum GhostAuthMethod { agent, password, privateKey }

/// The form's fields a host may leave out. A hidden field shows nothing and
/// keeps the draft's value.
enum GhostServerOptionalField { startDirectory }

/// One server as the editor shows it: the fields it can change, already
/// trimmed and normalized as they would be stored. Colour and icon are the
/// protocol enums' names, so a name this build does not know reads as none.
final class GhostServerDraft {
  const GhostServerDraft({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.syncSecret,
    required this.excludeFromSync,
    this.identityFilePath,
    this.group,
    this.colorName,
    this.customColor,
    this.iconName,
    this.iconEmoji,
    this.iconImage,
    this.loginScript,
    this.startDirectory,
  });

  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final GhostAuthMethod authMethod;
  final bool syncSecret;
  final bool excludeFromSync;
  final String? identityFilePath;
  final String? group;
  final String? colorName;
  final String? customColor;
  final String? iconName;
  final String? iconEmoji;
  final String? iconImage;
  final String? loginScript;
  final String? startDirectory;
}

/// The credential boxes as typed, read before the first await of a Save so
/// an edit made while the save runs is not in it.
final class GhostCredentialEntry {
  const GhostCredentialEntry({
    required this.referenceKeyFile,
    required this.password,
    required this.keyPem,
    required this.keyPassphrase,
  });

  /// Whether the key is read from [GhostServerDraft.identityFilePath] at
  /// connect rather than stored.
  final bool referenceKeyFile;
  final String password;
  final String keyPem;
  final String keyPassphrase;
}

/// What a connection test may use: each box only under its own method, and
/// the pasted key only while the key is not referenced from disk. A box the
/// method does not use is hidden and may be stale.
final class GhostCredentialDraft {
  const GhostCredentialDraft({
    this.password,
    this.privateKeyPem,
    this.keyPassphrase,
  });

  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;
}

/// One Save: the server, the credential as typed, and the vault id a new
/// credential is written under, minted once per editor so a retried save
/// reuses it.
final class GhostServerSave {
  const GhostServerSave({
    required this.draft,
    required this.credential,
    required this.draftSecretId,
  });

  final GhostServerDraft draft;
  final GhostCredentialEntry credential;
  final String draftSecretId;
}

/// Whether turning "exclude from sync" on needs confirming before it takes.
///
/// Only when there is something to retract: a server being added has never
/// been anywhere, one already excluded has been retracted once already, and
/// with no sync account configured there is no other device that could lose
/// it. Turning the switch back off is never destructive.
///
/// [syncConfigured] is read as it is *now*, which is not quite the same
/// question. A server that synced before the account was unlinked still has
/// a copy out there, and the stored exclusion would retract it on the first
/// round after re-linking, unprompted. Answering that properly needs a "has
/// ever synced" bit no device keeps, and the alternative, always confirming,
/// puts a dialog in front of someone who has never had a sync account.
bool ghostExcludingNeedsConfirmation({
  required GhostServerDraft? existing,
  required bool syncConfigured,
}) => existing != null && !existing.excludeFromSync && syncConfigured;
