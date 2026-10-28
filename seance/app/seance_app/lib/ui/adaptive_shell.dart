import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostPaneEdge, GhostResizeHandle;
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'header_toolbar.dart';
import 'macos_toolbar_band.dart';
import 'server_list_pane.dart';
import 'sidebar_panel.dart';
import 'terminal_pane.dart';

/// The adaptive layout. At and above [breakpoint] the server list, terminal, and
/// utility panel sit side by side as tiled, horizontally-resizable panes.
/// Below it they become screens the user moves between, with the utility panel
/// behind an end-drawer.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  static const double minimumTerminalWidth = 480;
  static const double minimumListWidth = 200;
  static const double defaultListWidth = 300;
  static const double maximumListWidth = 480;
  static const double minimumUtilityWidth = 260;
  static const double defaultUtilityWidth = 340;
  static const double maximumUtilityWidth = 680;

  /// The visible line between two panes: all the width the layout gives
  /// it, so the panes' own borders run into it.
  static const double seamWidth = 1;

  /// The drag target centred on a seam, floating over the panes' edges.
  static const double resizeHandleWidth = 10;
  static const double breakpoint =
      minimumListWidth +
      minimumTerminalWidth +
      minimumUtilityWidth +
      resizeHandleWidth * 2;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  // Narrow mode only: whether we're currently on the terminal screen.
  bool _viewingTerminal = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.services.settings;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return AdaptivePaneLayout(
          initialListWidth:
              settings.paneListWidth ?? AdaptiveShell.defaultListWidth,
          initialUtilityWidth:
              settings.paneUtilityWidth ?? AdaptiveShell.defaultUtilityWidth,
          onPaneWidthsChanged: (listWidth, utilityWidth) => unawaited(
            state.setPaneWidths(
              listWidth: listWidth,
              utilityWidth: utilityWidth,
            ),
          ),
          listPane: ServerListPane(
            posture: ServerListPosture.rail,
            onOpen: (s) => _open(state, s),
            onOpenLocal: () => _openLocal(state),
            // The rail starts level with the terminal's tab strip, under
            // the header and its rule.
            filterBarExtent: TerminalTabStrip.height,
          ),
          // The header and the list's top band carry the window's title
          // and toolbar on every platform.
          header: (list) => HeaderToolbar(sidebar: list),
          listHeader: const SidebarBand(),
          list: state.sidebarVisible
              ? PaneVisibility.shown
              : PaneVisibility.hidden,
          utility: state.inspectorVisible
              ? PaneVisibility.shown
              : PaneVisibility.hidden,
          terminalPane: const TerminalPane(
            showAppBar: false,
            showGenerateCommandInStrip: false,
          ),
          // The utility panel (Assistant + Snippets) is always available;
          // Snippets works without an LLM configured.
          utilityPane: const SidebarPanel(),
          narrowPane: _buildNarrow(state),
        );
      },
    );
  }

  Widget _buildNarrow(AppState state) {
    // activeServerId is the reserved local id for a local shell, so this guard
    // needs no local-specific branch — it only asks "is anything open".
    final showTerminal = _viewingTerminal && state.activeServerId != null;
    // The terminal is a state flag here, not a pushed route, so an unhandled
    // system back would reach the root route and go to the platform. On
    // Android that finishes the activity, and the engine and every live SSH
    // session die with it. While the terminal shows, back does what the app
    // bar's arrow does; on the list it stays the platform's.
    return PopScope(
      canPop: !showTerminal,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _backFromTerminal();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: showTerminal
            ? TerminalPane(
                key: const ValueKey('terminal'),
                showAssistantAffordance: true,
                onBack: () => setState(() => _viewingTerminal = false),
              )
            : ServerListPane(
                key: const ValueKey('list'),
                posture: ServerListPosture.home,
                onOpen: (s) => _open(state, s),
                onOpenLocal: () => _openLocal(state),
              ),
      ),
    );
  }

  void _backFromTerminal() {
    // A blocking PopScope outranks the route's local history, so an open
    // drawer would otherwise be skipped. Let the route close it first: the
    // imperative pop removes the history entry and leaves the route in place.
    if (ModalRoute.of(context)?.willHandlePopInternally ?? false) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _viewingTerminal = false);
  }

  Future<void> _open(AppState state, ServerConfig server) async {
    if (mounted) setState(() => _viewingTerminal = true);
    await state.openTerminal(server);
  }

  Future<void> _openLocal(AppState state) async {
    if (mounted) setState(() => _viewingTerminal = true);
    await state.openLocalShell();
  }
}

