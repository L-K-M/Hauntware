import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show NetworkActionsButton, PruneButton, networkActionEntries;
import '../sortable_table.dart';
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show searchTerms;
import 'docker_cells.dart';
import 'networks_view.dart';

/// The panel width from which the networks show as the sortable table;
/// narrower, as on a phone, they show as two-line rows. It grows with the
/// text scale, as the Images sub-tab's does.
const double _wideWidth = 600;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

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
/// failed.
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
  /// The order, search and filter, which outlive sub-tab switches: the
  /// tab keeps a sub-tab built once opened.
  TableSort _sort = TableSort(
    NetworkColumn.name.name,
    TableSortDirection.ascending,
  );
  final _search = TextEditingController();

  /// The filter field, which `/` in the table focuses (PLT-06).
  final _searchFocus = FocusNode();
  NetworkFilter _filter = NetworkFilter.all;

  /// The server whose network watch this panel holds, if any.
  String? _held;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(NetworksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      // Another server's networks.
      _release();
      _search.clear();
    }
    _sync();
  }

  @override
  void dispose() {
    _release();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchNetworks(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchNetworks(held);
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final networks = _docker.networksFor(widget.serverId);
    final containers = _docker.containersFor(widget.serverId);
    final endpoint = _docker.endpointFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([networks, containers, endpoint]),
      builder: (context, _) =>
          _build(context, networks.value, containers.value, endpoint.value),
    );
  }

  Widget _build(
    BuildContext context,
    DockerNetworkList list,
    DockerContainerList containers,
    DockerEndpointState? endpoint,
  ) {
    final l10n = AppLocalizations.of(context);
    final networks = list.networks;
    final failure = list.failure;
    // The network list names no container, so without a container list
    // the use is unknown.
    final useUnknown =
        containers.containers == null &&
        containers.failure != null &&
        (networks?.isNotEmpty ?? false);

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            // On the socket forward the events stream costs no session,
            // so low-session mode changes nothing the list shows.
            if ((endpoint?.lowSession ?? false) &&
                endpoint?.route?.rank != DockerRank.streamlocal)
              DockerNotice(
                icon: Icons.speed_outlined,
                text: l10n.dockerImagesLowSessionRelay,
              ),
            if (failure != null) ...[
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerNetworksFailed(failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: () => _docker.retryNetworks(widget.serverId),
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (networks != null)
                DockerNotice(icon: Icons.history, text: l10n.dockerImagesKept),
            ] else if (networks == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: l10n.dockerNetworksReading,
              ),
            if (useUnknown)
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerNetworksUseUnknown,
                detail: containers.failure?.detail,
              ),
            if (networks != null &&
                actionsAllowedAt(
                  context,
                  widget.serverId,
                  ActionEntryPoint.prune,
                ))
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: PruneButton(
                  choices: [
                    PruneDocker(
                      widget.serverId,
                      kind: DockerPruneKind.networks,
                    ),
                  ],
                ),
              ),
            if (networks != null)
              _filters(l10n, useKnown: containers.containers != null),
            if (networks != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (networks == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _body(
                    context,
                    networks,
                    containers.containers,
                    wide: wide,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    List<NetworkSummary> networks,
    List<ContainerSummary>? containers, {
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final columns = _columns(l10n);
    final terms = searchTerms(_search.text);
    final filter = _shownFilter(useKnown: containers != null);
    final entries = networkEntries(
      networks,
      containers: containers,
      filter: filter,
      terms: terms,
    );
    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        networks.isEmpty
            ? l10n.dockerNetworksEmpty
            : terms.isNotEmpty
            ? l10n.dockerNetworksNoMatch
            : switch (filter) {
                NetworkFilter.unused => l10n.dockerNetworksNoneUnused,
                // Every network passes; the engine listed none.
                NetworkFilter.all => l10n.dockerNetworksEmpty,
              },
      ),
    );
    if (!wide) {
      return _list(sortTableRows(entries, columns, _sort), columns, empty);
    }

    return SortableTable<NetworkEntry>(
      tableId: DockerWatchList.networks.name,
      filterFocus: _searchFocus,
      columns: columns,
      rows: entries,
      rowKey: _rowKey,
      sort: _sort,
      onSort: (sort) => setState(() => _sort = sort),
      rowActions:
          actionsAllowedAt(
            context,
            widget.serverId,
            ActionEntryPoint.networkRemove,
          )
          ? (entry) => networkActionEntries(
              context,
              serverId: widget.serverId,
              entry: entry,
            )
          : null,
      empty: empty,
    );
  }

  /// The filter the list applies: every network while no container list
  /// says which are unused, so an empty list never claims that every
  /// network has a container on it when that is unknown.
  NetworkFilter _shownFilter({required bool useKnown}) =>
      useKnown ? _filter : NetworkFilter.all;

  Widget _filters(AppLocalizations l10n, {required bool useKnown}) => Wrap(
    spacing: 12,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.dockerNetworksSearchHint,
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l10n.dockerImagesSearchClear,
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final filter in NetworkFilter.values)
            ChoiceChip(
              label: Text(switch (filter) {
                NetworkFilter.all => l10n.dockerImagesFilterAll,
                NetworkFilter.unused => l10n.dockerImagesFilterUnused,
              }),
              selected: _shownFilter(useKnown: useKnown) == filter,
              onSelected: useKnown
                  ? (_) => setState(() => _filter = filter)
                  : null,
            ),
        ],
      ),
    ],
  );

  /// The phone layout's order: the table's columns in a menu, and the
  /// direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = NetworkColumn.values.byName(_sort.columnId);
    final ascending = _sort.direction == TableSortDirection.ascending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.dockerImagesSortBy,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        DropdownButton<NetworkColumn>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in NetworkColumn.values)
              DropdownMenuItem(
                value: choice,
                child: Text(_label(l10n, choice)),
              ),
          ],
          onChanged: (choice) {
            if (choice == null) return;
            setState(
              () => _sort = TableSort(
                choice.name,
                choice == NetworkColumn.use
                    ? TableSortDirection.descending
                    : TableSortDirection.ascending,
              ),
            );
          },
        ),
        IconButton(
          tooltip: ascending
              ? l10n.tableSortedAscending
              : l10n.tableSortedDescending,
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
          onPressed: () => setState(
            () => _sort = TableSort(
              _sort.columnId,
              ascending
                  ? TableSortDirection.descending
                  : TableSortDirection.ascending,
            ),
          ),
        ),
      ],
    );
  }

  /// The phone layout: two-line rows that wrap at large text, the name
  /// over the other figures, each row one node naming its cells as the
  /// table's rows do.
  Widget _list(
    List<NetworkEntry> entries,
    List<SortableTableColumn<NetworkEntry>> columns,
    Widget empty,
  ) {
    if (entries.isEmpty) return empty;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final cells = [
          for (final column in columns)
            (label: column.label, text: column.text(entry)),
        ];
        final row = Semantics(
          key: ValueKey(_phoneRowKey(entry)),
          container: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.network.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (entry.builtin) const NetworkBuiltinBadge(),
                  ],
                ),
                Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    // The name heads the row.
                    for (final cell in cells.skip(1))
                      Text(
                        l10n.dockerImagesFact(cell.label, cell.text),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        // The actions sit beside the row's one node, so a screen reader
        // reaches them as a button of their own.
        return Row(
          children: [
            Expanded(child: row),
            NetworkActionsButton(serverId: widget.serverId, entry: entry),
          ],
        );
      },
    );
  }

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

/// The key tests find a phone row by, in the table rows' form.
String _phoneRowKey(NetworkEntry entry) =>
    '${DockerWatchList.networks.name}.row.${_rowKey(entry)}';

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
