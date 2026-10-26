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
/// workspace: it selects a server, and asks the workspace for a tab and
/// the inspector for a container. The desktop shell applies the container
/// and the workspace's tabs the request, which they consume, so a request
/// never outlives the switch it asked for. A narrow window's phone shell
/// follows the selection only.
final class WorkspaceNavigation extends ChangeNotifier {
  WorkspaceNavigation(this._fleet);

  final FleetController _fleet;
  PanelRequest? _request;
  InspectedContainer? _container;
  int _serial = 0;

  /// The tab asked for and not yet shown.
  PanelRequest? get request => _request;

  /// The container asked for and not yet handed to the inspector.
  InspectedContainer? get container => _container;

  /// Selects [serverId] and asks its workspace for [panel].
  void openPanel(String serverId, ServerPanel panel) {
    _fleet.select(serverId);
    _request = PanelRequest(
      serverId: serverId,
      panel: panel,
      serial: ++_serial,
    );
    notifyListeners();
  }

  /// Selects [serverId], asks for its Docker tab and hands [container] to
  /// the inspector.
  void openContainer(String serverId, ContainerSummary container) {
    _fleet.select(serverId);
    _container = InspectedContainer(serverId: serverId, container: container);
    openPanel(serverId, ServerPanel.docker);
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
