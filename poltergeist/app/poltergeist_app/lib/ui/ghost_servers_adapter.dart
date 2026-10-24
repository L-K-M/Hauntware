/// Poltergeist's side of Planchette's `ghost_servers` (docs/design/
/// ghost-servers-part1.md §5): every conversion between the engine's truth
/// types and the package's neutral ones, and the ARB strings and chrome
/// colours the package's surfaces draw with.
library;

import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/identity_file_reader.dart';
import '../theme/app_theme.dart';
import 'server_appearance_strings.dart' show PoltergeistColorPickerStrings;

/// The status words in ARB. [status] picks the word for an attempt in
/// flight: a recovery says "Reconnecting", a first connect "Connecting".
GhostServerStatusStrings poltergeistServerStatusStrings(
  AppLocalizations l10n, {
  ServerStatus? status,
}) => GhostServerStatusStrings(
  connected: l10n.connectionStateConnected,
  connecting: status?.state == ServerConnectionState.reconnecting
      ? l10n.connectionStateReconnecting
      : l10n.connectionStateConnecting,
  failed: l10n.connectionFailedTitle,
  blocked: l10n.connectionBlockedTitle,
  notConnected: l10n.connectionStateNotConnected,
  probeOnline: l10n.probeStatusOnline,
  probeOffline: l10n.probeStatusOffline,
  probeUnknown: l10n.probeStatusUnknown,
  // The indicator's words are the state's title alone: Poltergeist's
  // server appearance has no detail line.
  blockedDetail: null,
  hiddenConnected: l10n.sidebarHiddenConnected,
  hiddenConnecting: l10n.sidebarHiddenConnecting,
);

/// Live connection truth in the shared vocabulary. A `detail` on the status
/// means the state explains a failure (03 §3.2); cancellation and idle
/// teardown carry none, so `disconnected` splits into failed and idle.
GhostSessionState ghostSessionOf(ServerStatus? status) {
  if (status == null) return GhostSessionState.none;

  return switch (status.state) {
    ServerConnectionState.connecting ||
    ServerConnectionState.reconnecting => GhostSessionState.connecting,
    ServerConnectionState.connected => GhostSessionState.connected,
    ServerConnectionState.disconnected =>
      status.detail != null ? GhostSessionState.failed : GhostSessionState.idle,
    ServerConnectionState.blocked => GhostSessionState.blocked,
  };
}

/// Reachability truth in the shared vocabulary; null where there is none.
GhostProbeState? ghostProbeOf(ProbeStatus? probe) => switch (probe) {
  ProbeStatus.online => GhostProbeState.online,
  ProbeStatus.offline => GhostProbeState.offline,
  ProbeStatus.unknown => GhostProbeState.unknown,
  null => null,
};

/// The engine's host-key prompt as the shared dialog shows it, field for
/// field. The payload names no pinned key type, so a changed key's pinned
/// fingerprint is labelled with the presented key's type.
GhostHostKeyPrompt ghostHostKeyPromptOf(HostKeyPromptData data) =>
    GhostHostKeyPrompt(
      host: data.host,
      port: data.port,
      keyType: data.keyType,
      fingerprintSha256: data.fingerprintSha256,
      pinnedFingerprintSha256: data.pinnedFingerprintSha256,
    );

/// The host-key prompt's words in ARB.
GhostHostKeyStrings poltergeistHostKeyStrings(AppLocalizations l10n) =>
    GhostHostKeyStrings(
      unknownTitle: l10n.hostKeyUnknownTitle,
      changedTitle: l10n.hostKeyChangedTitle,
      changedWarning: l10n.hostKeyChangedWarning,
      endpoint: l10n.hostKeyEndpoint,
      fingerprintLabel: l10n.hostKeyFingerprintLabel,
      newKeyLabel: l10n.hostKeyNewLabel,
      previousLabel: l10n.hostKeyPreviousLabel,
      cancel: l10n.hostKeyCancel,
      trustConnect: l10n.hostKeyTrustConnect,
      trustNewKey: l10n.hostKeyTrustNewKey,
    );

/// The engine's keyboard-interactive prompt as the shared dialog shows it,
/// field for field.
GhostKeyboardPrompt ghostKeyboardPromptOf(KeyboardInteractivePromptData data) =>
    GhostKeyboardPrompt(
      username: data.username,
      host: data.host,
      port: data.port,
      name: data.name,
      instruction: data.instruction,
      prompts: data.prompts,
    );

