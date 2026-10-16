import 'package:flutter/widgets.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_core/seance_core.dart';

import '../theme.dart' show SeanceTheme;
import 'ghost_servers_adapter.dart';

/// Shows the trust-on-first-use prompt. On a *changed* key this is a hard,
/// visually alarming block that requires explicit re-pinning — never a
/// one-click dismiss. Returns true to trust (and pin) the presented key.
///
/// The dialog lives in Planchette's `ghost_servers` since 2026-10-16
/// (docs/design/ghost-servers-part1.md, PR 4); its default words are
/// Séance's, so only the decision and the monospace stack go in.
Future<bool> showHostKeyDialog(
  BuildContext context,
  HostKeyDecision decision,
) => showGhostHostKeyDialog(
  context,
  ghostHostKeyPromptOf(decision),
  monoStyle: SeanceTheme.mono,
);
