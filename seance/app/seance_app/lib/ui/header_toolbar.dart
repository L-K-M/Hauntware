import 'package:flutter/material.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show macosTrafficLightsInset;
import 'package:ghost_ui/ghost_ui.dart' show formatShortcutActivator;
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../theme.dart';
import 'adaptive_shell.dart' show PaneVisibility;
import 'app_menus.dart';
import 'macos_toolbar_band.dart';
import 'server_appearance.dart';

/// The space before the first control where nothing sits ahead of it.
const double _edgeInset = 8;

/// The space a leading control or the title keeps from what follows.
const double _gap = 8;

/// Where the window's leading controls start: after the traffic lights
/// under the macOS titlebar, in full screen too, and at the edge
/// everywhere else (other platforms, the Settings window).
double _leadingInset(BuildContext context) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? macosTrafficLightsInset
    : _edgeInset;

/// [child] as a control inside the macOS toolbar band: there AppKit takes
/// every click for window drag unless a passthrough view hands it back.
/// Plain Flutter on every other platform.
Widget _clickable(BuildContext context, Widget child) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? MacosToolbarPassthrough(child: child)
    : child;

/// [child] with the passthrough views inside it registered, on macOS.
Widget _passthroughScope(BuildContext context, Widget child) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? MacosToolbarPassthroughScope(child: child)
    : child;

/// The wide layout's header, on every platform: the window's title and
/// its toolbar in one row, Poltergeist's arrangement. On macOS it draws
/// under the unified toolbar band (`MacosTitlebar.install`), with the
/// traffic lights over the server list to its left instead of a standard
/// titlebar above everything; elsewhere it sits under the native title bar.
///
///     ┌──────────────┬──────────────────────────────────────────────┐
///     │ ●●●  [◧]     │ [badge] prod-db         [✦ Generate…] [◨]   │
///     │ (SidebarBand)│         user@host                            │
///     ├──────────────┼──────────────────────────────────────────────┤
///     │ servers      │ tabs, terminal               │ inspector     │
///
/// The title is the active server's badge and label with `user@host` under
/// it, what a titlebar would otherwise say. It stays out of the click
/// passthrough, so on macOS dragging it moves the window and
/// double-clicking it zooms, as a titlebar does; the buttons take their
/// clicks through [MacosToolbarPassthrough]. Generate command lives here
/// as the primary, labelled button (Poltergeist's Connect), and leaves the
/// tab strip below. The inspector button ends the row; the sidebar button
/// leads it while the server list is hidden, and sits over the list
/// ([SidebarBand]) while it shows.
class HeaderToolbar extends StatelessWidget {
  const HeaderToolbar({super.key, this.sidebar = PaneVisibility.shown});

  static const titleKey = ValueKey('header.title');
  static const subtitleKey = ValueKey('header.subtitle');
  static const generateCommandKey = ValueKey('header.generateCommand');
  static const sidebarToggleKey = ValueKey('header.sidebarToggle');
  static const inspectorToggleKey = ValueKey('header.inspectorToggle');

  /// Whether the server list shows beside the header, carrying the sidebar
  /// button; while it is hidden the header carries it.
  final PaneVisibility sidebar;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    final platform = Theme.of(context).platform;
    final leadsWithSidebar = sidebar == PaneVisibility.hidden;