/// The keyboard-interactive prompt's words in ARB. The engine payload
/// always names the user; without one the endpoint reads as the host-key
/// prompt's host and port.
GhostKeyboardInteractiveStrings poltergeistKeyboardInteractiveStrings(
  AppLocalizations l10n,
) => GhostKeyboardInteractiveStrings(
  title: l10n.keyboardAuthTitle,
  requestFrom: l10n.keyboardRequestFrom,
  serverMessage: l10n.keyboardServerMessage,
  endpoint: (username, host, port) => username == null
      ? l10n.hostKeyEndpoint(host, port)
      : l10n.credentialEndpoint(username, host, port),
  showAnswer: l10n.keyboardShowAnswer,
  hideAnswer: l10n.keyboardHideAnswer,
  cancel: l10n.keyboardCancel,
  submit: l10n.keyboardSubmit,
);

/// The engine's credential prompt as the shared dialog shows it: the
/// identity-file form, prefilled with the config's path, and the vault
/// offer only where the config names a secretRef (04 §2.1). The endpoint
/// shows the host as configured, without IPv6 brackets.
GhostCredentialRequest ghostCredentialRequestOf(
  CredentialPromptData data, {
  required bool vaultUnavailable,
}) => GhostCredentialRequest(
  authMethod: data.authMethod,
  endpointLabel: data.host,
  keyField: GhostKeyField.filePath,
  username: data.username,
  host: data.host,
  port: data.port,
  initialKeyPath: data.identityFilePath,
  offerVaultSave: data.secretRef != null,
  vaultUnavailable: vaultUnavailable,
);

/// The credential prompt's words in ARB: one title for both methods and no
/// explanation line. A read failure shows the audited reader's file-system
/// detail (D18) and nothing of any other error.
GhostCredentialStrings poltergeistCredentialStrings(AppLocalizations l10n) =>
    GhostCredentialStrings(
      passwordTitle: (_) => l10n.credentialTitle,
      privateKeyTitle: (_) => l10n.credentialTitle,
      explanation: null,
      endpoint: (username, host, port) => username == null
          ? l10n.hostKeyEndpoint(host, port)
          : l10n.credentialEndpoint(username, host, port),
      vaultUnavailable: l10n.credentialVaultUnavailable,
      passwordField: l10n.credentialPasswordField,
      keyFileField: l10n.credentialKeyFileField,
      keyFileRequired: l10n.credentialKeyFileRequired,
      keyFileError: (error) => l10n.credentialKeyFileReadError(
        error is IdentityFileReadException &&
                error.kind == IdentityFileReadFailureKind.fileSystem
            ? error.message
            : l10n.credentialKeyFileUnreadable,
      ),
      passphraseField: l10n.credentialPassphraseField,
      saveInVault: l10n.credentialSaveInVault,
      cancel: l10n.credentialCancel,
      connect: l10n.credentialConnect,
    );

/// The connection log view's words in ARB.
GhostConnectionLogStrings poltergeistConnectionLogStrings(
  AppLocalizations l10n,
) => GhostConnectionLogStrings(
  title: l10n.connectionLogTitle,
  copy: l10n.connectionLogCopy,
  copied: l10n.connectionLogCopied,
  copyFailed: l10n.connectionLogCopyFailed,
  empty: l10n.connectionLogEmpty,
);

/// The test report's spoken outcomes in ARB.
GhostConnectionTestStrings poltergeistConnectionTestStrings(
  AppLocalizations l10n,
) => GhostConnectionTestStrings(
  succeeded: l10n.connectionTestSucceeded,
  failed: l10n.connectionTestFailed,
);

/// A test result as the shared report takes it.
GhostTestReport ghostTestReportOf(ConnectionTestResult result) =>
    GhostTestReport(
      ok: result.ok,
      summary: result.summary,
      notes: result.notes,
      log: result.log,
    );

