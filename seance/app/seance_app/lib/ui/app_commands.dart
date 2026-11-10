import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        GhostCommandRow,
        GhostCommandSpec,
        GhostMenu,
        GhostShortcutHint,
        PaletteCommand,
        ghostMenuBarChildren,
        showCommandPalette;
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../main.dart';
import 'adaptive_shell.dart' show AdaptivePaneLayout;
import 'app_menus.dart';
import 'inspector_page.dart';
import 'server_list_pane.dart';
import 'top_toast.dart';

/// The top-level menu a command belongs to, in bar order. Séance draws
/// these in the ☰ button (Linux, Windows, phones); on macOS the native
/// menu covers the same ground and the button stays hidden.
enum SeanceMenu { file, edit, view, terminal, help }

extension SeanceMenuTitle on SeanceMenu {
  /// The menu's title as the ☰ and the palette path show it.
  String get title => switch (this) {
    SeanceMenu.file => 'File',
    SeanceMenu.edit => 'Edit',
    SeanceMenu.view => 'View',
    SeanceMenu.terminal => 'Terminal',
    SeanceMenu.help => 'Help',
  };
}

/// The command palette's own row, left out of [seancePaletteCommands]:
/// the palette does not offer to open itself (Klabautermann's rule).
const kCommandPaletteId = 'view.commandPalette';

/// One app command as the menus and palette see it: a snapshot resolved
/// by [seanceCommands], with [label], [enabled] and [checked] already read,
/// so the renderers never reach back into [AppState]. Rebuild the list
/// whenever the state it read notifies; the snapshot is as fresh as the
/// build that produced it.
final class SeanceCommand {
  const SeanceCommand({
    required this.id,
    required this.label,
    required this.menu,
    this.group = 0,
    this.order = 0,
    this.activators = const [],
    this.enabled = true,
    this.checked,
    this.wideOnly = false,
    required this.run,
  });

  /// The command's stable identifier; keys its menu row (`menu.item.<id>`).
  final String id;

  /// The display label, already resolved for the current state. Undo and
  /// Redo name the change they would take ("Undo Pin to top").
  final String label;

  /// The menu the command sits in, which is also its palette path.
  final SeanceMenu menu;

  /// The divider-separated section inside [menu]; groups render in order.
  final int group;

  /// The row's position inside its [group].
  final int order;

  /// The command's chords on this platform, for the hint a menu row or
  /// palette entry shows. The chord layer dispatches; the hint only reads.
  final List<ShortcutActivator> activators;

  /// Whether the command applies right now; a disabled row stays visible,
  /// dimmed, so its place and its shortcut stay discoverable.
  final bool enabled;

  /// Toggle state for checkable rows (the pane toggles); null for plain
  /// commands.
  final bool? checked;

  /// Whether the command needs the wide layout's panes and drops out in
  /// the narrow posture.
  final bool wideOnly;

  /// Runs the command with the context that invoked it.
  final void Function(BuildContext context, AppState state) run;
}

