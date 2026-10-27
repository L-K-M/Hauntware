import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// NET-11 and DKE-09's port forwards (03 §5.11) this run opened: each
/// asked for with [open], followed through the engine's
/// [PortForwardState]s, and ended with [close] or by the engine. A
/// concern of its own for one engine run, beside the monitoring
/// controller.
///
/// A forward that ended stays listed, with its reason, until the user
/// dismisses it ([dismiss]) or opens another to the same target, so the
/// reason does not vanish with the forward. A stopped engine ends every
/// forward as [PortForwardEnd.closed].
final class PortForwardsController extends ChangeNotifier {
  PortForwardsController(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  /// Every forward this run opened and not dismissed, by forward id, in
  /// the order they were opened.
  final Map<String, PortForwardState> _forwards = {};
  var _count = 0;
  bool _stopped = false;

  /// [serverId]'s forwards, open or ended, oldest first.
  List<PortForwardState> forwardsFor(String serverId) => [
    for (final forward in _forwards.values)
      if (forward.serverId == serverId) forward,
  ];

  /// Asks the engine to forward [host]:[port] on [serverId] to a loopback
  /// port; returns the forward's id. An ended forward to the same target
  /// gives way to it.
  String open(String serverId, {required String host, required int port}) {
    final forwardId = 'forward-${_count++}';
    _forwards.removeWhere(
      (_, f) =>
          f.ended != null &&
          f.serverId == serverId &&
          f.host == host &&
          f.port == port,
    );
    final opening = PortForwardState(
      serverId: serverId,
      forwardId: forwardId,
      host: host,
      port: port,
    );
    _forwards[forwardId] = opening;
    notifyListeners();
    if (_stopped) {
      _end(opening, PortForwardEnd.closed);
      return forwardId;
    }
    try {
      _engine.send(
        OpenPortForward(
          serverId: serverId,
          forwardId: forwardId,
          host: host,
          port: port,
        ),
      );
    } on StateError {
      _engineStopped();
    }
    return forwardId;
  }

  /// Ends [forwardId]'s forward; its final state arrives from the engine.
  void close(String forwardId) {
    final forward = _forwards[forwardId];
    if (forward == null || forward.ended != null || _stopped) return;
    try {
      _engine.send(ClosePortForward(forwardId));
    } on StateError {
      _engineStopped();
    }
  }

  /// Ends every open forward of [serverId], as its view closes (NET-11:
  /// a forward closes with its view).
  void closeServer(String serverId) {
    for (final forward in forwardsFor(serverId)) {
      close(forward.forwardId);
    }
  }

  /// Drops an ended forward from the list.
  void dismiss(String forwardId) {
    if (_forwards[forwardId]?.ended == null) return;
    _forwards.remove(forwardId);
    notifyListeners();
  }

  void _onEvent(EngineEvent event) {
    if (event case PortForwardState(:final forwardId)) {
      if (!_forwards.containsKey(forwardId)) return;
      _forwards[forwardId] = event;
      notifyListeners();
    }
  }

  void _end(PortForwardState forward, PortForwardEnd reason) {
    _forwards[forward.forwardId] = PortForwardState(
      serverId: forward.serverId,
      forwardId: forward.forwardId,
      host: forward.host,
      port: forward.port,
      ended: reason,
    );
  }

  void _engineStopped() {
    _stopped = true;
    for (final forward in [..._forwards.values]) {
      if (forward.ended == null) _end(forward, PortForwardEnd.closed);
    }
    notifyListeners();
  }

  void _onEngineDone() {
    if (_stopped) return;
    _engineStopped();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _stopped = true;
    super.dispose();
  }
}
