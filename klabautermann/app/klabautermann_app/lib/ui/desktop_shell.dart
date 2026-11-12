import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:ghost_desktop/ghost_desktop.dart'
    show
        ClaimMacosToolbarBand,
        MacosToolbarBandScope,
        macosToolbarBandHeight,
        macosTrafficLightsInset;
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart'
    show GhostPaneEdge, GhostResizeHandle, formatShortcutActivator;
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../controllers/window_panes.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show klabautermannThemeStyle;
import 'coverage.dart';
import 'docker/container_details.dart';
import 'docker/container_logs.dart';
import 'fleet_rail.dart';
import 'inspector_pane.dart';
import 'server_workspace.dart';
import 'sidebar_kit.dart' show SidebarThemeTokens;
import 'window_pane_actions.dart';
import 'workspace_dock.dart';
import 'workspace_navigation.dart';

/// The desktop three-pane shell of 03 §10.2, shown at widths of 960 px
/// and up: fleet rail, server workspace, inspector. It holds the
/// container the inspector shows, which the workspace's Containers
/// sub-tab opens ([ContainerInspectionScope]), and the container whose
/// logs the Docker tab shows, which the inspector or a row opens
/// ([ContainerLogsScope]), and the workspace's bottom dock (OV-10,
/// [WorkspaceDockScope]).
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.coverage,
    required this.onOpenSettings,
    this.onAddServer,
    this.sync,
    this.navigation,
    required this.panes,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Heads the workspace with the first-run card (03 §9.5 item 1).
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;
  final SyncController? sync;

  /// Whether the rail and the inspector show: the composition root keeps
  /// them in settings.json, the shell in memory otherwise.
  final WindowPanesController panes;

  /// Where the command palette sends the workspace: its tabs follow the
  /// requests and the inspector takes the containers.
  final WorkspaceNavigation? navigation;

  /// The rail's width until the user resizes it, and its bounds: a
  /// missing or unreadable stored width falls back to the default; the
  /// kit's rows keep their own insets. The default is also the least
  /// width, since the rail's rows were laid out for it: a pane can be
  /// widened, as in Séance and Poltergeist, but a narrow window keeps the
  /// layout it had before panes could be resized.
  static const double railWidth = WindowPanesController.defaultSidebarWidth;
  static const double minimumRailWidth = railWidth;
  static const double maximumRailWidth = 480;

  /// The inspector's width until the user resizes it, and its bounds
  /// (Séance's utility panel's maximum), read as the rail's are.
  static const double inspectorWidth =
      WindowPanesController.defaultInspectorWidth;
  static const double minimumInspectorWidth = inspectorWidth;
  static const double maximumInspectorWidth = 680;

  /// The workspace's least width: the panes' rendered widths are shrunk
  /// toward their minimums to leave it (Séance's terminal's rule).
  static const double minimumWorkspaceWidth = 480;

  /// The visible line between two panes.
  static const double seamWidth = 1;

  /// The drag target centred on a seam, floating over the panes' edges.
  static const double resizeHandleWidth = 10;

  /// The rail seam's resize handle, showing while the rail does.
  static const sidebarResizeHandleKey = ValueKey('shell.sidebarResize');

  /// The inspector seam's resize handle, showing while the inspector does.
  static const inspectorResizeHandleKey = ValueKey('shell.inspectorResize');

  /// The sidebar toggle, in the rail's band while it shows and leading
  /// the header while it is hidden.
  static const sidebarToggleKey = ValueKey('shell.sidebarToggle');

  /// The inspector toggle, ending the header.
  static const inspectorToggleKey = ValueKey('shell.inspectorToggle');

  /// The selected server's name in the header band.
  static const serverTitleKey = ValueKey('shell.serverTitle');

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  /// The inspector's container, which belongs to the selected server: a
  /// selection of another lets it go.
  final _inspection = ValueNotifier<InspectedContainer?>(null);

  /// The container whose logs the Docker tab shows, which belongs to the
  /// selected server too.
  final _logs = ValueNotifier<InspectedContainer?>(null);

  /// The workspace's dock, whose items outlive a change of server.
  final _dock = WorkspaceDock();

  /// The live widths while a seam is dragged — the pane's own, and its
  /// sibling's frozen at the rendered width so a growing pane does not
  /// re-scale it mid-drag. Both start from the widths rendered at the
  /// gesture's start, so a width the window clamped does not jump back
  /// to its stale stored request (Séance's drag model).
  double? _railWidthOverride;
  double? _inspectorWidthOverride;

  double? _railDragStart, _inspectorDragStart;
  double _railDragDelta = 0, _inspectorDragDelta = 0;
  double _railDragMaximum = DesktopShell.maximumRailWidth;
  double _inspectorDragMaximum = DesktopShell.maximumInspectorWidth;

  @override
  void initState() {
    super.initState();
    widget.fleet.addListener(_onFleetChanged);
    widget.navigation?.addListener(_onNavigation);
    _inspection.addListener(_revealInspection);
  }

  @override
  void didUpdateWidget(DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navigation != oldWidget.navigation) {
      oldWidget.navigation?.removeListener(_onNavigation);
      widget.navigation?.addListener(_onNavigation);
    }
    if (widget.fleet == oldWidget.fleet) return;
    oldWidget.fleet.removeListener(_onFleetChanged);
    widget.fleet.addListener(_onFleetChanged);
    _onFleetChanged();
  }

  @override
  void dispose() {
    widget.navigation?.removeListener(_onNavigation);
    widget.fleet.removeListener(_onFleetChanged);
    _inspection.dispose();
    _logs.dispose();
    _dock.dispose();
    super.dispose();
  }

  /// A container the palette picked goes to the inspector; the selection
  /// that came with it has already let the previous one go.
  void _onNavigation() {
    if (widget.navigation?.takeContainer() case final container?) {
      _inspection.value = container;
    }
  }

  void _revealInspection() {
    if (!mounted || _inspection.value == null || widget.panes.inspectorShown) {
      return;
    }
    unawaited(toggleWindowPane(context, widget.panes, WindowPane.inspector));
  }

  /// [child] under the palette's navigation, which the workspace's tabs
  /// follow; as is without one.
  Widget _withNavigation(Widget child) => switch (widget.navigation) {
    final navigation? => WorkspaceNavigationScope(
      navigation: navigation,
      child: child,
    ),
    null => child,
  };

  void _onFleetChanged() {
    final selected = widget.fleet.selectedServer?.id;
    for (final shown in [_inspection, _logs]) {
      final container = shown.value;
      if (container != null && container.serverId != selected) {
        shown.value = null;
      }
    }
    // A server that left the fleet takes its dock items, shells included.
    final known = {for (final server in widget.fleet.servers) server.id};
    for (final serverId in {for (final item in _dock.items) item.serverId}) {
      if (!known.contains(serverId)) _dock.forgetServer(serverId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClaimMacosToolbarBand(
      // Under the macOS unified titlebar the header and the rail's band
      // draw in the band at the window's top, where AppKit takes every
      // click for window drag unless a passthrough view hands it back.
      child: _passthroughScope(
        Scaffold(
          body: SafeArea(
            top: false,
            // The context under the SafeArea: its MediaQuery has the side
            // and bottom insets consumed and the Scaffold's keyboard inset
            // removed. DesktopShell's own context would bring them back.
            child: Builder(
              builder: (context) {
                // The remaining top inset: a tablet's status bar (the
                // macOS band is already claimed). The bands paint up
                // through it and start their controls below.
                final top = MediaQuery.paddingOf(context).top;
                return MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: _withNavigation(
                    ContainerInspectionScope(
                      inspection: _inspection,
                      child: ContainerLogsScope(
                        logs: _logs,
                        child: WorkspaceDockScope(
                          dock: _dock,
                          child: _panes(context, top),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The three columns: [rail band and rail] | [header over workspace and
  /// inspector], a hidden pane leaving the column and its divider to the
  /// workspace. Each shown pane's seam carries a [GhostResizeHandle] that
  /// floats over it rather than taking layout width (Séance's rule):
  /// pointer drags and arrow-key steps resize the pane, and a finished
  /// gesture writes its width through [WindowPanesController].
  Widget _panes(BuildContext context, double top) {
    final fleet = widget.fleet;
    final monitoring = widget.monitoring;
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.panes, fleet]),
      builder: (context, _) {
        final sidebar = widget.panes.sidebarShown;
        final inspector = widget.panes.inspectorShown;
        return LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxWidth;
            ShellPaneWidths widths() => allocateShellPaneWidths(
              availableWidth: available,
              requestedRailWidth:
                  _railWidthOverride ?? widget.panes.sidebarWidth,
              requestedInspectorWidth:
                  _inspectorWidthOverride ?? widget.panes.inspectorWidth,
              railShown: sidebar,
              inspectorShown: inspector,
            );
            final allocated = widths();
            final workspace = Expanded(
              child: CoverageHeader(
                placement: CoveragePlacement.desktopWorkspace,
                coverage: widget.coverage,
                fleet: fleet,
                child: ServerWorkspace(
                  fleet: fleet,
                  monitoring: monitoring,
                  // The header names the selected server.
                  showTitle: false,
                ),
              ),
            );
            // The inspector seam lives inside this row, so its handle
            // floats over the row below the band rather than the whole
            // shell (Séance's inner `_straddle`).
            final lower = inspector
                ? _straddle(
                    Row(
                      children: [
                        workspace,
                        _Seam(color: colors.outlineVariant),
                        SizedBox(
                          width: allocated.inspector,
                          child: ColoredBox(
                            color: colors.surfaceContainerLow,
                            child: InspectorPane(
                              fleet: fleet,
                              monitoring: monitoring,
                            ),
                          ),
                        ),
                      ],
                    ),
                    handle: _resizeHandle(
                      GhostPaneEdge.trailing,
                      widths,
                      available,
                      l10n,
                    ),
                    end: allocated.inspector,
                  )
                : Row(children: [workspace]);
            final row = Row(
              children: [
                if (sidebar) ...[
                  SizedBox(
                    width: allocated.rail,
                    child: ColoredBox(
                      color: SidebarThemeTokens.of(context).sidebarBackground,
                      child: Column(
                        children: [
                          _Band(
                            top: top,
                            child: Padding(
                              padding: EdgeInsetsDirectional.only(
                                start: _leadingInset(context),
                              ),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: _clickable(
                                  context,
                                  _PaneToggle(
                                    key: DesktopShell.sidebarToggleKey,
                                    pane: WindowPane.sidebar,
                                    shown: sidebar,
                                    onToggle: () => unawaited(
                                      toggleWindowPane(
                                        context,
                                        widget.panes,
                                        WindowPane.sidebar,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Divider(height: 1, color: colors.outlineVariant),
                          Expanded(
                            child: FleetRail(
                              fleet: fleet,
                              monitoring: monitoring,
                              onOpenSettings: widget.onOpenSettings,
                              onAddServer: widget.onAddServer,
                              sync: widget.sync,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _Seam(color: colors.outlineVariant),
                ],
                Expanded(
                  child: Column(
                    children: [
                      _Band(
                        top: top,
                        child: Padding(
                          padding: EdgeInsetsDirectional.only(
                            start: sidebar ? 8 : _leadingInset(context),
                            end: 8,
                          ),
                          child: Row(
                            children: [
                              if (!sidebar) ...[
                                _clickable(
                                  context,
                                  _PaneToggle(
                                    key: DesktopShell.sidebarToggleKey,
                                    pane: WindowPane.sidebar,
                                    shown: sidebar,
                                    onToggle: () => unawaited(
                                      toggleWindowPane(
                                        context,
                                        widget.panes,
                                        WindowPane.sidebar,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: switch (fleet.selectedServer) {
                                  final server? => Text(
                                    key: DesktopShell.serverTitleKey,
                                    server.displayName,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  null => const SizedBox.shrink(),
                                },
                              ),
                              const SizedBox(width: 8),
                              _clickable(
                                context,
                                _PaneToggle(
                                  key: DesktopShell.inspectorToggleKey,
                                  pane: WindowPane.inspector,
                                  shown: inspector,
                                  onToggle: () => unawaited(
                                    toggleWindowPane(
                                      context,
                                      widget.panes,
                                      WindowPane.inspector,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Divider(height: 1, color: colors.outlineVariant),
                      Expanded(child: lower),
                    ],
                  ),
                ),
              ],
            );
            return sidebar
                ? _straddle(
                    row,
                    // The seam's top lies in the macOS band, which hands
                    // its clicks back through the passthrough.
                    handle: _clickable(
                      context,
                      _resizeHandle(
                        GhostPaneEdge.leading,
                        widths,
                        available,
                        l10n,
                      ),
                    ),
                    start: allocated.rail,
                  )
                : row;
          },
        );
      },
    );
  }

  /// [row] with [handle] floated over the seam that follows [start]
  /// logical pixels of it, or precedes its last [end] (Séance's
  /// `_straddle`): only the one-pixel seam takes layout width, so the
  /// panes' borders meet it while the drag target overhangs both panes
  /// by the same amount. Hit-testing reaches the whole target because
  /// the floated handle is a sibling above [row], not a child inside
  /// the seam's own box.
  Widget _straddle(
    Widget row, {
    required Widget handle,
    double? start,
    double? end,
  }) {
    const overhang =
        (DesktopShell.resizeHandleWidth - DesktopShell.seamWidth) / 2;
    return Stack(
      children: [
        Positioned.fill(child: row),
        PositionedDirectional(
          top: 0,
          bottom: 0,
          start: start == null ? null : start - overhang,
          end: end == null ? null : end - overhang,
          width: DesktopShell.resizeHandleWidth,
          child: handle,
        ),
      ],
    );
  }

  /// A pane seam's drag and keyboard target, parametrized by [edge]: the
  /// rail's leading edge grows toward the workspace, the inspector's
  /// trailing edge toward it. The announced bounds are the rendered
  /// allocation's, so they follow the window, not the stored request.
  GhostResizeHandle _resizeHandle(
    GhostPaneEdge edge,
    ShellPaneWidths Function() currentWidths,
    double availableWidth,
    AppLocalizations l10n,
  ) {
    final leading = edge == GhostPaneEdge.leading;
    final widths = currentWidths();
    return GhostResizeHandle(
      key: leading
          ? DesktopShell.sidebarResizeHandleKey
          : DesktopShell.inspectorResizeHandleKey,
      label: leading ? l10n.sidebarResize : l10n.inspectorResize,
      // Tap-to-focus competes with dragging; retain movement before the
      // drag wins the arena, as the previous pane handles did.
      dragStartBehavior: DragStartBehavior.down,
      width: leading ? widths.rail : widths.inspector,
      minimumWidth: leading
          ? DesktopShell.minimumRailWidth
          : DesktopShell.minimumInspectorWidth,
      maximumWidth: leading
          ? _maximumRailWidth(widths)
          : _maximumInspectorWidth(widths),
      edge: edge,
      widthAfterStep: (delta) =>
          _widthAfterStep(edge, currentWidths(), availableWidth, delta),
      onStep: (delta) => _stepPane(edge, currentWidths(), delta),
      onStart: () => leading
          ? _startRailResize(currentWidths())
          : _startInspectorResize(currentWidths()),
      onDelta: leading ? _resizeRail : _resizeInspector,
      onEnd: leading ? _endRailResize : _endInspectorResize,
      handleWidth: DesktopShell.resizeHandleWidth,
      valueText: (width) => l10n.paneWidthPixels(width.round()),
    );
  }

  /// How wide [widths] lets the rail grow: its rendered width plus the
  /// workspace's spare down to the workspace's minimum, within the rail's
  /// own bounds.
  double _maximumRailWidth(ShellPaneWidths widths) =>
      (widths.rail + widths.workspace - DesktopShell.minimumWorkspaceWidth)
          .clamp(DesktopShell.minimumRailWidth, DesktopShell.maximumRailWidth)
          .toDouble();

  /// [_maximumRailWidth]'s counterpart for the inspector.
  double _maximumInspectorWidth(ShellPaneWidths widths) =>
      (widths.inspector + widths.workspace - DesktopShell.minimumWorkspaceWidth)
          .clamp(
            DesktopShell.minimumInspectorWidth,
            DesktopShell.maximumInspectorWidth,
          )
          .toDouble();

  /// A keyboard or assistive step, which is a whole drag in one event:
  /// start, one move of [delta] in the physical arrow direction, end. Its
  /// bounds are read off the live allocation, so a step from a width the
  /// window clamped behaves like a drag's (Séance's `_stepPane`).
  void _stepPane(GhostPaneEdge edge, ShellPaneWidths widths, double delta) {
    final leading = edge == GhostPaneEdge.leading;
    final growing = (leading ? delta : -delta) > 0;
    final width = leading ? widths.rail : widths.inspector;
    final minimum = leading
        ? DesktopShell.minimumRailWidth
        : DesktopShell.minimumInspectorWidth;
    final maximum = leading
        ? _maximumRailWidth(widths)
        : _maximumInspectorWidth(widths);
    if ((growing && width >= maximum) || (!growing && width <= minimum)) {
      return;
    }
    if (leading) {
      _startRailResize(widths);
      _resizeRail(delta);
      _endRailResize();
    } else {
      _startInspectorResize(widths);
      _resizeInspector(delta);
      _endInspectorResize();
    }
  }

  /// The width an assistive increase or decrease of [delta] would leave,
  /// re-allocated against the window, which is what the handle announces
  /// (Séance's `_widthAfterStep`).
  double _widthAfterStep(
    GhostPaneEdge edge,
    ShellPaneWidths widths,
    double availableWidth,
    double delta,
  ) {
    final leading = edge == GhostPaneEdge.leading;
    final requested = leading
        ? (widths.rail + delta).clamp(
            DesktopShell.minimumRailWidth,
            _maximumRailWidth(widths),
          )
        : (widths.inspector + delta).clamp(
            DesktopShell.minimumInspectorWidth,
            _maximumInspectorWidth(widths),
          );
    final next = allocateShellPaneWidths(
      availableWidth: availableWidth,
      requestedRailWidth: leading
          ? requested
          : _railWidthOverride ?? widget.panes.sidebarWidth,
      requestedInspectorWidth: leading
          ? _inspectorWidthOverride ?? widget.panes.inspectorWidth
          : requested,
      railShown: widget.panes.sidebarShown,
      inspectorShown: widget.panes.inspectorShown,
    );
    return leading ? next.rail : next.inspector;
  }

  void _startRailResize(ShellPaneWidths widths) {
    _railDragStart = widths.rail;
    _railDragDelta = 0;
    _railDragMaximum = _maximumRailWidth(widths);
    setState(() {
      _railWidthOverride = widths.rail;
      _inspectorWidthOverride = widths.inspector;
    });
  }

  void _resizeRail(double dx) {
    final dragStart = _railDragStart;
    if (dragStart == null) return;
    _railDragDelta += dx;
    setState(() {
      _railWidthOverride = (dragStart + _railDragDelta)
          .clamp(DesktopShell.minimumRailWidth, _railDragMaximum)
          .toDouble();
    });
  }

  void _startInspectorResize(ShellPaneWidths widths) {
    _inspectorDragStart = widths.inspector;
    _inspectorDragDelta = 0;
    _inspectorDragMaximum = _maximumInspectorWidth(widths);
    setState(() {
      _railWidthOverride = widths.rail;
      _inspectorWidthOverride = widths.inspector;
    });
  }

  void _resizeInspector(double dx) {
    final dragStart = _inspectorDragStart;
    if (dragStart == null) return;
    // The inspector grows as the pointer travels toward the leading edge.
    _inspectorDragDelta -= dx;
    setState(() {
      _inspectorWidthOverride = (dragStart + _inspectorDragDelta)
          .clamp(DesktopShell.minimumInspectorWidth, _inspectorDragMaximum)
          .toDouble();
    });
  }

  void _endRailResize() {
    final committed = _railWidthOverride;
    if (committed != null) {
      unawaited(
        setWindowPaneWidth(
          context,
          widget.panes,
          WindowPane.sidebar,
          committed,
        ),
      );
    }
    setState(() {
      _railDragStart = null;
      _railWidthOverride = null;
      _inspectorWidthOverride = null;
    });
  }

  void _endInspectorResize() {
    final committed = _inspectorWidthOverride;
    if (committed != null) {
      unawaited(
        setWindowPaneWidth(
          context,
          widget.panes,
          WindowPane.inspector,
          committed,
        ),
      );
    }
    setState(() {
      _inspectorDragStart = null;
      _railWidthOverride = null;
      _inspectorWidthOverride = null;
    });
  }
}

/// The widths [allocateShellPaneWidths] gives the desktop shell's
/// columns for one window width.
final class ShellPaneWidths {
  const ShellPaneWidths({
    required this.rail,
    required this.workspace,
    required this.inspector,
  });

  /// The fleet rail's rendered width; zero while it is hidden.
  final double rail;

  /// The workspace's rendered width.
  final double workspace;

  /// The inspector's rendered width; zero while it is hidden.
  final double inspector;
}

/// Allocates the desktop shell's columns for [availableWidth] (Séance's
/// `allocateAdaptivePaneWidths`): each shown side pane takes its request
/// clamped to its own bounds, and when both requests would leave the
/// workspace under its minimum their room above the minimums shrinks
/// proportionally — which keeps a stored width the window cannot fit,
/// ready to render again when the window can.
ShellPaneWidths allocateShellPaneWidths({
  required double availableWidth,
  required double requestedRailWidth,
  required double requestedInspectorWidth,
  bool railShown = true,
  bool inspectorShown = true,
}) {
  const minWorkspace = DesktopShell.minimumWorkspaceWidth;
  const seam = DesktopShell.seamWidth;
  if (!railShown && !inspectorShown) {
    return ShellPaneWidths(rail: 0, workspace: availableWidth, inspector: 0);
  }
  if (!railShown || !inspectorShown) {
    final isRail = railShown;
    final request = isRail ? requestedRailWidth : requestedInspectorWidth;
    final minimum = isRail
        ? DesktopShell.minimumRailWidth
        : DesktopShell.minimumInspectorWidth;
    final maximum = isRail
        ? DesktopShell.maximumRailWidth
        : DesktopShell.maximumInspectorWidth;
    // The pane's own bound, or what the window leaves above the
    // workspace's minimum; a narrower window keeps the pane's minimum
    // and the workspace shrinks, which only sizes under the layout's
    // floor can reach.
    final room = availableWidth - minWorkspace - seam;
    final cap = room < maximum ? room : maximum;
    final side = request.clamp(minimum, cap < minimum ? minimum : cap);
    final workspace = availableWidth - side - seam;
    return isRail
        ? ShellPaneWidths(rail: side, workspace: workspace, inspector: 0)
        : ShellPaneWidths(rail: 0, workspace: workspace, inspector: side);
  }
  const minRail = DesktopShell.minimumRailWidth;
  const maxRail = DesktopShell.maximumRailWidth;
  const minInspector = DesktopShell.minimumInspectorWidth;
  const maxInspector = DesktopShell.maximumInspectorWidth;
  final requestedRail = requestedRailWidth.clamp(minRail, maxRail).toDouble();
  final requestedInspector = requestedInspectorWidth
      .clamp(minInspector, maxInspector)
      .toDouble();
  final budget = availableWidth - minWorkspace - seam * 2;
  final extra = budget - minRail - minInspector;
  final railExtra = requestedRail - minRail;
  final inspectorExtra = requestedInspector - minInspector;
  final requestedExtra = railExtra + inspectorExtra;
  late final double rawRail, rawInspector;
  if (requestedExtra <= extra || requestedExtra <= 0) {
    rawRail = requestedRail;
    rawInspector = requestedInspector;
  } else {
    final scale = extra / requestedExtra;
    rawRail = minRail + railExtra * scale;
    rawInspector = minInspector + inspectorExtra * scale;
  }
  final rail = rawRail.clamp(minRail, maxRail).toDouble();
  final inspector = rawInspector.clamp(minInspector, maxInspector).toDouble();
  final workspace = availableWidth - rail - inspector - seam * 2;
  return ShellPaneWidths(
    rail: rail,
    workspace: workspace,
    inspector: inspector,
  );
}

/// Where the window's leading controls start: after the traffic lights
/// under the macOS titlebar, in full screen too, and at the edge
/// everywhere else.
double _leadingInset(BuildContext context) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? macosTrafficLightsInset
    : 8;

/// [child] as a control inside the macOS toolbar band: there AppKit takes
/// every click for window drag unless a passthrough view hands it back.
/// Plain Flutter on every other platform.
Widget _clickable(BuildContext context, Widget child) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? MacosToolbarPassthrough(child: child)
    : child;

/// [child] with the passthrough views inside it registered, on macOS.
Widget _passthroughScope(Widget child) => Builder(
  builder: (context) => MacosToolbarBandScope.unifiedToolbarOf(context)
      ? MacosToolbarPassthroughScope(child: child)
      : child,
);

/// The one-pixel line between two panes (Séance's `_Seam`): all the
/// width the layout gives it, so the panes' borders run into it. The
/// [GhostResizeHandle] floats over it in [_DesktopShellState._straddle].
class _Seam extends StatelessWidget {
  const _Seam({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      VerticalDivider(width: DesktopShell.seamWidth, color: color);
}

/// The 52 pt strip level with the macOS band and the header: the rail's
/// sidebar toggle, and the header itself above the workspace. [top] is a
/// tablet's status bar, which the controls start below while the strip's
/// colour paints through it.
class _Band extends StatelessWidget {
  const _Band({required this.top, required this.child});

  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The suite's header fill, as Séance's and Poltergeist's headers paint.
    return ColoredBox(
      color: GhostChrome.of(context, klabautermannThemeStyle).headerBackground,
      child: SizedBox(
        height: top + macosToolbarBandHeight,
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: child,
        ),
      ),
    );
  }
}

/// A side pane's toggle (Séance's `_PaneToggleButton`): the suite's
/// `view_sidebar` glyph, its panel on the leading side for the rail and
/// the trailing one for the inspector, named for what it would do with
/// the pane's shortcut in its tooltip.
class _PaneToggle extends StatelessWidget {
  const _PaneToggle({
    super.key,
    required this.pane,
    required this.shown,
    required this.onToggle,
  });

  final WindowPane pane;
  final bool shown;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    final label = switch ((pane, shown)) {
      (WindowPane.sidebar, true) => l10n.sidebarToggleHide,
      (WindowPane.sidebar, false) => l10n.sidebarToggleShow,
      (WindowPane.inspector, true) => l10n.inspectorToggleHide,
      (WindowPane.inspector, false) => l10n.inspectorToggleShow,
    };
    final keys = formatShortcutActivator(
      windowPaneChord(pane, platform),
      platform,
    );
    final tooltip = keys == null ? label : l10n.paneToggleTooltip(label, keys);
    // view_sidebar draws its panel on the right: mirrored for the panel
    // on the reading direction's start.
    final ltr = Directionality.of(context) == TextDirection.ltr;
    final leading = pane == WindowPane.sidebar;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onToggle,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 30,
            height: 26,
            child: Transform.flip(
              flipX: leading == ltr,
              child: Icon(
                Icons.view_sidebar_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