/// The app's commands resolved for [state] and [platform]: the single
/// list the ☰ menus, the command palette and their tests read, so rows,
/// shortcuts and enablement cannot drift between them. [wide] keeps the
/// side-pane commands out of the narrow posture, where there are no panes
/// to toggle (the end-drawer holds the inspector and the back button the
/// server list).
List<SeanceCommand> seanceCommands(
  AppState state,
  TargetPlatform platform, {
  required bool wide,
}) {
  final apple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  ShortcutActivator primary(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: apple, control: !apple, shift: shift);
  SingleActivator window(WindowCommand command) => windowShortcuts(
    platform,
  ).firstWhere((shortcut) => shortcut.command == command).chord;
  List<SeanceCommand> pages() => [
    for (final page in InspectorPage.values)
      SeanceCommand(
        id: 'view.${page.name}',
        label: 'Show ${page.label}',
        menu: SeanceMenu.view,
        group: 1,
        order: page.index,
        activators: [window(inspectorPageCommand(page))],
        wideOnly: true,
        run: (context, state) =>
            runWindowCommand(context, state, inspectorPageCommand(page)),
      ),
  ];

  return [
    SeanceCommand(
      id: 'file.newTab',
      label: 'New Tab',
      menu: SeanceMenu.file,
      activators: [primary(LogicalKeyboardKey.keyT)],
      enabled: state.activeSession != null,
      run: (context, state) => openNewTab(state),
    ),
    SeanceCommand(
      id: 'file.settings',
      label: 'Settings…',
      menu: SeanceMenu.file,
      group: 1,
      activators: [primary(LogicalKeyboardKey.comma)],
      run: (context, state) => openSettings(),
    ),
    SeanceCommand(
      id: 'edit.undo',
      label: switch (state.undoHistory.undoName) {
        final name? => 'Undo $name',
        null => 'Undo',
      },
      menu: SeanceMenu.edit,
      activators: [window(WindowCommand.undo)],
      enabled: state.undoHistory.undoName != null,
      run: (context, state) =>
          runWindowCommand(context, state, WindowCommand.undo),
    ),
    SeanceCommand(
      id: 'edit.redo',
      label: switch (state.undoHistory.redoName) {
        final name? => 'Redo $name',
        null => 'Redo',
      },
      menu: SeanceMenu.edit,
      order: 1,
      activators: [
        for (final shortcut in windowShortcuts(platform))
          if (shortcut.command == WindowCommand.redo) shortcut.chord,
      ],
      enabled: state.undoHistory.redoName != null,
      run: (context, state) =>
          runWindowCommand(context, state, WindowCommand.redo),
    ),
    SeanceCommand(
      id: 'edit.findInEditor',
      label: 'Find in Editor…',
      menu: SeanceMenu.edit,
      group: 1,
      // The chords the editor itself binds for find (⌘F / Ctrl+F); the
      // macOS Edit menu's Find item lands on the same handler.
      activators: [primary(LogicalKeyboardKey.keyF)],
      enabled:
          state.activeTab is EditorTab &&
          (state.activeTab! as EditorTab).editorKey.currentState != null,
      run: (context, state) {
        if (state.activeTab case final EditorTab tab) {
          tab.editorKey.currentState?.openSearch();
        }
      },
    ),
    SeanceCommand(
      id: 'view.sidebar',
      label: state.sidebarVisible ? 'Hide Sidebar' : 'Show Sidebar',
      menu: SeanceMenu.view,
      activators: [window(WindowCommand.toggleSidebar)],
      checked: state.sidebarVisible,
      wideOnly: true,
      run: (context, state) =>
          runWindowCommand(context, state, WindowCommand.toggleSidebar),
    ),
    SeanceCommand(
      id: 'view.inspector',
      label: state.inspectorVisible ? 'Hide Inspector' : 'Show Inspector',
      menu: SeanceMenu.view,
      order: 1,
      activators: [window(WindowCommand.toggleInspector)],
      checked: state.inspectorVisible,
      wideOnly: true,
      run: (context, state) =>
          runWindowCommand(context, state, WindowCommand.toggleInspector),
    ),
    ...pages(),
    SeanceCommand(
      id: 'view.filterServers',
      label: 'Filter Servers',
      menu: SeanceMenu.view,
      group: 2,
      activators: [serverFilterActivator(platform)],
      run: (context, state) => ServerListPane.revealFilter(),
    ),
    SeanceCommand(
      id: kCommandPaletteId,
      label: 'Command Palette…',
      menu: SeanceMenu.view,
      group: 2,
      order: 1,
      activators: [window(WindowCommand.showPalette)],
      run: (context, state) => unawaited(openCommandPalette(context, state)),
    ),
    SeanceCommand(
      id: 'terminal.generateCommand',
      label: 'Generate Command…',
      menu: SeanceMenu.terminal,
      activators: [
        apple
            ? const SingleActivator(LogicalKeyboardKey.keyK, meta: true)
            : const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
                shift: true,
              ),
      ],
      run: (context, state) => openCommandGenerator(state),
    ),
    SeanceCommand(
      id: 'help.keyboardShortcuts',
      label: 'Keyboard Shortcuts',
      menu: SeanceMenu.help,
      activators: [window(WindowCommand.showKeyboardShortcuts)],
      run: (context, state) =>
          runWindowCommand(context, state, WindowCommand.showKeyboardShortcuts),
    ),
    SeanceCommand(
      id: 'help.checkForUpdates',
      label: 'Check for Updates…',
      menu: SeanceMenu.help,
      order: 1,
      run: (context, state) => runCheckForUpdates(context, state),
    ),
    // macOS keeps AppKit's own About in the application menu; everywhere
    // else the Help menu carries the dialog.
    if (platform != TargetPlatform.macOS)
      SeanceCommand(
        id: 'help.about',
        label: 'About Séance',
        menu: SeanceMenu.help,
        order: 2,
        run: (context, state) => showSeanceAboutDialog(context, state),
      ),
  ].where((command) => wide || !command.wideOnly).toList();
}

/// [commands] grouped into [GhostMenu]s for [ghostMenuBarChildren]: each
/// menu's divider-separated sections in order. The spec carries the
/// command as its tag; activate resolves it back to run with [context].
List<GhostMenu> seanceMenus(List<SeanceCommand> commands) => [
  for (final menu in SeanceMenu.values)
    if (commands.any((command) => command.menu == menu))
      GhostMenu(
        id: menu,
        title: menu.title,
        groups: [
          for (final group in _menuGroups(commands, menu))
            [
              for (final command in group)
                GhostCommandRow(
                  GhostCommandSpec(
                    id: command.id,
                    label: command.label,
                    enabled: command.enabled,
                    checked: command.checked,
                    activators: command.activators,
                    tag: command,
                  ),
                ),
            ],
        ],
      ),
];

List<List<SeanceCommand>> _menuGroups(
  List<SeanceCommand> commands,
  SeanceMenu menu,
) {
  final byGroup = <int, List<SeanceCommand>>{};
  for (final command in commands.where((command) => command.menu == menu)) {
    (byGroup[command.group] ??= []).add(command);
  }
  return [
    for (final key in byGroup.keys.toList()..sort())
      byGroup[key]!..sort((a, b) => a.order.compareTo(b.order)),
  ];
}

