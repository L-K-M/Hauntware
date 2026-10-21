// 03 §8.5's operation model and §8.6's tiers (M4 E09): plans are
// immutable, the preview shares the executed steps, danger findings come
// from the rendered command lines, and held plans run once, fresh, on the
// link they were planned on.
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/plan_registry.dart';
import 'package:test/test.dart';

const _intent = UnitAction(
  'srv-1',
  unit: 'nginx.service',
  verb: SystemctlVerb.restart,
);

OperationPlan _plan({
  String serverId = 'srv-1',
  Iterable<PlanStep>? steps,
  OperationKind kind = OperationKind.restart,
  ProtectedReason? protected,
  PlanOwnership? ownership,
}) => OperationPlan(
  intent: serverId == 'srv-1'
      ? _intent
      : UnitAction(
          serverId,
          unit: 'nginx.service',
          verb: SystemctlVerb.restart,
        ),
  kind: kind,
  targetName: 'nginx.service',
  steps:
      steps ??
      [
        ShellStep(['systemctl', 'restart', 'nginx.service']),
      ],
  requiredLevel: RequiredLevel.admin,
  runner: const RunnerFacts(
    identity: 'root',
    credentials: RunnerCredentials.adminPassword,
  ),
  hostWrites: const [HostWriteRow.loginRecords],
  protected: protected,
  ownership: ownership,
  revalidate: const [UnitLoaded('nginx.service')],
);

