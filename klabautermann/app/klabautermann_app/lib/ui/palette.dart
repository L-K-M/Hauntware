import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart'
    show BuildContext, SingleActivator, TargetPlatform;
import 'package:ghost_ui/ghost_ui.dart' show PaletteCommand;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'adaptive_shell.dart' show showsDesktopShell;
import 'docker/containers_panel.dart' show containerStateText;
import 'docker/containers_view.dart' show containerNameOf;
import 'menus/app_commands.dart';
import 'server_surfaces.dart' show ServerPanel;
import 'workspace_navigation.dart';

/// The command palette's rows (PLT-07, 03 §10.6), each provider's under a
/// path of its own, so `:servers` or `:containers` narrows to one: the
/// app's [actions] but the palette's own, every fleet server, and, while
/// the window shows the desktop workspace, the selected server's tabs
/// and the containers its held list names.
List<PaletteCommand> paletteCommands({
  required AppLocalizations l10n,
  required TargetPlatform platform,
  required BuildContext context,
  required List<AppCommand> actions,
  required FleetController fleet,
  required MonitoringController monitoring,
  required WorkspaceNavigation navigation,
}) {
  // A narrow window's phone shell has no workspace tabs or inspector to
  // send rows to.
  final selected = showsDesktopShell(context) ? fleet.selectedServer : null;
  final containers = selected == null
      ? null
      : monitoring.docker.containersFor(selected.id).value.containers;
  return [
    for (final action in actions)
      if (action.id != kAppCommandPaletteCommandId)
        PaletteCommand(
          label: action.label(l10n),
          path: l10n.paletteActions,
          shortcut: action
              .activators(platform)
              .whereType<SingleActivator>()
              .firstOrNull,
          enabled: action.enabled(),
          run: () => unawaited(action.run(context)),
        ),
    for (final server in fleet.servers)
      switch (server.address) {
        final address? => PaletteCommand(
          label: server.displayName,
          path: l10n.paletteServers,
          description: address,
          keywords: [?server.group, address],
          run: () => fleet.select(server.id),
        ),
        null => PaletteCommand(
          label: server.displayName,
          path: l10n.paletteServers,
          keywords: [?server.group],
          run: () => fleet.select(server.id),
        ),
      },
    if (selected != null)
      for (final panel in ServerPanel.values)
        PaletteCommand(
          label: panel.label(l10n),
          path: l10n.paletteTabs(selected.displayName),
          run: () => navigation.openPanel(selected.id, panel),
        ),
    if (selected != null)
      for (final container in containers ?? const [])
        PaletteCommand(
          label: containerNameOf(container),
          path: l10n.paletteContainers(selected.displayName),
          description: switch (container.image) {
            final image? => l10n.paletteContainerDescription(
              containerStateText(l10n, container.state),
              image,
            ),
            null => containerStateText(l10n, container.state),
          },
          run: () => navigation.openContainer(selected.id, container),
        ),
  ];
}
