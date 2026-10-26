import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/log_streams.dart';
import 'log_query.dart';
import 'log_search.dart';
import 'log_view_controller.dart';

/// The records a window reads, and the earlier ones a follow delivers
/// first: LOG-01's page (03 §7.6).
const int kLogsPanelWindow = 500;

/// One Logs panel's reading (LOG-01 to LOG-05, LOG-22): its [query], the
/// stream that reads it into [logs], and [live], whether that stream
/// follows (LOG-02). It notifies when the query, [live] or the stream's
/// state changes; lines reach the view through [logs].
///
/// A stream is open only while the panel is visible (03 §6.4). Showing it
/// again resumes a follow after the newest journal record held, so a
/// return leaves no gap; a file or `dmesg` has no cursor, so its follow
/// starts over. A window ([live] off) reads the newest
/// [kLogsPanelWindow] records, which arrive newest first, and shows them
/// oldest first once it ends; a full window stays as it is while hidden.
/// Turning [live] off closes the follow and keeps its entries, or reads
/// a window when it showed none.
///
/// [LogsPanelController.container] reads one container's logs instead
/// (CTX-01), with no query: like a file, its follow has no cursor and
/// starts over when shown again, and its window arrives oldest first, as
/// the Docker API sends it.
class LogsPanelController extends ChangeNotifier implements LogStreamListener {
  /// A source given here is read whatever the query says, as a file is
  /// read: a detached operation's output (03 §7.17) has no query.
  LogsPanelController({
    required this._streams,
    required this.serverId,
    this._source,
    this._now = DateTime.now,
  }) : containerId = null;

  /// Reads [containerId]'s logs on [serverId] over its Docker endpoint.
  LogsPanelController.container({
    required this._streams,
    required this.serverId,
    required String this.containerId,
    this._now = DateTime.now,
  }) : _source = null;

  final LogStreams _streams;
  final String serverId;
  final LogSource? _source;
  final DateTime Function() _now;

  /// The container whose logs this reads, or null for the host's logs
  /// by [query].
  final String? containerId;

  final LogViewController logs = LogViewController();
  late final LogSearch search = LogSearch(logs);

  LogQuery _query = const LogQuery();
  ContainerLogRange _range = const ContainerLogRange();
  bool _live = true;
  bool _visible = false;

  LogStreamHandle? _stream;
  bool _following = false;
  bool _opening = false;
  bool _rejected = false;
  LogStreamStatus? _status;

  /// The cursor of the newest journal record held.
  String? _cursor;

  /// Whether [logs] holds what showing the panel again should keep: a
  /// full window, or a follow's entries once [live] turned off.
  bool _kept = false;

  /// A window's records, newest first, until it ends.
  final List<LogRecord> _window = [];
  int _windowDropped = 0;

  LogQuery get query => _query;

  /// A container's time range (CTX-03).
  ContainerLogRange get range => _range;

  /// Whether there is something to read: a container, a given source, or
  /// a [query] that is ready.
  bool get ready => containerId != null || _source != null || _query.ready;

  /// Whether the stream follows: [setLive]'s choice, while the query can
  /// be followed ([LogQuery.followable]).
  bool get live => _live && canFollow;

  /// Whether [setLive] can follow the query, or for a container its
  /// [range]: one with an end has nothing new to follow.
  bool get canFollow =>
      containerId != null ? !_range.chosen : _query.followable;

  /// Sent, with no answer yet.
  bool get opening => _opening;

  /// The engine refused the last open outright.
  bool get rejected => _rejected;

