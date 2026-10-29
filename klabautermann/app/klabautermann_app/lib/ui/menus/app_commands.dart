import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoHistory;
import 'package:window_manager/window_manager.dart';

import '../../controllers/fleet_controller.dart';
import '../../controllers/window_panes.dart';
import '../../l10n/app_localizations.dart';
import '../about_dialog.dart';
import '../app_undo.dart';
import '../server_surfaces.dart' show ServerPanel;
import '../ssh_config_import_action.dart';
import '../window_pane_actions.dart';

/// The app's top-level menus in menu-bar order (03 §10.2). [app] is the
/// macOS application menu: commands reach it only through
/// [CommandMenuPlacement.appMenuOnMac], never by naming it. A server menu
/// joins when commands for it exist; a menu with no rows is left out.
enum AppMenuId { app, file, edit, view, window, help }

/// A command's place in a top-level menu, declared where the command is
/// registered (Poltergeist's `CommandMenuPlacement`): menus are a rendering
/// of the registry, never a list of their own.
final class CommandMenuPlacement {
  const CommandMenuPlacement({
    required this.menu,
    required this.order,
    this.group = 0,
    this.appMenuOnMac = false,
  });

  final AppMenuId menu;

  /// Ascending within a group; gaps leave room for later commands.
  final int order;

  /// Divider-separated section within the menu; ascending across groups.
  final int group;

  /// On macOS the command moves into the application menu instead of
  /// [menu], at the same [order] and [group] (Settings…, the AppKit
  /// convention); every other platform keeps [menu].
  final bool appMenuOnMac;
}

/// One user action of the menu registry (03 §10.2), modelled on
/// Poltergeist's `RegisteredCommand` with only what the app's commands use
/// today: an id, an ARB label, enablement, per-platform shortcuts, a menu
/// placement and the action. Menus and the keyboard layer are renderings
/// of these rows, so a menu item, its shortcut and its hint cannot drift.
final class AppCommand {
  const AppCommand({
    required this.id,
    required this.label,
    required this.menuPlacement,
    required this.run,
    this.enabled = _alwaysEnabled,
    this.checked,
    this.activators = _noActivators,
    this.leftAltOnly = false,
    this.repeats = false,
  });

  /// Dotted lowerCamel, grouped by noun (`app.*`, `fleet.*`).
  final String id;

  final String Function(AppLocalizations l10n) label;

  final CommandMenuPlacement menuPlacement;

  /// Whether the command applies right now; a disabled one renders dimmed
  /// and never runs, from the menu or its shortcut.
  final bool Function() enabled;

  /// A toggle's on state, read when the menus are built; null marks the
  /// row uncheckable.
  final bool Function()? checked;

  /// The shortcut chords on a platform; empty when the command has none.
  final List<ShortcutActivator> Function(TargetPlatform platform) activators;

  /// Whether the chords hold only when the left Alt is down: set for
  /// every non-Apple Ctrl+Alt chord so AltGr, which Windows reports as
  /// Ctrl+Alt, is not captured (ghost_ui's `GhostChordBinding`).
  final bool leftAltOnly;

  /// Whether a held chord repeats its run (Undo, which steps back change
  /// by change); a toggle leaves it off so a held key does not flicker.
  final bool repeats;

  /// Runs the command with the menu host's [BuildContext], resolved at
  /// invocation. Implementations must not keep [context] and must check
  /// `context.mounted` after an await before using it again.
  final Future<void> Function(BuildContext context) run;

  static bool _alwaysEnabled() => true;

  static List<ShortcutActivator> _noActivators(TargetPlatform _) => const [];
}

/// About Klabautermann: the app's About dialog (M16), on desktops.
const String kAppAboutCommandId = 'app.about';

/// Settings…: the settings window on desktop, the route where the runner
/// cannot open it (`KlabautermannApp`).
const String kAppSettingsCommandId = 'app.settings';

/// Import from ~/.ssh/config (FL-02), on desktops.
const String kFleetImportSshConfigCommandId = 'fleet.importSshConfig';

/// File ▸ Quit on Linux and Windows.
const String kAppQuitCommandId = 'app.quit';

/// View ▸ Command Palette… (PLT-07, 03 §10.6), on desktops.
const String kAppCommandPaletteCommandId = 'app.commandPalette';

/// Help ▸ Keyboard Shortcuts (PLT-06, 03 §10.6), on desktops.
const String kAppKeyboardShortcutsCommandId = 'app.keyboardShortcuts';

/// View ▸ the selected server's tabs (PLT-06), one command per
/// [ServerPanel]: `view.panel.<name>`.
String viewPanelCommandId(ServerPanel panel) => 'view.panel.${panel.name}';

/// View ▸ the fleet rail's toggle (⌃⌘S / Ctrl+Alt+S), on desktops.
const String kViewToggleSidebarCommandId = 'view.toggleSidebar';

