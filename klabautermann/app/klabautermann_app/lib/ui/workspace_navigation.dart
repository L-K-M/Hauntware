import 'package:flutter/widgets.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary;

import '../controllers/fleet_controller.dart';
import 'docker/container_details.dart' show InspectedContainer;
import 'server_surfaces.dart' show ServerPanel;

/// A request to show [panel] of [serverId]'s workspace; [serial] tells
/// two requests for the same tab apart.
@immutable
final class PanelRequest {
  const PanelRequest({
    required this.serverId,
    required this.panel,
    required this.serial,
  });

  final String serverId;
  final ServerPanel panel;
  final int serial;
}

/// Where the command palette (PLT-07, 03 §10.6) sends the desktop
/// workspace: it selects a server, and asks the workspace for a tab, the
/// inspector for a container, the Services tab for a unit and the Docker
/// tab for a stack. The desktop shell applies the container, the
/// workspace's tabs the request and the panels their unit or stack, each
/// of which they consume, so a request never outlives the switch it asked
/// for. A narrow window's palette
/// offers neither, as its phone shell has no tabs or inspector to show.
final class WorkspaceNavigation extends ChangeNotifier {
  WorkspaceNavigation(this._fleet);

  final FleetController _fleet;
  PanelRequest? _request;
  InspectedContainer? _container;
  ({String serverId, String name})? _unit;
  ({String serverId, String name})? _stack;
  int _serial = 0;

  /// The tab asked for and not yet shown.
  PanelRequest? get request => _request;

  /// The container asked for and not yet handed to the inspector.
  InspectedContainer? get container => _container;

  /// Selects [serverId] and asks its workspace for [panel]; a container,
  /// unit or stack asked for earlier and not yet taken is dropped.
  void openPanel(String serverId, ServerPanel panel) => _open(serverId, panel);

  /// Selects [serverId], asks for its Docker tab and hands [container] to
  /// the inspector.
  void openContainer(String serverId, ContainerSummary container) => _open(
    serverId,
    ServerPanel.docker,
    container: InspectedContainer(serverId: serverId, container: container),
  );

  /// Selects [serverId], asks for its Services tab and opens the system
  /// unit named [unit] there.
  void openUnit(String serverId, String unit) => _open(
    serverId,
    ServerPanel.services,
    unit: (serverId: serverId, name: unit),
  );

  /// Selects [serverId], asks for its Docker tab and opens the compose
  /// project named [project] under Stacks.
  void openStack(String serverId, String project) => _open(
    serverId,
    ServerPanel.docker,
    stack: (serverId: serverId, name: project),
  );

  void _open(
    String serverId,
    ServerPanel panel, {
    InspectedContainer? container,
    ({String serverId, String name})? unit,
    ({String serverId, String name})? stack,
  }) {
    _fleet.select(serverId);
    _container = container;
    _unit = unit;
    _stack = stack;
    _request = PanelRequest(
      serverId: serverId,
      panel: panel,
      serial: ++_serial,
    );
    notifyListeners();
  }

  /// [request] was shown; a newer one stays.
  void consumeRequest(PanelRequest request) {
    if (identical(_request, request)) _request = null;
  }

  /// The container asked for went to the inspector.
  InspectedContainer? takeContainer() {
    final container = _container;
    _container = null;
    return container;
  }

  /// The unit asked for on [serverId], which the Services tab now opens.
  String? takeUnit(String serverId) {
    final unit = _unit;
    if (unit == null || unit.serverId != serverId) return null;
    _unit = null;
    return unit.name;
  }

  /// The stack asked for on [serverId], which the Docker tab now opens.
  String? takeStack(String serverId) {
    final stack = _stack;
    if (stack == null || stack.serverId != serverId) return null;
    _stack = null;
    return stack.name;
  }
}

/// Hands [WorkspaceNavigation] to the workspace's tabs.
class WorkspaceNavigationScope extends InheritedWidget {
  const WorkspaceNavigationScope({
    super.key,
    required this.navigation,
    required super.child,
  });

  final WorkspaceNavigation navigation;

  /// The navigation, without rebuilding [context] as requests arrive: the
  /// tabs listen to it themselves.
  static WorkspaceNavigation? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<WorkspaceNavigationScope>()
      ?.navigation;

  @override
  bool updateShouldNotify(WorkspaceNavigationScope oldWidget) =>
      navigation != oldWidget.navigation;
}
