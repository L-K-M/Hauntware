import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/registered_command.dart';
import '../../services/seance_links.dart';
import '../../services/workspace_controller.dart';

const kOpenTerminalInSeanceCommandId = 'connect.openTerminalInSeance';

/// The Server-menu form of the cross-app handoff. Context menus render the
/// parameter-bound variants below through the same command id and label.
RegisteredCommand buildOpenTerminalInSeanceCommand({
  required WorkspaceController workspace,
  required SeanceLauncher launcher,
}) {
  Bookmark? activeBookmark() => workspace.activeTabController?.remoteBookmark;

  return _command(
    enabled: () => activeBookmark()?.server != null,
    open: () async {
      final bookmark = activeBookmark();
      if (bookmark == null) return;
      await launcher.openBookmark(bookmark);
    },
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.server,
      order: 28,
    ),
  );
}

RegisteredCommand buildBookmarkTerminalCommand({
  required Bookmark bookmark,
  required SeanceLauncher launcher,
}) => _command(open: () => launcher.openBookmark(bookmark));

RegisteredCommand buildCatalogTerminalCommand({
  required ServerConfig server,
  required SeanceLauncher launcher,
}) => _command(open: () => launcher.openServer(server));

RegisteredCommand _command({
  required Future<void> Function() open,
  bool Function() enabled = _enabled,
  CommandMenuPlacement? menuPlacement,
}) => RegisteredCommand(
  id: kOpenTerminalInSeanceCommandId,
  scope: CommandScope.pane,
  label: (l10n) => l10n.sidebarOpenTerminalInSeance,
  icon: Icons.terminal,
  enabled: enabled,
  disabledReason: (l10n) => l10n.commandDisabledNoRemoteServer,
  run: (context) => open(),
  menuPlacement: menuPlacement,
);

bool _enabled() => true;
