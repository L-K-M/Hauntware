/// Séance's side of Planchette's `ghost_servers` (docs/design/
/// ghost-servers-part1.md §5): every conversion between Séance's truth
/// types and the package's neutral ones, and the strings and colours the
/// package's surfaces draw with.
library;

import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../theme.dart';

/// Séance's status words: the package's defaults are Séance's own.
const seanceServerStatusStrings = GhostServerStatusStrings();

/// A terminal session's state in the shared vocabulary; no session is
/// [GhostSessionState.none]. A failed session reads as blocked only when
/// its host key no longer matches the pinned one ([hostKeyBlocked]).
GhostSessionState ghostSessionOf(
  TerminalStatus? status, {
  bool hostKeyBlocked = false,
}) => switch (status) {
  null => GhostSessionState.none,
  TerminalStatus.connecting => GhostSessionState.connecting,
  TerminalStatus.connected => GhostSessionState.connected,
  TerminalStatus.error =>
    hostKeyBlocked ? GhostSessionState.blocked : GhostSessionState.failed,
  TerminalStatus.disconnected => GhostSessionState.idle,
};

/// The reverse of [ghostSessionOf]: a block is an error to Séance, the
/// host-key bookkeeping saying which kind.
TerminalStatus? terminalStatusOf(GhostSessionState state) => switch (state) {
  GhostSessionState.none => null,
  GhostSessionState.connecting => TerminalStatus.connecting,
  GhostSessionState.connected => TerminalStatus.connected,
  GhostSessionState.failed || GhostSessionState.blocked => TerminalStatus.error,
  GhostSessionState.idle => TerminalStatus.disconnected,
};

GhostProbeState ghostProbeOf(ProbeStatus probe) => switch (probe) {
  ProbeStatus.online => GhostProbeState.online,
  ProbeStatus.offline => GhostProbeState.offline,
  ProbeStatus.unknown => GhostProbeState.unknown,
};

/// A host-key decision as the shared prompt shows it: the presented key,
/// and the pinned key's fingerprint and type. The pin marks the changed-key
/// review; a trusted decision, the one other verdict that carries a pin,
/// never reaches the prompt (`seance_core` connects without asking).
GhostHostKeyPrompt ghostHostKeyPromptOf(HostKeyDecision decision) =>
    GhostHostKeyPrompt(
      host: decision.presented.host,
      port: decision.presented.port,
      keyType: decision.presented.type,
      fingerprintSha256: decision.presented.fingerprintSha256,
      pinnedFingerprintSha256: decision.pinned?.fingerprintSha256,
      pinnedKeyType: decision.pinned?.type,
    );

/// A keyboard-interactive challenge as the shared prompt shows it: the
/// trusted endpoint from the server's configuration, and the server's own
/// name, instruction and questions.
GhostKeyboardPrompt ghostKeyboardPromptOf(
  KeyboardInteractiveChallenge challenge,
) => GhostKeyboardPrompt(
  username: challenge.server.username,
  host: challenge.server.host,
  port: challenge.server.port,
  name: challenge.name,
  instruction: challenge.instruction,
  prompts: challenge.prompts,
);

/// The theme's status colours ([StatusColors]) as the package takes them.
GhostStatusColors seanceStatusColors(BuildContext context) => GhostStatusColors(
  online: StatusColors.online(context),
  connecting: StatusColors.connecting(context),
  offline: StatusColors.offline(context),
);