/// The line under the macOS header, across the terminal and utility panes.
const double _headerRuleHeight = 1;

/// The pane sizes that fit within one wide-layout constraint.
class AdaptivePaneWidths {
  const AdaptivePaneWidths({
    required this.list,
    required this.terminal,
    required this.utility,
  });

  final double list;
  final double terminal;
  final double utility;
}

/// Whether a side pane of the wide layout is on screen.
enum PaneVisibility { shown, hidden }

/// Allocates a wide layout while preserving a useful terminal. Returns `null`
/// when the narrow layout should be used instead. A [PaneVisibility.hidden]
/// pane takes no width (it reports zero), and no room is kept for it.
///
/// When both requested side panes do not fit, their space above their minimums
/// is reduced proportionally. This preserves the user's relative drag choices
/// without letting either side pane crowd out the terminal.
AdaptivePaneWidths? allocateAdaptivePaneWidths({
  required double availableWidth,
  required double requestedListWidth,
  required double requestedUtilityWidth,
  PaneVisibility list = PaneVisibility.shown,
  PaneVisibility utility = PaneVisibility.shown,
}) {
  final listShown = list == PaneVisibility.shown;
  final utilityShown = utility == PaneVisibility.shown;
  if (!listShown || !utilityShown) {
    return _allocateOneSide(
      availableWidth: availableWidth,
      requestedList: listShown ? requestedListWidth : null,
      requestedUtility: utilityShown ? requestedUtilityWidth : null,
    );
  }
  if (availableWidth < AdaptiveShell.breakpoint) return null;

  final requestedList = requestedListWidth
      .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
      .toDouble();
  final requestedUtility = requestedUtilityWidth
      .clamp(
        AdaptiveShell.minimumUtilityWidth,
        AdaptiveShell.maximumUtilityWidth,
      )
      .toDouble();
  final sidePaneBudget =
      availableWidth -
      AdaptiveShell.minimumTerminalWidth -
      AdaptiveShell.resizeHandleWidth * 2;
  final availableExtra =
      sidePaneBudget -
      AdaptiveShell.minimumListWidth -
      AdaptiveShell.minimumUtilityWidth;
  final listExtra = requestedList - AdaptiveShell.minimumListWidth;
  final utilityExtra = requestedUtility - AdaptiveShell.minimumUtilityWidth;
  final requestedExtra = listExtra + utilityExtra;

  late final double rawList;
  late final double rawUtility;
  if (requestedExtra <= availableExtra) {
    rawList = requestedList;
    rawUtility = requestedUtility;
  } else {
    final scale = availableExtra / requestedExtra;
    rawList = AdaptiveShell.minimumListWidth + listExtra * scale;
    rawUtility = AdaptiveShell.minimumUtilityWidth + utilityExtra * scale;
  }
  final listWidth = rawList
      .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
      .toDouble();
  final utilityWidth = rawUtility
      .clamp(
        AdaptiveShell.minimumUtilityWidth,
        AdaptiveShell.maximumUtilityWidth,
      )
      .toDouble();

  // The side panes are sized as if each handle took its full width, which
  // keeps the breakpoint and every pane width where they were. The seams
  // take one pixel each, and the terminal gets the rest: the handles'
  // overhang, [AdaptiveShell.resizeHandleWidth] less a seam per edge, lies
  // over its edges.
  return AdaptivePaneWidths(
    list: listWidth,
    terminal:
        availableWidth - listWidth - utilityWidth - AdaptiveShell.seamWidth * 2,
    utility: utilityWidth,
  );
}

