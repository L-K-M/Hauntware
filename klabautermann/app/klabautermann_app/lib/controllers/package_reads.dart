import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// PKG-01 to PKG-03's reads (03 §7.8): each [read] asks the engine for a
/// server's package check, which the engine keeps for an hour, and
/// completes with its [PackagesReport]. A concern of its own for one
/// engine run, listening to the engine beside the monitoring controller.
final class PackageReads {
  PackageReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, (String, Completer<PackagesReport>)> _pending = {};
  var _count = 0;
  bool _engineStopped = false;

  /// [serverId]'s check: the engine's kept one unless [fresh]. A stopped
  /// engine, or one that stops before it answers, answers
  /// [PackagesReportFailure.noLink].
  Future<PackagesReport> read(String serverId, {bool fresh = false}) {
    final requestId = 'packages-${_count++}';
    if (_engineStopped) return Future.value(_noLink(serverId, requestId));
    final answer = Completer<PackagesReport>();
    _pending[requestId] = (serverId, answer);
    try {
      _engine.send(ReadPackages(serverId, requestId: requestId, fresh: fresh));
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_noLink(serverId, requestId));
    }
    return answer.future;
  }

  static PackagesReport _noLink(String serverId, String requestId) =>
      PackagesReport(
        serverId: serverId,
        requestId: requestId,
        failure: PackagesReportFailure.noLink,
      );

  void _onEvent(EngineEvent event) {
    if (event case PackagesReport(:final requestId)) {
      _pending.remove(requestId)?.$2.complete(event);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final MapEntry(key: requestId, value: (serverId, answer))
        in _pending.entries) {
      answer.complete(_noLink(serverId, requestId));
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
