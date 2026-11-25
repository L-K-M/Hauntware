import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/docker_actions.dart'
    show
        CreateVolumeButton,
        PruneButton,
        VolumeActionsButton,
        volumeActionEntries;
import '../panel_kit.dart' show kSilentListenable;
import '../sortable_table.dart';
import '../time_display.dart';
import 'docker_cells.dart';
import 'docker_list_panel.dart';
import 'volumes_view.dart';

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
/// shows; the shared [DockerListPanel] owns that state and the layout.
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
  DockerController get _docker => widget.monitoring.docker;

  @override
  Widget build(
    BuildContext context,
  ) => DockerListPanel<VolumeSummary, VolumeEntry, VolumeFilter, VolumeColumn>(
    serverId: widget.serverId,
    visible: widget.visible,
    list: () => _docker.volumesFor(widget.serverId),
    containers: () => _docker.containersFor(widget.serverId),
    endpoint: () => _docker.endpointFor(widget.serverId),
    watch: _docker.watchVolumes,
    unwatch: _docker.unwatchVolumes,
    retry: () => _docker.retryVolumes(widget.serverId),
    itemsOf: (payload) => (payload as DockerVolumeList?)?.volumes,
    failureOf: (payload) => (payload as DockerVolumeList?)?.failure,
    initialSort: TableSort(
      VolumeColumn.name.name,
      TableSortDirection.ascending,
    ),
    filters: VolumeFilter.values,
    initialFilter: VolumeFilter.all,
    filterLabel: (l10n, filter) => switch (filter) {
      VolumeFilter.all => l10n.dockerImagesFilterAll,
      VolumeFilter.unused => l10n.dockerImagesFilterUnused,
    },
    shownFilter: (selected, useKnown) => useKnown ? selected : VolumeFilter.all,
    useKnown: (containers) => containers.containers != null,
    searchHint: (l10n) => l10n.dockerVolumesSearchHint,
    columns: (context, l10n) => _columns(l10n, widget.monitoring.clock.value),
    sortColumns: VolumeColumn.values,
    sortLabel: (l10n, column) => _label(l10n, column),
    descendingFirst: (column) => column == VolumeColumn.created,
    entries: (items, containers, filter, terms) => volumeEntries(
      items,
      containers: containers,
      filter: filter,
      terms: terms,
    ),
    empty: (items, filter, terms, l10n) => Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        items.isEmpty
            ? l10n.dockerVolumesEmpty
            : terms.isNotEmpty
            ? l10n.dockerVolumesNoMatch
            : switch (filter) {
                VolumeFilter.unused => l10n.dockerVolumesNoneUnused,
                // Every volume passes; the engine listed none.
                VolumeFilter.all => l10n.dockerVolumesEmpty,
              },
      ),
    ),
    tableId: DockerWatchList.volumes.name,
    rowKey: _rowKey,
    heading: (context, entry) => Text(
      entry.volume.name,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall,
    ),
    phoneActions: (context, entry) =>
        VolumeActionsButton(serverId: widget.serverId, entry: entry),
    menuActions: (context, entry) =>
        volumeActionEntries(context, serverId: widget.serverId, entry: entry),
    actionPoint: ActionEntryPoint.volumeRemove,
    failedText: (l10n, failure) => l10n.dockerVolumesFailed(failure),
    keptText: (l10n) => l10n.dockerImagesKept,
    readingText: (l10n) => l10n.dockerVolumesReading,
    useUnknownText: (l10n) => l10n.dockerVolumesUseUnknown,
    actions: (context) =>
        actionsAllowedAt(
          context,
          widget.serverId,
          ActionEntryPoint.volumeCreate,
        )
        ? Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              CreateVolumeButton(serverId: widget.serverId),
              PruneButton(
                choices: [
                  PruneDocker(widget.serverId, kind: DockerPruneKind.volumes),
                ],
              ),
            ],
          )
        : null,
    bodyClock: (visible, items) => visible && (items?.isNotEmpty ?? false)
        ? widget.monitoring.clock
        : kSilentListenable,
  );

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
        l10n.dockerImagesDate(displayTime(context, widget.serverId, at)),
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

/// A row's identity: the volume's name, which the engine keeps unique.
Object _rowKey(VolumeEntry entry) => entry.volume.name;

String _label(AppLocalizations l10n, VolumeColumn column) => switch (column) {
  VolumeColumn.name => l10n.dockerVolumesColumnName,
  VolumeColumn.driver => l10n.dockerVolumesColumnDriver,
  VolumeColumn.created => l10n.dockerImagesColumnCreated,
  VolumeColumn.use => l10n.dockerImagesColumnUse,
};
