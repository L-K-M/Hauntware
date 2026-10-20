import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, ghostFormatBinarySize, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/docker_actions.dart' show containerActionEntries;
import '../sortable_table.dart';
import 'container_details.dart';
import 'container_logs.dart';
import 'containers_view.dart';

/// The panel width from which the containers show as the sortable table;
/// narrower, as on a phone, they show as two-line rows. It grows with the
/// text scale, as the table's columns do (the Processes tab's rule).
const double _wideWidth = 600;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

/// How old a container's list stats grow before they read as stale: four
/// rounds of the engine's 5 s stats cadence (CST-01 [E]), since a relay
/// or low-session mode reads one container at a time and a long screen
/// takes longer to go round.
const Duration _statsStaleAfter = Duration(seconds: 20);

/// How long the rows on screen hold still before their ids go to the
/// watch, so a scroll sends one [DockerWatch] when it settles rather than
/// one per row it passes.
const Duration kStatsForSettle = Duration(milliseconds: 250);

/// The Containers sub-tab (03 §7.12 CTR-01, CTR-04, CST-01): every
/// container by name, state, health, the engine's status (its uptime),
/// image, ports, compose project, CPU and memory, grouped by compose
/// project under headings that fold, with a running-only toggle and a
/// search by name, image or ID.
///
/// While [visible], it holds the server's container watch
/// ([DockerController.watchContainers]) and reports the running
/// containers its rows show, whose list stats the engine then reads
/// ([DockerController.showStatsFor]); hidden, it lets the watch go. Stats
/// older than [_statsStaleAfter] turn grey beside a history icon. A
/// failed read keeps the last list under why it failed.
///
/// The list carries no sizes: the protocol's container watch does not
/// ask for `size=1`, so 02 CTR-01's lazy sizes wait for a query that
/// does. A container's row opens its details ([openContainerDetails]):
/// in the desktop inspector, or on a page of its own. The table's row
/// actions open its logs ([openContainerLogs]).
class ContainersPanel extends StatefulWidget {
  const ContainersPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<ContainersPanel> createState() => _ContainersPanelState();
}

class _ContainersPanelState extends State<ContainersPanel> {
  /// What the clock's listeners hear instead while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The order, search, toggle and folds, which outlive sub-tab switches:
  /// the tab keeps a sub-tab built once opened.
  TableSort _sort = TableSort(
    ContainerColumn.name.name,
    TableSortDirection.ascending,
  );
  final _search = TextEditingController();
  bool _runningOnly = false;
  final Set<String?> _collapsed = {};

  /// The server whose container watch this panel holds, if any.
  String? _held;

  /// The running containers on screen, last reported, which a watch that
  /// starts again reads stats for at once.
  List<String> _shown = const [];
  Timer? _settle;

