import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, ghostFormatBinarySize, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/container_usage.dart'
    show kMemoryRiskShare, memoryLimitShare;
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
import '../sortable_table.dart';
import 'container_details.dart';
import 'container_logs.dart';
import 'container_terminal.dart' show openContainerShellPage;
import 'containers_view.dart';
import 'docker_cells.dart' show dockerAgeText;

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

/// The selection column's id in the table, beside [ContainerColumn]'s.
const _selectColumnId = 'select';

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
  /// What the clock's listeners hear instead while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The order, search, toggle and folds, which outlive sub-tab switches:
  /// the tab keeps a sub-tab built once opened.
  TableSort _sort = TableSort(
    ContainerColumn.name.name,
    TableSortDirection.ascending,
  );
  final _search = TextEditingController();

  /// The filter field, which `/` in the table focuses (PLT-06).
  final _searchFocus = FocusNode();
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

  /// The server whose container watch this panel holds, if any.
  String? _held;

  /// The running containers on screen, last reported, which a watch that
  /// starts again reads stats for at once.
  List<String> _shown = const [];
  Timer? _settle;

  /// The phone list's running rows that are built, as on screen.
  late final _BuiltRows _builtRows = _BuiltRows(() => _report(_builtRows.ids));

  DockerController get _docker => widget.monitoring.docker;

  /// The columns after the name, as chosen on this device (CTR-08).
  List<ContainerColumn> get _chosen =>
      chosenContainerColumns(widget.monitoring.containerColumns.names);

  Future<void> _chooseColumns() async {
    final chosen = await showDialog<List<ContainerColumn>>(
      context: context,
      builder: (context) => _ColumnsDialog(chosen: _chosen),
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
      _selecting = false;
      _selected.clear();
      _shown = const [];
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
              _selectionBar(l10n, containers),
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
    final allColumns = _columns(l10n, stats, widget.monitoring.clock.value);
    final columns = _shownColumns(allColumns, _chosen);
    final terms = searchTerms(_search.text);
    final selecting = _selecting && _bulkAllowed(context);
    final shown = containersShown(
      containers,
      runningOnly: _runningOnly,
      terms: terms,
    );
    final entries = containerListEntries(
      containers,
      runningOnly: _runningOnly || _top,
      terms: terms,
      collapsed: _collapsed,
      grouping: _top ? ContainerGrouping.flat : ContainerGrouping.byProject,
      // Top ranks by CPU even with its column hidden (CST-05).
      order: (rows) => sortTableRows<ContainerListEntry>(
        rows,
        _top ? allColumns : columns,
        _sort,
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
      return _list(entries, columns, empty, selecting: selecting, shown: shown);
    }

    return SortableTable<ContainerListEntry>(
      tableId: DockerWatchList.containers.name,
      filterFocus: _searchFocus,
      keyActions: _keyActions(l10n),
      columns: [if (selecting) _selectColumn(l10n), ...columns],
      rows: entries,
      rowKey: _rowKey,
      sort: _sort,
      onSort: (sort) => setState(() => _sort = sort),
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
        final ContainerGroupEntry group => _GroupHeading(
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
        run: (entry) => openContainerShellPage(
          context,
          monitoring: widget.monitoring,
          serverId: widget.serverId,
          container: containerOf(entry)!,
        ),
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
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
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
            _sort = TableSort(
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

  /// The bulk bar (CTR-07): how many are selected, a button per verb
  /// naming how many of them it takes, and select-all and clear.
  Widget _selectionBar(
    AppLocalizations l10n,
    List<ContainerSummary> containers,
  ) {
    final selected = [
      for (final container in containers)
        if (_selected.contains(container.id)) container,
    ];
    final shown = containersShown(
      containers,
      runningOnly: _runningOnly,
      terms: searchTerms(_search.text),
    );
    final tooMany = selected.length > kContainerBulkMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l10n.dockerContainersSelectedCount(selected.length)),
            for (final verb in ContainerBulkVerb.values)
              if (actionsAllowedAt(
                context,
                widget.serverId,
                verb == ContainerBulkVerb.remove
                    ? ActionEntryPoint.containerRemove
                    : ActionEntryPoint.containerVerb,
              ))
                switch (bulkTargets(selected, verb)) {
                  final ids => OutlinedButton(
                    onPressed: ids.isEmpty || tooMany
                        ? null
                        : () => startAction(
                            context,
                            ContainerBulkAction(
                              widget.serverId,
                              containerIds: ids,
                              verb: verb,
                            ),
                          ),
                    child: Text(
                      l10n.dockerContainersBulkVerb(verb.name, ids.length),
                    ),
                  ),
                },
            TextButton(
              onPressed: shown.every((c) => _selected.contains(c.id))
                  ? null
                  : () => setState(
                      () => _selected.addAll(shown.map((c) => c.id)),
                    ),
              child: Text(l10n.dockerContainersSelectAll),
            ),
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => setState(_selected.clear),
              child: Text(l10n.dockerContainersSelectNone),
            ),
          ],
        ),
        if (tooMany)
          DockerNotice(
            icon: Icons.info_outline,
            text: l10n.dockerContainersBulkMax(kContainerBulkMax),
          ),
      ],
    );
  }

  /// The table's checkbox column while selecting; it reads as whether the
  /// row is selected.
  SortableTableColumn<ContainerListEntry> _selectColumn(
    AppLocalizations l10n,
  ) => SortableTableColumn(
    id: _selectColumnId,
    label: l10n.dockerContainersColumnSelect,
    text: (entry) => switch (entry) {
      ContainerEntry(:final container) => l10n.dockerContainersRowSelected(
        _selected.contains(container.id).toString(),
      ),
      ContainerGroupEntry() => '',
    },
    extent: const FixedColumnExtent(64),
    cell: (context, entry) => switch (entry) {
      ContainerEntry(:final container) => Checkbox(
        value: _selected.contains(container.id),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: (_) => _toggleSelected(container.id),
      ),
      ContainerGroupEntry() => const SizedBox.shrink(),
    },
  );

  /// The phone layout's order: the table's sortable columns in a menu,
  /// and the direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final shown = [ContainerColumn.name, ..._chosen];
    final column = switch (ContainerColumn.values.asNameMap()[_sort.columnId]) {
      final sorted? when shown.contains(sorted) => sorted,
      _ => ContainerColumn.name,
    };
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
            for (final choice in shown)
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
    Widget empty, {
    required bool selecting,
    required List<ContainerSummary> shown,
  }) {
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
          final selected = selecting
              ? _projectSelection(group.project, shown)
              : false;
          return Semantics(
            key: ValueKey(_phoneRowKey(group)),
            container: true,
            button: true,
            onTap: () => _toggle(group.project),
            customSemanticsActions: selecting
                ? {
                    CustomSemanticsAction(
                      label: selected ?? false
                          ? l10n.dockerContainersDeselectProject
                          : l10n.dockerContainersSelectProject,
                    ): () =>
                        _toggleProject(group.project, shown),
                  }
                : null,
            child: InkWell(
              excludeFromSemantics: true,
              onTap: () => _toggle(group.project),
              child: ConstrainedBox(
                // A touch needs a 48 dp target (A11Y-01).
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: _GroupHeading(
                  group: group,
                  selection: selecting
                      ? (
                          selected: selected,
                          onToggle: () => _toggleProject(group.project, shown),
                        )
                      : null,
                ),
              ),
            ),
          );
        }

        final container = (entry as ContainerEntry).container;
        final checked = _selected.contains(container.id);
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
          checked: selecting ? checked : null,
          excludeSemantics: true,
          onTap: selecting
              ? () => _toggleSelected(container.id)
              : () => _open(container),
          child: InkWell(
            excludeFromSemantics: true,
            onTap: selecting
                ? () => _toggleSelected(container.id)
                : () => _open(container),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: _Selectable(
                checked: selecting ? checked : null,
                onChanged: () => _toggleSelected(container.id),
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
      Comparable<Object>? Function(ContainerListStats stats) sortKey, {
      double width = 88,
      bool Function(ContainerListStats stats)? risky,
    }) {
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
        extent: FixedColumnExtent(width),
        alignment: CellAlignment.end,
        cell: (context, container) => switch (read(container)) {
          null => const SizedBox.shrink(),
          (final value, final stale) => _Figure(
            value: value,
            stale: stale,
            risky: switch (stats[container.id]) {
              final row? => risky?.call(row) ?? false,
              null => false,
            },
          ),
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
        (container) => containerStateFlagText(l10n, container),
        (container) => _stateRank(container.state),
        extent: const FixedColumnExtent(88),
        // The flag's icon sits in the wider Status cell, so "Restarting"
        // keeps its room here.
        cell: (context, container) =>
            ContainerStateBadge(container: container, icon: false),
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
        cell: (context, container) => _StatusCell(
          text: containerStatusText(container) ?? unknown,
          flag: containerFlagOf(container),
        ),
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
        (row) => switch ((row.memoryUsed, memoryLimitShare(row))) {
          // IEC units (03 §10.10); near its limit, its share of it (CST-04).
          (_?, final share?) when share >= kMemoryRiskShare =>
            l10n.dockerContainersMemoryRisk(share),
          (final bytes?, _) => ghostFormatBinarySize(bytes),
          (null, _) => null,
        },
        (row) => row.memoryUsed,
        risky: (row) => (memoryLimitShare(row) ?? 0) >= kMemoryRiskShare,
      ),
      figure(
        ContainerColumn.network,
        (row) => _ioText(l10n, row.networkRx, row.networkTx),
        (row) => _ioTotal(row.networkRx, row.networkTx),
        width: 152,
      ),
      figure(
        ContainerColumn.blockIo,
        (row) => _ioText(l10n, row.blockRead, row.blockWrite),
        (row) => _ioTotal(row.blockRead, row.blockWrite),
        width: 152,
      ),
      figure(
        ContainerColumn.pids,
        (row) => row.pids?.toString(),
        (row) => row.pids,
        width: 64,
      ),
      column(
        ContainerColumn.ip,
        (container) => containerIpOf(container) ?? '',
        containerIpOf,
        extent: const FixedColumnExtent(120),
      ),
      column(
        ContainerColumn.started,
        (container) => switch (containerUptime(container)) {
          final uptime? => dockerAgeText(l10n, uptime),
          null => '',
        },
        // The latest start first when ascending, as the uptime is least.
        (container) => containerUptime(container)?.inSeconds,
        extent: const FixedColumnExtent(120),
      ),
    ];
  }

  /// The columns shown, the name first, then [chosen]'s in order.
  List<SortableTableColumn<ContainerListEntry>> _shownColumns(
    List<SortableTableColumn<ContainerListEntry>> all,
    List<ContainerColumn> chosen,
  ) {
    final byId = {for (final column in all) column.id: column};
    return [
      byId[ContainerColumn.name.name]!,
      for (final column in chosen) byId[column.name]!,
    ];
  }
}

