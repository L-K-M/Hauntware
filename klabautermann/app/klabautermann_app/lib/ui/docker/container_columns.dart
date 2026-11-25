import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/container_usage.dart'
    show kMemoryRiskShare, memoryLimitShare;
import '../../l10n/app_localizations.dart';
import '../sortable_table.dart';
import 'container_badges.dart';
import 'containers_view.dart';
import 'docker_cells.dart' show dockerAgeText;

/// How old a container's list stats grow before they read as stale: four
/// rounds of the engine's 5 s stats cadence (CST-01 [E]), since a relay
/// or low-session mode reads one container at a time and a long screen
/// takes longer to go round.
const Duration _statsStaleAfter = Duration(seconds: 20);

/// The columns whose largest values matter, which start descending.
const firstDirection = {
  ContainerColumn.cpu,
  ContainerColumn.memory,
  ContainerColumn.network,
  ContainerColumn.blockIo,
  ContainerColumn.pids,
};

/// A column's label, as the table and its chooser name it.
String label(AppLocalizations l10n, ContainerColumn column) => switch (column) {
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

/// The table's columns, each with its text, sort key and cell.
List<SortableTableColumn<ContainerListEntry>> columns(
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
    label: label(l10n, id),
    text: (entry) => switch (entry) {
      ContainerEntry(:final container) => text(container),
      ContainerGroupEntry() => '',
    },
    sortKey: (entry) => switch (entry) {
      ContainerEntry(:final container) => sortKey(container),
      ContainerGroupEntry() => null,
    },
    firstDirection: firstDirection.contains(id)
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
        (final value, final stale) => Figure(
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
      (container) => _containerStateFlagText(l10n, container),
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
      cell: (context, container) => StatusCell(
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
    column(ContainerColumn.stack, (container) => _stackText(l10n, container), (
      container,
    ) {
      final text = _stackText(l10n, container).toLowerCase();
      return text.isEmpty ? null : text;
    }, extent: const FixedColumnExtent(120)),
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
List<SortableTableColumn<ContainerListEntry>> shownColumns(
  List<SortableTableColumn<ContainerListEntry>> all,
  List<ContainerColumn> chosen,
) {
  final byId = {for (final column in all) column.id: column};
  return [
    byId[ContainerColumn.name.name]!,
    for (final column in chosen) byId[column.name]!,
  ];
}

/// [container]'s state in words, with its CTR-09 flag when it has one:
/// "Restarting (restart loop)", "Exited (failed)".
String _containerStateFlagText(
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

/// CTR-08's chooser: every column but the name, the shown ones checked
/// and first in their order, the rest after; drag to reorder. Done
/// answers the checked ones in order, Reset the default.
class ColumnsDialog extends StatefulWidget {
  const ColumnsDialog({super.key, required this.chosen});

  final List<ContainerColumn> chosen;

  @override
  State<ColumnsDialog> createState() => _ColumnsDialogState();
}

class _ColumnsDialogState extends State<ColumnsDialog> {
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
                title: Text(label(l10n, column)),
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
