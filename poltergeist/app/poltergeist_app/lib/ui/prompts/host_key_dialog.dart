// Ported from Séance app/seance_app/lib/ui/host_key_dialog.dart @ a9add15; see docs/PORTS.md.
// The dialog lives in Planchette's ghost_servers since 2026-10-16
// (docs/design/ghost-servers-part1.md, PR 4). This delegate keeps the
// divergences: the engine protocol's HostKeyPromptData as the payload
// (prompts cross the isolate as plain data, 03 §5) and ARB strings (D20).
import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show poltergeistMonoTextStyle;
import '../ghost_servers_adapter.dart';

/// Shows the trust-on-first-use prompt. On a *changed* key this is a hard,
/// visually alarming block that requires explicit re-pinning — never a
/// one-click dismiss (D18). Returns true to trust (and pin) the presented
/// key.
Future<bool> showHostKeyDialog(
  BuildContext context,
  HostKeyPromptData data, {
  GlobalKey? dialogKey,
}) => showGhostHostKeyDialog(
  context,
  ghostHostKeyPromptOf(data),
  strings: poltergeistHostKeyStrings(AppLocalizations.of(context)),
  dialogKey: dialogKey,
  monoStyle: poltergeistMonoTextStyle,
);