/// The columns whose largest values matter, which start descending.
const _firstDirection = {
  ContainerColumn.cpu,
  ContainerColumn.memory,
  ContainerColumn.network,
  ContainerColumn.blockIo,
  ContainerColumn.pids,
};

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
      ContainerColumn.network => l10n.dockerContainersColumnNetwork,
      ContainerColumn.blockIo => l10n.dockerContainersColumnBlockIo,
      ContainerColumn.pids => l10n.dockerContainersColumnPids,
      ContainerColumn.ip => l10n.dockerContainersColumnIp,
      ContainerColumn.started => l10n.dockerContainersColumnStarted,
    };

/// A pair of byte totals as `docker stats` shows them, in then out, or
/// read then written, in IEC units (03 §10.10); null when both are
/// unknown.
String? _ioText(AppLocalizations l10n, int? first, int? second) {
  if (first == null && second == null) return null;
  String size(int? bytes) =>
      bytes == null ? l10n.chartUnknownValue : ghostFormatBinarySize(bytes);
  return l10n.dockerContainersIo(size(first), size(second));
}

int? _ioTotal(int? first, int? second) =>
    first == null && second == null ? null : (first ?? 0) + (second ?? 0);

/// A state in words; one the API does not list reads as the engine gave
/// it, and none as unknown. The Stacks sub-tab's overview shares it.
String containerStateText(AppLocalizations l10n, String? state) {
  if (state == null || state.isEmpty) return l10n.chartUnknownValue;
  return switch (EngineContainerState.of(state)) {
    final known? => l10n.dockerContainerState(known.name),
    null => state,
  };
}