/// [commands] as palette rows: the label resolved, the menu as the path
/// ("Edit" under "Undo Pin to top"), the first chord as the hint, a
/// disabled row listed but inert. The palette's own row is left out.
List<PaletteCommand> seancePaletteCommands(
  BuildContext context,
  AppState state,
  List<SeanceCommand> commands,
) => [
  for (final command in commands)
    if (command.id != kCommandPaletteId)
      PaletteCommand(
        label: command.label,
        path: command.menu.title,
        shortcut: command.activators.whereType<SingleActivator>().firstOrNull,
        enabled: command.enabled,
        run: () => command.run(context, state),
      ),
];

/// The palette over every command this posture has: ⇧⌘P / Ctrl+Shift+P,
/// the ☰ row, or its own palette entry (which is listed, but not in it).
Future<void> openCommandPalette(BuildContext context, AppState state) {
  final platform = Theme.of(context).platform;
  return showCommandPalette(
    context,
    seancePaletteCommands(
      context,
      state,
      seanceCommands(
        state,
        platform,
        wide: !AdaptivePaneLayout.isNarrow(context),
      ),
    ),
  );
}

/// The manual Check for Updates… (the macOS application menu's, the ☰'s
/// and the palette's): [AppState.checkNow] runs even while the launch
/// check is opted out. A newer release is announced with a link to its
/// page, matching the banner; otherwise the toast says no newer version
/// was found, never "up to date": the checker cannot tell that from a
/// check that could not reach GitHub.
Future<void> runCheckForUpdates(
  BuildContext context,
  AppState state, {
  OverlayState? overlay,
}) async {
  final rootOverlay = overlay ?? Overlay.of(context, rootOverlay: true);
  final version = state.appVersion;
  final info = version == null ? null : await state.checkNow(version);
  if (!rootOverlay.mounted) return;
  if (info == null) {
    showTopToast(
      rootOverlay,
      message:
          'No newer version was found. If you’re offline, try again later.',
    );
    return;
  }
  showTopToast(
    rootOverlay,
    message: 'Séance ${info.latestVersion} is available.',
    actionLabel: 'View release',
    onAction: () => unawaited(
      launchUrl(info.releasesUrl, mode: LaunchMode.externalApplication),
    ),
  );
}

/// Help ▸ About Séance where there is no AppKit About: the same name,
/// version and legalese as Settings ▸ About, and the built-in
/// View-licenses button, which lists the ghost_licenses notices too.
void showSeanceAboutDialog(BuildContext context, AppState state) {
  showAboutDialog(
    context: context,
    applicationName: 'Séance',
    applicationVersion: state.appVersion,
    applicationLegalese:
        "Séance's own code is public domain (Unlicense). It includes "
        'third-party components that keep their own licenses, listed '
        'here.',
  );
}

/// The ☰ menu for the platforms with no native menu bar (Linux, Windows,
/// phones): the app's commands as a popup, one submenu per [SeanceMenu],
/// each row running its command and showing its chord. macOS hides it: the
/// native menu covers the same ground.
class SeanceMenuButton extends StatelessWidget {
  const SeanceMenuButton({super.key, this.wide});

  static const buttonKey = ValueKey('menu.main');

  /// Whether the list keeps the side-pane commands; defaults to the layout's
  /// posture (the wide layout's header, the phone home's app bar).
  final bool? wide;

  /// The panel's floor width, and how far it is pulled back from the
  /// button's trailing edge: a panel this wide ends where the button does.
  static const double _panelWidth = 160;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.macOS) {
      return const SizedBox.shrink();
    }
    final state = AppScope.of(context);
    return ListenableBuilder(
      // The undo rows read the history's names, so a step or a recorded
      // change refreshes the menu even when the state itself is silent.
      listenable: Listenable.merge([state, state.undoHistory]),
      builder: (context, _) {
        final commands = seanceCommands(
          state,
          platform,
          wide: wide ?? !AdaptivePaneLayout.isNarrow(context),
        );
        return MenuAnchor(
          alignmentOffset: const Offset(-_panelWidth, 0),
          crossAxisUnconstrained: false,
          style: const MenuStyle(
            alignment: AlignmentDirectional.bottomEnd,
            minimumSize: WidgetStatePropertyAll(Size(_panelWidth, 0)),
            visualDensity: VisualDensity.standard,
          ),
          menuChildren: ghostMenuBarChildren(
            seanceMenus(commands),
            activate: (spec) =>
                (spec.tag as SeanceCommand).run(context, state),
            trailingFor: (spec) => spec.activators.isEmpty
                ? null
                : GhostShortcutHint(
                    spec.activators.first,
                    enabled: spec.enabled,
                  ),
          ),
          builder: (context, controller, _) => IconButton(
            key: buttonKey,
            tooltip: 'Menu',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.menu),
          ),
        );
      },
    );
  }
}
