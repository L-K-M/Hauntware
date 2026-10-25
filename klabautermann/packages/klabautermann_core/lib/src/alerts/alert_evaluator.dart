// In-app threshold alerts (ALR-01, 03 §7.19, D29): the engine evaluates
// every synced `rule` on the live samples of the servers it applies to,
// with threshold.dart's hysteresis, and reports each raise and clear.
// Evaluated on this device while Klabautermann is open, and only then.
import 'package:klabautermann_host/klabautermann_host.dart'
    show FsMount, RuleEvalScope, RuleScope, ThresholdState, evaluateThreshold;

import '../catalog/klabautermann_records.dart' show SyncedRule;
import '../engine/protocol.dart';

/// The metrics a rule can name, by their wire ids (03 §7.19), each a
/// percentage or ratio the samples already carry.
enum AlertMetric {
  /// CPU busy percent, `100 - idle - iowait` (`overview`, `core`).
  cpuBusy('cpu.busy'),

  /// Used memory as a percentage of the total (`overview`, `core`).
  memoryUsed('memory.used'),

  /// The 1-minute load average per core (`overview`, `core`).
  loadPerCore('load.perCore'),

  /// The fullest real filesystem's used space, in percent (`fs`).
  diskUsed('disk.used'),

  /// The fullest real filesystem's used inodes, in percent (`fs`).
  diskInodes('disk.inodes');

  const AlertMetric(this.id);

  /// The id a rule's `metric` field carries.
  final String id;

  /// The metric [id] names, or null for one this version does not know,
  /// whose rules stay idle.
  static AlertMetric? byId(String id) {
    for (final metric in values) {
      if (metric.id == id) return metric;
    }
    return null;
  }
}

/// What [result] says of each [AlertMetric] it carries; a metric it does
/// not carry, or carries as unknown, is absent, which holds a rule's
/// phase (an unknown value is never zero, 03 §10.4).
Map<AlertMetric, double> alertValues(SampleResult result) {
  final values = <AlertMetric, double>{};
  void put(AlertMetric metric, double? value) {
    if (value != null && value.isFinite) values[metric] = value;
  }

  switch (result) {
    case OverviewResult(:final cpu, :final memory, :final loadPerCore) ||
        CoreResult(:final cpu, :final memory, :final loadPerCore):
      put(AlertMetric.cpuBusy, cpu?.busy);
      put(AlertMetric.memoryUsed, _percent(memory));
      put(AlertMetric.loadPerCore, loadPerCore);
    case FsResult(:final fs):
      double? fullest(int? Function(FsMount mount) of) {
        double? top;
        for (final mount in fs.mounts) {
          if (mount.isPseudo) continue;
          final value = of(mount);
          if (value != null && (top == null || value > top)) {
            top = value.toDouble();
          }
        }
        return top;
      }
      put(AlertMetric.diskUsed, fullest((m) => m.capacityPercent));
      put(AlertMetric.diskInodes, fullest((m) => m.inodeUsePercent));
    default:
      break;
  }
  return values;
}

double? _percent(MemoryUsage? memory) {
  final used = memory?.usedBytes;
  final total = memory?.totalBytes;
  if (used == null || total == null || total <= 0) return null;
  return used / total * 100;
}

/// The rules' state per server, fed with every sample: one hysteresis
/// state per rule and server it applies to.
final class AlertEvaluator {
  List<SyncedRule> _rules = const [];

  /// Each fleet server's group; a server outside the fleet is never
  /// evaluated.
  Map<String, String?> _fleet = const {};

  final Map<(String, String), ThresholdState> _states = {};

  /// The last value each state saw, which a clear reports.
  final Map<(String, String), double> _values = {};

  /// Takes the synced rules. A rule that is gone or changed starts over,
  /// and one that was raised reports its clear.
  List<LocalAlertChanged> setRules(List<SyncedRule> rules, DateTime at) {
    final kept = {
      for (final rule in rules)
        if (_ruleFor(rule.id) case final old? when _same(old, rule)) rule.id,
    };
    final old = _rules;
    _rules = List.unmodifiable(rules);
    return _drop(
      (ruleId, _) => !kept.contains(ruleId),
      at,
      ruleOf: (id) => _find(old, id),
    );
  }

  /// Takes the fleet, each server with its group. A server that left, or
  /// whose group no longer matches a rule, reports its raised alerts as
  /// cleared.
  List<LocalAlertChanged> setFleet(Map<String, String?> fleet, DateTime at) {
    _fleet = Map.unmodifiable(fleet);
    return _drop(
      (ruleId, serverId) {
        final rule = _ruleFor(ruleId);
        return rule == null || !_applies(rule, serverId);
      },
      at,
      ruleOf: _ruleFor,
    );
  }

  /// Evaluates every rule that applies to [serverId] on [result], read
  /// at [at], and reports each that raised or cleared.
  List<LocalAlertChanged> observe(
    String serverId,
    SampleResult result,
    DateTime at,
  ) {
    final values = alertValues(result);
    if (values.isEmpty) return const [];

    final changes = <LocalAlertChanged>[];
    for (final synced in _rules) {
      if (!_applies(synced, serverId)) continue;
      final metric = AlertMetric.byId(synced.rule.metric);
      final value = values[metric];
      if (value == null) continue;

      final key = (synced.id, serverId);
      final before = _states[key] ?? ThresholdState.idle;
      final after = evaluateThreshold(
        synced.rule,
        before,
        value: value,
        at: at,
      );
      _states[key] = after;
      _values[key] = value;
      if (before.raised == after.raised) continue;
      changes.add(_change(synced, serverId, after, value, at));
    }
    return changes;
  }

  /// Forgets the states [gone] names, reporting each raised one as
  /// cleared with the rule [ruleOf] finds for it.
  List<LocalAlertChanged> _drop(
    bool Function(String ruleId, String serverId) gone,
    DateTime at, {
    required SyncedRule? Function(String ruleId) ruleOf,
  }) {
    final changes = <LocalAlertChanged>[];
    _states.removeWhere((key, state) {
      final (ruleId, serverId) = key;
      if (!gone(ruleId, serverId)) return false;
      final value = _values.remove(key);
      final rule = ruleOf(ruleId);
      if (state.raised && rule != null) {
        changes.add(_change(rule, serverId, ThresholdState.idle, value, at));
      }
      return true;
    });
    return changes;
  }

  LocalAlertChanged _change(
    SyncedRule synced,
    String serverId,
    ThresholdState state,
    double? value,
    DateTime at,
  ) => LocalAlertChanged(
    serverId: serverId,
    ruleId: synced.id,
    metric: synced.rule.metric,
    severity: AlertSeverity.values.byName(synced.rule.severity.name),
    raised: state.raised,
    value: value,
    at: at,
    since: state.raised ? state.since : null,
  );

  SyncedRule? _ruleFor(String id) => _find(_rules, id);

  static SyncedRule? _find(List<SyncedRule> rules, String id) {
    for (final rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }

  bool _applies(SyncedRule synced, String serverId) {
    if (!_fleet.containsKey(serverId)) return false;
    if (synced.rule.evalScope != RuleEvalScope.client) return false;
    return switch (synced.rule.scope) {
      RuleScope.server => synced.target == serverId,
      RuleScope.group =>
        synced.target != null && _fleet[serverId] == synced.target,
      RuleScope.all => true,
    };
  }

  static bool _same(SyncedRule a, SyncedRule b) =>
      a.target == b.target &&
      a.rule.toJson().toString() == b.rule.toJson().toString();
}