void main() {
  group('PlanStep', () {
    test('a shell step is the exact quoted command line the shell runs', () {
      final step = ShellStep(['systemctl', 'restart', "it's.service"]);

      expect(
        step.commandLine,
        HostCommands.commandLine([
          'systemctl',
          'restart',
          "it's.service",
        ], quote: quoteShellWord),
      );
      expect(step.display, step.commandLine);
      expect(ShellStep(['true'], elevated: true).display, startsWith('sudo: '));
      expect(() => step.argv.add('x'), throwsUnsupportedError);
    });

    test('an API step shows its method, versioned path and query', () {
      final step = ApiStep(
        method: 'POST',
        path: '/v1.44/containers/abc/stop',
        query: {'t': '10'},
      );
      expect(step.display, 'POST /v1.44/containers/abc/stop?t=10');
      expect(
        ApiStep(method: 'DELETE', path: '/v1.44/images/busybox').display,
        'DELETE /v1.44/images/busybox',
      );
      expect(() => step.query['force'] = '1', throwsUnsupportedError);
    });
  });

  group('OperationPlan', () {
    test('is immutable', () {
      final steps = [
        ShellStep(['systemctl', 'restart', 'nginx.service']),
      ];
      final plan = _plan(steps: steps);
      steps.add(ShellStep(['reboot']));

      expect(plan.steps, hasLength(1), reason: 'the plan copied its steps');
      expect(
        () => plan.steps.add(ShellStep(['reboot'])),
        throwsUnsupportedError,
      );
      expect(
        () => plan.hostWrites.add(HostWriteRow.engineState),
        throwsUnsupportedError,
      );
      expect(() => plan.revalidate.clear(), throwsUnsupportedError);
      expect(() => plan.danger.clear(), throwsUnsupportedError);
    });

    test('its preview carries the very steps a runner takes', () {
      final plan = _plan();
      final preview = plan.preview;

      expect(identical(preview.steps, plan.steps), isTrue);
      expect(identical(preview.hostWrites, plan.hostWrites), isTrue);
      expect(identical(preview.danger, plan.danger), isTrue);
      expect(preview.intent, same(plan.intent));
      expect(preview.targetName, 'nginx.service');
      expect(preview.requiredLevel, RequiredLevel.admin);
      expect(preview.requiredTier, plan.tier);
      expect(preview.runner.identity, 'root');
    });

    test('lints the shell steps\' words, not the API steps', () {
      final plan = _plan(
        steps: [
          ShellStep(['rm', '-rf', '/etc']),
          ApiStep(method: 'POST', path: '/v1.44/containers/prune'),
        ],
      );
      expect(plan.danger, isNotEmpty);
      expect(
        plan.danger.map((f) => f.line),
        everyElement(1),
        reason: 'each step is scanned as its own text',
      );
      expect(_plan().danger, isEmpty);
    });

    test('raises the tier for a protected or owned target', () {
      expect(_plan().tier, ConfirmationTier.acknowledge);
      expect(
        _plan(protected: ProtectedReason.builtIn).tier,
        ConfirmationTier.typedPhrase,
      );
      expect(
        _plan(ownership: const PlanOwnership('coolify')).tier,
        ConfirmationTier.typedPhrase,
      );
      expect(
        _plan(kind: OperationKind.composeDown).tier,
        ConfirmationTier.typedPhrase,
      );
    });

    test('refuses a plan without steps or a target name', () {
      expect(() => _plan(steps: const []), throwsArgumentError);
      expect(
        () => OperationPlan(
          intent: _intent,
          kind: OperationKind.restart,
          targetName: '',
          steps: [
            ShellStep(['true']),
          ],
          requiredLevel: RequiredLevel.login,
          runner: const RunnerFacts(identity: 'deploy'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('confirmation tiers (03 §8.6)', () {
    test('follow the table row by row', () {
      const tier1 = {
        OperationKind.start,
        OperationKind.stop,
        OperationKind.restart,
        OperationKind.reload,
        OperationKind.pause,
        OperationKind.unpause,
        OperationKind.kill,
        OperationKind.runTimerNow,
        OperationKind.stackStart,
        OperationKind.stackStop,
        OperationKind.stackRestart,
        OperationKind.redeploy,
        OperationKind.stackServicePull,
        OperationKind.stackServiceRecreate,
        OperationKind.stackServiceScale,
        OperationKind.removeContainer,
        OperationKind.removeUnusedImage,
        OperationKind.editFile,
        OperationKind.keepLastBackups,
      };
      for (final kind in OperationKind.values) {
        expect(
          confirmationTier(kind),
          tier1.contains(kind)
              ? ConfirmationTier.acknowledge
              : ConfirmationTier.typedPhrase,
          reason: kind.name,
        );
        for (final raised in [
          confirmationTier(kind, protected: true),
          confirmationTier(kind, actAnyway: true),
          confirmationTier(kind, fleetWide: true),
        ]) {
          expect(raised, ConfirmationTier.typedPhrase, reason: kind.name);
        }
      }
    });

    test('a typed confirmation must name the target exactly', () {
      bool ok(ConfirmationTier required, ConfirmationTier given, [String? p]) =>
          confirmationSatisfies(
            required: required,
            given: given,
            targetName: 'web-1',
            phrase: p,
          );

      expect(
        ok(ConfirmationTier.acknowledge, ConfirmationTier.acknowledge),
        isTrue,
      );
      expect(ok(ConfirmationTier.acknowledge, ConfirmationTier.none), isFalse);
      expect(
        ok(ConfirmationTier.typedPhrase, ConfirmationTier.typedPhrase, 'web-1'),
        isTrue,
      );
      expect(
        ok(ConfirmationTier.typedPhrase, ConfirmationTier.typedPhrase, 'web-2'),
        isFalse,
      );
      expect(
        ok(ConfirmationTier.typedPhrase, ConfirmationTier.acknowledge, 'web-1'),
        isFalse,
      );
      expect(
        ok(ConfirmationTier.acknowledge, ConfirmationTier.typedPhrase, 'x'),
        isTrue,
        reason: 'a higher tier satisfies a lower one',
      );
    });
  });

  group('PlanRegistry', () {
    late DateTime now;
    late PlanRegistry registry;

    setUp(() {
      now = DateTime.utc(2026, 10, 18, 12);
      registry = PlanRegistry(now: () => now, random: Random(1));
    });

    test('runs a held plan once, on the generation it was planned on', () {
      final plan = _plan();
      final id = registry.hold(plan, linkGeneration: 3);

      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      final first = registry.take(id, linkGeneration: (_) => 3);
      expect(first.plan, same(plan));
      expect(first.missing, isNull);
      expect(
        registry.take(id, linkGeneration: (_) => 3).missing,
        PlanMissing.unknown,
      );
    });

    test('refuses a plan past its lifetime or from an older link', () {
      final expired = registry.hold(_plan(), linkGeneration: 1);
      final stale = registry.hold(_plan(), linkGeneration: 1);
      now = now.add(kPlanLifetime - const Duration(seconds: 1));
      expect(
        registry.take(stale, linkGeneration: (_) => 2).missing,
        PlanMissing.stale,
      );
      now = now.add(const Duration(seconds: 1));
      expect(
        registry.take(expired, linkGeneration: (_) => 1).missing,
        PlanMissing.expired,
      );
      expect(registry.length, 0, reason: 'refused plans never run later');
    });

    test('drops expired plans as new ones come, and forgets servers', () {
      registry.hold(_plan(), linkGeneration: 1);
      now = now.add(kPlanLifetime);
      final kept = registry.hold(_plan(serverId: 'srv-2'), linkGeneration: 1);
      registry.hold(_plan(), linkGeneration: 1);
      expect(registry.length, 2);

      registry.forget({'srv-1'});
      expect(registry.length, 1);
      expect(registry.take(kept, linkGeneration: (_) => 1).plan, isNotNull);
    });
  });
}
