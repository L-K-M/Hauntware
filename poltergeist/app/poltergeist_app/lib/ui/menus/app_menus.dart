import 'package:flutter/widgets.dart';
import 'package:ghost_ui/ghost_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';

/// The registry command behind a row built by [buildAppMenus] — its
/// [GhostCommandSpec.tag]. Surfaces that need more than the snapshot
/// (disabled reasons, icons, run routing) recover it here.
RegisteredCommand ghostRowCommand(GhostCommandSpec spec) =>
    spec.tag! as RegisteredCommand;

/// The resolved snapshot the shared renderers draw for [command]:
/// label, enablement, toggle state and chords fixed for [platform] at
/// model-build time; the command itself rides in [GhostCommandSpec.tag].
GhostCommandSpec ghostCommandSpec(
  RegisteredCommand command,
  AppLocalizations l10n,
  TargetPlatform platform,
) => GhostCommandSpec(
  id: command.id,
  label: command.label(l10n),
  enabled: command.enabled(),
  checked: command.checked?.call(),
  activators: command.activators?.call(platform) ?? const [],
  tag: command,
);

/// Derives the app's menus from the registered commands for [platform]
/// into the shared [GhostMenu] model both menu backends render.
///
/// Commands without a [RegisteredCommand.menuPlacement] never appear —
/// there are no disabled placeholders for commands that do not exist yet,
/// and stable [CommandMenuPlacement.order] slots leave gaps for future
/// commands. Menus with no rows are dropped (except the macOS chrome
/// below).
List<GhostMenu> buildAppMenus({
  required List<RegisteredCommand> commands,
  required AppLocalizations l10n,
  required TargetPlatform platform,
}) {
  final mac = platform == TargetPlatform.macOS;
  final placed = <AppMenuId, List<RegisteredCommand>>{};
  final appMenu = <RegisteredCommand>[];
  for (final command in commands) {
    final placement = command.menuPlacement;
    if (placement == null) continue;
    assert(
      placement.menu != AppMenuId.app,
      'commands reach the macOS application menu via appMenuOnMac',
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
      // AppKit's own Enter/Exit Full Screen item (⌃⌘F), last in View as
      // every Mac app places it.
      groups = [
        ...groups,
        const [
          GhostProvidedRow(PlatformProvidedMenuItemType.toggleFullScreen),
        ],
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
          GhostProvidedRow(
            PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ];
    }
    if (groups.isEmpty) continue;
    menus.add(
      GhostMenu(id: id, title: _menuTitle(id, l10n), groups: groups),
    );
  }
  return menus;
}

/// The macOS application menu (10 §8): About, then the commands that
/// declare [CommandMenuPlacement.appMenuOnMac] (Check for Updates…,
/// Settings…), then Services, the hide trio, and Quit — AppKit's order.
/// Quit is AppKit's own row here; Linux and Windows get a registered
/// Quit command at the end of File instead (`app_menu_commands.dart`).
GhostMenu _macAppMenu(
  AppLocalizations l10n,
  List<List<GhostMenuRow>> commandGroups,
) => GhostMenu(
  id: AppMenuId.app,
  title: l10n.appTitle,
  groups: [
    const [GhostProvidedRow(PlatformProvidedMenuItemType.about)],
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

/// Sorts one menu's commands by `(group, order)` and splits the sorted
/// run into divider-separated groups.
List<List<GhostMenuRow>> _menuGroups(
  List<RegisteredCommand> items,
  AppLocalizations l10n,
  TargetPlatform platform,
) {
  final sorted = [...items]..sort((a, b) {
    final pa = a.menuPlacement!;
    final pb = b.menuPlacement!;
    final byGroup = pa.group.compareTo(pb.group);
    if (byGroup != 0) return byGroup;
    final byOrder = pa.order.compareTo(pb.order);
    if (byOrder != 0) return byOrder;
    return a.id.compareTo(b.id);
  });
  assert(() {
    final slots = <String>{};
    for (final command in sorted) {
      final p = command.menuPlacement!;
      assert(
        slots.add('${p.group}:${p.order}'),
        '${command.id} shares menu slot ${p.group}:${p.order}',
      );
    }
    return true;
  }());

  // Per divider-separated section: `ordered` keeps each row's
  // first-occurrence position (a command, a GhostSubmenuRow built
  // from a parameterized command's own items, or a submenu title for
  // merged submenu rows whose members buffer in `submenuItems`).
  final groups = <List<GhostMenuRow>>[];
  int? group;
  List<Object>? ordered;
  Map<String, List<GhostCommandRow>>? submenuItems;

  void flush() {
    final entries = ordered;
    final submenus = submenuItems;
    if (entries == null || submenus == null) return;
    groups.add([
      for (final entry in entries)
        switch (entry) {
          String() => GhostSubmenuRow(
            title: entry,
            items: submenus[entry]!,
          ),
          GhostSubmenuRow() => entry,
          _ => GhostCommandRow(
            ghostCommandSpec(entry as RegisteredCommand, l10n, platform),
          ),
        },
    ]);
  }

  for (final command in sorted) {
    final placement = command.menuPlacement!;
    if (placement.group != group) {
      flush();
      group = placement.group;
      ordered = [];
      submenuItems = {};
    }
    final submenu = placement.submenu;
    final items = command.submenuItems;
    if (items != null) {
      // A parameterized command renders its own ▸ submenu at its slot:
      // the row's items are the parameter-bound invocations, built at
      // render time so they track the live selection/registry.
      ordered!.add(
        GhostSubmenuRow(
          title: command.label(l10n),
          items: [
            for (final item in items(l10n))
              GhostCommandRow(ghostCommandSpec(item, l10n, platform)),
          ],
        ),
      );
    } else if (submenu == null) {
      ordered!.add(command);
    } else {
      final title = submenu(l10n);
      submenuItems!
          .putIfAbsent(title, () {
            ordered!.add(title);
            return [];
          })
          .add(GhostCommandRow(ghostCommandSpec(command, l10n, platform)));
    }
  }
  flush();
  return groups;
}

/// The localized title of one top-level menu — the palette prints it
/// in a command row's "File ▸ Open" path line (02 §8.4).
String appMenuTitle(AppMenuId id, AppLocalizations l10n) =>
    _menuTitle(id, l10n);

String _menuTitle(AppMenuId id, AppLocalizations l10n) => switch (id) {
  AppMenuId.app => l10n.appTitle,
  AppMenuId.file => l10n.menuFile,
  AppMenuId.edit => l10n.menuEdit,
  AppMenuId.view => l10n.menuView,
  AppMenuId.go => l10n.menuGo,
  AppMenuId.server => l10n.menuServer,
  AppMenuId.window => l10n.menuWindow,
  AppMenuId.help => l10n.menuHelp,
};
