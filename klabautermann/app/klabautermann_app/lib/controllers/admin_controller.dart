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

  /// The crontab reads waiting on the engine, by request id, each with
  /// its server.
  final Map<String, (String, Completer<UserCrontabs>)> _crontabReads = {};

  /// The drive health reads waiting on the engine, likewise.
  final Map<String, (String, Completer<SmartReport>)> _smartReads = {};
  int _nextRead = 0;
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

  /// Reads every user's crontab on [serverId] (JOB-03), which needs
  /// admin mode; the engine answers with [UserCrontabs], a failure
  /// included. A stopped engine answers no link.
  Future<UserCrontabs> readUserCrontabs(String serverId) {
    final requestId = (_nextRead++).toString();
    if (_engineStopped) return Future.value(_noLink(serverId, requestId));
    final read = Completer<UserCrontabs>();
    _crontabReads[requestId] = (serverId, read);
    try {
      _engine.send(ReadUserCrontabs(serverId, requestId: requestId));
    } on StateError {
      _onEngineDone();
    }
    return read.future;
  }

  /// Reads every drive's health on [serverId] (HW-04), which needs admin
  /// mode; the engine answers with [SmartReport], a failure included. A
  /// stopped engine answers no link.
  Future<SmartReport> readSmart(String serverId) {
    final requestId = (_nextRead++).toString();
    if (_engineStopped) {
      return Future.value(_noSmartLink(serverId, requestId));
    }
    final read = Completer<SmartReport>();
    _smartReads[requestId] = (serverId, read);
    try {
      _engine.send(ReadSmart(serverId, requestId: requestId));
    } on StateError {
      _onEngineDone();
    }
    return read.future;
  }

  static SmartReport _noSmartLink(String serverId, String requestId) =>
      SmartReport(
        serverId: serverId,
        requestId: requestId,
        failure: SmartReportFailure.noLink,
      );

  static UserCrontabs _noLink(String serverId, String requestId) =>
      UserCrontabs(
        serverId: serverId,
        requestId: requestId,
        failure: UserCrontabsFailure.noLink,
      );

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case AdminModeState():
        _states[event.serverId] = event;
        notifyListeners();
      case UserCrontabs(:final requestId):
        _crontabReads.remove(requestId)?.$2.complete(event);
      case SmartReport(:final requestId):
        _smartReads.remove(requestId)?.$2.complete(event);
      default:
    }
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    _states.clear();
    for (final MapEntry(key: requestId, value: (serverId, read))
        in _crontabReads.entries) {
      read.complete(_noLink(serverId, requestId));
    }
    _crontabReads.clear();
    for (final MapEntry(key: requestId, value: (serverId, read))
        in _smartReads.entries) {
      read.complete(_noSmartLink(serverId, requestId));
    }
    _smartReads.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
