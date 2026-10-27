import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/log_streams.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../logs/container_lines.dart';
import '../logs/log_export.dart' show showLogExport;
import '../logs/log_search.dart';
import '../logs/log_view.dart';
import '../logs/log_view_controller.dart';
import '../logs/logs_panel.dart' show LogSearchField;
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show containerNameOf;

/// The most containers one stack's logs read at once: each follow holds
/// one of the server's SSH channels (03 §5.3), and sshd's `MaxSessions`
/// defaults to 10 [E].
const kStackLogsMax = 6;

/// The lines each container's log delivers before its new ones.
const kStackLogsWindow = 200;

/// The merged lines a stack's logs keep, oldest dropped first.
const kStackLogsKept = 10000;

/// The xterm colours the containers' names take, in order: distinct
/// hues without red, which reads as an error. The log view holds each to
/// its contrast floor (03 §10.8).
const _nameColours = [33, 35, 166, 129, 37, 136, 162, 25, 64, 130];

/// One container of the stack, as its logs name it.
@immutable
final class StackLogContainer {
  const StackLogContainer({required this.id, required this.name});

  final String id;
  final String name;
}

/// How one container's stream stands.
enum StackLogState { opening, running, waiting, ended, refused }

/// CTX-04's reading of one stack's logs: a follow of each container's
/// logs, the first [kStackLogsMax] of them, merged by time into [logs],
/// each line led by its container's name in that container's colour.
/// Lines arrive in batches per container; one older than the newest
/// shown rebuilds the view in time order, keeping its scroll state.
/// [hidden] containers stay read, so showing one again shows its lines.
/// Streams are open only while [setVisible] says the logs show.
class StackLogsController extends ChangeNotifier {
  StackLogsController({
    required this._streams,
    required this.serverId,
    required List<StackLogContainer> containers,
  }) : containers = List.unmodifiable(containers.take(kStackLogsMax)),
       omitted = (containers.length - kStackLogsMax).clamp(
         0,
         containers.length,
       );

  final LogStreams _streams;
  final String serverId;

  /// The containers read, in the stack's order.
  final List<StackLogContainer> containers;

  /// How many of the stack's containers are not read, past
  /// [kStackLogsMax].
  final int omitted;

  final LogViewController logs = LogViewController();
  late final LogSearch search = LogSearch(logs);

  /// The lines' levels and JSON fields (CTX-05), past each line's name.
  late final ContainerLineReader lines = ContainerLineReader(
    logs,
    skipWords: 1,
  );

  final Set<int> _hidden = {};
  late final List<_Stream> _streamsOf = [
    for (var i = 0; i < containers.length; i++) _Stream(this, i),
  ];

  /// Every line read, merged by time, oldest first.
  final List<_Entry> _merged = [];
  bool _visible = false;

  /// Containers whose lines are not shown.
  Set<String> get hidden => {for (final i in _hidden) containers[i].id};

  StackLogState stateOf(String containerId) =>
      _streamsOf[_indexOf(containerId)].state;

  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _merged.clear();
      logs.clear();
      for (final stream in _streamsOf) {
        stream.open();
      }
    } else {
      for (final stream in _streamsOf) {
        stream.close();
      }
    }
    notifyListeners();
  }

  /// Shows or hides [containerId]'s lines.
  void toggle(String containerId) {
    final index = _indexOf(containerId);
    if (!_hidden.remove(index)) _hidden.add(index);
    _rebuild();
    notifyListeners();
  }

  int _indexOf(String containerId) =>
      containers.indexWhere((container) => container.id == containerId);

  void _take(int index, List<ContainerRecord> records, {int dropped = 0}) {
    if (records.isEmpty) return;
    final newest = _merged.isEmpty ? null : _merged.last.at;
    // A line without a time sorts where it arrived: after the line before
    // it, or after the newest shown.
    var at = newest;
    final added = [
      for (final record in records) _Entry(index, record, at = record.at ?? at),
    ];
    final inOrder =
        newest == null ||
        added.every((entry) => entry.at == null || !entry.at!.isBefore(newest));
    _merged.addAll(added);
    if (inOrder) {
      _trim();
      if (!_hidden.contains(index)) {
        logs.addContainer([
          for (final record in records) _named(index, record),
        ], dropped: dropped);
      }
      return;
    }

    mergeSort(_merged, compare: _Entry.byTime);
    _trim();
    _rebuild();
  }

  void _trim() {
    if (_merged.length > kStackLogsKept) {
      _merged.removeRange(0, _merged.length - kStackLogsKept);
    }
  }

  void _rebuild() => logs.replaceContainer([
    for (final entry in _merged)
      if (!_hidden.contains(entry.index)) _named(entry.index, entry.record),
  ]);

  ContainerRecord _named(int index, ContainerRecord record) {
    final colour = _nameColours[index % _nameColours.length];
    return ContainerRecord(
      stream: record.stream,
      at: record.at,
      text: _labelled(colour, containers[index].name, record.text),
    );
  }

  void _changed() => notifyListeners();

  @override
  void dispose() {
    for (final stream in _streamsOf) {
      stream.close();
    }
    search.dispose();
    logs.dispose();
    super.dispose();
  }
}

