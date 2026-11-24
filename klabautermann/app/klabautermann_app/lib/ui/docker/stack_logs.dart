import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, mergeSort;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart' show DockerStackList;
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
import 'stacks_view.dart' show stackNamed;

/// The most containers one stack's logs read at once: each follow holds
/// one of the server's SSH channels (03 §5.3), and sshd's `MaxSessions`
/// defaults to 10 [E].
const kStackLogsMax = 6;

/// The lines each container's log delivers before its new ones.
const kStackLogsWindow = 200;

/// The merged lines a stack's logs keep, oldest dropped first.
const kStackLogsKept = 10000;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the log out of sight.
const double _headerShare = 0.4;

/// The xterm colours the containers' names take, in order: distinct
/// hues without red, which reads as an error. The log view holds each to
/// its contrast floor (03 §10.8).
const _nameColours = [33, 35, 166, 129, 37, 136, 162, 25, 64, 130];

/// How long a batch waits for the other containers' lines of the same
/// moment before it is shown. Each container's lines arrive in batches of
/// their own, so without the wait the second container's batch is older
/// than the first's last line nearly every time.
const kStackLogsHold = Duration(milliseconds: 250);

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
/// [hidden] containers stay read, so showing one again shows its lines.
/// Streams are open only while [setVisible] says the logs show.
///
/// Lines arrive in batches per container. Each waits [kStackLogsHold]
/// for the other containers' lines of the same moment, then they are
/// shown together in time order, so ordinary interleaving only appends.
/// A line that is still older than the newest shown rebuilds the view in
/// time order, but only while the view follows: a rebuild renumbers every
/// line, which would move a paused view, close the fields open in it and
/// lose the search's current match. A paused view therefore keeps such a
/// line back and takes it in when it follows again; until then the view,
/// a search over it and an export lack it.
///
/// [setContainers] takes the stack's containers as they are now: a
/// container that replaced one of the same name, as a redeploy's do,
/// is read in its place, under its chip and colour, after the lines the
/// old one left.
class StackLogsController extends ChangeNotifier {
  StackLogsController({
    required this._streams,
    required this.serverId,
    required List<StackLogContainer> containers,
    this._hold = kStackLogsHold,
  }) {
    logs.following.addListener(_onFollowing);
    setContainers(containers);
  }

  final LogStreams _streams;
  final String serverId;
  final Duration _hold;

  /// The containers read or once read, in the order they were first
  /// seen: the stack's own order until one joins it.
  List<StackLogContainer> get containers => [
    for (final slot in _slots) slot.container,
  ];

  /// How many of the stack's containers are not read, past
  /// [kStackLogsMax].
  int get omitted => _omitted;
  int _omitted = 0;

  late final LogViewController logs = LogViewController(serverId: serverId);
  late final LogSearch search = LogSearch(logs);

  /// The lines' levels and JSON fields (CTX-05), past each line's name.
  late final ContainerLineReader lines = ContainerLineReader(
    logs,
    skipWords: 1,
  );

  /// A place per container name ever read. An [_Entry] and [_hidden]
  /// name one by its index, so none is ever removed.
  final List<_Slot> _slots = [];
  final Set<int> _hidden = {};

  /// Every line taken in, merged by time, oldest first, with a marker
  /// where a container's stream dropped lines.
  final List<_Entry> _merged = [];

  /// The lines waiting out [_hold], in arrival order.
  final List<_Entry> _held = [];
  Timer? _release;

  /// The time of the newest line in [logs], or null before the first
  /// timed one.
  DateTime? _shownNewest;

  /// The newest time any line read carried, which a line without a time
  /// takes.
  DateTime? _readNewest;

  /// Whether [_merged] holds a visible line that [logs] does not, kept
  /// back from a paused view.
  bool _keptBack = false;
  bool _visible = false;

  /// Containers whose lines are not shown.
  Set<String> get hidden => {for (final i in _hidden) _slots[i].container.id};