    final header = Material(
      color: chrome.headerBackground,
      // As wide as it is let be, title or not: with nothing open it would
      // shrink to its padding, and the page would show beside it.
      child: SizedBox(
        width: double.infinity,
        height: chrome.headerHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leadsWithSidebar ? _leadingInset(context) : 12,
            end: _edgeInset,
          ),
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) => Row(
              children: [
                if (leadsWithSidebar) ...[
                  _clickable(
                    context,
                    _PaneToggleButton(
                      key: sidebarToggleKey,
                      command: WindowCommand.toggleSidebar,
                      visible: state.sidebarVisible,
                    ),
                  ),
                  const SizedBox(width: _gap),
                ],
                Expanded(child: _HeaderTitle(state: state)),
                const SizedBox(width: _gap),
                _clickable(
                  context,
                  _Capsule(
                    children: [
                      _ToolbarButton(
                        key: generateCommandKey,
                        icon: Icons.auto_fix_high,
                        // The assistant's purple (Poltergeist's D34), as in
                        // the tab strip it replaces.
                        hue: FamilyHue.purple,
                        label: 'Generate command',
                        shortcut: platform == TargetPlatform.macOS
                            ? '⌘K'
                            : 'Ctrl+Shift+K',
                        onPressed: () => openCommandGenerator(state),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: _gap),
                _clickable(
                  context,
                  _PaneToggleButton(
                    key: inspectorToggleKey,
                    command: WindowCommand.toggleInspector,
                    visible: state.inspectorVisible,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return _passthroughScope(context, header);
  }
}

/// The server list's top while the header shows: level with the header,
/// with the sidebar button after the traffic lights on macOS and at the
/// leading edge elsewhere. On macOS the empty rest drags the window.
class SidebarBand extends StatelessWidget {
  const SidebarBand({super.key});

  static const sidebarToggleKey = ValueKey('sidebarBand.sidebarToggle');

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    return _passthroughScope(
      context,
      SizedBox(
        height: chrome.headerHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: _leadingInset(context)),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => _clickable(
                context,
                _PaneToggleButton(
                  key: sidebarToggleKey,
                  command: WindowCommand.toggleSidebar,
                  visible: state.sidebarVisible,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The active server's badge and label, `user@host` under it. Empty while
/// nothing is open: the band is then all window drag, like a titlebar
/// with no title.
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final active = state.activeTab;
    if (active == null) return const SizedBox.shrink();
    // The stored config, not the session's connect-time snapshot, as the
    // tab strip reads it: a rename or recolour shows at once.
    final server = state.configFor(active.serverId) ?? active.config;
    final theme = Theme.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    // A local shell has no server to read colour, mark or address from:
    // the terminal glyph on the neutral badge, and the session's own words
    // for what it is and where it runs.
    final local = server == null && active is TerminalSession ? active : null;
    final port = server != null && server.port != 22 ? ':${server.port}' : '';
    final address = server == null
        ? local?.displayTarget ?? 'this machine'
        : server.username.isEmpty
        ? '${server.host}$port'
        : '${server.username}@${server.host}$port';
    return Semantics(
      header: true,
      child: Row(
        children: [
          // Decorative: the label beside it names the server, so a label
          // here would have a screen reader say the name twice.
          ExcludeSemantics(
            child: ServerBadge(
              tint: server == null ? ServerTint.none : ServerTint.of(server),
              mark: server?.mark ?? const ServerGlyphMark(ServerIcon.terminal),
              size: 24,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server?.label ?? local?.displayLabel ?? 'Local shell',
                  key: HeaderToolbar.titleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  address,
                  key: HeaderToolbar.subtitleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: chrome.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ForkLift's rounded group behind related toolbar buttons, as in
/// Poltergeist's header. A [Material] rather than a filled box, so the
/// buttons' hover and splash ink paints above the fill.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    return Material(
      color: chrome.capsuleFill,
      borderRadius: BorderRadius.circular(chrome.corner(8)),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A labelled header button in Poltergeist's geometry: 26 px tall, a
/// 17 px glyph in its family hue, the label in the ink.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.icon,
    required this.hue,
    required this.label,
    required this.shortcut,
    required this.onPressed,
  });

  final IconData icon;
  final FamilyHue hue;
  final String label;
  final String shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    final radius = BorderRadius.circular(chrome.corner(6));
    return Tooltip(
      message: '$label $shortcut',
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        // excludeSemantics drops the InkWell's own tap action with its
        // subtree, so the node carries it for a screen reader's activate.
        onTap: onPressed,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: chrome.hoverFill,
          child: Container(
            height: 26,
            constraints: const BoxConstraints(minWidth: 30),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: FamilyPalette.of(context).glyph(hue),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon-only button that shows or hides a side pane: the sidebar's
/// glyph has its panel on the leading side, the inspector's on the
/// trailing side. Named for what it would do ("Hide sidebar"), with the
/// pane's shortcut in its tooltip.
class _PaneToggleButton extends StatelessWidget {
  const _PaneToggleButton({
    super.key,
    required this.command,
    required this.visible,
  });

  /// [WindowCommand.toggleSidebar] or [WindowCommand.toggleInspector].
  final WindowCommand command;

  /// Whether the pane shows now.
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    final platform = Theme.of(context).platform;
    final pane = command == WindowCommand.toggleSidebar
        ? 'sidebar'
        : 'inspector';
    final label = '${visible ? 'Hide' : 'Show'} $pane';
    final chord = windowShortcuts(
      platform,
    ).firstWhere((shortcut) => shortcut.command == command).chord;
    final keys = formatShortcutActivator(chord, platform);
    // view_sidebar draws its panel on the right: mirrored for the panel on
    // the reading direction's start.
    final leading = command == WindowCommand.toggleSidebar;
    final ltr = Directionality.of(context) == TextDirection.ltr;
    void toggle() => runWindowCommand(context, state, command);
    return Tooltip(
      message: keys == null ? label : '$label $keys',
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: toggle,
        child: InkWell(
          onTap: toggle,
          borderRadius: BorderRadius.circular(chrome.corner(6)),
          hoverColor: chrome.hoverFill,
          child: SizedBox(
            width: 30,
            height: 26,
            child: Transform.flip(
              flipX: leading == ltr,
              child: Icon(
                Icons.view_sidebar_outlined,
                size: 18,
                color: chrome.secondaryText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
