import 'package:flutter/widgets.dart';
import 'package:ghost_ui/ghost_ui.dart';

import '../../l10n/app_localizations.dart';
import 'app_commands.dart';

/// The resolved snapshot the shared renderers draw for [command]: label,
/// enablement and shortcuts fixed for [platform] when the model is built.
GhostCommandSpec appCommandSpec(
  AppCommand command,
  AppLocalizations l10n,
  TargetPlatform platform,
) => GhostCommandSpec(
  id: command.id,
  label: command.label(l10n),
  enabled: command.enabled(),
  checked: command.checked?.call(),
  activators: command.activators(platform),
);

/// Derives the app's menus from the registered [commands] for [platform]
/// into ghost_ui's [GhostMenu] model, which both menu backends render
/// (Poltergeist's `buildAppMenus`, 03 §10.2).
///
/// Commands sort by `(group, order)` within their menu, and each group is
/// a divider-separated section. Menus with no rows are left out, except
/// the macOS application, View and Window menus, which carry AppKit's own
/// rows: Services, the hide trio and Quit; Enter Full Screen; and
/// Minimize, Zoom and Bring All to Front. About is the app's own command,
/// not AppKit's panel (04 §12.3).
List<GhostMenu> buildAppMenus({
  required List<AppCommand> commands,
  required AppLocalizations l10n,
  required TargetPlatform platform,
}) {
  final mac = platform == TargetPlatform.macOS;
  final placed = <AppMenuId, List<AppCommand>>{};
  final appMenu = <AppCommand>[];
  for (final command in commands) {
    final placement = command.menuPlacement;
    assert(
      placement.menu != AppMenuId.app,
      'commands reach the macOS application menu through appMenuOnMac',
    );
    if (mac && placement.appMenuOnMac) {
      appMenu.add(command);
      continue;
    }
    placed.putIfAbsent(placement.menu, () => []).add(command);
  }

  final menus = <GhostMenu>[
    if (mac) _macAppMenu(l10n, _menuGroups(appMenu, l10n, platform)),
  ];
  for (final id in AppMenuId.values) {
    if (id == AppMenuId.app) continue;
    var groups = _menuGroups(placed[id] ?? const [], l10n, platform);
    if (mac && id == AppMenuId.view) {
      // AppKit's Enter/Exit Full Screen (⌃⌘F), last in View as every Mac
      // app places it.
      groups = [
        ...groups,
        const [GhostProvidedRow(PlatformProvidedMenuItemType.toggleFullScreen)],
      ];
    }
    if (mac && id == AppMenuId.window) {
      groups = [
        const [
          GhostProvidedRow(PlatformProvidedMenuItemType.minimizeWindow),
          GhostProvidedRow(PlatformProvidedMenuItemType.zoomWindow),
        ],
        ...groups,
        const [
          GhostProvidedRow(PlatformProvidedMenuItemType.arrangeWindowsInFront),
        ],
      ];
    }
    if (groups.isEmpty) continue;
    menus.add(GhostMenu(id: id, title: _menuTitle(id, l10n), groups: groups));
  }
  return menus;
}

/// The macOS application menu in AppKit's order: the commands that declare
/// [CommandMenuPlacement.appMenuOnMac] (About Klabautermann, then
/// Settings…), Services, the hide trio, and AppKit's own Quit (⌘Q).
/// AppKit's About row is left out: its panel shows `CFBundleName`, an
/// identity, without the preview label (M16, 04 §12.3).
GhostMenu _macAppMenu(
  AppLocalizations l10n,
  List<List<GhostMenuRow>> commandGroups,
) => GhostMenu(
  id: AppMenuId.app,
  title: l10n.appTitle,
  groups: [
    ...commandGroups,
    const [GhostProvidedRow(PlatformProvidedMenuItemType.servicesSubmenu)],
    const [
      GhostProvidedRow(PlatformProvidedMenuItemType.hide),
      GhostProvidedRow(PlatformProvidedMenuItemType.hideOtherApplications),
      GhostProvidedRow(PlatformProvidedMenuItemType.showAllApplications),
    ],
    const [GhostProvidedRow(PlatformProvidedMenuItemType.quit)],
  ],
);

/// One menu's commands sorted by `(group, order)` and split into
/// divider-separated groups.
List<List<GhostMenuRow>> _menuGroups(
  List<AppCommand> commands,
  AppLocalizations l10n,
  TargetPlatform platform,
) {
  final sorted = [...commands]
    ..sort((a, b) {
      final pa = a.menuPlacement;
      final pb = b.menuPlacement;
      final byGroup = pa.group.compareTo(pb.group);
      if (byGroup != 0) return byGroup;
      final byOrder = pa.order.compareTo(pb.order);
      if (byOrder != 0) return byOrder;
      return a.id.compareTo(b.id);
    });
  assert(() {
    final slots = <String>{};
    for (final command in sorted) {
      final placement = command.menuPlacement;
      assert(
        slots.add('${placement.group}:${placement.order}'),
        '${command.id} shares menu slot ${placement.group}:${placement.order}',
      );
    }
    return true;
  }());

  final groups = <List<GhostMenuRow>>[];
  int? group;
  for (final command in sorted) {
    if (command.menuPlacement.group != group) {
      group = command.menuPlacement.group;
      groups.add([]);
    }
    groups.last.add(GhostCommandRow(appCommandSpec(command, l10n, platform)));
  }
  return groups;
}

String _menuTitle(AppMenuId id, AppLocalizations l10n) => switch (id) {
  AppMenuId.app => l10n.appTitle,
  AppMenuId.file => l10n.menuFile,
  AppMenuId.edit => l10n.menuEdit,
  AppMenuId.view => l10n.menuView,
  AppMenuId.window => l10n.menuWindow,
  AppMenuId.help => l10n.menuHelp,
};
