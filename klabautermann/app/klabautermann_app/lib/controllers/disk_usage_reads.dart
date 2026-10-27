import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// DSK-07's folder reads (03 §7.3): each [read] asks the engine for one
/// folder of a server and completes with its [DiskUsageReport]. A concern
/// of its own for one engine run, beside the monitoring controller, as
/// the accounts reads are. A stopped engine, or one that stops before it
/// answers, answers [DiskUsageReportFailure.noLink].
final class DiskUsageReads {
  DiskUsageReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, (String, String, Completer<DiskUsageReport>)> _pending = {};
  var _count = 0;
  bool _engineStopped = false;

  /// [path] on [serverId] as it is now; as root through admin mode when
  /// [elevated].
  Future<DiskUsageReport> read(
    String serverId,
    String path, {
    bool elevated = false,
  }) {
    final requestId = 'disk-usage-${_count++}';
    if (_engineStopped) {
      return Future.value(_noLink(serverId, requestId, path));
    }
    final answer = Completer<DiskUsageReport>();
    _pending[requestId] = (serverId, path, answer);
    try {
      _engine.send(
        ReadDiskUsage(serverId, path, requestId: requestId, elevated: elevated),
      );
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_noLink(serverId, requestId, path));
    }
    return answer.future;
  }

  static DiskUsageReport _noLink(
    String serverId,
    String requestId,
    String path,
  ) => DiskUsageReport(
    serverId: serverId,
    requestId: requestId,
    path: path,
    failure: DiskUsageReportFailure.noLink,
  );

  void _onEvent(EngineEvent event) {
    if (event case DiskUsageReport(:final requestId)) {
      _pending.remove(requestId)?.$3.complete(event);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final MapEntry(key: requestId, value: (serverId, path, answer))
        in _pending.entries) {
      answer.complete(_noLink(serverId, requestId, path));
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
