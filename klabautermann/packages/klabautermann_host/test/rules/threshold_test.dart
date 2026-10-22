// Threshold rule evaluator tests (03 §7.19, the rule model): the pure
// `ok -> pending -> firing -> resolving -> ok` state machine with
// separate raise and clear thresholds and durations (hysteresis).
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 13, 12);

ThresholdRule _rule({
  Duration raiseFor = Duration.zero,
  Duration clearFor = Duration.zero,
}) => ThresholdRule(
  metric: 'cpu.busy',
  op: ThresholdOp.greaterThan,
  raise: ThresholdBound(value: 90, duration: raiseFor),
  clear: ThresholdBound(value: 80, duration: clearFor),
  severity: AlertSeverity.critical,
);

void main() {
  test('a zero raise duration fires immediately on the breach', () {
    final s = evaluateThreshold(
      _rule(),
      ThresholdState.idle,
      value: 95,
      at: _t0,
    );
    expect(s.phase, RulePhase.firing);
    expect(s.raised, isTrue);
  });

  test('a raise duration passes through pending before firing', () {
    final rule = _rule(raiseFor: const Duration(minutes: 5));
    var s = evaluateThreshold(rule, ThresholdState.idle, value: 95, at: _t0);
    expect(s.phase, RulePhase.pending);
    expect(s.since, _t0);
    s = evaluateThreshold(
      rule,
      s,
      value: 96,
      at: _t0.add(const Duration(minutes: 4)),
    );
    expect(s.phase, RulePhase.pending);
    s = evaluateThreshold(
      rule,
      s,
      value: 97,
      at: _t0.add(const Duration(minutes: 5)),
    );
    expect(s.phase, RulePhase.firing);
  });

  test('the hysteresis band holds firing until clear is crossed', () {
    final rule = _rule(clearFor: const Duration(minutes: 2));
    var s = evaluateThreshold(rule, ThresholdState.idle, value: 95, at: _t0);
    expect(s.phase, RulePhase.firing);
    // 85 is above clear (80) but below raise (90): still firing.
    s = evaluateThreshold(
      rule,
      s,
      value: 85,
      at: _t0.add(const Duration(minutes: 1)),
    );
    expect(s.phase, RulePhase.firing);
    // Crossing clear starts resolving.
    s = evaluateThreshold(
      rule,
      s,
      value: 70,
      at: _t0.add(const Duration(minutes: 2)),
    );
    expect(s.phase, RulePhase.resolving);
    s = evaluateThreshold(
      rule,
      s,
      value: 70,
      at: _t0.add(const Duration(minutes: 3)),
    );
    expect(s.phase, RulePhase.resolving);
    s = evaluateThreshold(
      rule,
      s,
      value: 70,
      at: _t0.add(const Duration(minutes: 4)),
    );
    expect(s.phase, RulePhase.ok);
    expect(s.raised, isFalse);
  });

  test('a breach during resolving refires immediately', () {
    final rule = _rule(clearFor: const Duration(minutes: 5));
    var s = evaluateThreshold(rule, ThresholdState.idle, value: 95, at: _t0);
    s = evaluateThreshold(
      rule,
      s,
      value: 50,
      at: _t0.add(const Duration(minutes: 1)),
    );
    expect(s.phase, RulePhase.resolving);
    s = evaluateThreshold(
      rule,
      s,
      value: 95,
      at: _t0.add(const Duration(minutes: 2)),
    );
    expect(s.phase, RulePhase.firing);
  });

  test('a drop to normal during pending returns to ok', () {
    final rule = _rule(raiseFor: const Duration(minutes: 5));
    var s = evaluateThreshold(rule, ThresholdState.idle, value: 95, at: _t0);
    expect(s.phase, RulePhase.pending);
    s = evaluateThreshold(
      rule,
      s,
      value: 10,
      at: _t0.add(const Duration(minutes: 1)),
    );
    expect(s.phase, RulePhase.ok);
  });

  test('a null or NaN value holds the previous state', () {
    final firing = ThresholdState(RulePhase.firing, _t0);
    expect(
      evaluateThreshold(_rule(), firing, value: null, at: _t0).phase,
      RulePhase.firing,
    );
    expect(
      evaluateThreshold(_rule(), firing, value: double.nan, at: _t0).phase,
      RulePhase.firing,
    );
  });

  test('a less-than rule inverts the band', () {
    final rule = ThresholdRule(
      metric: 'disk.free',
      op: ThresholdOp.lessThan,
      raise: const ThresholdBound(value: 10, duration: Duration.zero),
      clear: const ThresholdBound(value: 20, duration: Duration.zero),
    );
    expect(
      evaluateThreshold(rule, ThresholdState.idle, value: 5, at: _t0).phase,
      RulePhase.firing,
    );
    // 15 is between raise (10) and clear (20): still firing.
    expect(
      evaluateThreshold(
        rule,
        ThresholdState(RulePhase.firing, _t0),
        value: 15,
        at: _t0,
      ).phase,
      RulePhase.firing,
    );
    expect(
      evaluateThreshold(
        rule,
        ThresholdState(RulePhase.firing, _t0),
        value: 25,
        at: _t0,
      ).phase,
      RulePhase.ok,
    );
  });

  test('a rule reads back from its JSON, and a malformed one is refused', () {
    final rule = _rule(
      raiseFor: const Duration(minutes: 5),
      clearFor: const Duration(seconds: 30),
    );
    expect(ThresholdRule.fromJson(rule.toJson()).toJson(), rule.toJson());

    for (final change in <Map<String, Object?>>[
      {'metric': ''},
      {'op': 'between'},
      {'severity': null},
      {
        'raise': {'value': double.infinity, 'for': 0},
      },
      {
        'clear': {'value': 1, 'for': -1},
      },
      {'clear': 'soon'},
    ]) {
      expect(
        () => ThresholdRule.fromJson({...rule.toJson(), ...change}),
        throwsFormatException,
        reason: '$change',
      );
    }
  });
}
