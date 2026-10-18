import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The admin-mode concern (03 §8.2, SAF-02): each server's latest
/// [AdminModeState] from the engine, which runs the state machine and
/// alone holds the password, and the user's requests to turn it on or off.
/// Like the other per-run controllers it lasts one engine run: the engine
/// that stops takes every admin session with it.
final class AdminController extends ChangeNotifier {
  AdminController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, AdminModeState> _states = {};
  bool _engineStopped = false;

  /// [serverId]'s latest state, or null when admin mode was never asked
  /// for there this run.
  AdminModeState? stateFor(String serverId) => _states[serverId];

  /// Whether [serverId]'s admin mode is on or on its way there.
  bool isActive(String serverId) => switch (_states[serverId]?.phase) {
    AdminModePhase.detecting ||
    AdminModePhase.awaitingPassword ||
    AdminModePhase.validating ||
    AdminModePhase.on => true,
    _ => false,
  };

  /// Asks the engine to turn [serverId]'s admin mode on or off; the engine
  /// answers with [AdminModeState]s, which [stateFor] follows.
  void setEnabled(String serverId, {required bool enabled}) {
    if (_engineStopped) return;
    try {
      _engine.send(SetAdminMode(serverId, enabled: enabled));
    } on StateError {
      _onEngineDone();
    }
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! AdminModeState) return;
    _states[event.serverId] = event;
    notifyListeners();
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    _states.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
