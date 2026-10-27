import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'server_appearance.dart';

/// What sits over the header's leading end: nothing while the server list
/// is under the traffic lights, or the traffic lights and the toolbar's
/// sidebar button once the list is hidden.
enum TitlebarControls { overSidebar, overHeader }

/// The wide layout's header on macOS, drawn under the window's unified
/// toolbar (`SeanceToolbar` in the runner): the window's title in the
/// terminal's column, with the traffic lights over the rail to its left
/// and the toolbar's native buttons over its trailing end.
///
/// The title is the active server's badge and label with `user@host` under
/// it, what a titlebar would otherwise say. It takes no clicks, so dragging
/// it moves the window and double-clicking it zooms, as a titlebar does.
class HeaderToolbar extends StatelessWidget {
  const HeaderToolbar({
    super.key,
    this.titlebarControls = TitlebarControls.overSidebar,
  });

  static const titleKey = ValueKey('header.title');
  static const subtitleKey = ValueKey('header.subtitle');

  /// The width the traffic lights and the sidebar button take at the
  /// window's leading edge, which the title keeps clear of when the list
  /// is hidden.
  static const double titlebarControlsWidth = 132;

  /// The room kept at the trailing end for the toolbar's buttons, so a long
  /// title ellipsizes before it runs under them.
  static const double toolbarItemsWidth = 220;

  final TitlebarControls titlebarControls;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context, seanceThemeStyle);
    final leading = switch (titlebarControls) {
      TitlebarControls.overSidebar => 12.0,
      TitlebarControls.overHeader => titlebarControlsWidth,
    };
    return Material(
      color: chrome.headerBackground,
      child: SizedBox(
        height: chrome.headerHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leading,
            end: toolbarItemsWidth,
          ),
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) => _HeaderTitle(state: state),
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