/// The server editor's words in ARB. Every member has a key of its own,
/// and the custom colour picker takes the app's colour picker words.
GhostServerEditorStrings poltergeistServerEditorStrings(
  AppLocalizations l10n,
) => GhostServerEditorStrings(
  addTitle: l10n.serverEditorAddTitle,
  editTitle: l10n.serverEditorEditTitle,
  label: l10n.serverEditorLabel,
  host: l10n.serverEditorHost,
  port: l10n.serverEditorPort,
  username: l10n.serverEditorUsername,
  authentication: l10n.serverEditorAuthentication,
  authAgent: l10n.serverEditorAuthAgent,
  authPassword: l10n.serverEditorAuthPassword,
  authPrivateKey: l10n.serverEditorAuthPrivateKey,
  agentInfo: l10n.serverEditorAgentInfo,
  passwordLabel: l10n.serverEditorPasswordLabel,
  referenceKeyTitle: l10n.serverEditorReferenceKeyTitle,
  referenceKeySubtitle: l10n.serverEditorReferenceKeySubtitle,
  identityFilePath: l10n.serverEditorIdentityFilePath,
  identityFileHint: l10n.serverEditorIdentityFileHint,
  browse: l10n.serverEditorBrowse,
  privateKeyPem: l10n.serverEditorPrivateKeyPem,
  keyPassphrase: l10n.serverEditorKeyPassphrase,
  startDirectory: l10n.serverEditorStartDirectory,
  startDirectoryHint: l10n.serverEditorStartDirectoryHint,
  startDirectoryNote: l10n.serverEditorStartDirectoryNote,
  startDirectoryInvalid: l10n.serverEditorStartDirectoryInvalid,
  loginScript: l10n.serverEditorLoginScript,
  loginScriptHint: l10n.serverEditorLoginScriptHint,
  loginScriptNote: l10n.serverEditorLoginScriptNote,
  appearance: l10n.serverEditorAppearance,
  group: l10n.serverEditorGroup,
  groupHint: l10n.serverEditorGroupHint,
  colour: l10n.serverEditorColour,
  mark: l10n.serverEditorMark,
  chooseMark: l10n.serverEditorChooseMark,
  defaultMarkTooltip: l10n.serverEditorDefaultMarkTooltip,
  customColour: l10n.serverEditorCustomColour,
  syncSecretTitle: l10n.serverEditorSyncSecretTitle,
  syncSecretExcluded: l10n.serverEditorSyncSecretExcluded,
  syncSecretSubtitle: l10n.serverEditorSyncSecretSubtitle,
  excludeTitle: l10n.serverEditorExcludeTitle,
  excludeOnSubtitle: l10n.serverEditorExcludeOnSubtitle,
  excludeOffSubtitle: l10n.serverEditorExcludeOffSubtitle,
  excludeConfirmTitle: l10n.serverEditorExcludeConfirmTitle,
  excludeConfirmBody: l10n.serverEditorExcludeConfirmBody,
  excludeConfirmCancel: l10n.serverEditorExcludeConfirmCancel,
  excludeConfirmAction: l10n.serverEditorExcludeConfirmAction,
  test: l10n.serverEditorTest,
  testing: l10n.serverEditorTesting,
  testingSemantic: l10n.serverEditorTestingSemantic,
  testFailedSummary: l10n.serverEditorTestFailedSummary,
  testDisclaimer: l10n.serverEditorTestDisclaimer,
  cancel: l10n.serverEditorCancel,
  save: l10n.serverEditorSave,
  required: l10n.serverEditorRequired,
  portRange: l10n.serverEditorPortRange,
  saveFailed: l10n.serverEditorSaveFailed,
  customColourValue: l10n.serverEditorCustomColourValue,
  colorPickerStrings: PoltergeistColorPickerStrings(l10n),
  testStrings: poltergeistConnectionTestStrings(l10n),
  logStrings: poltergeistConnectionLogStrings(l10n),
);

/// The chrome's status colours as the package takes them.
GhostStatusColors poltergeistStatusColors(PoltergeistChrome chrome) =>
    GhostStatusColors(
      online: chrome.statusConnected,
      connecting: chrome.statusConnecting,
      offline: chrome.statusFailed,
    );

/// The one indicator a server shows under [rule], from its live [status]
/// and its [probe], worded in ARB.
GhostServerIndicator resolveServerIndicator(
  AppLocalizations l10n,
  GhostIndicatorRule rule, {
  ServerStatus? status,
  ProbeStatus? probe,
}) => ghostServerIndicator(
  poltergeistServerStatusStrings(l10n, status: status),
  rule,
  session: ghostSessionOf(status),
  probe: ghostProbeOf(probe),
);
