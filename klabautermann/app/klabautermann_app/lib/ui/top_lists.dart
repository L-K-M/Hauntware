import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/docker_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'docker/containers_view.dart' show containerIsUp, containerNameOf;
import 'server_surfaces.dart';
import 'system_panel.dart' show PanelSection;

/// How many rows each of the Overview's top lists shows.
const int kTopListLength = 5;

/// What a top list ranks by.
enum TopMeasure { cpu, memory }

/// One row of a top list: what it names, a process's id, and the figure
/// it ranks by.
typedef TopEntry = ({String label, int? pid, double value});

/// [processes]' first [kTopListLength] by [measure], the most first; a
/// process that did not report the figure stays out.
List<TopEntry> topProcesses(List<ProcessRow> processes, TopMeasure measure) {
  final entries = [
    for (final row in processes)
      if (switch (measure) {
            TopMeasure.cpu => row.cpuPercent,
            TopMeasure.memory => row.residentBytes?.toDouble(),
          }
          case final value? when value > 0)
        (label: row.name ?? '${row.pid}', pid: row.pid, value: value),
  ]..sort((a, b) => b.value.compareTo(a.value));
  return entries.take(kTopListLength).toList();
}

/// [containers]' first [kTopListLength] by [measure] from their latest
/// list [stats], the most first; one without the figure stays out.
List<TopEntry> topContainers(
  List<ContainerSummary> containers,
  Map<String, ContainerListStats> stats,
  TopMeasure measure,
) {
  final entries = [
    for (final container in containers)
      if (switch (measure) {
            TopMeasure.cpu => stats[container.id]?.cpuPercent,
            TopMeasure.memory => stats[container.id]?.memoryUsed?.toDouble(),
          }
          case final value? when value > 0)
        (label: containerNameOf(container), pid: null, value: value),
  ]..sort((a, b) => b.value.compareTo(a.value));
  return entries.take(kTopListLength).toList();
}

/// OV-07's top lists on a server's Overview: its busiest processes and,
/// where its Docker engine answers, its busiest containers, each by CPU
/// and by memory. Closed until the user opens it, it then reads `procs`
/// and the containers' list stats while the Overview shows, as the
/// Processes tab and the Docker tab's Containers view would (03 §6.4);
/// closed or hidden, it reads nothing.
class TopListsCard extends StatefulWidget {
  const TopListsCard({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<TopListsCard> createState() => _TopListsCardState();
}

class _TopListsCardState extends State<TopListsCard> {
  DockerController get _docker => widget.monitoring.docker;

  /// The server whose container watch this card holds, if any.
  String? _watching;

  var _measure = TopMeasure.cpu;

  /// Whether the user opened the lists; closed, as at first, the card
  /// reads nothing, so an Overview costs the host no process list.
  var _open = false;

  bool get _reading => widget.visible && _open;

  @override
  void initState() {
    super.initState();
    _listen(widget.serverId);
    _sync();
  }

  @override
  void didUpdateWidget(TopListsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId) {
      _unlisten(oldWidget.serverId);
      _listen(widget.serverId);
    }
    _sync();
  }

  @override
  void dispose() {
    _unlisten(widget.serverId);
    _release();
    super.dispose();
  }

  // The engine can come ready after the card does, and each new list
  // names the containers whose stats the ranking needs.
  void _listen(String serverId) {
    _docker.endpointFor(serverId).addListener(_sync);
    _docker.containersFor(serverId).addListener(_onContainers);
  }

  void _unlisten(String serverId) {
    _docker.endpointFor(serverId).removeListener(_sync);
    _docker.containersFor(serverId).removeListener(_onContainers);
  }

  /// Holds the container watch while the card shows and the engine is
  /// ready, which the Docker summary card above it has asked for.
  void _sync() {
    final ready =
        _docker.endpointFor(widget.serverId).value?.phase ==
        DockerEndpointPhase.ready;
    final wanted = _reading && ready ? widget.serverId : null;
    if (wanted == _watching) return;
    _release();
    if (wanted == null) return;
    _docker.watchContainers(wanted);
    _watching = wanted;
    _onContainers();
  }

  void _release() {
    final held = _watching;
    if (held == null) return;
    _watching = null;
    _docker.unwatchContainers(held);
  }

  /// Asks for the running containers' list stats, which the ranking
  /// needs, once a list arrives.
  void _onContainers() {
    if (_watching == null) return;
    final list = _docker.containersFor(widget.serverId).value;
    final running = [
      for (final container in list.containers ?? const <ContainerSummary>[])
        if (containerIsUp(container)) container.id,
    ];
    _docker.showStatsFor(widget.serverId, running);
  }

  String _figure(AppLocalizations l10n, TopEntry entry) => switch (_measure) {
    TopMeasure.cpu => l10n.topListsPercent(entry.value.toStringAsFixed(1)),
    TopMeasure.memory => ghostFormatBinarySize(entry.value.round()),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final procs = widget.monitoring.sampleFor(
      widget.serverId,
      SampleStream.procs,
    );
    final containers = _docker.containersFor(widget.serverId);
    return SampledSurface(
      monitoring: widget.monitoring,
      serverId: widget.serverId,
      surface: 'overview-top',
      streams: const {SampleStream.procs},
      visible: _reading,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          procs,
          containers,
          _docker.endpointFor(widget.serverId),
        ]),
        builder: (context, _) {
          final processes = switch (procs.value?.result) {
            final ProcsResult result => result.processes,
            _ => null,
          };
          final list = containers.value;
          final containerRows = list.containers == null
              ? null
              : topContainers(list.containers!, list.stats, _measure);
          final toggle = TextButton.icon(
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
            label: Text(_open ? l10n.topListsHide : l10n.topListsShow),
            onPressed: () {
              setState(() => _open = !_open);
              _sync();
            },
          );
          if (!_open) {
            return PanelSection(title: l10n.topListsTitle, children: [toggle]);
          }
          return PanelSection(
            title: l10n.topListsTitle,
            children: [
              toggle,
              SegmentedButton<TopMeasure>(
                showSelectedIcon: false,
                segments: [
                  for (final measure in TopMeasure.values)
                    ButtonSegment(
                      value: measure,
                      label: Text(l10n.topListsMeasure(measure.name)),
                    ),
                ],
                selected: {_measure},
                onSelectionChanged: (picked) =>
                    setState(() => _measure = picked.single),
              ),
              _TopList(
                title: l10n.topListsProcesses,
                entries: processes == null
                    ? null
                    : topProcesses(processes, _measure),
                figure: (entry) => _figure(l10n, entry),
                waiting: l10n.topListsWaiting,
                empty: l10n.topListsEmpty,
              ),
              if (_watching != null)
                _TopList(
                  title: l10n.topListsContainers,
                  entries: containerRows,
                  figure: (entry) => _figure(l10n, entry),
                  waiting: l10n.topListsWaiting,
                  empty: l10n.topListsEmpty,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TopList extends StatelessWidget {
  const _TopList({
    required this.title,
    required this.entries,
    required this.figure,
    required this.waiting,
    required this.empty,
  });

  final String title;

  /// Null until the first reading.
  final List<TopEntry>? entries;
  final String Function(TopEntry entry) figure;
  final String waiting;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final entries = this.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.labelLarge),
        ),
        if (entries == null)
          Text(waiting, style: muted)
        else if (entries.isEmpty)
          Text(empty, style: muted)
        else
          for (final entry in entries)
            MergeSemantics(
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Text(
                      switch (entry.pid) {
                        final pid? => AppLocalizations.of(
                          context,
                        ).topListsProcess(entry.label, pid),
                        null => entry.label,
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    figure(entry),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