/// [container]'s state in words, with its CTR-09 flag when it has one:
/// "Restarting (restart loop)", "Exited (failed)".
String containerStateFlagText(
  AppLocalizations l10n,
  ContainerSummary container,
) {
  final state = containerStateText(l10n, container.state);
  return switch (containerFlagOf(container)) {
    final flag? => l10n.dockerContainerStateFlagged(state, flag.name),
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
  const _GroupHeading({required this.group, this.selection});

  final ContainerGroupEntry group;

  /// While selecting (CTR-07): whether its containers are all, none or
  /// some (null) selected, and what its checkbox does.
  final ({bool? selected, VoidCallback onToggle})? selection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = group.project ?? l10n.dockerContainersNoStack;
    final summary = l10n.dockerContainersGroupSummary(group.shown, group.up);
    final selection = this.selection;
    return Semantics(
      label: name,
      value: switch (selection?.selected) {
        _ when selection == null => summary,
        final selected => l10n.dockerContainersGroupSelection(
          summary,
          _GroupSelection.of(selected).name,
        ),
      },
      expanded: !group.collapsed,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          spacing: 4,
          children: [
            if (selection != null)
              Checkbox(
                tristate: true,
                value: selection.selected,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                // A tap on a partly selected heading selects them all.
                onChanged: (_) => selection.onToggle(),
              ),
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

/// CTR-08's chooser: every column but the name, the shown ones checked
/// and first in their order, the rest after; drag to reorder. Done
/// answers the checked ones in order, Reset the default.
class _ColumnsDialog extends StatefulWidget {
  const _ColumnsDialog({required this.chosen});

  final List<ContainerColumn> chosen;

  @override
  State<_ColumnsDialog> createState() => _ColumnsDialogState();
}

class _ColumnsDialogState extends State<_ColumnsDialog> {
  late List<ContainerColumn> _order = _ordered(widget.chosen);
  late Set<ContainerColumn> _shown = {...widget.chosen};

  static List<ContainerColumn> _ordered(List<ContainerColumn> chosen) => [
    ...chosen,
    for (final column in ContainerColumn.chooseable)
      if (!chosen.contains(column)) column,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.dockerContainersColumnsTitle),
      content: SizedBox(
        width: 320,
        child: ReorderableListView(
          shrinkWrap: true,
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => setState(() {
            _order.insert(to, _order.removeAt(from));
          }),
          children: [
            for (final (index, column) in _order.indexed)
              CheckboxListTile(
                key: ValueKey(column),
                value: _shown.contains(column),
                title: Text(_label(l10n, column)),
                controlAffinity: ListTileControlAffinity.leading,
                secondary: ReorderableDragStartListener(
                  index: index,
                  child: Tooltip(
                    message: l10n.dockerContainersColumnsDrag,
                    child: const Icon(Icons.drag_handle),
                  ),
                ),
                onChanged: (shown) => setState(() {
                  if (shown ?? false) {
                    _shown.add(column);
                  } else {
                    _shown.remove(column);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _order = _ordered(kDefaultContainerColumns);
            _shown = {...kDefaultContainerColumns};
          }),
          child: Text(l10n.dockerContainersColumnsReset),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.dockerContainersColumnsCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, [
            for (final column in _order)
              if (_shown.contains(column)) column,
          ]),
          child: Text(l10n.dockerContainersColumnsDone),
        ),
      ],
    );
  }
}

/// How much of a heading's group is selected, as its words name it.
enum _GroupSelection {
  all,
  some,
  none;

  static _GroupSelection of(bool? selected) => switch (selected) {
    true => all,
    false => none,
    null => some,
  };
}

/// [child] after a checkbox while selecting ([checked] not null), which
/// the row's own semantics name, so the box adds no node.
class _Selectable extends StatelessWidget {
  const _Selectable({
    required this.checked,
    required this.onChanged,
    required this.child,
  });

  final bool? checked;
  final VoidCallback onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final checked = this.checked;
    if (checked == null) return child;

    return Row(
      spacing: 8,
      children: [
        Checkbox(value: checked, onChanged: (_) => onChanged()),
        Expanded(child: child),
      ],
    );
  }
}

/// A container's state in words, after an icon in the error colour when
/// CTR-09 flags it (a restart loop, a failed exit), so colour is never
/// the only cue (A11Y-01); the tooltip says why. The list's rows and a
/// stack's share it.
class ContainerStateBadge extends StatelessWidget {
  const ContainerStateBadge({
    super.key,
    required this.container,
    this.style,
    this.icon = true,
  });

  final ContainerSummary container;

  /// Whether the flag's icon leads the words; the table puts it in the
  /// row's Status cell instead.
  final bool icon;

  /// The words' style; the body text's by default.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = this.style ?? theme.textTheme.bodyMedium;
    final words = containerStateText(l10n, container.state);
    final flag = containerFlagOf(container);
    if (flag == null) {
      return Text(
        words,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      );
    }

    final error = theme.colorScheme.error;
    if (!icon) {
      return Tooltip(
        message: l10n.dockerContainerFlagTooltip(
          flag.name,
          containerExitCode(container) ?? 0,
        ),
        child: Text(
          words,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: style?.copyWith(color: error),
        ),
      );
    }
    return Tooltip(
      message: l10n.dockerContainerFlagTooltip(
        flag.name,
        containerExitCode(container) ?? 0,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Icon(
            switch (flag) {
              ContainerFlag.restartLoop => Icons.loop,
              ContainerFlag.failed => Icons.error_outline,
            },
            size: 14,
            color: error,
          ),
          Flexible(
            child: Text(
              words,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: style?.copyWith(color: error),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Status column's text, after the CTR-09 flag's icon in the error
/// colour when the row has one.
class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.text, required this.flag});

  final String text;
  final ContainerFlag? flag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flag = this.flag;
    return Row(
      spacing: 4,
      children: [
        if (flag != null)
          Icon(
            switch (flag) {
              ContainerFlag.restartLoop => Icons.loop,
              ContainerFlag.failed => Icons.error_outline,
            },
            size: 14,
            color: theme.colorScheme.error,
          ),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// A stats figure on the end edge; a stale one grey after a history icon
/// (03 §9.5 item 4), so its age is told apart without colour.
class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.stale, this.risky = false});

  final String value;
  final bool stale;

  /// Near a limit (CST-04): after a warning icon, in the error colour.
  final bool risky;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 2,
      children: [
        if (stale) Icon(Icons.history, size: 12, color: muted),
        if (risky && !stale)
          Icon(Icons.warning_amber, size: 12, color: theme.colorScheme.error),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            textAlign: TextAlign.end,
            // Figures line up digit under digit.
            style: theme.textTheme.bodyMedium?.copyWith(
              color: stale
                  ? muted
                  : risky
                  ? theme.colorScheme.error
                  : null,
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
