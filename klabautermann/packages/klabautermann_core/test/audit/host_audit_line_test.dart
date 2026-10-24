// The host syslog line (SAF-13, 03 §8.10, M5 plan M19): the engine adds
// it to each inline plan as a last best-effort step, listed under the
// host writes, while the server's switch is on.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/audit/host_audit_line.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show DetachedRunner;
import 'package:test/test.dart';

OperationPlan _plan({
  String target = 'nginx.service',
  DetachedRunner? runner,
}) => OperationPlan(
  intent: const UnitAction(
    'srv-1',
    unit: 'nginx.service',
    verb: SystemctlVerb.restart,
  ),
  kind: OperationKind.restart,
  targetName: target,
  steps: [
    ShellStep(['systemctl', 'restart', 'nginx.service']),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(identity: 'deploy'),
  hostWrites: const [HostWriteRow.loginRecords],
  detachedRunner: runner,
);

void main() {
  test('the line ends the plan, best-effort, and the preview lists it', () {
    final plan = withHostAuditLine(
      _plan(),
      enabled: true,
      deviceName: 'Klabautermann on macOS',
    );

    final line = plan.preview.steps.last as ShellStep;
    expect(line.argv, [
      'logger',
      '-t',
      'klabautermann',
      '--',
      'restart nginx.service by Klabautermann on macOS',
    ]);
    expect(line.bestEffort, isTrue);
    expect(plan.preview.steps, hasLength(2));
    expect(plan.preview.hostWrites, [
      HostWriteRow.loginRecords,
      HostWriteRow.auditSyslog,
    ]);
    expect(plan.danger, isEmpty);
    expect(plan.tier, ConfirmationTier.acknowledge);
  });

  test('the switch off leaves the plan and its preview without it', () {
    final plain = _plan();
    final plan = withHostAuditLine(plain, enabled: false, deviceName: 'd');

    expect(plan, same(plain));
    expect(plan.preview.hostWrites, isNot(contains(HostWriteRow.auditSyslog)));
  });

  test('a detached plan, or a target with no word to log, keeps its '
      'steps', () {
    final detached = _plan(runner: DetachedRunner.loginSystemdUid);
    expect(
      withHostAuditLine(detached, enabled: true, deviceName: 'd'),
      same(detached),
    );

    final unloggable = _plan(target: '\n\t');
    expect(
      withHostAuditLine(unloggable, enabled: true, deviceName: 'd'),
      same(unloggable),
    );
  });

  test("the line keeps the plan's cleanup, so a failed step still removes "
      'its temp file (M5 M20a)', () {
    final cleanup = ShellStep(['rm', '-f', '--', '/srv/.app.conf.tmp']);
    final plain = OperationPlan(
      intent: const UnitAction(
        'srv-1',
        unit: 'nginx.service',
        verb: SystemctlVerb.restart,
      ),
      kind: OperationKind.restart,
      targetName: 'nginx.service',
      steps: [
        ShellStep(['systemctl', 'restart', 'nginx.service']),
      ],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
      cleanup: [cleanup],
    );

    final plan = withHostAuditLine(plain, enabled: true, deviceName: 'd');

    expect(plan, isNot(same(plain)));
    expect(plan.cleanup, [same(cleanup)]);
    expect(plain.steps, hasLength(1));
    expect(plain.cleanup, [same(cleanup)]);
  });

  test('a blank device name logs the line without one', () {
    final plan = withHostAuditLine(_plan(), enabled: true, deviceName: ' ');

    expect((plan.steps.last as ShellStep).argv.last, 'restart nginx.service');
  });
}
