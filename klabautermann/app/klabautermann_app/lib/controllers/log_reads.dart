import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'log_streams.dart';

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

/// No answer for the read follows: the engine refused the open outright
/// with a [RequestRejected], as it does for a server outside its fleet or
/// a server's 17th stream (03 §7.6), or it stopped and will answer
/// nothing.
final class LogReadRefused extends LogReadState {
  const LogReadRefused(this.rejection);

  final LogRejection rejection;
}

/// One bounded log read the app opened: a window, which reads the newest
/// [LogStreamSpec.window] records and ends, such as SVC-04's unit logs.
/// It notifies when [state] changes or records arrive. Its owner calls
/// [close] once it no longer shows the read, which stops a read still
/// running and releases this notifier.
final class LogRead extends ChangeNotifier {
  /// Opens [spec], a window, through [streams], the app's one sender of
  /// [OpenLogStream] (03 §10.1), which `MonitoringController.openLogRead`
  /// passes.
  LogRead(LogStreams streams, LogStreamSpec spec)
    : assert(!spec.follow, 'a follow is not a bounded read') {
    _stream = streams.open(spec, _ReadListener(this));
  }

  late final LogStreamHandle _stream;

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
    // A read that ended or was refused has nothing left to stop.
    _stream.close();
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

/// Hands a [LogRead]'s stream events to it, keeping the listener calls off
/// its public surface.
final class _ReadListener implements LogStreamListener {
  _ReadListener(this._read);

  final LogRead _read;

  @override
  void onLogBatch(LogBatch batch) => _read._add(batch.records, batch.dropped);

  @override
  void onLogStatus(LogStreamStatus status) =>
      _read._report(LogReadReported(status));

  @override
  void onLogRejected(LogRejection rejection) =>
      _read._report(LogReadRefused(rejection));
}
