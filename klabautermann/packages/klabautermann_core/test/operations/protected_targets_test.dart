// 03 §8.6's protected targets, 8.7's ownership, AI-01's danger findings
// and the impact facts (M4 E10): every built-in entry, the session's own
// path, containers on the SSH or a VPN port, a managed stack, and the
// linter's rules reaching a preview, API steps included.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/danger.dart';
import 'package:klabautermann_core/src/operations/impact.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/ownership.dart';
import 'package:klabautermann_core/src/operations/protected_targets.dart';
import 'package:test/test.dart';

const _none = ProtectionContext();

void main() {
  group('units', () {
    test('every built-in entry is protected', () {
      for (final pattern in kProtectedUnits) {
        final unit = pattern.replaceAll('*', 'wg0');
        expect(unitProtection(unit, _none), isNotNull, reason: unit);
      }
      expect(
        unitProtection('sshd.service', _none),
        ProtectedReason.sessionPath,
      );
      expect(
        unitProtection('wg-quick@office.service', _none),
        ProtectedReason.builtIn,
      );
    });

    test('other units are not, unless the user marked them', () {
      for (final unit in [
        'nginx.service',
        'wg-quick.service',
        'docker-cleanup.timer',
        'mysshd.service',
      ]) {
        expect(unitProtection(unit, _none), isNull, reason: unit);
      }
      expect(
        unitProtection(
          'nginx.service',
          const ProtectionContext(marks: {'nginx.service'}),
        ),
        ProtectedReason.userMarked,
      );
    });
  });

  group('processes', () {
    test('the session path, PID 1 and the core daemons', () {
      const context = ProtectionContext(sessionPids: {4242, 4241, 900});
      expect(
        processProtection(pid: 4241, comm: 'sshd', context: context),
        ProtectedReason.sessionPath,
      );
      expect(
        processProtection(pid: 1, comm: 'systemd', context: _none),
        ProtectedReason.builtIn,
      );
      for (final comm in ['sshd', 'dockerd', 'containerd']) {
        expect(
          processProtection(pid: 77, comm: comm, context: _none),
          ProtectedReason.builtIn,
          reason: comm,
        );
      }
      expect(processProtection(pid: 77, comm: 'nginx', context: _none), isNull);
    });

    test('the context joins sampler PIDs, the probe and the marks', () {
      final context = protectionContextOf(
        samplerPids: {4242, 4241},
        profile: HostProfile(
          sshConnection: '203.0.113.9 51515 192.0.2.10 2222',
          sessionParentPid: 900,
        ),
        safety: const ServerSafety(marks: {'web-1'}),
      );
      expect(context.sessionPids, {4242, 4241, 900});
      expect(context.sshPort, 2222);
      expect(context.marks, {'web-1'});
      expect(sshServerPort('not four fields'), isNull);
      expect(sshServerPort('a b c 70000'), isNull);
    });
  });

  group('containers', () {
    ProtectedReason? published(List<ContainerPort> ports, {int? sshPort}) =>
        containerProtection(
          name: 'c1',
          ports: ports,
          context: ProtectionContext(sshPort: sshPort),
        );

    test('publishing the SSH port, port 22 or a VPN port', () {
      expect(
        published(const [ContainerPort(privatePort: 22, publicPort: 22)]),
        ProtectedReason.publishesSessionPort,
      );
      expect(
        published(const [
          ContainerPort(privatePort: 22, publicPort: 2222, type: 'tcp'),
        ], sshPort: 2222),
        ProtectedReason.publishesSessionPort,
      );
      expect(
        published(const [
          ContainerPort(privatePort: 51820, publicPort: 51820, type: 'udp'),
        ]),
        ProtectedReason.publishesSessionPort,
        reason: 'a WireGuard container',
      );
      expect(
        published(const [
          ContainerPort(privatePort: 1194, publicPort: 1194, type: 'tcp'),
        ]),
        ProtectedReason.publishesSessionPort,
      );
    });

    test('other ports, an unpublished 22 and WireGuard over tcp are not', () {
      expect(
        published(const [ContainerPort(privatePort: 80, publicPort: 8080)]),
        isNull,
      );
      expect(published(const [ContainerPort(privatePort: 22)]), isNull);
      expect(
        published(const [
          ContainerPort(privatePort: 51820, publicPort: 51820, type: 'tcp'),
        ]),
        isNull,
      );
      expect(
        containerProtection(
          name: 'web-1',
          ports: const [],
          context: const ProtectionContext(marks: {'web-1'}),
        ),
        ProtectedReason.userMarked,
      );
    });
  });

  test('a managed stack names its manager and needs the typed step', () {
    final managed = stackOwnership([
      {'com.docker.compose.project': MaskedValue.plain('web')},
      {'coolify.managed': MaskedValue.plain('true')},
    ]);
    expect(managed?.manager, 'Coolify');
    expect(
      stackOwnership([
        {'com.docker.compose.project': MaskedValue.plain('web')},
      ]),
      isNull,
    );

    final plan = OperationPlan(
      intent: const StackAction('srv-1', project: 'web', verb: StackVerb.stop),
      kind: OperationKind.stackStop,
      targetName: 'web',
      steps: [ApiStep(method: 'POST', path: '/v1.44/containers/abc/stop')],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
      ownership: managed,
    );
    expect(plan.tier, ConfirmationTier.typedPhrase);
    expect(plan.preview.ownership?.manager, 'Coolify');
  });

  group('danger findings (AI-01)', () {
    test('API steps read as their Docker CLI command', () {
      final cases = {
        ApiStep(
          method: 'DELETE',
          path: '/v1.44/containers/abc',
          query: {'v': '1', 'force': 'true'},
        ): 'docker rm -f -v abc',
        ApiStep(method: 'DELETE', path: '/v1.44/images/busybox:1'):
            'docker rmi busybox:1',
        ApiStep(
          method: 'DELETE',
          path: '/images/library/redis:7',
          query: {'force': '1'},
        ): 'docker rmi -f library/redis:7',
        ApiStep(method: 'DELETE', path: '/v1.44/volumes/data'):
            'docker volume rm data',
        ApiStep(
          method: 'POST',
          path: '/v1.44/containers/abc/kill',
          query: {'signal': 'HUP'},
        ): 'docker kill -s HUP abc',
        ApiStep(method: 'POST', path: '/v1.44/volumes/prune'):
            'docker volume prune -f',
        ApiStep(method: 'POST', path: '/v1.44/containers/abc/restart'):
            'docker restart abc',
      };
      for (final MapEntry(key: step, value: cli) in cases.entries) {
        expect(cliEquivalent(step), cli, reason: step.display);
      }
      expect(
        cliEquivalent(ApiStep(method: 'POST', path: '/v1.44/images/create')),
        isNull,
      );
    });

    test('the linter\'s rules reach the preview, from both kinds of step', () {
      final plan = OperationPlan(
        intent: const RemoveContainer('srv-1', containerId: 'abc'),
        kind: OperationKind.removeContainerWithVolumes,
        targetName: 'abc',
        steps: [
          ShellStep(['rm', '-rf', '/etc']),
          ShellStep(['systemctl', 'stop', 'sshd']),
          ApiStep(method: 'DELETE', path: '/v1.44/volumes/data'),
          ApiStep(method: 'POST', path: '/v1.44/volumes/prune'),
        ],
        requiredLevel: RequiredLevel.login,
        runner: const RunnerFacts(identity: 'deploy'),
      );
      expect(plan.preview.danger, hasLength(4));
      expect(
        lintSteps([
          ShellStep(['true']),
        ]),
        isEmpty,
      );
    });
  });

  group('impact', () {
    test('units on the session path drop it; engines stop containers', () {
      expect(unitImpact('sshd.service').kind, ImpactKind.dropsSession);
      expect(unitImpact('wg-quick@wg0.service').kind, ImpactKind.dropsSession);
      final engine = unitImpact('docker.service', runningContainers: 23);
      expect(engine.kind, ImpactKind.stopsContainers);
      expect(engine.count, 23);
      expect(unitImpact('nginx.service').kind, ImpactKind.interruptsTarget);
    });

    test('removals name what they take', () {
      expect(
        containerRemovalImpact(volumes: true).kind,
        ImpactKind.removesVolumes,
      );
      expect(imageRemovalImpact(usingContainers: 0), isNull);
      final forced = imageRemovalImpact(usingContainers: 2)!;
      expect(forced.kind, ImpactKind.forcesImageInUse);
      expect(forced.count, 2);
      expect(stackImpact(runningContainers: 4).count, 4);
    });
  });
}
