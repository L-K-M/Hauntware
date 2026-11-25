import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'engine_reads.dart';

/// The admin-mode concern (03 §8.2, SAF-02): each server's latest
/// [AdminModeState] from the engine, which runs the state machine and
/// alone holds the password, and the user's requests to turn it on or off.
/// Like the other per-run controllers it lasts one engine run: the engine
/// that stops takes every admin session with it.
final class AdminController extends ChangeNotifier {
  AdminController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
    _crontabReads = _reads(
      (event) => switch (event) {
        UserCrontabs(:final requestId) => (requestId, event),
        _ => null,
      },
    );
    _smartReads = _reads(
      (event) => switch (event) {
        SmartReport(:final requestId) => (requestId, event),
        _ => null,
      },
    );
    _restartReads = _reads(
      (event) => switch (event) {
        RestartReport(:final requestId) => (requestId, event),
        _ => null,
      },
    );
    _firewallReads = _reads(
      (event) => switch (event) {
        FirewallReport(:final requestId) => (requestId, event),
        _ => null,
      },
    );
    _sshdReads = _reads(
      (event) => switch (event) {
        SshdPostureReport(:final requestId) => (requestId, event),
        _ => null,
      },
    );
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, AdminModeState> _states = {};

  /// The crontab reads, one concern of their own like the reports below:
  /// a stopped engine answers [UserCrontabsFailure.noLink].
  late final EngineReads<UserCrontabs> _crontabReads;

  /// The drive health reads, likewise.
  late final EngineReads<SmartReport> _smartReads;

  /// The services-needing-restart reads, likewise.
  late final EngineReads<RestartReport> _restartReads;

  /// The firewall reads, likewise.
  late final EngineReads<FirewallReport> _firewallReads;

  /// The sshd posture reads, likewise.
  late final EngineReads<SshdPostureReport> _sshdReads;
  int _nextRead = 0;
  bool _engineStopped = false;

  /// One [EngineReads] per report: each treats a refused send as a
  /// stopped engine, as the hand-written maps did, since a closed port
  /// leaves the whole controller nothing to ask.
  EngineReads<A> _reads<A>((String, A)? Function(EngineEvent) answerOf) =>
      EngineReads(
        _engine,
        answerOf,
        sendFailure: SendFailure.engineStopped,
        onEngineStopped: _onEngineDone,
      );

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

  /// Turns admin mode off on every server where it is on or on its way
  /// there: it expires at once when the app locks (03 §8.2, SAF-20).
  void turnOffAll() {
    for (final serverId in _states.keys.where(isActive).toList()) {
      setEnabled(serverId, enabled: false);
    }
  }

  /// Reads every user's crontab on [serverId] (JOB-03), which needs
  /// admin mode; the engine answers with [UserCrontabs], a failure
  /// included. A stopped engine answers no link.
  Future<UserCrontabs> readUserCrontabs(String serverId) {
    final requestId = (_nextRead++).toString();
    return _crontabReads.read(
      requestId,
      ReadUserCrontabs(serverId, requestId: requestId),
      () => _noLink(serverId, requestId),
    );
  }

  /// Reads every drive's health on [serverId] (HW-04), which needs admin
  /// mode; the engine answers with [SmartReport], a failure included. A
  /// stopped engine answers no link.
  Future<SmartReport> readSmart(String serverId) {
    final requestId = (_nextRead++).toString();
    return _smartReads.read(
      requestId,
      ReadSmart(serverId, requestId: requestId),
      () => _noSmartLink(serverId, requestId),
    );
  }

  /// Reads the services on [serverId] still running replaced libraries
  /// (PKG-04), which needs admin mode; the engine answers with
  /// [RestartReport], a failure included. A stopped engine answers no
  /// link.
  Future<RestartReport> readRestarts(String serverId) {
    final requestId = (_nextRead++).toString();
    return _restartReads.read(
      requestId,
      ReadRestarts(serverId, requestId: requestId),
      () => _noRestartsLink(serverId, requestId),
    );
  }

  /// Reads [serverId]'s firewall rules (NET-06), which needs admin mode;
  /// the engine answers with [FirewallReport], a failure included. A
  /// stopped engine answers no link.
  Future<FirewallReport> readFirewall(String serverId) {
    final requestId = (_nextRead++).toString();
    return _firewallReads.read(
      requestId,
      ReadFirewall(serverId, requestId: requestId),
      () => _noFirewallLink(serverId, requestId),
    );
  }

  static FirewallReport _noFirewallLink(String serverId, String requestId) =>
      FirewallReport(
        serverId: serverId,
        requestId: requestId,
        failure: FirewallReportFailure.noLink,
      );

  /// Reads [serverId]'s effective sshd configuration for this connection
  /// (SEC-01), which needs admin mode; the engine answers with
  /// [SshdPostureReport], a failure included. A stopped engine answers
  /// no link.
  Future<SshdPostureReport> readSshdPosture(String serverId) {
    final requestId = (_nextRead++).toString();
    return _sshdReads.read(
      requestId,
      ReadSshdPosture(serverId, requestId: requestId),
      () => _noSshdLink(serverId, requestId),
    );
  }

  static SshdPostureReport _noSshdLink(String serverId, String requestId) =>
      SshdPostureReport(
        serverId: serverId,
        requestId: requestId,
        failure: SshdPostureFailure.noLink,
      );

  static RestartReport _noRestartsLink(String serverId, String requestId) =>
      RestartReport(
        serverId: serverId,
        requestId: requestId,
        failure: RestartReportFailure.noLink,
      );

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
    // The reports and their rejections are matched inside their own
    // EngineReads; only the admin-mode states are this controller's.
    if (event case AdminModeState(:final serverId)) {
      _states[serverId] = event;
      notifyListeners();
    }
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    _states.clear();
    // Each helper answers its own no-link value, as the loops here did.
    _crontabReads.dispose();
    _smartReads.dispose();
    _restartReads.dispose();
    _firewallReads.dispose();
    _sshdReads.dispose();
    notifyListeners();
  }

  @override
  void dispose() {
    // The helpers' listeners go with this controller's own: a read still
    // pending is left unanswered, as it was before they existed.
    _crontabReads.cancel();
    _smartReads.cancel();
    _restartReads.cancel();
    _firewallReads.cancel();
    _sshdReads.cancel();
    unawaited(_events.cancel());
    super.dispose();
  }
}