  StackLogState stateOf(String containerId) =>
      _slots[_indexOf(containerId)].state;

  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _merged.clear();
      _shownNewest = null;
      _readNewest = null;
      _keptBack = false;
      logs.clear();
      for (final slot in _slots) {
        slot.open();
      }
    } else {
      _release?.cancel();
      _release = null;
      _held.clear();
      for (final slot in _slots) {
        slot.close();
      }
    }
    notifyListeners();
  }

  /// Reads [containers], the stack's as they are now, the first
  /// [kStackLogsMax] of them. One already read stays read. One with the
  /// name of a container that is gone takes its place (a redeploy
  /// recreates a service's containers under their names with new ids,
  /// UIB-9): its lines follow the old one's under the same chip. Any
  /// other is read as a new container. One that is gone keeps its chip
  /// and its lines, and is read no more.
  void setContainers(List<StackLogContainer> containers) {
    final read = containers.take(kStackLogsMax).toList();
    final ids = {for (final container in read) container.id};
    final omitted = containers.length - read.length;
    var changed = omitted != _omitted;
    _omitted = omitted;

    for (final slot in _slots) {
      if (slot.gone || ids.contains(slot.container.id)) continue;
      slot
        ..close()
        ..gone = true;
      changed = true;
    }
    for (final container in read) {
      if (_slots.any((slot) => slot.container.id == container.id)) continue;

      changed = true;
      final index = _slots.indexWhere(
        (slot) => slot.gone && slot.container.name == container.name,
      );
      final slot = index < 0 ? _Slot(this, _slots.length) : _slots[index];
      if (index < 0) _slots.add(slot);
      slot
        ..container = container
        ..gone = false;
      if (_visible) slot.open();
    }
    if (changed) notifyListeners();
  }

  /// Shows or hides [containerId]'s lines.
  void toggle(String containerId) {
    final index = _indexOf(containerId);
    if (!_hidden.remove(index)) _hidden.add(index);
    _rebuild();
    notifyListeners();
  }

  int _indexOf(String containerId) =>
      _slots.indexWhere((slot) => slot.container.id == containerId);

  void _take(int index, List<ContainerRecord> records, {int dropped = 0}) {
    if (records.isEmpty && dropped == 0) return;
    // A line without a time sorts where it arrived: after the line before
    // it, or after the newest read.
    var at = _readNewest;
    final added = [
      for (final record in records) _Entry(index, record, at = record.at ?? at),
    ];
    // The engine dropped the lines before this batch's: the marker sorts
    // with its first line, or after the newest one for a batch of none.
    _held.addAll([
      if (dropped > 0)
        _Entry.gap(index, added.firstOrNull?.at ?? _readNewest, dropped),
      ...added,
    ]);
    for (final entry in added) {
      if (_isBefore(_readNewest, entry.at)) _readNewest = entry.at;
    }
    // A stack of one container has no other's lines to wait for.
    final read = _slots.where((slot) => !slot.gone).length;
    _release ??= Timer(read > 1 ? _hold : Duration.zero, _releaseHeld);
  }

  /// Takes the held lines in, in time order: appended when none of those
  /// that show is older than the newest shown, else by a rebuild, which
  /// a paused view puts off until it follows again.
  void _releaseHeld() {
    _release = null;
    final added = [..._held];
    _held.clear();
    mergeSort(added, compare: _Entry.byTime);

    final sorted =
        _merged.isEmpty ||
        added.isEmpty ||
        _Entry.byTime(_merged.last, added.first) <= 0;
    _merged.addAll(added);
    if (!sorted) mergeSort(_merged, compare: _Entry.byTime);
    _trim();

    // Of the lines that show, those not older than the newest shown can
    // be appended; they are the last, as the lines are in time order.
    final shown = [
      for (final entry in added)
        if (!_hidden.contains(entry.index)) entry,
    ];
    final late = shown.where((entry) => _isBefore(entry.at, _shownNewest));
    if (late.isEmpty && !_keptBack) {
      _append(shown);
      return;
    }
    if (logs.following.value) {
      _rebuild();
      return;
    }
    _keptBack = true;
    _append(shown.sublist(late.length));
  }

  /// Whether [a] is a time before [b]: no time is before any time, as
  /// [_Entry.byTime] sorts it.
  static bool _isBefore(DateTime? a, DateTime? b) =>
      b != null && (a == null || a.isBefore(b));

  /// A view that follows again takes in the lines kept back while it was
  /// paused. Not at once: the view says that it follows in the middle of
  /// a scroll, when its lines must not change.
  void _onFollowing() {
    if (_keptBack && logs.following.value) {
      _release ??= Timer(Duration.zero, _releaseHeld);
    }
  }

  void _trim() {
    if (_merged.length > kStackLogsKept) {
      _merged.removeRange(0, _merged.length - kStackLogsKept);
    }
  }

  /// Adds [entries], visible and in time order, after the lines shown.
  void _append(List<_Entry> entries) {
    var records = <ContainerRecord>[];
    var dropped = 0;
    void add() {
      if (records.isEmpty && dropped == 0) return;
      logs.addContainer(records, dropped: dropped);
    }

    for (final entry in entries) {
      switch (entry.record) {
        case final record?:
          records.add(_named(entry.index, record));
          _shownNewest = entry.at ?? _shownNewest;
        case null:
          add();
          records = [];
          dropped = entry.dropped;
      }
    }
    add();
  }

  void _rebuild() {
    final records = <ContainerRecord>[];
    final droppedBefore = <int, int>{};
    _shownNewest = null;
    for (final entry in _merged) {
      if (_hidden.contains(entry.index)) continue;
      switch (entry.record) {
        case final record?:
          records.add(_named(entry.index, record));
          _shownNewest = entry.at ?? _shownNewest;
        case null:
          droppedBefore.update(
            records.length,
            (count) => count + entry.dropped,
            ifAbsent: () => entry.dropped,
          );
      }
    }
    _keptBack = false;
    logs.replaceContainer(records, droppedBefore: droppedBefore);
  }

  ContainerRecord _named(int index, ContainerRecord record) {
    final colour = _nameColours[index % _nameColours.length];
    return ContainerRecord(
      stream: record.stream,
      at: record.at,
      text: _labelled(colour, _slots[index].container.name, record.text),
    );
  }

  void _changed() => notifyListeners();

  @override
  void dispose() {
    _release?.cancel();
    for (final slot in _slots) {
      slot.close();
    }
    logs.following.removeListener(_onFollowing);
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
/// by: its own, or for a line without one the time before it. A gap
/// ([record] null) stands for [dropped] lines the container's stream
/// lost at that point.
@immutable
final class _Entry {
  const _Entry(this.index, ContainerRecord this.record, this.at) : dropped = 0;

  const _Entry.gap(this.index, this.at, this.dropped) : record = null;

  final int index;
  final ContainerRecord? record;
  final DateTime? at;
  final int dropped;

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

/// One container's place among the stack's and its follow. A container
/// that replaces it takes the place over ([container] changes); one
/// that is [gone] is not read.
final class _Slot implements LogStreamListener {
  _Slot(this._owner, this._index);

  final StackLogsController _owner;
  final int _index;
  late StackLogContainer container;
  bool gone = false;
  LogStreamHandle? _handle;
  StackLogState state = StackLogState.opening;

  void open() {
    if (_handle != null || gone) return;
    state = StackLogState.opening;
    _handle = _owner._streams.open(
      LogStreamSpec(
        serverId: _owner.serverId,
        source: ContainerLogSource(container.id),
        window: kStackLogsWindow,
        follow: true,
      ),
      this,
    );
  }

  /// Stops reading: the container is read no more until [open].
  void close() {
    _handle?.close();
    _handle = null;
    state = StackLogState.ended;
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

/// [project]'s containers as its logs name them, in the stack's order.
List<StackLogContainer> _containersOf(ComposeProject project) => [
  for (final service in project.services)
    for (final container in service.containers)
      StackLogContainer(id: container.id, name: containerNameOf(container)),
];

/// Opens [project]'s logs (CTX-04) on a page of their own.
void openStackLogs(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ComposeProject project,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => StackLogsPage(
        monitoring: monitoring,
        serverId: serverId,
        project: project.name,
        containers: _containersOf(project),
      ),
    ),
  );
}

/// A stack's logs: a chip per container that shows or hides its lines,
/// each container's state where it is not running, the search and
/// export, and the merged lines. It reads while it shows, and follows
/// the stack's containers as the server's stack list names them, so a
/// redeployed stack's new containers are read in the old ones' places
/// (UIB-9). The list is the Stacks view's: this page starts no watch of
/// its own, as a stack watch runs compose commands on the host.
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

  late final ValueListenable<DockerStackList> _stacks = widget.monitoring.docker
      .stacksFor(widget.serverId);

  @override
  void initState() {
    super.initState();
    _stacks.addListener(_onStacks);
  }

  /// Takes the stack's containers from a new list. A list that could
  /// not be read, or one without the stack (as between a redeploy's
  /// down and up), changes nothing: the page keeps reading what it has.
  void _onStacks() {
    final project = stackNamed(_stacks.value.stacks, widget.project);
    if (project == null) return;

    _logs.setContainers(_containersOf(project));
  }

  @override
  void dispose() {
    _stacks.removeListener(_onStacks);
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
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(
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
                                label: Text(switch (_logs.stateOf(
                                  container.id,
                                )) {
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
      ),
    );
  }
}
