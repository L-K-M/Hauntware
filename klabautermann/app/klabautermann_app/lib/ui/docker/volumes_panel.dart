import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show CreateVolumeButton, VolumeActionsButton, volumeActionEntries;
import '../sortable_table.dart';
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show searchTerms;
import 'docker_cells.dart';
import 'volumes_view.dart';

/// The panel width from which the volumes show as the sortable table;
/// narrower, as on a phone, they show as two-line rows. It grows with the
/// text scale, as the Images sub-tab's does.
const double _wideWidth = 600;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

/// The Volumes sub-tab (03 §7.15 VOL-01): every volume by name, its
/// driver, age and date of creation, and how many containers mount it,
/// with a filter for the unused ones and a search by name or driver.
/// Where actions are allowed, a volume is created over the list and
/// removed from its row (VOL-02).
///
/// While [visible], it holds the server's volume watch
/// ([DockerController.watchVolumes]), which reads the containers too:
/// their mounts tell which volumes are in use ([containersByVolume]).
/// Hidden, it lets the watch go. A failed read keeps the last list under
/// why it failed. The ages follow the monitoring clock while the tab
/// shows.
class VolumesPanel extends StatefulWidget {
  const VolumesPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<VolumesPanel> createState() => _VolumesPanelState();
}

class _VolumesPanelState extends State<VolumesPanel> {
  /// What the clock's listeners hear instead while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The order, search and filter, which outlive sub-tab switches: the
  /// tab keeps a sub-tab built once opened.
  TableSort _sort = TableSort(
    VolumeColumn.name.name,
    TableSortDirection.ascending,
  );
  final _search = TextEditingController();
  VolumeFilter _filter = VolumeFilter.all;

  /// The server whose volume watch this panel holds, if any.
  String? _held;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(VolumesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      // Another server's volumes.
      _release();
      _search.clear();
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

    _docker.watchVolumes(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchVolumes(held);
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final volumes = _docker.volumesFor(widget.serverId);
    final containers = _docker.containersFor(widget.serverId);
    final endpoint = _docker.endpointFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([volumes, containers, endpoint]),
      builder: (context, _) =>
          _build(context, volumes.value, containers.value, endpoint.value),
    );
  }

