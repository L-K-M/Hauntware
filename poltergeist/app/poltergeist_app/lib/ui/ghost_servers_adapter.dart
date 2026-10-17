/// Poltergeist's side of Planchette's `ghost_servers` (docs/design/
/// ghost-servers-part1.md §5): every conversion between the engine's truth
/// types and the package's neutral ones, and the ARB strings and chrome
/// colours the package's surfaces draw with.
library;

import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

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