  /// The engine's last status for the stream, which may have ended, as
  /// a kept window's end; otherwise null while none is open or before
  /// the engine said anything.
  LogStreamStatus? get status => _status;

  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _open();
    } else if (!_kept) {
      // What is kept has no stream open, and keeps its end status, so an
      // empty window still says why it is empty.
      _closeStream();
    }
    notifyListeners();
  }

  /// Reads [query] from the start; a container's logs take none.
  void apply(LogQuery query) {
    assert(containerId == null);
    _query = query;
    _closeStream();
    _cursor = null;
    _kept = false;
    logs.clear();
    _open();
    notifyListeners();
  }

  /// Reads a container's logs in [range] from the start.
  void setRange(ContainerLogRange range) {
    assert(containerId != null);
    if (range == _range) return;
    _range = range;
    _closeStream();
    _kept = false;
    logs.clear();
    _open();
    notifyListeners();
  }

  void setLive(bool live) {
    if (live == _live) return;
    _live = live;
    _closeStream();
    // Only what a follow showed is kept; with nothing shown, read a window.
    _kept = !live && logs.length > 0;
    _open();
    notifyListeners();
  }

  /// Opens the reading again after a refusal or a failed end, resuming a
  /// follow where it can.
  void retry() {
    _closeStream();
    _kept = false;
    _open();
    notifyListeners();
  }

  void _open() {
    if (!_visible || _stream != null || _kept || !ready) return;

    // A container's logs, or a given source, are read as a file is.
    final source = switch (containerId) {
      final container? => ContainerLogSource(
        container,
        since: _range.sinceAt(_now()),
        until: _range.until,
      ),
      null => _source,
    };
    final follow = live;
    final resume =
        follow && source == null && _query.source != LogSourceKind.file
        ? _cursor
        : null;
    if (resume == null) {
      logs.clear();
      _cursor = null;
    }
    _following = follow;
    _opening = true;
    _stream = _streams.open(
      LogStreamSpec(
        serverId: serverId,
        source: source ?? _query.toSource(_now()),
        window: kLogsPanelWindow,
        follow: follow,
        afterCursor: resume,
      ),
      this,
    );
  }

  void _closeStream() {
    _stream?.close();
    _stream = null;
    _opening = false;
    _rejected = false;
    _status = null;
    _window.clear();
    _windowDropped = 0;
  }

  @override
  void onLogBatch(LogBatch batch) {
    if (_following) {
      _append(batch.records, batch.dropped);
    } else {
      _window.addAll(batch.records);
      _windowDropped += batch.dropped;
    }
    if (!_opening) return;
    _opening = false;
    notifyListeners();
  }

  @override
  void onLogStatus(LogStreamStatus status) {
    _opening = false;
    _status = status;
    if (status case LogStreamEnded(:final reason)) {
      _stream = null;
      if (!_following) {
        // A container's window arrives oldest first (D07), unlike the
        // host's, which LogStreamSpec describes.
        _append(
          containerId == null ? _window.reversed.toList() : [..._window],
          _windowDropped,
        );
        _window.clear();
        _windowDropped = 0;
        _kept =
            reason == LogStreamEndReason.windowFilled ||
            reason == LogStreamEndReason.oldestReached;
      }
    }
    notifyListeners();
  }

  // The status words both reasons alike: the engine did not open the log.
  @override
  void onLogRejected(LogRejection rejection) {
    _stream = null;
    _opening = false;
    _rejected = true;
    notifyListeners();
  }

  /// Appends [records], oldest first, in runs: journal records as journal
  /// rows, container records as container rows, the rest as lines.
  void _append(List<LogRecord> records, int dropped) {
    var start = 0;
    while (start < records.length || dropped > 0) {
      final kind = start < records.length
          ? _RunKind.of(records[start])
          : _RunKind.line;
      var end = start;
      while (end < records.length && _RunKind.of(records[end]) == kind) {
        end++;
      }
      final run = records.sublist(start, end);
      switch (kind) {
        case _RunKind.journal:
          final entries = run.cast<JournalRecord>();
          logs.addJournal([
            for (final record in entries) JournalEntry(record.fields),
          ], dropped: dropped);
          for (final record in entries) {
            if (record.cursor case final cursor?) _cursor = cursor;
          }
        case _RunKind.container:
          logs.addContainer(run.cast<ContainerRecord>(), dropped: dropped);
        case _RunKind.line:
          logs.add([
            for (final record in run)
              if (record case KernelRecord(:final message))
                message
              else if (record case FileRecord(:final text))
                text,
          ], dropped: dropped);
      }
      dropped = 0;
      start = end;
    }
  }

  @override
  void dispose() {
    _closeStream();
    search.dispose();
    logs.dispose();
    super.dispose();
  }
}

/// How [LogsPanelController] appends a run of records.
enum _RunKind {
  journal,
  container,
  line;

  static _RunKind of(LogRecord record) => switch (record) {
    JournalRecord() => journal,
    ContainerRecord() => container,
    KernelRecord() || FileRecord() => line,
  };
}