/// [allocateAdaptivePaneWidths] with at most one side pane: the one whose
/// request is not null. The terminal keeps its minimum; the side pane gets
/// its request, clamped to its own bounds and to what the terminal leaves.
AdaptivePaneWidths? _allocateOneSide({
  required double availableWidth,
  double? requestedList,
  double? requestedUtility,
}) {
  final request = requestedList ?? requestedUtility;
  if (request == null) {
    if (availableWidth < AdaptiveShell.minimumTerminalWidth) return null;
    return AdaptivePaneWidths(list: 0, terminal: availableWidth, utility: 0);
  }
  final isList = requestedList != null;
  final minimum = isList
      ? AdaptiveShell.minimumListWidth
      : AdaptiveShell.minimumUtilityWidth;
  final maximum = isList
      ? AdaptiveShell.maximumListWidth
      : AdaptiveShell.maximumUtilityWidth;
  final room =
      availableWidth -
      AdaptiveShell.minimumTerminalWidth -
      AdaptiveShell.resizeHandleWidth;
  if (room < minimum) return null;
  final side = request
      .clamp(minimum, maximum < room ? maximum : room)
      .toDouble();
  final terminal = availableWidth - side - AdaptiveShell.seamWidth;
  return isList
      ? AdaptivePaneWidths(list: side, terminal: terminal, utility: 0)
      : AdaptivePaneWidths(list: 0, terminal: terminal, utility: side);
}

/// Constraint-aware tiled panes used by [AdaptiveShell]. Kept independent of
/// app state so allocation and drag behavior can be exercised in widget tests.
class AdaptivePaneLayout extends StatefulWidget {
  const AdaptivePaneLayout({
    super.key,
    required this.listPane,
    required this.terminalPane,
    required this.utilityPane,
    required this.narrowPane,
    this.header,
    this.listHeader,
    this.list = PaneVisibility.shown,
    this.utility = PaneVisibility.shown,
    this.initialListWidth = AdaptiveShell.defaultListWidth,
    this.initialUtilityWidth = AdaptiveShell.defaultUtilityWidth,
    this.onPaneWidthsChanged,
  });

  final Widget listPane;
  final Widget terminalPane;
  final Widget utilityPane;
  final Widget narrowPane;

  /// Builds the header ([HeaderToolbar]) for the list's visibility this
  /// frame, or null for no header. When set, it spans the terminal and
  /// utility panes the way Poltergeist's spans its panes and inspector; the
  /// list pane stays full height and starts below [listHeader] and the
  /// header's rule, where the traffic lights sit on macOS, and the layout
  /// takes the macOS toolbar band back from the app's reservation
  /// ([ClaimMacosToolbarBand]).
  final Widget Function(PaneVisibility list)? header;

  /// What the list's top shows, level with the header ([SidebarBand]):
  /// laid out at the header's height, and only while there is a header.
  final Widget? listHeader;

  /// Whether the server list and the utility panel show (the sidebar and
  /// inspector buttons, or their shortcuts).
  final PaneVisibility list;
  final PaneVisibility utility;

  /// Requested pane widths to start from (the persisted values, on real
  /// launches). The widget owns them once mounted; later changes to these
  /// fields do not reset a live layout.
  final double initialListWidth;
  final double initialUtilityWidth;

  /// Fired when a resize drag ends, with the user's *requested* widths — the
  /// values worth persisting (rendered widths are just these, clamped to the
  /// current window).
  final void Function(double listWidth, double utilityWidth)?
  onPaneWidthsChanged;

  static const listPaneKey = ValueKey('adaptive-list-pane');
  static const terminalPaneKey = ValueKey('adaptive-terminal-pane');
  static const utilityPaneKey = ValueKey('adaptive-utility-pane');
  static const narrowPaneKey = ValueKey('adaptive-narrow-pane');
  static const listResizeHandleKey = ValueKey('adaptive-list-resize-handle');
  static const utilityResizeHandleKey = ValueKey(
    'adaptive-utility-resize-handle',
  );

  @override
  State<AdaptivePaneLayout> createState() => _AdaptivePaneLayoutState();
}

class _AdaptivePaneLayoutState extends State<AdaptivePaneLayout> {
  late double _requestedListWidth = widget.initialListWidth;
  late double _requestedUtilityWidth = widget.initialUtilityWidth;
  double? _temporaryListWidth;
  double? _temporaryUtilityWidth;