  Widget _build(
    BuildContext context,
    DockerVolumeList list,
    DockerContainerList containers,
    DockerEndpointState? endpoint,
  ) {
    final l10n = AppLocalizations.of(context);
    final volumes = list.volumes;
    final failure = list.failure;
    final clock = widget.visible && (volumes?.isNotEmpty ?? false)
        ? widget.monitoring.clock
        : _silent;
    // The volume list carries no count, so without a container list the
    // use is unknown.
    final useUnknown =
        containers.containers == null &&
        containers.failure != null &&
        (volumes?.isNotEmpty ?? false);

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
                text: l10n.dockerVolumesFailed(failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: () => _docker.retryVolumes(widget.serverId),
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (volumes != null)
                DockerNotice(icon: Icons.history, text: l10n.dockerImagesKept),
            ] else if (volumes == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: l10n.dockerVolumesReading,
              ),
            if (useUnknown)
              DockerNotice(
                icon: Icons.error_outline,
                text: l10n.dockerVolumesUseUnknown,
                detail: containers.failure?.detail,
              ),
            if (volumes != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: CreateVolumeButton(serverId: widget.serverId),
              ),
            if (volumes != null) _filters(l10n),
            if (volumes != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (volumes == null) {
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
                  // Only the ages move with the clock.
                  child: ListenableBuilder(
                    listenable: clock,
                    builder: (context, _) => _body(
                      context,
                      volumes,
                      containers.containers,
                      wide: wide,
                    ),
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
    List<VolumeSummary> volumes,
    List<ContainerSummary>? containers, {
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final columns = _columns(l10n, widget.monitoring.clock.value);
    final terms = searchTerms(_search.text);
    final entries = volumeEntries(
      volumes,
      containers: containers,
      filter: _filter,
      terms: terms,
    );
    final empty = Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        volumes.isEmpty
            ? l10n.dockerVolumesEmpty
            : terms.isNotEmpty
            ? l10n.dockerVolumesNoMatch
            : switch (_filter) {
                VolumeFilter.unused => l10n.dockerVolumesNoneUnused,
                // Every volume passes; the engine listed none.
                VolumeFilter.all => l10n.dockerVolumesEmpty,
              },
      ),
    );
    if (!wide) {
      return _list(sortTableRows(entries, columns, _sort), columns, empty);
    }

    return SortableTable<VolumeEntry>(
      tableId: DockerWatchList.volumes.name,
      columns: columns,
      rows: entries,
      rowKey: _rowKey,
      sort: _sort,
      onSort: (sort) => setState(() => _sort = sort),
      rowActions:
          actionsAllowedAt(
            context,
            widget.serverId,
            ActionEntryPoint.volumeRemove,
          )
          ? (entry) => volumeActionEntries(
              context,
              serverId: widget.serverId,
              entry: entry,
            )
          : null,
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
            hintText: l10n.dockerVolumesSearchHint,
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
          for (final filter in VolumeFilter.values)
            ChoiceChip(
              label: Text(switch (filter) {
                VolumeFilter.all => l10n.dockerImagesFilterAll,
                VolumeFilter.unused => l10n.dockerImagesFilterUnused,
              }),
              selected: _filter == filter,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
    ],
  );

  /// The phone layout's order: the table's columns in a menu, and the
  /// direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = VolumeColumn.values.byName(_sort.columnId);
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
        DropdownButton<VolumeColumn>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in VolumeColumn.values)
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
                choice == VolumeColumn.created
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
    List<VolumeEntry> entries,
    List<SortableTableColumn<VolumeEntry>> columns,
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
                Text(
                  entry.volume.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
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
            VolumeActionsButton(serverId: widget.serverId, entry: entry),
          ],
        );
      },
    );
  }

  List<SortableTableColumn<VolumeEntry>> _columns(
    AppLocalizations l10n,
    DateTime now,
  ) {
    final unknown = l10n.chartUnknownValue;

    /// [entry]'s age in words and its date, or null when unknown.
    (String, String)? created(VolumeEntry entry) {
      final at = entry.volume.createdAt;
      if (at == null) return null;
      return (
        dockerAgeText(l10n, now.difference(at)),
        l10n.dockerImagesDate(at.toLocal()),
      );
    }

    return [
      SortableTableColumn(
        id: VolumeColumn.name.name,
        label: _label(l10n, VolumeColumn.name),
        text: (entry) => entry.volume.name,
        sortKey: (entry) => entry.volume.name.toLowerCase(),
        extent: const FlexColumnExtent(3),
      ),
      SortableTableColumn(
        id: VolumeColumn.driver.name,
        label: _label(l10n, VolumeColumn.driver),
        text: (entry) => entry.volume.driver ?? unknown,
        sortKey: (entry) => entry.volume.driver?.toLowerCase(),
        extent: const FixedColumnExtent(120),
      ),
      SortableTableColumn(
        id: VolumeColumn.created.name,
        label: _label(l10n, VolumeColumn.created),
        text: (entry) => switch (created(entry)) {
          (final age, final date) => l10n.dockerImagesCreated(age, date),
          null => unknown,
        },
        sortKey: (entry) => entry.volume.createdAt?.millisecondsSinceEpoch,
        firstDirection: TableSortDirection.descending,
        extent: const FlexColumnExtent(2),
        cell: (context, entry) => switch (created(entry)) {
          (final age, final date) => DockerCreatedCell(age: age, date: date),
          null => DockerCellText(text: unknown),
        },
      ),
      SortableTableColumn(
        id: VolumeColumn.use.name,
        label: _label(l10n, VolumeColumn.use),
        text: (entry) => switch (entry.containers) {
          null => unknown,
          0 => l10n.dockerImagesUnused,
          final count => l10n.dockerVolumesInUse(count),
        },
        sortKey: (entry) => entry.containers,
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
String _phoneRowKey(VolumeEntry entry) =>
    '${DockerWatchList.volumes.name}.row.${_rowKey(entry)}';

/// A row's identity: the volume's name, which the engine keeps unique.
Object _rowKey(VolumeEntry entry) => entry.volume.name;

String _label(AppLocalizations l10n, VolumeColumn column) => switch (column) {
  VolumeColumn.name => l10n.dockerVolumesColumnName,
  VolumeColumn.driver => l10n.dockerVolumesColumnDriver,
  VolumeColumn.created => l10n.dockerImagesColumnCreated,
  VolumeColumn.use => l10n.dockerImagesColumnUse,
};