  /// The phone list's running rows that are built, as on screen.
  late final _BuiltRows _builtRows = _BuiltRows(() => _report(_builtRows.ids));

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ContainersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      // Another server's containers.
      _release();
      _search.clear();
      _collapsed.clear();
      _shown = const [];
    }
    _sync();
  }

  @override
  void dispose() {
    _release();
    _search.dispose();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchContainers(wanted, statsFor: _shown);
    _held = wanted;
  }

  void _release() {
    _settle?.cancel();
    _settle = null;
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchContainers(held);
  }

  /// Takes [ids], the running containers on screen, and sends them once
  /// they hold still for [kStatsForSettle].
  void _report(List<String> ids) {
    _shown = ids;
    if (_held == null) return;

    _settle?.cancel();
    _settle = Timer(kStatsForSettle, () {
      final held = _held;
      if (held != null) _docker.showStatsFor(held, _shown);
    });
  }

  void _toggle(String? project) => setState(() {
    if (!_collapsed.remove(project)) _collapsed.add(project);
  });

  void _open(ContainerSummary container) => openContainerDetails(
    context,
    monitoring: widget.monitoring,
    serverId: widget.serverId,
    container: container,
  );

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final list = _docker.containersFor(widget.serverId);
    final endpoint = _docker.endpointFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([list, endpoint]),
      builder: (context, _) => _build(context, list.value, endpoint.value),
    );
  }

  Widget _build(
    BuildContext context,
    DockerContainerList list,
    DockerEndpointState? endpoint,
  ) {
    final l10n = AppLocalizations.of(context);
    final containers = list.containers;
    final failure = list.failure;
    final clock = widget.visible && list.stats.isNotEmpty
        ? widget.monitoring.clock
        : _silent;

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (endpoint?.lowSession ?? false)
              DockerNotice(
                icon: Icons.speed_outlined,
                text: endpoint?.route?.rank == DockerRank.streamlocal
                    ? l10n.dockerContainersLowSession
                    : l10n.dockerContainersLowSessionRelay,
              ),
            if (failure != null) ...[
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerContainersFailed(failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: () => _docker.retryContainers(widget.serverId),
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (containers != null)
                DockerNotice(
                  icon: Icons.history,
                  text: l10n.dockerContainersKept,
                ),
            ] else if (containers == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: l10n.dockerContainersReading,
              ),
            if (list.statsFailure != null && containers != null)
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerContainersStatsFailed,
                detail: list.statsFailure?.detail,
              ),
            if (containers != null) _filters(l10n),
            if (containers != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (containers == null) {
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
                  // Only the stats age with the clock.
                  child: ListenableBuilder(
                    listenable: clock,
                    builder: (context, _) =>
                        _body(context, containers, list.stats, wide: wide),
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
    List<ContainerSummary> containers,
    Map<String, ContainerListStats> stats, {
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final columns = _columns(l10n, stats, widget.monitoring.clock.value);
    final terms = searchTerms(_search.text);
    final entries = containerListEntries(
      containers,
      runningOnly: _runningOnly,
      terms: terms,
      collapsed: _collapsed,
      order: (rows) =>
          sortTableRows<ContainerListEntry>(rows, columns, _sort).cast(),
    );
    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        containers.isEmpty
            ? l10n.dockerContainersEmpty
            : terms.isNotEmpty
            ? l10n.dockerContainersNoMatch
            : l10n.dockerContainersNoneRunning,
      ),
    );
    if (!wide) return _list(entries, columns, empty);

    return SortableTable<ContainerListEntry>(
      tableId: DockerWatchList.containers.name,
      columns: columns,
      rows: entries,
      rowKey: _rowKey,
      sort: _sort,
      onSort: (sort) => setState(() => _sort = sort),
      rowOrder: TableRowOrder.asGiven,
      // A heading folds; a container opens its details.
      onRowActivated: (entry) => switch (entry) {
        ContainerGroupEntry(:final project) => _toggle(project),
        ContainerEntry(:final container) => _open(container),
      },
      rowActions: (entry) => switch (entry) {
        ContainerGroupEntry() => const [],
        ContainerEntry(:final container) => [
          SidebarMenuAction(
            label: l10n.dockerLogsShow,
            onSelected: () => openContainerLogs(
              context,
              monitoring: widget.monitoring,
              serverId: widget.serverId,
              container: container,
            ),
          ),
          ...containerActionEntries(
            context,
            serverId: widget.serverId,
            container: container,
          ),
        ],
      },
      spanningRow: (context, entry) => switch (entry) {
        final ContainerGroupEntry group => _GroupHeading(group: group),
        ContainerEntry() => null,
      },
      onShownRowsChanged: (rows) => _report([
        for (final row in rows)
          if (row case ContainerEntry(
            :final container,
          ) when containerIsUp(container))
            container.id,
      ]),
      empty: empty,
    );
  }

  Widget _filters(AppLocalizations l10n) => Wrap(
    spacing: 12,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.dockerContainersSearchHint,
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l10n.dockerContainersSearchClear,
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
      ),
      FilterChip(
        label: Text(l10n.dockerContainersRunningOnly),
        selected: _runningOnly,
        onSelected: (selected) => setState(() => _runningOnly = selected),
      ),
    ],
  );

  /// The phone layout's order: the table's sortable columns in a menu,
  /// and the direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = ContainerColumn.values.byName(_sort.columnId);
    final ascending = _sort.direction == TableSortDirection.ascending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.dockerContainersSortBy,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        DropdownButton<ContainerColumn>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in ContainerColumn.values)
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
                _firstDirection.contains(choice)
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

  /// The phone layout: headings that fold, and two-line rows that wrap at
  /// large text, each one node naming its cells as the table's rows do.
  /// The running rows the list has built, its viewport and the small
  /// margin it builds ahead, count as on screen.
  Widget _list(
    List<ContainerListEntry> entries,
    List<SortableTableColumn<ContainerListEntry>> columns,
    Widget empty,
  ) {
    if (entries.isEmpty) {
      _report(const []);
      return empty;
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry is ContainerGroupEntry) {
          final group = entry;
          return Semantics(
            key: ValueKey(_phoneRowKey(group)),
            container: true,
            button: true,
            onTap: () => _toggle(group.project),
            child: InkWell(
              excludeFromSemantics: true,
              onTap: () => _toggle(group.project),
              child: ConstrainedBox(
                // A touch needs a 48 dp target (A11Y-01).
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: _GroupHeading(group: group),
              ),
            ),
          );
        }

        final container = (entry as ContainerEntry).container;
        final cells = [
          for (final column in columns)
            if (column.text(entry) case final text when text.isNotEmpty)
              (id: column.id, label: column.label, text: text),
        ];
        final row = Semantics(
          key: ValueKey(_phoneRowKey(entry)),
          container: true,
          button: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          excludeSemantics: true,
          onTap: () => _open(container),
          child: InkWell(
            excludeFromSemantics: true,
            onTap: () => _open(container),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      Flexible(
                        child: Text(
                          containerNameOf(container),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (container.health case final health?
                          when health != HealthStatus.none)
                        ContainerHealthBadge(health: health),
                    ],
                  ),
                  Wrap(
                    spacing: 16,
                    runSpacing: 2,
                    children: [
                      // The name and the health badge head the row.
                      for (final cell in cells.skip(1))
                        if (cell.id != ContainerColumn.health.name)
                          Text(
                            l10n.dockerContainersFact(cell.label, cell.text),
                            style: theme.textTheme.bodySmall,
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        if (!containerIsUp(container)) return row;
        return _BuiltRow(id: container.id, rows: _builtRows, child: row);
      },
    );
  }

  List<SortableTableColumn<ContainerListEntry>> _columns(
    AppLocalizations l10n,
    Map<String, ContainerListStats> stats,
    DateTime now,
  ) {
    final unknown = l10n.chartUnknownValue;

    SortableTableColumn<ContainerListEntry> column(
      ContainerColumn id,
      String Function(ContainerSummary container) text,
      Comparable<Object>? Function(ContainerSummary container) sortKey, {
      ColumnExtent extent = const FlexColumnExtent(),
      CellAlignment alignment = CellAlignment.start,
      Widget Function(BuildContext context, ContainerSummary container)? cell,
    }) => SortableTableColumn(
      id: id.name,
      label: _label(l10n, id),
      text: (entry) => switch (entry) {
        ContainerEntry(:final container) => text(container),
        ContainerGroupEntry() => '',
      },
      sortKey: (entry) => switch (entry) {
        ContainerEntry(:final container) => sortKey(container),
        ContainerGroupEntry() => null,
      },
      firstDirection: _firstDirection.contains(id)
          ? TableSortDirection.descending
          : TableSortDirection.ascending,
      extent: extent,
      alignment: alignment,
      cell: cell == null
          ? null
          : (context, entry) => switch (entry) {
              ContainerEntry(:final container) => cell(context, container),
              ContainerGroupEntry() => const SizedBox.shrink(),
            },
    );

    /// A figure from a running container's list stats: nothing for one
    /// that is not up, unknown until a round has read it, and stale,
    /// greyed and said so, once its round is old.
    SortableTableColumn<ContainerListEntry> figure(
      ContainerColumn id,
      String? Function(ContainerListStats stats) shown,
      Comparable<Object>? Function(ContainerListStats stats) sortKey,
    ) {
      (String, bool)? read(ContainerSummary container) {
        if (!containerIsUp(container)) return null;
        final row = stats[container.id];
        if (row == null) return (unknown, false);
        return (
          shown(row) ?? unknown,
          now.difference(row.at) >= _statsStaleAfter,
        );
      }

      return column(
        id,
        (container) => switch (read(container)) {
          null => '',
          (final value, true) => l10n.dockerContainersStale(value),
          (final value, false) => value,
        },
        (container) => switch (stats[container.id]) {
          final row? when containerIsUp(container) => sortKey(row),
          _ => null,
        },
        extent: const FixedColumnExtent(88),
        alignment: CellAlignment.end,
        cell: (context, container) => switch (read(container)) {
          null => const SizedBox.shrink(),
          (final value, final stale) => _Figure(value: value, stale: stale),
        },
      );
    }

    return [
      column(
        ContainerColumn.name,
        containerNameOf,
        (container) => containerNameOf(container).toLowerCase(),
        extent: const FlexColumnExtent(2),
      ),
      column(
        ContainerColumn.state,
        (container) => containerStateText(l10n, container.state),
        (container) => _stateRank(container.state),
        extent: const FixedColumnExtent(88),
      ),
      column(
        ContainerColumn.health,
        (container) => switch (container.health) {
          null || HealthStatus.none => '',
          final health => l10n.dockerContainerHealth(health.name),
        },
        (container) => healthRank(container.health),
        extent: const FixedColumnExtent(104),
        cell: (context, container) => switch (container.health) {
          null || HealthStatus.none => const SizedBox.shrink(),
          final health => ContainerHealthBadge(health: health),
        },
      ),
      column(
        ContainerColumn.status,
        (container) => containerStatusText(container) ?? unknown,
        (container) => containerUptime(container)?.inSeconds,
        extent: const FlexColumnExtent(2),
      ),
      column(
        ContainerColumn.image,
        (container) => container.image ?? unknown,
        (container) => container.image?.toLowerCase(),
        extent: const FlexColumnExtent(2),
      ),
      column(
        ContainerColumn.ports,
        containerPortsText,
        (container) => switch (containerPortsText(container)) {
          '' => null,
          final ports => ports,
        },
        extent: const FlexColumnExtent(2),
      ),
      column(
        ContainerColumn.stack,
        (container) => _stackText(l10n, container),
        (container) {
          final text = _stackText(l10n, container).toLowerCase();
          return text.isEmpty ? null : text;
        },
        extent: const FixedColumnExtent(120),
      ),
      figure(
        ContainerColumn.cpu,
        (row) => switch (row.cpuPercent) {
          final cpu? => l10n.dockerContainersCpu(cpu / 100),
          null => null,
        },
        (row) => row.cpuPercent,
      ),
      figure(
        ContainerColumn.memory,
        (row) => switch (row.memoryUsed) {
          // IEC units (03 §10.10).
          final bytes? => ghostFormatBinarySize(bytes),
          null => null,
        },
        (row) => row.memoryUsed,
      ),
    ];
  }
}

/// The columns whose largest values matter, which start descending.
const _firstDirection = {ContainerColumn.cpu, ContainerColumn.memory};

/// The key tests find a phone row by, in the table rows' form.
String _phoneRowKey(ContainerListEntry entry) =>
    '${DockerWatchList.containers.name}.row.${_rowKey(entry)}';

/// A row's identity: a container's id, or a heading's project.
Object _rowKey(ContainerListEntry entry) => switch (entry) {
  ContainerEntry(:final container) => container.id,
  ContainerGroupEntry(:final project) => 'group.${project ?? ''}',
};

String _label(AppLocalizations l10n, ContainerColumn column) =>
    switch (column) {
      ContainerColumn.name => l10n.dockerContainersColumnName,
      ContainerColumn.state => l10n.dockerContainersColumnState,
      ContainerColumn.health => l10n.dockerContainersColumnHealth,
      ContainerColumn.status => l10n.dockerContainersColumnStatus,
      ContainerColumn.image => l10n.dockerContainersColumnImage,
      ContainerColumn.ports => l10n.dockerContainersColumnPorts,
      ContainerColumn.stack => l10n.dockerContainersColumnStack,
      ContainerColumn.cpu => l10n.dockerContainersColumnCpu,
      ContainerColumn.memory => l10n.dockerContainersColumnMemory,
    };

/// A state in words; one the API does not list reads as the engine gave
/// it, and none as unknown. The Stacks sub-tab's overview shares it.
String containerStateText(AppLocalizations l10n, String? state) {
  if (state == null || state.isEmpty) return l10n.chartUnknownValue;
  return switch (EngineContainerState.of(state)) {
    final known? => l10n.dockerContainerState(known.name),
    null => state,
  };
}

/// The state column's order: [EngineContainerState]'s, then a state the
/// API does not list, then none.
int? _stateRank(String? state) {
  if (state == null || state.isEmpty) return null;
  return EngineContainerState.of(state)?.index ??
      EngineContainerState.values.length;
}

/// The Stack column: the compose project, or a Swarm task's service.
String _stackText(AppLocalizations l10n, ContainerSummary container) {
  if (composeProjectOf(container) case final project?) return project;
  if (swarmServiceOf(container) case final service?) {
    return l10n.dockerContainersSwarmService(service);
  }
  return '';
}

/// A compose project's heading: a chevron that says whether it is
/// folded, its name and its counts, read as one node with its state.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.group});

  final ContainerGroupEntry group;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = group.project ?? l10n.dockerContainersNoStack;
    final summary = l10n.dockerContainersGroupSummary(group.shown, group.up);
    return Semantics(
      label: name,
      value: summary,
      expanded: !group.collapsed,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          spacing: 4,
          children: [
            Icon(
              group.collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 16,
              color: muted,
            ),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A health status as an icon and its word, the unhealthy in the error
/// colour, so colour is never the only cue (A11Y-01); the list's rows and
/// a container's details share it.
class ContainerHealthBadge extends StatelessWidget {
  const ContainerHealthBadge({super.key, required this.health});

  final HealthStatus health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = switch (health) {
      HealthStatus.unhealthy => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(
          switch (health) {
            HealthStatus.healthy => Icons.check_circle_outline,
            HealthStatus.unhealthy => Icons.error_outline,
            HealthStatus.starting => Icons.hourglass_top,
            HealthStatus.none => Icons.remove,
          },
          size: 14,
          color: color,
        ),
        Flexible(
          child: Text(
            l10n.dockerContainerHealth(health.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: health == HealthStatus.unhealthy ? color : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// A stats figure on the end edge; a stale one grey after a history icon
/// (03 §9.5 item 4), so its age is told apart without colour.
class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.stale});

  final String value;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 2,
      children: [
        if (stale) Icon(Icons.history, size: 12, color: muted),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            textAlign: TextAlign.end,
            // Figures line up digit under digit.
            style: theme.textTheme.bodyMedium?.copyWith(
              color: stale ? muted : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The phone list's built running rows, by id in build order, which
/// [onChanged] hears of as they come and go.
final class _BuiltRows {
  _BuiltRows(this.onChanged);

  final VoidCallback onChanged;
  final Map<String, int> _counts = {};

  List<String> get ids => _counts.keys.toList();

  void add(String id) {
    _counts.update(id, (count) => count + 1, ifAbsent: () => 1);
    onChanged();
  }

  void remove(String id) {
    final count = _counts[id];
    if (count == null) return;
    if (count > 1) {
      _counts[id] = count - 1;
    } else {
      _counts.remove(id);
    }
    onChanged();
  }
}

/// Counts [child] among [rows] while it is built.
class _BuiltRow extends StatefulWidget {
  const _BuiltRow({required this.id, required this.rows, required this.child});

  final String id;
  final _BuiltRows rows;
  final Widget child;

  @override
  State<_BuiltRow> createState() => _BuiltRowState();
}

class _BuiltRowState extends State<_BuiltRow> {
  @override
  void initState() {
    super.initState();
    widget.rows.add(widget.id);
  }

  @override
  void didUpdateWidget(_BuiltRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id == widget.id) return;
    oldWidget.rows.remove(oldWidget.id);
    widget.rows.add(widget.id);
  }

  @override
  void dispose() {
    widget.rows.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A state in words beside an icon, read as one node, with the engine's
/// own [detail] under it, never translated, and an optional [action];
/// the Containers and Images sub-tabs share it.
class DockerNotice extends StatelessWidget {
  const DockerNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    final action = this.action;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Icon(icon, size: 18, color: muted),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(text, style: theme.textTheme.bodyMedium),
                    if (detail != null && detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ?action,
      ],
    );
  }
}
