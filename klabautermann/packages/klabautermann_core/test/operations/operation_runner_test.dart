// The operation runner (03 §8.5, M4 E12): it re-validates, runs exactly
// the previewed steps in order, stops at the first failure, and says why
// in typed facts.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/operation_runner.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show DockerConflictException;
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ChannelRefusal,
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';
const _password = 'correct-horse-staple';

/// Answers each command with [answer]'s result and records it, with the
/// stdin it carried.
final class _Link extends TestLinkBase {
  _Link(this.answer);

  final RemoteCommandResult Function(String command, String stdin) answer;
  final commands = <String>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    return answer(command, utf8.decode(stdin ?? const []));
  }
}

const _ok = RemoteCommandResult(exitCode: 0);

OperationPlan _plan(
  List<PlanStep> steps, {
  RequiredLevel level = RequiredLevel.login,
  List<Revalidation> revalidate = const [],
  List<ShellStep> cleanup = const [],
}) => OperationPlan(
  intent: const UnitAction(
    _server,
    unit: 'nginx.service',
    verb: SystemctlVerb.restart,
  ),
  kind: OperationKind.restart,
  targetName: 'nginx.service',
  steps: steps,
  requiredLevel: level,
  runner: const RunnerFacts(identity: 'deploy'),
  revalidate: revalidate,
  cleanup: cleanup,
);

