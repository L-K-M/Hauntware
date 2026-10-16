import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_core/seance_core.dart';

import 'ghost_servers_adapter.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
///
/// The dialog lives in Planchette's `ghost_servers` since 2026-10-16
/// (docs/design/ghost-servers-part1.md, PR 4); its default words are
/// Séance's, so only the challenge goes in. Séance keeps Flutter's default
/// Enter handling (`submitOnEnter: false`) until a follow-up adopts the
/// shared focus chain with its own test (§6).
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  KeyboardInteractiveChallenge challenge,
) => showGhostKeyboardInteractiveDialog(
  context,
  ghostKeyboardPromptOf(challenge),
  submitOnEnter: false,
);
