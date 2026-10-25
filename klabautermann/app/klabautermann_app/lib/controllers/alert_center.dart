import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// One raised in-app alert (ALR-01): a rule over one server's readings.
@immutable
final class ActiveAlert {
  const ActiveAlert({
    required this.serverId,
    required this.ruleId,
    required this.metric,
    required this.severity,
    required this.raisedAt,
    this.value,
    this.since,
  });

  final String serverId;
  final String ruleId;

  /// The rule's metric id, such as `cpu.busy` ([AlertMetric.byId]).
  final String metric;

  final AlertSeverity severity;

  /// The reading that raised it, by the engine's clock in UTC.
  final DateTime raisedAt;

  /// The reading's value; null where the engine reported none.
  final double? value;

  /// When the breach began, as the rule's `for` counts it.
  final DateTime? since;
}

/// One raise or clear, as the alert center's history keeps it.
@immutable
final class AlertTransition {
  const AlertTransition({
    required this.serverId,
    required this.ruleId,
    required this.metric,
    required this.severity,
    required this.raised,
    required this.at,
    this.value,
  });

  final String serverId;
  final String ruleId;
  final String metric;
  final AlertSeverity severity;

  /// True for a raise, false for a clear.
  final bool raised;

  /// The reading behind it, by the engine's clock in UTC.
  final DateTime at;

  final double? value;
}

/// The in-app alert center (ALR-01, ALR-02; 03 §7.19): what the engine's
/// rule evaluation reports this run, on Poltergeist's alert-center
/// pattern. [active] holds every raised alert until its clear arrives,
/// and [history] the latest raises and clears, newest first. Like the
/// other per-run controllers it lasts one engine run: an engine that
/// stops evaluates nothing, so its raised alerts end with it, and the
/// history stays only until the next run's controllers replace this one.
///
/// Alerts are evaluated on this device while Klabautermann is open, and
/// only then; every surface that shows them says so (Y3).
final class AlertCenter extends ChangeNotifier {
  AlertCenter(EngineClient engine) {
    _events = engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  /// How many transitions [history] keeps.
  static const int historyLimit = 100;

  late final StreamSubscription<EngineEvent> _events;
  final Map<(String, String), ActiveAlert> _active = {};
  final List<AlertTransition> _history = [];

  /// How many of [history]'s entries arrived since [markSeen].
  int _unseen = 0;

  /// Every raised alert: critical first, then warnings, then info, and
  /// within a severity the newest raise first.
  List<ActiveAlert> get active {
    final alerts = _active.values.toList()
      ..sort((a, b) {
        final bySeverity = b.severity.index.compareTo(a.severity.index);
        if (bySeverity != 0) return bySeverity;
        return b.raisedAt.compareTo(a.raisedAt);
      });
    return alerts;
  }

  /// The latest [historyLimit] raises and clears, newest first.
  List<AlertTransition> get history => List.unmodifiable(_history);

  /// The transitions that arrived since the user last opened the alert
  /// center.
  int get unseen => _unseen;

  /// The number of servers with a raised alert.
  int get serversWithAlerts => {for (final key in _active.keys) key.$2}.length;

  /// [serverId]'s raised alerts, for its fleet row's badge (ALR-02).
  int countFor(String serverId) =>
      _active.keys.where((key) => key.$2 == serverId).length;

  /// The highest severity among [serverId]'s raised alerts, or null when
  /// none is raised.
  AlertSeverity? severityFor(String serverId) {
    AlertSeverity? top;
    for (final MapEntry(:key, :value) in _active.entries) {
      if (key.$2 != serverId) continue;
      if (top == null || value.severity.index > top.index) top = value.severity;
    }
    return top;
  }

  /// Marks every transition so far as seen, as opening the alert center
  /// does.
  void markSeen() {
    if (_unseen == 0) return;
    _unseen = 0;
    notifyListeners();
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! LocalAlertChanged) return;

    final key = (event.ruleId, event.serverId);
    if (event.raised) {
      _active[key] = ActiveAlert(
        serverId: event.serverId,
        ruleId: event.ruleId,
        metric: event.metric,
        severity: event.severity,
        raisedAt: event.at,
        value: event.value,
        since: event.since,
      );
    } else {
      _active.remove(key);
    }
    _history.insert(
      0,
      AlertTransition(
        serverId: event.serverId,
        ruleId: event.ruleId,
        metric: event.metric,
        severity: event.severity,
        raised: event.raised,
        at: event.at,
        value: event.value,
      ),
    );
    if (_history.length > historyLimit) _history.removeLast();
    _unseen = (_unseen + 1).clamp(0, historyLimit);
    notifyListeners();
  }

  /// A stopped engine evaluates nothing, so no alert stays raised.
  void _onEngineDone() {
    if (_active.isEmpty) return;
    _active.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }
}