/// View ▸ the inspector's toggle (⌥⌘I / Ctrl+Alt+I), on desktops.
const String kViewToggleInspectorCommandId = 'view.toggleInspector';

/// Edit ▸ Undo, of the app's own history (⌘Z / Ctrl+Z), on desktops.
const String kEditUndoCommandId = 'edit.undo';

/// Edit ▸ Redo (⇧⌘Z / Ctrl+Shift+Z, Ctrl+Y), on desktops.
const String kEditRedoCommandId = 'edit.redo';

/// The digit keys of the tab commands, in [ServerPanel] order.
const List<LogicalKeyboardKey> _panelDigits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

/// ⌘[key] on macOS and Ctrl+[key] elsewhere.
List<ShortcutActivator> primaryChord(
  TargetPlatform platform,
  LogicalKeyboardKey key,
) => [
  platform == TargetPlatform.macOS
      ? SingleActivator(key, meta: true)
      : SingleActivator(key, control: true),
];

/// The commands the app has a real action for today, for [platform]: no
/// placeholders for commands that do not exist yet.
///
/// - About Klabautermann, on desktops, opens the About dialog with the
///   preview label, [appVersion] and the licence (M16). On macOS it leads
///   the application menu in place of AppKit's About panel, which shows
///   `CFBundleName`, an identity, and no label (04 §12.3); Help holds it
///   elsewhere. Phones reach the dialog from Settings > General. No
///   shortcut, as in AppKit.
/// - Settings… opens Settings through [onOpenSettings]: ⌘, on macOS and
///   Ctrl+, elsewhere, as in Poltergeist and Séance. In the application
///   menu on macOS, in File's last section elsewhere.
/// - Import from ~/.ssh/config runs the FL-02 import with its toast, where
///   [fleet] has an ssh_config source (desktops), and is disabled while an
///   import runs. No shortcut, as Poltergeist's import has none.
/// - Quit, on Linux and Windows only, asks the main window to close through
///   [requestClose] (window_manager's `close` by default): the path the
///   close button takes, so the window state is saved and the settings
///   window goes with it. macOS has AppKit's own Quit (⌘Q) in the
///   application menu, and a phone has no quit. No shortcut, as in
///   Poltergeist.
///
/// - Command Palette…, on desktops with [onOpenPalette], opens the palette
///   over every command, server, tab and held container: ⌘K on macOS and
///   Ctrl+K elsewhere (03 §10.6). In View.
///
/// - The tab commands, on desktops with [onOpenPanel], show a tab of the
///   selected server's workspace: ⌘1 to ⌘8 on macOS and Ctrl+1 to Ctrl+8
///   elsewhere, in [ServerPanel] order (03 §10.6). In View, disabled
///   while no server is selected.
/// - Keyboard Shortcuts, on desktops with [onShowKeyboardMap], lists the
///   keys the app takes: ⌘/ on macOS and Ctrl+/ elsewhere. In Help.
///
/// The window commands (Minimize, Zoom, Bring All to Front) and Enter
/// Full Screen are AppKit's own rows on macOS (`buildAppMenus`); Linux and
/// Windows have no counterparts in the app yet.
List<AppCommand> buildAppCommands({
  required TargetPlatform platform,
  required FleetController fleet,
  required VoidCallback onOpenSettings,
  required String? appVersion,
  WindowPanesController? panes,
  GhostUndoHistory? undoHistory,
  Future<void> Function()? requestClose,
  Future<void> Function(BuildContext context)? onOpenPalette,
  void Function(BuildContext context, ServerPanel panel)? onOpenPanel,
  Future<void> Function(BuildContext context)? onShowKeyboardMap,
}) {
  assert(ServerPanel.values.length <= _panelDigits.length);
  final desktop = switch (platform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
  return [
    if (desktop)
      AppCommand(
        id: kAppAboutCommandId,
        label: (l10n) => l10n.aboutCommand,
        run: (context) async =>
            showAppAboutDialog(context, version: appVersion),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.help,
          order: 10,
          appMenuOnMac: true,
        ),
      ),
    if (desktop && onOpenPalette != null)
      AppCommand(
        id: kAppCommandPaletteCommandId,
        label: (l10n) => l10n.paletteCommand,
        activators: (platform) => platform == TargetPlatform.macOS
            ? const [SingleActivator(LogicalKeyboardKey.keyK, meta: true)]
            : const [SingleActivator(LogicalKeyboardKey.keyK, control: true)],
        run: onOpenPalette,
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.view,
          order: 10,
        ),
      ),
    if (desktop && onOpenPanel != null)
      for (final panel in ServerPanel.values)
        AppCommand(
          id: viewPanelCommandId(panel),
          label: (l10n) => l10n.viewPanelCommand(panel.label(l10n)),
          enabled: () => fleet.selectedServer != null,
          activators: (platform) =>
              primaryChord(platform, _panelDigits[panel.index]),
          run: (context) async => onOpenPanel(context, panel),
          menuPlacement: CommandMenuPlacement(
            menu: AppMenuId.view,
            order: 10 + panel.index,
            group: 1,
          ),
        ),
    if (desktop && panes != null) ...[
      // The suite's pane toggles (common.md): ⌃⌘S and ⌥⌘I on macOS,
      // Ctrl+Alt+S and Ctrl+Alt+I elsewhere, the left Alt only so AltGr
      // is not captured. Checked rows name the pane they show.
      AppCommand(
        id: kViewToggleSidebarCommandId,
        label: (l10n) => panes.sidebarShown
            ? l10n.sidebarToggleHide
            : l10n.sidebarToggleShow,
        checked: () => panes.sidebarShown,
        activators: (platform) => [
          windowPaneChord(WindowPane.sidebar, platform),
        ],
        leftAltOnly: platform != TargetPlatform.macOS,
        run: (context) =>
            toggleWindowPane(context, panes, WindowPane.sidebar),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.view,
          order: 20,
        ),
      ),
      AppCommand(
        id: kViewToggleInspectorCommandId,
        label: (l10n) => panes.inspectorShown
            ? l10n.inspectorToggleHide
            : l10n.inspectorToggleShow,
        checked: () => panes.inspectorShown,
        activators: (platform) => [
          windowPaneChord(WindowPane.inspector, platform),
        ],
        leftAltOnly: platform != TargetPlatform.macOS,
        run: (context) =>
            toggleWindowPane(context, panes, WindowPane.inspector),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.view,
          order: 30,
        ),
      ),
    ],
    if (desktop && undoHistory != null) ...[
      AppCommand(
        id: kEditUndoCommandId,
        label: (l10n) => switch (undoHistory.undoName) {
          final name? => l10n.editUndoNamed(name),
          null => l10n.editUndo,
        },
        enabled: () => undoHistory.undoName != null,
        activators: (platform) => platform == TargetPlatform.macOS
            ? const [SingleActivator(LogicalKeyboardKey.keyZ, meta: true)]
            : const [SingleActivator(LogicalKeyboardKey.keyZ, control: true)],
        repeats: true,
        run: (context) => stepUndoHistory(
          Overlay.of(context, rootOverlay: true),
          undoHistory,
          direction: UndoDirection.undo,
        ),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.edit,
          order: 10,
        ),
      ),
      AppCommand(
        id: kEditRedoCommandId,
        label: (l10n) => switch (undoHistory.redoName) {
          final name? => l10n.editRedoNamed(name),
          null => l10n.editRedo,
        },
        enabled: () => undoHistory.redoName != null,
        activators: (platform) => platform == TargetPlatform.macOS
            ? const [
                SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  meta: true,
                  shift: true,
                ),
              ]
            : const [
                SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  control: true,
                  shift: true,
                ),
                SingleActivator(LogicalKeyboardKey.keyY, control: true),
              ],
        repeats: true,
        run: (context) => stepUndoHistory(
          Overlay.of(context, rootOverlay: true),
          undoHistory,
          direction: UndoDirection.redo,
        ),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.edit,
          order: 20,
        ),
      ),
    ],
    if (desktop && onShowKeyboardMap != null)
      AppCommand(
        id: kAppKeyboardShortcutsCommandId,
        label: (l10n) => l10n.keyboardMapCommand,
        activators: (platform) =>
            primaryChord(platform, LogicalKeyboardKey.slash),
        run: onShowKeyboardMap,
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.help,
          order: 20,
        ),
      ),
    if (fleet.canImportSshConfig)
      AppCommand(
        id: kFleetImportSshConfigCommandId,
        label: (l10n) => l10n.importSshConfig,
        enabled: () => !fleet.isImportingSshConfig,
        run: (context) => importSshConfigWithFeedback(context, fleet),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.file,
          order: 10,
        ),
      ),
    AppCommand(
      id: kAppSettingsCommandId,
      label: (l10n) => l10n.settingsCommand,
      activators: (platform) => platform == TargetPlatform.macOS
          ? const [SingleActivator(LogicalKeyboardKey.comma, meta: true)]
          : const [SingleActivator(LogicalKeyboardKey.comma, control: true)],
      run: (_) async => onOpenSettings(),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 10,
        group: 9,
        appMenuOnMac: true,
      ),
    ),
    if (platform == TargetPlatform.linux || platform == TargetPlatform.windows)
      AppCommand(
        id: kAppQuitCommandId,
        label: (l10n) => l10n.appQuitLabel,
        run: (_) => (requestClose ?? windowManager.close)(),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.file,
          order: 20,
          group: 9,
        ),
      ),
  ];
}
