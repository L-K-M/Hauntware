import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/action_preview.dart' show startAction;
import '../actions/docker_actions.dart'
    show
        ContainerOffer,
        PruneButton,
        containerActionEntries,
        containerIntent,
        containerOffers;
import '../panel_kit.dart';
import '../sortable_table.dart';
import '../workspace_dock.dart' show DockedShell, WorkspaceDockScope;
import 'container_columns.dart';
import 'container_details.dart';
import 'container_logs.dart';
import 'container_selection.dart';
import 'container_terminal.dart' show openContainerShellPage;
import 'containers_list.dart';
import 'containers_view.dart';
import 'docker_list_state.dart';
import 'docker_notice.dart';

/// How long the rows on screen hold still before their ids go to the
/// watch, so a scroll sends one [DockerWatch] when it settles rather than
/// one per row it passes.
const Duration kStatsForSettle = Duration(milliseconds: 250);

/// The Containers sub-tab (03 §7.12 CTR-01, CTR-04, CST-01): every
/// container by name, state, health, the engine's status (its uptime),
/// image, ports, compose project, CPU and memory, grouped by compose
/// project under headings that fold, with a running-only toggle and a
/// search by name, image or ID. Where actions are allowed, Select puts a
/// checkbox on each row and heading (CTR-07): a heading's selects its
/// project's containers, and the bar above the list starts, stops,
/// restarts or removes the selected ones that take the verb, as one
/// [ContainerBulkAction].
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
  /// The order, search and watch, which outlive sub-tab switches: the
  /// tab keeps a sub-tab built once opened.
  late final DockerListState _state = DockerListState(
    initialSort: TableSort(
      ContainerColumn.name.name,
      TableSortDirection.ascending,
    ),
    watch: (serverId) => _docker.watchContainers(serverId, statsFor: _shown),
    unwatch: _docker.unwatchContainers,
    onRelease: _cancelSettle,
    onServerChanged: _forgetServer,
  );

  bool _runningOnly = false;

  /// CST-05's Top view: the running containers in one list, the busiest
  /// first, as ctop ranks them.
  bool _top = false;
  final Set<String?> _collapsed = {};

  /// CTR-07's selection: whether the rows carry checkboxes, and the
  /// containers checked, by id. An id whose container is gone is
  /// ignored.
  bool _selecting = false;
  final Set<String> _selected = {};

  /// The running containers on screen, last reported, which a watch that
  /// starts again reads stats for at once.
  List<String> _shown = const [];
  Timer? _settle;

  /// The phone list's running rows that are built, as on screen.
  late final BuiltRows _builtRows = BuiltRows(() => _report(_builtRows.ids));

  DockerController get _docker => widget.monitoring.docker;

  /// The columns after the name, as chosen on this device (CTR-08).
  List<ContainerColumn> get _chosen =>
      chosenContainerColumns(widget.monitoring.containerColumns.names);

  Future<void> _chooseColumns() async {
    final chosen = await showDialog<List<ContainerColumn>>(
      context: context,
      builder: (context) => ColumnsDialog(chosen: _chosen),
    );
    if (chosen == null || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    try {
      await widget.monitoring.containerColumns.setNames([
        for (final column in chosen) column.name,
      ]);
    } on Object {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.dockerContainersColumnsNotSaved)),
      );
    }
  }

  /// Drops what another server's selection left behind.
  void _forgetServer() {
    _collapsed.clear();
    _selecting = false;
    _selected.clear();
    _shown = const [];
  }

  void _cancelSettle() {
    _settle?.cancel();
    _settle = null;
  }

  @override
  void initState() {
    super.initState();
    _state.sync(visible: widget.visible, serverId: widget.serverId);
  }

  @override
  void didUpdateWidget(ContainersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _state.sync(visible: widget.visible, serverId: widget.serverId);
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  /// Takes [ids], the running containers on screen, and sends them once
  /// they hold still for [kStatsForSettle].
  void _report(List<String> ids) {
    _shown = ids;
    final held = _state.held;
    if (held == null) return;

    _settle?.cancel();
    _settle = Timer(kStatsForSettle, () {
      final held = _state.held;
      if (held != null) _docker.showStatsFor(held, _shown);
    });
  }

  void _toggle(String? project) => setState(() {
    if (!_collapsed.remove(project)) _collapsed.add(project);
  });

  void _toggleSelected(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  /// Selects [project]'s containers among [shown], or clears them when
  /// all are selected already.
  void _toggleProject(String? project, List<ContainerSummary> shown) {
    final ids = [
      for (final container in shown)
        if (composeProjectOf(container) == project) container.id,
    ];
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  /// Whether every one of [project]'s containers among [shown] is
  /// selected (true), none is (false), or some are (null).
  bool? _projectSelection(String? project, List<ContainerSummary> shown) {
    final ids = [
      for (final container in shown)
        if (composeProjectOf(container) == project) container.id,
    ];
    final count = ids.where(_selected.contains).length;
    if (count == 0) return false;
    return count == ids.length ? true : null;
  }

  bool _bulkAllowed(BuildContext context) =>
      actionsAllowedAt(
        context,
        widget.serverId,
        ActionEntryPoint.containerVerb,
      ) ||
      actionsAllowedAt(
        context,
        widget.serverId,
        ActionEntryPoint.containerRemove,
      );

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
      listenable: Listenable.merge([
        list,
        endpoint,
        widget.monitoring.containerColumns,
      ]),
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
        : kSilentListenable;

    return LayoutBuilder(
      builder: (context, box) {
        final wide = panelIsWide(context, box);
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
            if (containers != null &&
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
                      kind: DockerPruneKind.containers,
                    ),
                  ],
                ),
              ),
            if (containers != null) _filters(l10n),
            if (containers != null && _selecting && _bulkAllowed(context))
              SelectionBar(
                containers: containers,
                shown: _shownContainers(containers),
                selected: _selected,
                serverId: widget.serverId,
                onSelectAll: (ids) => setState(() => _selected.addAll(ids)),
                onClear: () => setState(_selected.clear),
              ),
            if (containers != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (containers == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        return Padding(
          padding: padding,
          child: HeadedPanelBody(
            header: header,
            // Only the stats age with the clock.
            body: ListenableBuilder(
              listenable: clock,
              builder: (context, _) =>
                  _body(context, containers, list.stats, wide: wide),
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
    final allColumns = containerTableColumns(
      l10n,
      stats,
      widget.monitoring.clock.value,
    );
    final tableColumns = shownContainerColumns(allColumns, _chosen);
    final terms = searchTerms(_state.search.text);
    final selecting = _selecting && _bulkAllowed(context);
    final shown = _shownContainers(containers);
    final entries = containerListEntries(
      containers,
      runningOnly: _runningOnly || _top,
      terms: terms,
      collapsed: _collapsed,
      grouping: _top ? ContainerGrouping.flat : ContainerGrouping.byProject,
      // Top ranks by CPU even with its column hidden (CST-05).
      order: (rows) => sortTableRows<ContainerListEntry>(
        rows,
        _top ? allColumns : tableColumns,
        _state.sort,
      ).cast(),
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
    if (!wide) {
      return ContainersList(
        entries: entries,
        columns: tableColumns,
        empty: empty,
        selecting: selecting,
        shown: shown,
        selected: _selected,
        builtRows: _builtRows,
        projectSelection: _projectSelection,
        onToggleProject: _toggleProject,
        onToggle: _toggle,
        onOpen: _open,
        onToggleSelected: _toggleSelected,
        onReportEmpty: () => _report(const []),
      );
    }

    return SortableTable<ContainerListEntry>(
      tableId: DockerWatchList.containers.name,
      filterFocus: _state.searchFocus,
      keyActions: _keyActions(l10n),
      columns: [
        if (selecting) containerSelectColumn(l10n, _selected, _toggleSelected),
        ...tableColumns,
      ],
      rows: entries,
      rowKey: containerRowKey,
      sort: _state.sort,
      onSort: (sort) => setState(() => _state.sort = sort),
      rowOrder: TableRowOrder.asGiven,
      // A heading folds; a container opens its details, or while
      // selecting, is checked or unchecked.
      onRowActivated: (entry) => switch (entry) {
        ContainerGroupEntry(:final project) => _toggle(project),
        ContainerEntry(:final container) when selecting => _toggleSelected(
          container.id,
        ),
        ContainerEntry(:final container) => _open(container),
      },
      rowActions: (entry) => switch (entry) {
        ContainerGroupEntry(:final project) when selecting => [
          SidebarMenuAction(
            label: _projectSelection(project, shown) ?? false
                ? l10n.dockerContainersDeselectProject
                : l10n.dockerContainersSelectProject,
            onSelected: () => _toggleProject(project, shown),
          ),
        ],
        ContainerGroupEntry() => const [],
        ContainerEntry(:final container) => [
          if (selecting)
            SidebarMenuAction(
              label: _selected.contains(container.id)
                  ? l10n.dockerContainersDeselect
                  : l10n.dockerContainersSelectOne,
              onSelected: () => _toggleSelected(container.id),
            ),
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
        final ContainerGroupEntry group => GroupHeading(
          group: group,
          selection: selecting
              ? (
                  selected: _projectSelection(group.project, shown),
                  onToggle: () => _toggleProject(group.project, shown),
                )
              : null,
        ),
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

  /// The table's single-key verbs (PLT-06, 03 §10.6) on a container
  /// row: `l` its logs, `s` a shell in it while it runs, `r` a restart
  /// through the action's confirmation; each only where its menu verb
  /// would be allowed.
  List<TableKeyAction<ContainerListEntry>> _keyActions(AppLocalizations l10n) {
    ContainerSummary? containerOf(ContainerListEntry entry) => switch (entry) {
      ContainerEntry(:final container) => container,
      ContainerGroupEntry() => null,
    };
    return [
      TableKeyAction(
        key: LogicalKeyboardKey.keyL,
        label: l10n.keyActionLogs,
        appliesTo: (entry) => containerOf(entry) != null,
        run: (entry) => openContainerLogs(
          context,
          monitoring: widget.monitoring,
          serverId: widget.serverId,
          container: containerOf(entry)!,
        ),
      ),
      TableKeyAction(
        key: LogicalKeyboardKey.keyS,
        label: l10n.keyActionShell,
        appliesTo: (entry) => switch (containerOf(entry)) {
          final container? =>
            containerIsUp(container) &&
                actionsAllowedAt(
                  context,
                  widget.serverId,
                  ActionEntryPoint.containerShell,
                ),
          null => false,
        },
        run: (entry) {
          final container = containerOf(entry)!;
          // The desktop dock (OV-10) holds a shell, as the inspector's
          // shell button does; elsewhere it opens on a page.
          if (WorkspaceDockScope.maybeOf(context) case final dock?) {
            dock.show(DockedShell(widget.serverId, container));
            return;
          }
          openContainerShellPage(
            context,
            monitoring: widget.monitoring,
            serverId: widget.serverId,
            container: container,
          );
        },
      ),
      TableKeyAction(
        key: LogicalKeyboardKey.keyR,
        label: l10n.keyActionRestart,
        appliesTo: (entry) => switch (containerOf(entry)) {
          final container? =>
            containerOffers(container.state).contains(ContainerOffer.restart) &&
                actionsAllowedAt(
                  context,
                  widget.serverId,
                  ActionEntryPoint.containerVerb,
                ),
          null => false,
        },
        run: (entry) => startAction(
          context,
          containerIntent(
            widget.serverId,
            containerOf(entry)!.id,
            ContainerOffer.restart,
          ),
        ),
      ),
    ];
  }

  Widget _filters(AppLocalizations l10n) => Wrap(
    spacing: 12,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      DockerListSearchField(
        controller: _state.search,
        focusNode: _state.searchFocus,
        hint: l10n.dockerContainersSearchHint,
        clearTooltip: l10n.dockerContainersSearchClear,
        onChanged: () => setState(() {}),
      ),
      FilterChip(
        label: Text(l10n.dockerContainersRunningOnly),
        selected: _runningOnly || _top,
        onSelected: _top
            ? null
            : (selected) => setState(() => _runningOnly = selected),
      ),
      FilterChip(
        avatar: const Icon(Icons.leaderboard_outlined),
        label: Text(l10n.dockerContainersTop),
        tooltip: l10n.dockerContainersTopTooltip,
        selected: _top,
        onSelected: (top) => setState(() {
          _top = top;
          if (top) {
            _state.sort = TableSort(
              ContainerColumn.cpu.name,
              TableSortDirection.descending,
            );
          }
        }),
      ),
      TextButton.icon(
        onPressed: _chooseColumns,
        icon: const Icon(Icons.view_column_outlined),
        label: Text(l10n.dockerContainersColumns),
      ),
      if (_bulkAllowed(context))
        FilterChip(
          avatar: const Icon(Icons.checklist),
          label: Text(l10n.dockerContainersSelect),
          selected: _selecting,
          onSelected: (selecting) => setState(() {
            _selecting = selecting;
            if (!selecting) _selected.clear();
          }),
        ),
    ],
  );

  /// The phone layout's order: the table's sortable columns in a menu,
  /// and the direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final shown = [ContainerColumn.name, ..._chosen];
    final current = ContainerColumn.values.asNameMap()[_state.sort.columnId];
    final column = switch (current) {
      final sorted? when shown.contains(sorted) => sorted,
      _ => ContainerColumn.name,
    };
    final ascending = _state.sort.direction == TableSortDirection.ascending;
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
            for (final choice in shown)
              DropdownMenuItem(
                value: choice,
                child: Text(containerColumnLabel(l10n, choice)),
              ),
          ],
          onChanged: (choice) {
            if (choice == null) return;
            setState(
              () => _state.sort = TableSort(
                choice.name,
                descendingFirstColumns.contains(choice)
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
            () => _state.sort = TableSort(
              _state.sort.columnId,
              ascending
                  ? TableSortDirection.descending
                  : TableSortDirection.ascending,
            ),
          ),
        ),
      ],
    );
  }

  /// The containers the list shows, which Select all and the project
  /// toggles act on. The Top view lists running containers only, whatever
  /// the running filter says, so a selection never takes one it hides.
  List<ContainerSummary> _shownContainers(List<ContainerSummary> containers) =>
      containersShown(
        containers,
        runningOnly: _runningOnly || _top,
        terms: searchTerms(_state.search.text),
      );
}
