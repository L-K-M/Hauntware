// The app's side of the rule model (03 §7.19): the rule model carries
// klabautermann_host's severity, which the barrel cannot export beside
// the protocol's AlertSeverity of the same name, so a rule is built and
// read here with the protocol's.
import 'package:klabautermann_host/klabautermann_host.dart'
    as host
    show AlertSeverity;
import 'package:klabautermann_host/klabautermann_host.dart'
    show RuleEvalScope, RuleScope, ThresholdBound, ThresholdOp, ThresholdRule;

import '../engine/protocol.dart' show AlertSeverity;

/// A rule over [metric] with the protocol's [severity].
ThresholdRule alertRule({
  required String metric,
  required RuleScope scope,
  required ThresholdOp op,
  required ThresholdBound raise,
  required ThresholdBound clear,
  required AlertSeverity severity,
  RuleEvalScope evalScope = RuleEvalScope.client,
}) => ThresholdRule(
  metric: metric,
  scope: scope,
  op: op,
  raise: raise,
  clear: clear,
  severity: host.AlertSeverity.values.byName(severity.name),
  evalScope: evalScope,
);

/// [rule]'s severity as the protocol names it.
AlertSeverity alertRuleSeverity(ThresholdRule rule) =>
    AlertSeverity.values.byName(rule.severity.name);