void main() {
  late List<EngineEvent> events;
  late List<OperationResult> results;

  setUp(() {
    events = [];
    results = [];
  });

  OperationRunner runner(
    _Link? link, {
    ApiStepRunner? api,
    ExecStepRunner? exec,
  }) => OperationRunner(
    linkFor: (_) => link,
    emit: events.add,
    api: api,
    exec: exec,
    finished: results.add,
  );

  test('runs exactly the previewed command lines, in order', () async {
    final link = _Link((_, _) => _ok);
    final plan = _plan([
      ShellStep(['systemctl', 'restart', 'nginx.service']),
      ShellStep(['systemctl', 'is-active', 'nginx.service']),
    ]);

    final finished = await runner(link).run('plan-1', plan);

    expect(finished.outcome, ActionOutcome.succeeded);
    expect(link.commands, [
      for (final step in plan.preview.steps) (step as ShellStep).commandLine,
    ]);
    expect(
      [for (final e in events.whereType<ActionProgress>()) e.stepIndex],
      [0, 1],
    );
    expect(events.last, same(finished));
    expect(results.single.finished, same(finished));
    expect(results.single.plan, same(plan));
  });

  test('stops at the first failing step with its exit status', () async {
    final link = _Link(
      (command, _) => command.contains('restart')
          ? const RemoteCommandResult(exitCode: 5, stderr: 'failed')
          : _ok,
    );
    final finished = await runner(link).run(
      'plan-1',
      _plan([
        ShellStep(['systemctl', 'restart', 'nginx.service']),
        ShellStep(['systemctl', 'is-active', 'nginx.service']),
      ]),
    );

    expect(finished.outcome, ActionOutcome.failed);
    expect(finished.failure, ActionFailure.stepFailed);
    expect(finished.failedStep, 0);
    expect(finished.exitCode, 5);
    expect(link.commands, hasLength(1), reason: 'nothing ran after it');
  });

  group('re-validates before the first step (03 §8.5)', () {
    Future<(ActionFinished, _Link)> check(
      Revalidation revalidation,
      RemoteCommandResult answer,
    ) async {
      final link = _Link(
        (command, _) => command.contains("'reboot'") ? _ok : answer,
      );
      final finished = await runner(link).run(
        'plan-1',
        _plan(
          [
            ShellStep(['reboot']),
          ],
          revalidate: [revalidation],
        ),
      );
      return (finished, link);
    }

    final cases = <(String, Revalidation, RemoteCommandResult, Object?)>[
      (
        'a loaded unit passes',
        const UnitLoaded('nginx.service'),
        const RemoteCommandResult(exitCode: 0, stdout: 'loaded\n'),
        null,
      ),
      (
        'a unit that no longer loads',
        const UnitLoaded('nginx.service'),
        const RemoteCommandResult(exitCode: 0, stdout: 'not-found\n'),
        RevalidationFailure.unitMissing,
      ),
      (
        'the same process passes',
        const ProcessStarted(42, 9001),
        const RemoteCommandResult(exitCode: 0, stdout: '9001\n'),
        null,
      ),
      (
        'a reused PID',
        const ProcessStarted(42, 9001),
        const RemoteCommandResult(exitCode: 0, stdout: '9100\n'),
        RevalidationFailure.processReused,
      ),
      (
        'a gone process',
        const ProcessStarted(42, 9001),
        const RemoteCommandResult(exitCode: 3),
        RevalidationFailure.processGone,
      ),
      (
        'an unreadable stat',
        const ProcessStarted(42, 9001),
        const RemoteCommandResult(exitCode: 5),
        RevalidationFailure.unreadable,
      ),
      (
        'a Docker target without the Docker checker',
        const DockerTargetUnchanged(
          DockerTargetKind.container,
          'web-1',
          'abc123',
        ),
        _ok,
        RevalidationFailure.unreadable,
      ),
    ];
    for (final (name, revalidation, answer, expected) in cases) {
      test(name, () async {
        final (finished, link) = await check(revalidation, answer);
        if (expected == null) {
          expect(finished.outcome, ActionOutcome.succeeded);
          // The check went over the link, and the step only after it.
          expect(link.commands, hasLength(2));
          expect(link.commands.first, isNot(contains("'reboot'")));
          expect(link.commands.last, contains("'reboot'"));
        } else {
          expect(finished.failure, ActionFailure.revalidation);
          expect(finished.revalidation, expected);
          expect(events.whereType<ActionProgress>(), isEmpty);
        }
      });
    }
  });

  test(
    'runs elevated steps through the session, the password on stdin',
    () async {
      final link = _Link(
        (command, stdin) => stdin.split('\n').first == _password
            ? _ok
            : const RemoteCommandResult(
                exitCode: 125,
                stderr:
                    'Sorry, try again.\nsudo: 1 incorrect password attempt\n',
              ),
      );
      const probe = ElevationProbe(
        sudoVersionLine: 'Sudo version 1.9.16p2',
        printfIsBuiltin: true,
      );
      final plan = _plan([
        ShellStep(['systemctl', 'restart', 'nginx.service'], elevated: true),
      ], level: RequiredLevel.admin);

      final ok = await runner(link).run(
        'plan-1',
        plan,
        session: AdminSession.test(ElevatedExecutor(link, probe), _password),
      );
      expect(ok.outcome, ActionOutcome.succeeded);
      expect(link.commands.single, contains(' elevate '));
      expect(link.commands.single, isNot(contains(_password)));

      final refused = await runner(link).run(
        'plan-2',
        plan,
        session: AdminSession.test(ElevatedExecutor(link, probe), 'changed'),
      );
      expect(refused.failure, ActionFailure.elevationRefused);

      final noSession = await runner(link).run('plan-3', plan);
      expect(noSession.failure, ActionFailure.elevationRefused);
    },
  );

  test("a step's input reaches its stdin, after the password line when "
      'elevated', () async {
    final stdins = <String>[];
    final link = _Link((command, stdin) {
      stdins.add(stdin);
      return _ok;
    });
    const probe = ElevationProbe(
      sudoVersionLine: 'Sudo version 1.9.16p2',
      printfIsBuiltin: true,
    );
    final content = utf8.encode('new: content\n');
    final plan = _plan([
      ShellStep(['cat'], input: content),
      ShellStep(['cat'], input: content, elevated: true),
    ], level: RequiredLevel.admin);

    final finished = await runner(link).run(
      'plan-1',
      plan,
      session: AdminSession.test(ElevatedExecutor(link, probe), _password),
    );

    expect(finished.outcome, ActionOutcome.succeeded);
    expect(stdins.first, 'new: content\n');
    expect(stdins.last, '$_password\nnew: content\n');
    expect(link.commands.join(), isNot(contains(_password)));
    expect(plan.steps.first.display, endsWith('< new content (13 bytes)'));
    expect(
      ShellStep(['cat'], input: utf8.encode('x')).display,
      endsWith(' < new content (1 byte)'),
    );
  });

  test('a failed step runs the cleanup; a step exit can mean the content '
      'changed', () async {
    final link = _Link(
      (command, _) => command.contains('replace')
          ? const RemoteCommandResult(exitCode: 101)
          : _ok,
    );
    final plan = OperationPlan(
      intent: const UnitAction(
        _server,
        unit: 'nginx.service',
        verb: SystemctlVerb.restart,
      ),
      kind: OperationKind.editFile,
      targetName: '/etc/app.conf',
      steps: [
        ShellStep(['write']),
        ShellStep(
          ['replace'],
          exitMeanings: const {101: RevalidationFailure.contentChanged},
        ),
        ShellStep(['never']),
      ],
      cleanup: [
        ShellStep(['cleanup']),
      ],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
    );

    final finished = await runner(link).run('plan-1', plan);

    expect(finished.failure, ActionFailure.revalidation);
    expect(finished.revalidation, RevalidationFailure.contentChanged);
    expect(finished.failedStep, 1);
    expect(link.commands.map((c) => c.split(' ').last), [
      "'write'",
      "'replace'",
      "'cleanup'",
    ]);
  });

  test('a refused channel mid-plan still runs the cleanup', () async {
    // The link refuses the second step's channel, at its session limit;
    // the temporary file the first step wrote is still removed.
    var refused = false;
    final link = _Link((command, _) {
      if (command.contains('replace') && !refused) {
        refused = true;
        throw const ChannelOpenException(
          ChannelRefusal.sessionLimit,
          'no session channel',
        );
      }
      return _ok;
    });
    final plan = _plan(
      [
        ShellStep(['write']),
        ShellStep(['replace']),
      ],
      cleanup: [
        ShellStep(['cleanup']),
      ],
    );

    final finished = await runner(link).run('plan-1', plan);

    expect(finished.failure, ActionFailure.transport);
    expect(link.commands.map((c) => c.split(' ').last), [
      "'write'",
      "'replace'",
      "'cleanup'",
    ]);
  });

  test('API steps need the Docker runner and a 2xx answer', () async {
    final link = _Link((_, _) => _ok);
    final plan = _plan([
      ApiStep(method: 'POST', path: '/v1.44/containers/abc/restart'),
    ]);

    expect(
      (await runner(link).run('plan-1', plan)).failure,
      ActionFailure.unsupportedStep,
    );
    final statuses = [204, 404];
    final answers = <ActionFinished>[];
    for (final status in statuses) {
      answers.add(
        await runner(link, api: (_, _) async => status).run('plan-1', plan),
      );
    }
    expect(answers.first.outcome, ActionOutcome.succeeded);
    expect(answers.last.failure, ActionFailure.stepFailed);
    expect(answers.last.httpStatus, 404);
  });

  test('an exec step needs the exec runner; its output comes back with '
      'the exit code, succeeded or not (CTX-08)', () async {
    final link = _Link((_, _) => _ok);
    final plan = _plan([
      ExecStep(
        path: '/v1.44/containers/abc/exec',
        containerId: 'abc',
        argv: const ['ls'],
      ),
    ]);
    expect(
      (await runner(link).run('plan-1', plan)).failure,
      ActionFailure.unsupportedStep,
    );

    const output = ExecOutput(stdout: 'a\n', stderr: 'warn\n');
    final done = await runner(
      link,
      exec: (_, step) async => (exitCode: 0, output: output),
    ).run('plan-1', plan);
    expect(done.outcome, ActionOutcome.succeeded);
    expect(done.exitCode, 0);
    expect(done.output, same(output));

    final failed = await runner(
      link,
      exec: (_, step) async => (exitCode: 2, output: output),
    ).run('plan-1', plan);
    expect(failed.failure, ActionFailure.stepFailed);
    expect((failed.failedStep, failed.exitCode), (0, 2));
    expect(failed.output, same(output));

    // A daemon that refuses the exec answered: the step failed, not the
    // transport.
    final refused = await runner(
      link,
      exec: (_, step) async => throw const DockerConflictException(
        409,
        'container abc is not running',
      ),
    ).run('plan-1', plan);
    expect(refused.failure, ActionFailure.stepFailed);
    expect((refused.failedStep, refused.httpStatus), (0, 409));
  });

  test('without a link, or when it fails, nothing is claimed to run', () async {
    final plan = _plan([
      ShellStep(['true']),
    ]);
    expect(
      (await runner(null).run('plan-1', plan)).failure,
      ActionFailure.noLink,
    );

    final broken = _Link(
      (_, _) => throw const RemoteCommandException('channel closed'),
    );
    final finished = await runner(broken).run('plan-2', plan);
    expect(finished.outcome, ActionOutcome.failed);
    expect(finished.failure, ActionFailure.transport);

    // A link at its session limit refuses the channel instead.
    final full = _Link(
      (_, _) => throw const ChannelOpenException(
        ChannelRefusal.sessionLimit,
        'no session channel',
      ),
    );
    final refused = await runner(full).run('plan-3', plan);
    expect(refused.failure, ActionFailure.transport);
    expect(events.whereType<ActionFinished>(), hasLength(3));
    expect(results, hasLength(3));
  });

  test('an elevated step never runs without a session, whatever the '
      'plan claims', () async {
    final link = _Link((_, _) => _ok);
    final finished = await runner(link).run(
      'plan-1',
      _plan([
        ShellStep(['systemctl', 'restart', 'nginx.service'], elevated: true),
      ]),
    );
    expect(finished.failure, ActionFailure.elevationRefused);
    expect(link.commands, isEmpty);
  });

  test('shell steps run with a session lent for them, API steps without '
      '(M4 E13, plan M6)', () async {
    final link = _Link((_, _) => _ok);
    final lent = <String>[];
    var inside = false;
    final lending = OperationRunner(
      linkFor: (_) => link,
      emit: events.add,
      api: (_, _) async {
        expect(inside, isFalse, reason: 'an API step borrows nothing');
        return 204;
      },
      lend: <T>(serverId, body) async {
        lent.add(serverId);
        inside = true;
        try {
          return await body();
        } finally {
          inside = false;
        }
      },
    );

    final shell = await lending.run(
      'plan-1',
      _plan([
        ShellStep(['systemctl', 'restart', 'nginx.service']),
      ]),
    );
    expect(shell.outcome, ActionOutcome.succeeded);
    expect(lent, [_server]);
    expect(link.commands, hasLength(1));

    final api = await lending.run(
      'plan-2',
      _plan([ApiStep(method: 'POST', path: '/v1.44/containers/abc/restart')]),
    );
    expect(api.outcome, ActionOutcome.succeeded);
    expect(lent, [_server], reason: 'no second lending');
  });
}