  AdaptivePaneWidths? _allocate(double availableWidth) =>
      allocateAdaptivePaneWidths(
        availableWidth: availableWidth,
        requestedListWidth: _temporaryListWidth ?? _requestedListWidth,
        requestedUtilityWidth: _temporaryUtilityWidth ?? _requestedUtilityWidth,
        list: widget.list,
        utility: widget.utility,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = _allocate(constraints.maxWidth);
        if (widths == null) {
          return KeyedSubtree(
            key: AdaptivePaneLayout.narrowPaneKey,
            child: widget.narrowPane,
          );
        }
        AdaptivePaneWidths currentWidths() =>
            _allocate(constraints.maxWidth) ?? widths;
        final listShown = widget.list == PaneVisibility.shown;
        final utilityShown = widget.utility == PaneVisibility.shown;

        final header = widget.header?.call(widget.list);
        final terminal = SizedBox(
          key: AdaptivePaneLayout.terminalPaneKey,
          child: widget.terminalPane,
        );
        // Hidden panes leave empty slots rather than a different tree: the
        // terminal and its neighbours keep their places, so hiding the
        // sidebar or the inspector keeps the terminal's state (its scroll
        // position, an open find bar) instead of rebuilding it.
        const empty = SizedBox.shrink();
        final utilityHandle = utilityShown
            ? GhostResizeHandle(
                key: AdaptivePaneLayout.utilityResizeHandleKey,
                label: 'Resize utility panel',
                width: widths.utility,
                minimumWidth: AdaptiveShell.minimumUtilityWidth,
                maximumWidth: _maximumUtilityWidth(widths),
                edge: GhostPaneEdge.trailing,
                widthAfterStep: (delta) => _widthAfterStep(
                  GhostPaneEdge.trailing,
                  currentWidths(),
                  constraints.maxWidth,
                  delta,
                ),
                onStep: (delta) =>
                    _stepPane(GhostPaneEdge.trailing, currentWidths(), delta),
                onStart: () => _startUtilityResize(currentWidths()),
                onDelta: _resizeUtility,
                onEnd: _endUtilityResize,
                handleWidth: AdaptiveShell.resizeHandleWidth,
                valueText: _pixels,
              )
            : empty;
        // The terminal, its seam and the utility pane, with the utility
        // handle floated over that seam.
        final panes = _straddle(
          Row(
            children: [
              Expanded(child: terminal),
              if (utilityShown) const _Seam() else empty,
              if (utilityShown)
                SizedBox(
                  key: AdaptivePaneLayout.utilityPaneKey,
                  width: widths.utility,
                  child: widget.utilityPane,
                )
              else
                empty,
            ],
          ),
          handle: utilityHandle,
          end: widths.utility,
        );

        final chrome = SeanceChrome.of(context, seanceThemeStyle);
        // Under a header: the header and its rule over the panes. The
        // header takes the status bar's inset on a tablet, so the panes
        // below it keep none.
        final content = header == null
            ? panes
            : Column(
                children: [
                  _UnderStatusBar(
                    color: chrome.headerBackground,
                    child: header,
                  ),
                  Divider(
                    height: _headerRuleHeight,
                    thickness: _headerRuleHeight,
                    color: chrome.separator,
                  ),
                  Expanded(child: _BelowHeader(child: panes)),
                ],
              );

        Widget listHandle = listShown
            ? GhostResizeHandle(
                key: AdaptivePaneLayout.listResizeHandleKey,
                label: 'Resize server list',
                width: widths.list,
                minimumWidth: AdaptiveShell.minimumListWidth,
                maximumWidth: _maximumListWidth(widths),
                edge: GhostPaneEdge.leading,
                widthAfterStep: (delta) => _widthAfterStep(
                  GhostPaneEdge.leading,
                  currentWidths(),
                  constraints.maxWidth,
                  delta,
                ),
                onStep: (delta) =>
                    _stepPane(GhostPaneEdge.leading, currentWidths(), delta),
                onStart: () => _startListResize(currentWidths()),
                onDelta: _resizeList,
                onEnd: _endListResize,
                handleWidth: AdaptiveShell.resizeHandleWidth,
                valueText: _pixels,
              )
            : empty;
        // The list handle runs the full height, so its top lies inside the
        // band, where AppKit would take a drag on it for the window's.
        if (listShown &&
            header != null &&
            MacosToolbarBandScope.unifiedToolbarOf(context)) {
          listHandle = MacosToolbarPassthrough(child: listHandle);
        }
        final Widget list;
        if (!listShown) {
          list = empty;
        } else if (header == null) {
          list = SizedBox(
            key: AdaptivePaneLayout.listPaneKey,
            width: widths.list,
            child: widget.listPane,
          );
        } else {
          list = SizedBox(
            key: AdaptivePaneLayout.listPaneKey,
            width: widths.list,
            // On macOS the traffic lights sit over the list's top, which
            // drags the window natively: Finder's layout, and Poltergeist's.
            child: ColoredBox(
              color: chrome.sidebarBackground,
              child: Column(
                children: [
                  // The list's band level with the header, and the
                  // header's rule, so the list starts where the tab strip
                  // does and its filter field lines up with the tabs.
                  _UnderStatusBar(
                    color: chrome.sidebarBackground,
                    child: SizedBox(
                      height: chrome.headerHeight,
                      child: widget.listHeader,
                    ),
                  ),
                  const SizedBox(height: _headerRuleHeight),
                  Expanded(child: _BelowHeader(child: widget.listPane)),
                ],
              ),
            ),
          );
        }
        final body = _straddle(
          Row(
            children: [
              list,
              if (listShown) const _Seam() else empty,
              Expanded(child: content),
            ],
          ),
          handle: listHandle,
          start: widths.list,
        );
        return header == null
            ? Scaffold(body: body)
            : ClaimMacosToolbarBand(child: Scaffold(body: body));
      },
    );
  }

  /// [row] with [handle] floated over the seam that follows [start] logical
  /// pixels of it, or precedes the last [end]. Only the one-pixel seam takes
  /// layout width, so the panes' borders meet it; the drag target overhangs
  /// both panes by the same amount instead of pushing them apart.
  Widget _straddle(
    Widget row, {
    required Widget handle,
    double? start,
    double? end,
  }) {
    const overhang =
        (AdaptiveShell.resizeHandleWidth - AdaptiveShell.seamWidth) / 2;
    return Stack(
      children: [
        Positioned.fill(child: row),
        PositionedDirectional(
          top: 0,
          bottom: 0,
          start: start == null ? null : start - overhang,
          end: end == null ? null : end - overhang,
          width: AdaptiveShell.resizeHandleWidth,
          child: handle,
        ),
      ],
    );
  }

  double? _listDragStart;
  double _listDragDelta = 0;
  double _listDragMaximum = AdaptiveShell.maximumListWidth;

  double? _utilityDragStart;
  double _utilityDragDelta = 0;
  double _utilityDragMaximum = AdaptiveShell.maximumUtilityWidth;

  /// Read bounds with each event, not from the handle's last frame: an
  /// immediate reversal after leaving a bound must not see the old width.
  void _stepPane(GhostPaneEdge edge, AdaptivePaneWidths widths, double delta) {
    final leading = edge == GhostPaneEdge.leading;
    final growing = (leading ? delta : -delta) > 0;
    final width = leading ? widths.list : widths.utility;
    final minimum = leading
        ? AdaptiveShell.minimumListWidth
        : AdaptiveShell.minimumUtilityWidth;
    final maximum = leading
        ? _maximumListWidth(widths)
        : _maximumUtilityWidth(widths);
    if ((growing && width >= maximum) || (!growing && width <= minimum)) {
      return;
    }
    if (leading) {
      _startListResize(widths);
      _resizeList(delta);
      _endListResize();
    } else {
      _startUtilityResize(widths);
      _resizeUtility(delta);
      _endUtilityResize();
    }
  }

  /// A completed step releases the temporary sibling constraint just like
  /// a finished drag. Announce the resulting allocation, which may differ
  /// from the raw delta while the window clamps both requested widths.
  double _widthAfterStep(
    GhostPaneEdge edge,
    AdaptivePaneWidths widths,
    double availableWidth,
    double delta,
  ) {
    final leading = edge == GhostPaneEdge.leading;
    final requested = leading
        ? (widths.list + delta).clamp(
            AdaptiveShell.minimumListWidth,
            _maximumListWidth(widths),
          )
        : (widths.utility + delta).clamp(
            AdaptiveShell.minimumUtilityWidth,
            _maximumUtilityWidth(widths),
          );
    final next = allocateAdaptivePaneWidths(
      availableWidth: availableWidth,
      requestedListWidth: leading ? requested : _requestedListWidth,
      requestedUtilityWidth: leading ? _requestedUtilityWidth : requested,
      list: widget.list,
      utility: widget.utility,
    );
    if (next == null) return leading ? widths.list : widths.utility;
    return leading ? next.list : next.utility;
  }

  double _maximumListWidth(AdaptivePaneWidths widths) =>
      (widths.list + widths.terminal - AdaptiveShell.minimumTerminalWidth)
          .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
          .toDouble();

  double _maximumUtilityWidth(AdaptivePaneWidths widths) =>
      (widths.utility + widths.terminal - AdaptiveShell.minimumTerminalWidth)
          .clamp(
            AdaptiveShell.minimumUtilityWidth,
            AdaptiveShell.maximumUtilityWidth,
          )
          .toDouble();

  void _startListResize(AdaptivePaneWidths widths) {
    // A window shrink clamps rendered widths without replacing the user's
    // requests. Starting a drag intentionally adopts the rendered widths so
    // the handle does not jump back toward those stale requests.
    _listDragStart = widths.list;
    _listDragDelta = 0;
    _listDragMaximum = _maximumListWidth(widths);
    setState(() {
      _requestedListWidth = widths.list;
      _temporaryUtilityWidth = widths.utility;
    });
  }

  void _resizeList(double dx) {
    final dragStart = _listDragStart;
    if (dragStart == null) return;
    _listDragDelta += dx;
    setState(() {
      _requestedListWidth = (dragStart + _listDragDelta)
          .clamp(AdaptiveShell.minimumListWidth, _listDragMaximum)
          .toDouble();
    });
  }

  void _startUtilityResize(AdaptivePaneWidths widths) {
    // See _startListResize: interaction starts from what the user can see.
    _utilityDragStart = widths.utility;
    _utilityDragDelta = 0;
    _utilityDragMaximum = _maximumUtilityWidth(widths);
    setState(() {
      _temporaryListWidth = widths.list;
      _requestedUtilityWidth = widths.utility;
    });
  }

  void _resizeUtility(double dx) {
    final dragStart = _utilityDragStart;
    if (dragStart == null) return;
    _utilityDragDelta -= dx;
    setState(() {
      _requestedUtilityWidth = (dragStart + _utilityDragDelta)
          .clamp(AdaptiveShell.minimumUtilityWidth, _utilityDragMaximum)
          .toDouble();
    });
  }

  void _endListResize() {
    setState(() {
      _listDragStart = null;
      _temporaryUtilityWidth = null;
    });
    widget.onPaneWidthsChanged?.call(
      _requestedListWidth,
      _requestedUtilityWidth,
    );
  }

  void _endUtilityResize() {
    setState(() {
      _utilityDragStart = null;
      _temporaryListWidth = null;
    });
    widget.onPaneWidthsChanged?.call(
      _requestedListWidth,
      _requestedUtilityWidth,
    );
  }
}

/// The owned pane's position in the direction-aware row.
/// The one-pixel line between two panes (see [AdaptiveShell.seamWidth]).
class _Seam extends StatelessWidget {
  const _Seam();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: AdaptiveShell.seamWidth,
    // A childless ColoredBox takes the smallest size it may, and a Row
    // leaves the height loose: ask for all of it.
    height: double.infinity,
    child: ColoredBox(color: Theme.of(context).dividerColor),
  );
}

String _pixels(double width) => '${width.round()} pixels';

/// [child] below the status bar's inset, its [color] drawn behind the bar,
/// as an app bar's is: a tablet's header and the list's band. Zero on the
/// desktop, and on macOS, whose toolbar band the layout claimed back. The
/// inset is consumed here, so nothing inside keeps it a second time.
class _UnderStatusBar extends StatelessWidget {
  const _UnderStatusBar({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color,
    child: Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: child,
      ),
    ),
  );
}

/// [child] with no top inset left to keep: the header above it took it.
class _BelowHeader extends StatelessWidget {
  const _BelowHeader({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      MediaQuery.removePadding(context: context, removeTop: true, child: child);
}
