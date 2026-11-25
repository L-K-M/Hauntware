import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show NetworkActionsButton, PruneButton, networkActionEntries;
import '../sortable_table.dart';
import 'docker_list_panel.dart';
import 'docker_cells.dart';
import 'networks_view.dart';

/// The Networks sub-tab (03 §7.15 DNW-01): every network by name, its
/// driver, scope and first subnet, and how many containers are on it,
/// the engine's own (`bridge`, `host`, `none`) marked built-in, with a
/// filter for the user-defined ones no container is on and a search by
/// name, driver or subnet. Where actions are allowed, a user-defined
/// network is removed from its row (DNW-02).
///
/// While [visible], it holds the server's network watch
/// ([DockerController.watchNetworks]), which reads the containers too:
/// their networks tell which are in use ([containersByNetwork]). Hidden,
/// it lets the watch go. A failed read keeps the last list under why it
/// failed. The shared [DockerListPanel] owns that state and the layout;
/// this panel supplies its columns, filters, notices and row widgets.
class NetworksPanel extends StatefulWidget {
  const NetworksPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<NetworksPanel> createState() => _NetworksPanelState();
}

class _NetworksPanelState extends State<NetworksPanel> {
  DockerController get _docker => widget.monitoring.docker;

  @override
  Widget build(BuildContext context) =>
      DockerListPanel<
        NetworkSummary,
        NetworkEntry,
        NetworkFilter,
        NetworkColumn
      >(
        serverId: widget.serverId,
        visible: widget.visible,
        list: () => _docker.networksFor(widget.serverId),
        containers: () => _docker.containersFor(widget.serverId),
        endpoint: () => _docker.endpointFor(widget.serverId),
        watch: _docker.watchNetworks,
        unwatch: _docker.unwatchNetworks,
        retry: () => _docker.retryNetworks(widget.serverId),
        itemsOf: (payload) => (payload as DockerNetworkList?)?.networks,
        failureOf: (payload) => (payload as DockerNetworkList?)?.failure,
        initialSort: TableSort(
          NetworkColumn.name.name,
          TableSortDirection.ascending,
        ),
        filters: NetworkFilter.values,
        initialFilter: NetworkFilter.all,
        filterLabel: (l10n, filter) => switch (filter) {
          NetworkFilter.all => l10n.dockerImagesFilterAll,
          NetworkFilter.unused => l10n.dockerImagesFilterUnused,
        },
        shownFilter: (selected, useKnown) =>
            useKnown ? selected : NetworkFilter.all,
        useKnown: (containers) => containers.containers != null,
        searchHint: (l10n) => l10n.dockerNetworksSearchHint,
        columns: (context, l10n) => _columns(l10n),
        sortColumns: NetworkColumn.values,
        sortLabel: (l10n, column) => _label(l10n, column),
        descendingFirst: (column) => column == NetworkColumn.use,
        entries: (items, containers, filter, terms) => networkEntries(
          items,
          containers: containers,
          filter: filter,
          terms: terms,
        ),
        empty: (items, filter, terms, l10n) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            items.isEmpty
                ? l10n.dockerNetworksEmpty
                : terms.isNotEmpty
                ? l10n.dockerNetworksNoMatch
                : switch (filter) {
                    NetworkFilter.unused => l10n.dockerNetworksNoneUnused,
                    // Every network passes; the engine listed none.
                    NetworkFilter.all => l10n.dockerNetworksEmpty,
                  },
          ),
        ),
        tableId: DockerWatchList.networks.name,
        rowKey: _rowKey,
        heading: (context, entry) => Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              entry.network.name,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (entry.builtin) const NetworkBuiltinBadge(),
          ],
        ),
        phoneActions: (context, entry) =>
            NetworkActionsButton(serverId: widget.serverId, entry: entry),
        menuActions: (context, entry) => networkActionEntries(
          context,
          serverId: widget.serverId,
          entry: entry,
        ),
        actionPoint: ActionEntryPoint.networkRemove,
        failedText: (l10n, failure) => l10n.dockerNetworksFailed(failure),
        keptText: (l10n) => l10n.dockerImagesKept,
        readingText: (l10n) => l10n.dockerNetworksReading,
        useUnknownText: (l10n) => l10n.dockerNetworksUseUnknown,
        actions: (context) =>
            actionsAllowedAt(context, widget.serverId, ActionEntryPoint.prune)
            ? PruneButton(
                choices: [
                  PruneDocker(widget.serverId, kind: DockerPruneKind.networks),
                ],
              )
            : null,
      );

  List<SortableTableColumn<NetworkEntry>> _columns(AppLocalizations l10n) {
    final unknown = l10n.chartUnknownValue;
    return [
      SortableTableColumn(
        id: NetworkColumn.name.name,
        label: _label(l10n, NetworkColumn.name),
        text: (entry) => entry.builtin
            ? l10n.dockerNetworksBuiltinName(entry.network.name)
            : entry.network.name,
        sortKey: (entry) => entry.network.name.toLowerCase(),
        extent: const FlexColumnExtent(3),
        cell: (context, entry) => Row(
          spacing: 8,
          children: [
            Flexible(child: DockerCellText(text: entry.network.name)),
            if (entry.builtin) const NetworkBuiltinBadge(),
          ],
        ),
      ),
      SortableTableColumn(
        id: NetworkColumn.driver.name,
        label: _label(l10n, NetworkColumn.driver),
        text: (entry) => entry.network.driver ?? unknown,
        sortKey: (entry) => entry.network.driver?.toLowerCase(),
        extent: const FixedColumnExtent(100),
      ),
      SortableTableColumn(
        id: NetworkColumn.scope.name,
        label: _label(l10n, NetworkColumn.scope),
        text: (entry) => entry.network.scope ?? unknown,
        sortKey: (entry) => entry.network.scope,
        extent: const FixedColumnExtent(80),
      ),
      SortableTableColumn(
        id: NetworkColumn.subnet.name,
        label: _label(l10n, NetworkColumn.subnet),
        text: (entry) => entry.network.subnet ?? l10n.dockerNetworksNoSubnet,
        sortKey: (entry) => entry.network.subnet,
        extent: const FlexColumnExtent(2),
      ),
      SortableTableColumn(
        id: NetworkColumn.gateway.name,
        label: _label(l10n, NetworkColumn.gateway),
        text: (entry) =>
            networkGateway(entry.network) ?? l10n.dockerNetworksNoSubnet,
        sortKey: (entry) => networkGateway(entry.network),
        extent: const FlexColumnExtent(1),
      ),
      SortableTableColumn(
        id: NetworkColumn.use.name,
        label: _label(l10n, NetworkColumn.use),
        text: (entry) => switch (entry.containers) {
          null => unknown,
          0 => l10n.dockerImagesUnused,
          final count => l10n.dockerNetworksInUse(count),
        },
        sortKey: (entry) => entry.containers,
        firstDirection: TableSortDirection.descending,
        extent: const FixedColumnExtent(128),
        cell: (context, entry) => switch (entry.containers) {
          null => DockerCellText(text: unknown),
          final count => DockerUseBadge(count: count),
        },
      ),
    ];
  }
}

/// A row's identity: the network's id.
Object _rowKey(NetworkEntry entry) => entry.network.id;

String _label(AppLocalizations l10n, NetworkColumn column) => switch (column) {
  NetworkColumn.name => l10n.dockerVolumesColumnName,
  NetworkColumn.driver => l10n.dockerVolumesColumnDriver,
  NetworkColumn.scope => l10n.dockerNetworksColumnScope,
  NetworkColumn.subnet => l10n.dockerNetworksColumnSubnet,
  NetworkColumn.gateway => l10n.dockerNetworksColumnGateway,
  NetworkColumn.use => l10n.dockerImagesColumnUse,
};

/// The mark of a built-in network (DNW-01): an icon and its word in a
/// tinted pill, so colour is never the only cue (A11Y-01).
class NetworkBuiltinBadge extends StatelessWidget {
  const NetworkBuiltinBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(
              Icons.lock_outline,
              size: 14,
              color: scheme.onSecondaryContainer,
            ),
            Text(
              l10n.dockerNetworksBuiltin,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
