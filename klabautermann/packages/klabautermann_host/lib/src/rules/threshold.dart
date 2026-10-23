/// The threshold rule model and its hysteresis evaluator (03 §7.19).
/// A rule raises when a metric holds past `raise` for its duration and
/// clears when it recovers past `clear` for its duration; the band
/// between the two holds the current phase, which is what keeps a
/// flapping metric from spamming alerts.
library;

import 'package:meta/meta.dart';

/// Where a rule applies (03 §7.19): one server, one group, or all hosts.
enum RuleScope { server, group, all }

/// The comparison a threshold applies (03 §7.19).
enum ThresholdOp { greaterThan, greaterOrEqual, lessThan, lessOrEqual }

/// Alert severity (03 §7.19).
enum AlertSeverity { info, warning, critical }

/// Where the rule is evaluated (03 §7.19): rules may run client-side
/// while the app is open or on a host that watches other hosts.
enum RuleEvalScope { client, host }

/// One side of the hysteresis: the threshold value and how long the
/// condition must hold (the rule model's `for` field, 03 §7.19).
@immutable
final class ThresholdBound {
  const ThresholdBound({required this.value, this.duration = Duration.zero});

  /// The threshold the comparison runs against.
  final double value;

  /// How long the condition must continuously hold before the phase
  /// changes (`for` in the rule model).
  final Duration duration;

  /// Reads [toJson]'s shape strictly: a [FormatException] for a missing
  /// or mistyped field, a value that is not finite or a negative
  /// duration.
  factory ThresholdBound.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('a bound is not an object');
    }
    final value = json['value'];
    final duration = json['for'];
    if (value is! num || !value.isFinite) {
      throw const FormatException('a bound has no finite value');
    }
    if (duration is! int || duration < 0) {
      throw const FormatException('a bound has no duration');
    }
    return ThresholdBound(
      value: value.toDouble(),
      duration: Duration(milliseconds: duration),
    );
  }

  Map<String, Object?> toJson() => {
    'value': value,
    'for': duration.inMilliseconds,
  };
}

/// A threshold alert rule (03 §7.19).
@immutable
final class ThresholdRule {
  const ThresholdRule({
    required this.metric,
    this.scope = RuleScope.server,
    required this.op,
    required this.raise,
    required this.clear,
    this.severity = AlertSeverity.warning,
    this.evalScope = RuleEvalScope.client,
  });

  /// The metric identifier the rule samples (e.g. `cpu.busy`).
  final String metric;

  /// Which hosts the rule applies to.
  final RuleScope scope;

  /// The comparison direction; `clear` uses the same operator, so a
  /// `greaterThan` rule clears once the value stops exceeding
  /// `clear.value` — the band between the two thresholds is the
  /// hysteresis window.
  final ThresholdOp op;

  /// The raise and clear conditions (03 §7.19 `raise`/`clear`).
  final ThresholdBound raise, clear;

  /// How loud the alert is.
  final AlertSeverity severity;

  /// Where evaluation happens.
  final RuleEvalScope evalScope;

  /// Reads [toJson]'s shape strictly, ignoring keys it does not name: a
  /// [FormatException] for a missing or mistyped field or a name no enum
  /// value has.
  factory ThresholdRule.fromJson(Map<String, Object?> json) {
    final metric = json['metric'];
    if (metric is! String || metric.isEmpty) {
      throw const FormatException('a rule has no metric');
    }
    return ThresholdRule(
      metric: metric,
      scope: _byName(RuleScope.values, json['scope'], 'scope'),
      op: _byName(ThresholdOp.values, json['op'], 'op'),
      raise: ThresholdBound.fromJson(json['raise']),
      clear: ThresholdBound.fromJson(json['clear']),
      severity: _byName(AlertSeverity.values, json['severity'], 'severity'),
      evalScope: _byName(RuleEvalScope.values, json['evalScope'], 'evalScope'),
    );
  }

  Map<String, Object?> toJson() => {
    'metric': metric,
    'scope': scope.name,
    'op': op.name,
    'raise': raise.toJson(),
    'clear': clear.toJson(),
    'severity': severity.name,
    'evalScope': evalScope.name,
  };
}

/// The value of [values] named [name], or a [FormatException] naming
/// [field].
T _byName<T extends Enum>(List<T> values, Object? name, String field) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('a rule has no known $field');
}

/// The hysteresis phase of one rule on one host (03 §7.19).
enum RulePhase {
  /// The metric is inside normal bounds.
  ok,

  /// The raise condition holds but has not held long enough.
  pending,

  /// The raise condition held for `raise.duration`: the alert is up.
  firing,

  /// The clear condition holds but has not held long enough.
  resolving,
}

/// The evaluation state carried between observations: the phase plus
/// the instant the pending or resolving stretch started.
@immutable
final class ThresholdState {
  const ThresholdState(this.phase, [this.since]);

  /// The current phase.
  final RulePhase phase;

  /// The instant the current stretch started: the first breaching
  /// observation for `pending`/`firing`, the first clearing one for
  /// `resolving`; null in `ok`.
  final DateTime? since;

  /// The initial state: `ok`, no stretch open.
  static const idle = ThresholdState(RulePhase.ok);

  /// Whether an alert is currently raised (firing or still resolving).
  bool get raised => phase == RulePhase.firing || phase == RulePhase.resolving;

  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'since': since?.toIso8601String(),
  };
}

/// Whether `value` satisfies `op` against `threshold` (03 §7.19).
bool thresholdHolds(ThresholdOp op, double value, double threshold) =>
    switch (op) {
      ThresholdOp.greaterThan => value > threshold,
      ThresholdOp.greaterOrEqual => value >= threshold,
      ThresholdOp.lessThan => value < threshold,
      ThresholdOp.lessOrEqual => value <= threshold,
    };

/// One evaluation step of the hysteresis state machine (03 §7.19):
/// `ok -> pending -> firing -> resolving -> ok`. Pure and total: a null
/// or NaN [value] is no observation and holds the previous state.
///
/// `pending` opens when the raise condition first holds and resolves to
/// `firing` once it has held for `raise.duration`. `resolving` is the
/// mirror on the clear side: it opens when the value stops satisfying
/// `clear` under the rule's operator (for `greaterThan`, recovering
/// below `clear.value`) and flips to `ok` after `clear.duration`.
/// A breach during `resolving` refires immediately; a value inside the
/// hysteresis band holds the current phase.
ThresholdState evaluateThreshold(
  ThresholdRule rule,
  ThresholdState previous, {
  required double? value,
  required DateTime at,
}) {
  if (value == null || value.isNaN) return previous;
  final breach = thresholdHolds(rule.op, value, rule.raise.value);
  final cleared = !thresholdHolds(rule.op, value, rule.clear.value);

  switch (previous.phase) {
    case RulePhase.ok:
      if (!breach) return previous;
      return rule.raise.duration <= Duration.zero
          ? ThresholdState(RulePhase.firing, at)
          : ThresholdState(RulePhase.pending, at);
    case RulePhase.pending:
      if (!breach) return ThresholdState.idle;
      final held = at.difference(previous.since ?? at);
      return held >= rule.raise.duration
          ? ThresholdState(RulePhase.firing, previous.since ?? at)
          : previous;
    case RulePhase.firing:
      if (!cleared) return previous;
      return rule.clear.duration <= Duration.zero
          ? ThresholdState.idle
          : ThresholdState(RulePhase.resolving, at);
    case RulePhase.resolving:
      if (breach) return ThresholdState(RulePhase.firing, at);
      final held = at.difference(previous.since ?? at);
      return held >= rule.clear.duration ? ThresholdState.idle : previous;
  }
}
