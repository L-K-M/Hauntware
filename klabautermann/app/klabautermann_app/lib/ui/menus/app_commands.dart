import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../controllers/fleet_controller.dart';
import '../../l10n/app_localizations.dart';
import '../about_dialog.dart';
import '../server_surfaces.dart' show ServerPanel;
import '../ssh_config_import_action.dart';

/// The app's top-level menus in menu-bar order (03 §10.2). [app] is the
/// macOS application menu: commands reach it only through
/// [CommandMenuPlacement.appMenuOnMac], never by naming it. Edit and a
/// server menu join when commands for them exist; a menu with no rows is
/// left out.
enum AppMenuId { app, file, view, window, help }

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
    this.activators = _noActivators,
  });

  /// Dotted lowerCamel, grouped by noun (`app.*`, `fleet.*`).
  final String id;

  final String Function(AppLocalizations l10n) label;

  final CommandMenuPlacement menuPlacement;

  /// Whether the command applies right now; a disabled one renders dimmed
  /// and never runs, from the menu or its shortcut.
  final bool Function() enabled;

  /// The shortcut chords on a platform; empty when the command has none.
  final List<ShortcutActivator> Function(TargetPlatform platform) activators;

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
