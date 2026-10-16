// Ported from Séance app/seance_app/lib/ui/keyboard_interactive_dialog.dart @ 3321a1f; see docs/PORTS.md.
// The dialog lives in Planchette's ghost_servers since 2026-10-16
// (docs/design/ghost-servers-part1.md, PR 4). This delegate keeps the
// divergences: the engine protocol's KeyboardInteractivePromptData as the
// payload (03 §5), ARB strings (D20) and Enter focus navigation, the
// shared dialog's default.
import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../ghost_servers_adapter.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  KeyboardInteractivePromptData data, {
  GlobalKey? dialogKey,
}) => showGhostKeyboardInteractiveDialog(
  context,
  ghostKeyboardPromptOf(data),
  strings: poltergeistKeyboardInteractiveStrings(AppLocalizations.of(context)),
  dialogKey: dialogKey,
);