/// [text] led by [name] in xterm colour [colour], as SGR escapes the log
/// view draws and its search and export leave out.
String _labelled(int colour, String name, String text) =>
    '\x1b[38;5;${colour}m$name\x1b[0m $text';

/// One line read, with the container it came from and the time it sorts
/// by: its own, or for a line without one the time before it.
@immutable
final class _Entry {
  const _Entry(this.index, this.record, this.at);

  final int index;
  final ContainerRecord record;
  final DateTime? at;

  /// By time, keeping arrival order among equals ([mergeSort] is
  /// stable); entries before the first timed line sort first.
  static int byTime(_Entry a, _Entry b) {
    final at = a.at;
    final bt = b.at;
    if (at == null || bt == null) {
      return (at == null ? 0 : 1) - (bt == null ? 0 : 1);
    }
    return at.compareTo(bt);
  }
}

/// One container's follow.
final class _Stream implements LogStreamListener {
  _Stream(this._owner, this._index);

  final StackLogsController _owner;
  final int _index;
  LogStreamHandle? _handle;
  StackLogState state = StackLogState.opening;

  void open() {
    if (_handle != null) return;
    state = StackLogState.opening;
    _handle = _owner._streams.open(
      LogStreamSpec(
        serverId: _owner.serverId,
        source: ContainerLogSource(_owner.containers[_index].id),
        window: kStackLogsWindow,
        follow: true,
      ),
      this,
    );
  }

  void close() {
    _handle?.close();
    _handle = null;
  }

  @override
  void onLogBatch(LogBatch batch) {
    if (_handle == null) return;
    _owner._take(
      _index,
      batch.records.whereType<ContainerRecord>().toList(),
      dropped: batch.dropped,
    );
  }

  @override
  void onLogStatus(LogStreamStatus status) {
    if (_handle == null) return;
    state = switch (status) {
      LogStreamRunning() => StackLogState.running,
      LogStreamWaiting() => StackLogState.waiting,
      LogStreamEnded() => StackLogState.ended,
    };
    _owner._changed();
  }

  @override
  void onLogRejected(LogRejection rejection) {
    if (_handle == null) return;
    _handle = null;
    state = StackLogState.refused;
    _owner._changed();
  }
}

/// Opens [project]'s logs (CTX-04) on a page of their own.
void openStackLogs(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ComposeProject project,
}) {
  final containers = [
    for (final service in project.services)
      for (final container in service.containers)
        StackLogContainer(id: container.id, name: containerNameOf(container)),
  ];
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => StackLogsPage(
        monitoring: monitoring,
        serverId: serverId,
        project: project.name,
        containers: containers,
      ),
    ),
  );
}

/// A stack's logs: a chip per container that shows or hides its lines,
/// each container's state where it is not running, the search and
/// export, and the merged lines. It reads while it shows.
class StackLogsPage extends StatefulWidget {
  const StackLogsPage({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.project,
    required this.containers,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String project;
  final List<StackLogContainer> containers;

  @override
  State<StackLogsPage> createState() => _StackLogsPageState();
}

class _StackLogsPageState extends State<StackLogsPage> {
  late final _logs = StackLogsController(
    streams: widget.monitoring.logs,
    serverId: widget.serverId,
    containers: widget.containers,
  )..setVisible(true);

  @override
  void dispose() {
    _logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dockerStackLogsTitle(widget.project)),
        actions: [
          ListenableBuilder(
            listenable: _logs.logs,
            builder: (context, _) => IconButton(
              tooltip: l10n.logsExport,
              icon: const Icon(Icons.ios_share),
              onPressed: _logs.logs.length == 0
                  ? null
                  : () => showLogExport(
                      context,
                      monitoring: widget.monitoring,
                      logs: _logs.logs,
                      fileName: l10n.dockerLogsExportFileName(widget.project),
                    ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _logs,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    if (_logs.containers.isEmpty)
                      DockerNotice(
                        icon: Icons.info_outline,
                        text: l10n.dockerStackLogsNone,
                      ),
                    if (_logs.omitted > 0)
                      DockerNotice(
                        icon: Icons.info_outline,
                        text: l10n.dockerStackLogsOmitted(
                          kStackLogsMax,
                          _logs.omitted,
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final container in _logs.containers)
                          FilterChip(
                            label: Text(switch (_logs.stateOf(container.id)) {
                              StackLogState.running ||
                              StackLogState.opening => container.name,
                              final state => l10n.dockerStackLogsState(
                                container.name,
                                state.name,
                              ),
                            }),
                            selected: !_logs.hidden.contains(container.id),
                            onSelected: (_) => _logs.toggle(container.id),
                          ),
                      ],
                    ),
                    LogSearchField(search: _logs.search),
                  ],
                ),
              ),
              Expanded(
                child: LogView(
                  controller: _logs.logs,
                  search: _logs.search,
                  levelOf: _logs.lines.levelOf,
                  fieldsOf: _logs.lines.fieldsOf,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
