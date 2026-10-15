import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What a [LogRead] is doing, as far as the app knows.
@immutable
sealed class LogReadState {
  const LogReadState();
}

/// The open is sent and the engine has not answered it yet.
final class LogReadRequested extends LogReadState {
  const LogReadRequested();
}

/// The engine's latest [LogStreamState] for the read.
final class LogReadReported extends LogReadState {
  const LogReadReported(this.status);

  final LogStreamStatus status;
}

/// The engine refused the open outright with a [RequestRejected], as it
/// does for every open until its log service is wired (03 §10.1).
final class LogReadRefused extends LogReadState {
  const LogReadRefused();
}

/// One bounded log read the app opened: a window, which reads the newest
/// [LogStreamSpec.window] records and ends, such as SVC-04's unit logs.
/// It notifies when [state] changes or records arrive. Its owner calls
/// [close] once it no longer shows the read, which stops a read still
/// running and releases this notifier.
final class LogRead extends ChangeNotifier {
  LogRead._(this._onClose);

  final VoidCallback _onClose;

  LogReadState _state = const LogReadRequested();
  final List<LogRecord> _records = [];
  int _dropped = 0;
  bool _closed = false;

  LogReadState get state => _state;

  /// The records so far in the stream's order: newest first for a window.
  late final List<LogRecord> records = UnmodifiableListView(_records);

  /// How many records the engine discarded in all.
  int get dropped => _dropped;

  /// Whether nothing more arrives for the read.
  bool get ended => switch (_state) {
    LogReadRequested() => false,
    LogReadReported(:final status) => status is LogStreamEnded,
    LogReadRefused() => true,
  };

  void close() {
    if (_closed) return;
    _closed = true;
    _onClose();
    dispose();
  }

  void _report(LogReadState state) {
    _state = state;
    notifyListeners();
  }

  void _add(List<LogRecord> records, int dropped) {
    _records.addAll(records);
    _dropped += dropped;
    notifyListeners();
  }
}

/// The log reads of one engine run by stream id, fed the engine's log
/// events by [MonitoringController], which owns it.
///
/// [RequestRejected] names no stream (03 §10.1), so a rejection of an
/// [OpenLogStream] goes to the oldest open without an answer. The engine
/// handles requests one at a time in arrival order, so this is exact
/// while it refuses every open; once its log service is wired it refuses
/// one outright only for a stream id an earlier open used, which a
/// counter never repeats. A read closed before its answer keeps its place
/// until the answer arrives, so a late rejection cannot land on the next.
final class LogReads {
  LogReads(this._send);

  final void Function(EngineRequest request) _send;

  /// The reads that have not ended or been closed.
  final Map<String, LogRead> _reads = {};

  /// The stream ids of the opens without an answer, oldest first.
  final Queue<String> _unanswered = Queue();

  int _count = 0;

  /// Sends an open for [spec], a window, under an id no other open of
  /// this engine run used.
  LogRead open(LogStreamSpec spec) {
    assert(!spec.follow, 'a follow is not a bounded read');
    final streamId = 'log-read-${_count++}';
    final read = LogRead._(() {
      // A read that ended has nothing left to stop.
      if (_reads.remove(streamId) != null) _send(CloseStream(streamId));
    });
    _reads[streamId] = read;
    _unanswered.add(streamId);
    _send(OpenLogStream(streamId: streamId, spec: spec));
    return read;
  }

  /// Applies [event] to the read it concerns, if any.
  void accept(EngineEvent event) {
    switch (event) {
      case LogStreamState(:final streamId, :final status):
        _unanswered.remove(streamId);
        final read = status is LogStreamEnded
            ? _reads.remove(streamId)
            : _reads[streamId];
        read?._report(LogReadReported(status));
      case LogBatch(:final streamId, :final records, :final dropped):
        _unanswered.remove(streamId);
        _reads[streamId]?._add(records, dropped);
      case RequestRejected(:final requestName)
          when requestName == '$OpenLogStream' && _unanswered.isNotEmpty:
        _reads
            .remove(_unanswered.removeFirst())
            ?._report(const LogReadRefused());
      case EngineEvent():
        break;
    }
  }
}
