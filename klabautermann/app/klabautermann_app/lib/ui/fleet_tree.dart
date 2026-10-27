import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/docker_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'docker/containers_view.dart'
    show composeProjectOf, containerIsUp, containerNameOf, containerStatusText;
import 'fleet_rail.dart' show linkStatusWord;
import 'fleet_row_state.dart';
import 'fleet_rows.dart' show fleetStatusStrings;
import 'server_header.dart' show LinkDot;
import 'server_surfaces.dart' show ServerPanel;
import 'workspace_navigation.dart';

/// FL-11's connection tree: the fleet, each server, its compose stacks
/// and its containers as one list of nested, expandable nodes (03 §10.3).
/// A server's containers are read while its node is open, through the
/// container watch the Docker tab uses; a container opens in the Docker
/// tab and the inspector, a server or a stack in the server's workspace.
class FleetTree extends StatelessWidget {
  const FleetTree({
    super.key,
    required this.fleet,
    required this.monitoring,
    this.header,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Above the first server, scrolling with the tree: the board's picker.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ?header,
        for (final server in fleet.servers)
          _ServerNode(
            key: ValueKey(server.id),
            server: server,
            fleet: fleet,
            monitoring: monitoring,
          ),
      ],
    );
  }
}

class _ServerNode extends StatefulWidget {
  const _ServerNode({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
  });

  final FleetServer server;
  final FleetController fleet;
  final MonitoringController monitoring;

  @override
  State<_ServerNode> createState() => _ServerNodeState();
}

class _ServerNodeState extends State<_ServerNode> {
  DockerController get _docker => widget.monitoring.docker;

  /// Whether this node holds the server's container watch: while it is
  /// open, and given back when it closes or leaves the tree.
  var _watching = false;

  void _expanded(bool open) {
    if (open == _watching) return;
    _watching = open;
    if (open) {
      _docker.watchContainers(widget.server.id);
    } else {
      _docker.unwatchContainers(widget.server.id);
    }
  }

  @override
  void dispose() {
    if (_watching) _docker.unwatchContainers(widget.server.id);
    super.dispose();
  }

  void _openServer() {
    final id = widget.server.id;
    switch (WorkspaceNavigationScope.maybeOf(context)) {
      case final navigation?:
        navigation.openPanel(id, ServerPanel.docker);
      case null:
        widget.fleet.select(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final server = widget.server;
    final link = widget.fleet.linkStatusFor(server.id);
    final indicator = ghostServerIndicator(
      fleetStatusStrings(l10n, link),
      GhostIndicatorRule.rail,
      session: ghostSessionOf(link),
      probe: ghostProbeOf(widget.fleet.reachabilityFor(server.id)),
    );
    final chrome = GhostChrome.of(context, klabautermannThemeStyle);
    final dot = ghostStatusDot(
      indicator,
      GhostStatusColors(
        online: chrome.statusConnected,
        connecting: chrome.statusConnecting,
        offline: chrome.statusFailed,
      ),
    );
    final word = indicator.label ?? linkStatusWord(l10n, link);
    return ExpansionTile(
      key: PageStorageKey((#fleetTree, server.id)),
      onExpansionChanged: _expanded,
      leading: SizedBox.square(
        dimension: 24,
        child: Center(child: dot == null ? null : LinkDot(dot)),
      ),
      title: Text(server.displayName),
      subtitle: Text([word, ?server.address].join(l10n.fleetRowPartSeparator)),
      trailing: IconButton(
        tooltip: l10n.fleetTreeOpenServer(server.displayName),
        icon: const Icon(Icons.open_in_new),
        onPressed: _openServer,
      ),
      childrenPadding: const EdgeInsetsDirectional.only(start: 24),
      children: [
        ValueListenableBuilder(
          valueListenable: _docker.containersFor(server.id),
          builder: (context, list, _) => ValueListenableBuilder(
            valueListenable: _docker.endpointFor(server.id),
            builder: (context, endpoint, _) =>
                _containers(context, l10n, list, endpoint),
          ),
        ),
      ],
    );
  }

  Widget _containers(
    BuildContext context,
    AppLocalizations l10n,
    DockerContainerList list,
    DockerEndpointState? endpoint,
  ) {
    final containers = list.containers;
    if (containers == null) {
      final note = switch ((list.failure, endpoint?.phase)) {
        (_, DockerEndpointPhase.failed) => l10n.fleetTreeNoDocker,
        (final _?, _) => l10n.fleetTreeReadFailed,
        _ => l10n.fleetTreeReading,
      };
      return _Note(note);
    }
    if (containers.isEmpty) return _Note(l10n.fleetTreeNoContainers);

    final byProject = <String?, List<ContainerSummary>>{};
    for (final container in containers) {
      byProject
          .putIfAbsent(composeProjectOf(container), () => [])
          .add(container);
    }
    final projects = byProject.keys.whereType<String>().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final standalone = byProject[null] ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final project in projects)
          ExpansionTile(
            key: PageStorageKey((#fleetTree, widget.server.id, project)),
            leading: const Icon(Icons.layers_outlined),
            title: Text(project),
            subtitle: Text(
              l10n.fleetTreeStackUp(
                byProject[project]!.where(containerIsUp).length,
                byProject[project]!.length,
              ),
            ),
            childrenPadding: const EdgeInsetsDirectional.only(start: 24),
            children: [
              for (final container in _sorted(byProject[project]!))
                _ContainerLeaf(
                  serverId: widget.server.id,
                  container: container,
                ),
            ],
          ),
        for (final container in _sorted(standalone))
          _ContainerLeaf(serverId: widget.server.id, container: container),
      ],
    );
  }

  static List<ContainerSummary> _sorted(List<ContainerSummary> containers) =>
      [...containers]..sort(
        (a, b) => containerNameOf(
          a,
        ).toLowerCase().compareTo(containerNameOf(b).toLowerCase()),
      );
}

class _ContainerLeaf extends StatelessWidget {
  const _ContainerLeaf({required this.serverId, required this.container});

  final String serverId;
  final ContainerSummary container;

  @override
  Widget build(BuildContext context) {
    final up = containerIsUp(container);
    final navigation = WorkspaceNavigationScope.maybeOf(context);
    return ListTile(
      dense: true,
      leading: Icon(
        up ? Icons.play_circle_outline : Icons.stop_circle_outlined,
        color: up
            ? GhostChrome.of(context, klabautermannThemeStyle).statusConnected
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(containerNameOf(container)),
      subtitle: switch (containerStatusText(container) ?? container.state) {
        final status? => Text(status),
        null => null,
      },
      onTap: navigation == null
          ? null
          : () => navigation.openContainer(serverId, container),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
