// ALR-01's evaluation (03 §7.19, D29): synced rules on live samples, with
// raise and clear hysteresis, per server their scope names.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/alerts/alert_evaluator.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    as host
    show AlertSeverity;
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 10, 25, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

/// CPU busy past 90 % for 20 s raises; back under 70 % for 30 s clears.
SyncedRule _cpu({
  String id = 'r-cpu',
  RuleScope scope = RuleScope.all,
  String? target,
  RuleEvalScope evalScope = RuleEvalScope.client,
  String metric = 'cpu.busy',
  double raise = 90,
}) => SyncedRule(
  id: id,
  target: target,
  rule: ThresholdRule(
    metric: metric,
    scope: scope,
    op: ThresholdOp.greaterThan,
    raise: ThresholdBound(value: raise, duration: const Duration(seconds: 20)),
    clear: const ThresholdBound(value: 70, duration: Duration(seconds: 30)),
    severity: host.AlertSeverity.critical,
    evalScope: evalScope,
  ),
);

OverviewResult _cpuAt(double busy) =>
    OverviewResult(cpu: CpuPercentages(const [], busy));

void main() {
  late AlertEvaluator alerts;

  setUp(() {
    alerts = AlertEvaluator()
      ..setFleet({'web': 'prod', 'db': 'prod', 'lab': null}, _t0);
  });

  test('raises once the breach held for the raise duration, and clears '
      'once the value held under the clear threshold for its duration', () {
    alerts.setRules([_cpu()], _t0);

    expect(alerts.observe('web', _cpuAt(95), _at(0)), isEmpty);
    expect(alerts.observe('web', _cpuAt(96), _at(10)), isEmpty);
    final raised = alerts.observe('web', _cpuAt(97), _at(20)).single;
    expect(raised.serverId, 'web');
    expect(raised.ruleId, 'r-cpu');
    expect(raised.metric, 'cpu.busy');
    expect(raised.severity, AlertSeverity.critical);
    expect(raised.raised, isTrue);
    expect(raised.value, 97);
    expect(raised.since, _at(0));

    // Inside the band (70 to 90) it stays up; under 70 it starts to
    // clear, and a breach while clearing keeps it up.
    expect(alerts.observe('web', _cpuAt(80), _at(30)), isEmpty);
    expect(alerts.observe('web', _cpuAt(60), _at(40)), isEmpty);
    expect(alerts.observe('web', _cpuAt(95), _at(50)), isEmpty);
    expect(alerts.observe('web', _cpuAt(60), _at(60)), isEmpty);
    expect(alerts.observe('web', _cpuAt(60), _at(80)), isEmpty);
    final cleared = alerts.observe('web', _cpuAt(55), _at(90)).single;
    expect(cleared.raised, isFalse);
    expect(cleared.value, 55);
    expect(cleared.since, isNull);
  });

  test('the rule model and the protocol name the same severities, which '
      'the evaluator maps by name', () {
    expect(
      [for (final s in host.AlertSeverity.values) s.name],
      [for (final s in AlertSeverity.values) s.name],
    );
  });

  test('a short breach never raises, and an unknown value holds the '
      'phase rather than reading as zero', () {
    alerts.setRules([_cpu()], _t0);
    expect(alerts.observe('web', _cpuAt(95), _at(0)), isEmpty);
    expect(alerts.observe('web', _cpuAt(50), _at(10)), isEmpty);
    expect(alerts.observe('web', _cpuAt(95), _at(25)), isEmpty);
    // No CPU in this reading: the pending breach neither ends nor grows.
    expect(alerts.observe('web', OverviewResult(), _at(40)), isEmpty);
    expect(alerts.observe('web', _cpuAt(95), _at(45)).single.raised, isTrue);
  });

  test('a rule applies to its server, its group or the whole fleet, never '
      'outside the fleet, and a host-evaluated rule never here', () {
    alerts.setRules([
      _cpu(id: 'server', scope: RuleScope.server, target: 'db', raise: 10),
      _cpu(id: 'group', scope: RuleScope.group, target: 'prod', raise: 10),
      _cpu(id: 'host', evalScope: RuleEvalScope.host, raise: 10),
      _cpu(id: 'unknown', metric: 'gpu.busy', raise: 10),
    ], _t0);

    Set<String> raised(String serverId) {
      alerts.observe(serverId, _cpuAt(50), _at(0));
      return {
        for (final change in alerts.observe(serverId, _cpuAt(50), _at(30)))
          change.ruleId,
      };
    }

    expect(raised('db'), {'server', 'group'});
    expect(raised('web'), {'group'});
    expect(raised('lab'), isEmpty);
    expect(raised('elsewhere'), isEmpty);
  });

  test('disk.used and disk.inodes each come from the fullest real '
      'filesystem, past pseudo ones', () {
    final values = alertValues(
      FsResult(
        FsSnapshot([
          const FsMount(
            device: '/dev/sda1',
            type: 'ext4',
            mountPoint: '/',
            capacityPercent: 40,
            inodeUsePercent: 12,
          ),
          const FsMount(
            device: '/dev/sdb1',
            type: 'xfs',
            mountPoint: '/data',
            capacityPercent: 93,
            inodeUsePercent: 3,
          ),
          const FsMount(
            device: 'tmpfs',
            type: 'tmpfs',
            mountPoint: '/run',
            capacityPercent: 99,
            inodeUsePercent: 99,
          ),
        ]),
      ),
    );
    expect(values, {AlertMetric.diskUsed: 93, AlertMetric.diskInodes: 12});
  });

  test('a removed or changed rule, and a server leaving the fleet, clear '
      'a raised alert at once', () {
    void raise(String serverId) {
      alerts.observe(serverId, _cpuAt(95), _at(0));
      expect(alerts.observe(serverId, _cpuAt(95), _at(20)), hasLength(1));
    }

    alerts.setRules([_cpu()], _t0);
    raise('web');
    final removed = alerts.setRules(const [], _at(21)).single;
    expect(
      (removed.serverId, removed.raised, removed.metric),
      ('web', false, 'cpu.busy'),
    );

    alerts.setRules([_cpu()], _t0);
    raise('web');
    // The same rule again changes nothing; a new threshold starts over.
    expect(alerts.setRules([_cpu()], _at(22)), isEmpty);
    expect(alerts.setRules([_cpu(raise: 92)], _at(23)).single.raised, isFalse);

    raise('db');
    final left = alerts.setFleet({'web': 'prod'}, _at(30)).single;
    expect((left.serverId, left.raised), ('db', false));
  });
}
