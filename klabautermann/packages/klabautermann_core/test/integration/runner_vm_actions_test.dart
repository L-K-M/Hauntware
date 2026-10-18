// The engine's admin mode and host actions on the GitHub-hosted Ubuntu
// runner (M4 E29, X2, X4 and X7): a wrong sudo password asked again, rung
// 4 under timestamp_timeout=0, admin mode ending when the link drops, unit
// start, stop, restart and reload through elevation and polkit's refusal
// without it, the protected ssh.service's typed name, run timer now with
// its journal followed, other users' crontabs read masked, and a kill of
// another account's process through elevation. This is the engine-level
// elevation test beside Séance's real-sudo one. runner_vm.sh makes the
// accounts, units and crontabs and runs these one at a time; without it
// they skip.
@Tags(['runner-vm'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show CronJobEntry, HostCommands;
import 'package:test/test.dart';

import 'support/fixture.dart';
import 'support/runner_vm.dart';

/// Covers sudo's delay after each wrong password (pam_faildelay) and the
/// validation runs that follow.
const _adminWait = Duration(seconds: 60);

/// Covers a plan's steps over the link, a systemctl job included.
const _runWait = Duration(seconds: 60);

/// Covers journald writing a unit's output before a read finds it.
const _journalWait = Duration(seconds: 20);

/// Covers the supervisor seeing the link drop after its sshd processes
/// were killed.
const _dropWait = Duration(seconds: 60);

const _wrongPassword = 'not-the-password';

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('the runner-VM actions suite', () {}, skip: runnerVmSkipReason);
    return;
  }

  /// An engine with management on for every imported server, connected
  /// to [servers] and holding their probes.
  Future<FixtureEngine> managed(String name, List<String> servers) async {
    final engine = await vm.engine(name);
    engine.send(
      const SetSafetyPolicy(
        SafetyPolicy(
          servers: {
            limitedServer: ServerSafety(management: true),
            journalServer: ServerSafety(management: true),
            sudoServer: ServerSafety(management: true),
            nocacheServer: ServerSafety(management: true),
          },
        ),
      ),
    );
    for (final server in servers) {
      await engine.connect(server, vm.hostKeys);
      await _profile(engine, server);
    }
    return engine;
  }

  group('admin mode', () {
    test('a wrong password is asked again, the right one turns it on, and '
        'a dropped link ends it', () async {
      final engine = await managed('admin-retry', [sudoServer]);
      final password = await vm.sudoPassword();

      final (state, asked) = await _admin(engine, sudoServer, [
        _wrongPassword,
        password,
      ]);
      expect(state.phase, AdminModePhase.on);
      expect(state.expiresAt, isNotNull);
      expect(state.expiresAt!.isAfter(DateTime.now()), isTrue);
      expect([for (final r in asked) r.retry], [false, true]);
      expect(asked.first.user, vm.sudoUser);
      expect(
        engine.seen.whereType<AdminModeState>().where(
          (s) => s.serverId == sudoServer && s.retry,
        ),
        isNotEmpty,
        reason: 'the second ask says the first password was wrong',
      );

      // The link drops as a restarted sshd or a lost path would drop it.
      final processes = await vm.connectionProcesses(vm.sudoUser);
      expect(processes, isNotEmpty);
      await vm.sudo(['kill', '-KILL', for (final pid in processes) '$pid']);
      final ended = await engine.until<AdminModeState>(
        (s) => s.serverId == sudoServer && s.phase == AdminModePhase.expired,
        _dropWait,
      );
      expect(ended.ended, AdminEnd.linkLost);
    });

    test('three wrong passwords fail it', () async {
      final engine = await managed('admin-wrong', [sudoServer]);

      final (state, asked) = await _admin(
        engine,
        sudoServer,
        List.filled(3, _wrongPassword),
      );
      expect(state.phase, AdminModePhase.failed);
      expect(state.failure, AdminFailure.wrongPassword);
      expect(asked, hasLength(3));
    });

    test('without a cached credential (rung 4) it turns on, and an '
        'elevated restart runs', () async {
      final engine = await managed('admin-rung4', [nocacheServer]);
      final (state, _) = await _admin(engine, nocacheServer, [
        await vm.nocachePassword(),
      ]);
      expect(state.phase, AdminModePhase.on);

      final before = await _show(vm.testService, 'MainPID');
      final planned = await _plan(
        engine,
        UnitAction(
          nocacheServer,
          unit: vm.testService,
          verb: SystemctlVerb.restart,
        ),
      );
      expect(planned.preview.requiredLevel, RequiredLevel.admin);
      expect(planned.preview.runner.identity, 'root');
      _expectFinished(await _run(engine, planned));
      expect(await _show(vm.testService, 'ActiveState'), 'active');
      expect(await _show(vm.testService, 'MainPID'), isNot(before));
    });
  });

  group('units (SVC-03)', () {
    test('stop, start, restart and reload run as root in admin '
        'mode', () async {
      final engine = await managed('units-admin', [sudoServer]);
      await _admin(engine, sudoServer, [await vm.sudoPassword()]);

      Future<void> act(SystemctlVerb verb) async {
        final planned = await _plan(
          engine,
          UnitAction(sudoServer, unit: vm.testService, verb: verb),
        );
        final step = planned.preview.steps.single as ShellStep;
        expect(step.argv, [
          'systemctl',
          '--no-ask-password',
          verb.name,
          '--',
          vm.testService,
        ]);
        expect(step.elevated, isTrue);
        expect(planned.preview.protected, isNull);
        _expectFinished(await _run(engine, planned));
      }

      await act(SystemctlVerb.stop);
      expect(await _show(vm.testService, 'ActiveState'), 'inactive');

      await act(SystemctlVerb.start);
      expect(await _show(vm.testService, 'ActiveState'), 'active');

      final before = await _show(vm.testService, 'MainPID');
      await act(SystemctlVerb.restart);
      expect(await _show(vm.testService, 'MainPID'), isNot(before));

      await act(SystemctlVerb.reload);
      await _untilJournal(vm, vm.testService, vm.reloadMessage);
    });

    test('without admin mode polkit refuses, and the failure says admin '
        'mode would run it', () async {
      final engine = await managed('units-polkit', [limitedServer]);
      final planned = await _plan(
        engine,
        UnitAction(
          limitedServer,
          unit: vm.testService,
          verb: SystemctlVerb.restart,
        ),
      );
      expect(planned.preview.requiredLevel, RequiredLevel.login);
      expect((planned.preview.steps.single as ShellStep).elevated, isFalse);

      final finished = await _run(engine, planned) as ActionFinished;
      expect(finished.outcome, ActionOutcome.failed);
      expect(finished.failure, ActionFailure.adminRequired);
      expect(await _show(vm.testService, 'ActiveState'), 'active');
    });

    test('the protected ssh.service runs only with its typed name', () async {
      final engine = await managed('units-protected', [sudoServer]);
      await _admin(engine, sudoServer, [await vm.sudoPassword()]);

      final planned = await _plan(
        engine,
        const UnitAction(
          sudoServer,
          unit: 'ssh.service',
          verb: SystemctlVerb.restart,
        ),
      );
      expect(planned.preview.protected, ProtectedReason.sessionPath);
      expect(planned.preview.requiredTier, ConfirmationTier.typedPhrase);

      // Never confirmed: the runner's own sshd stays as it is.
      for (final confirmation in const [
        ActionConfirmation(tier: ConfirmationTier.acknowledge),
        ActionConfirmation(tier: ConfirmationTier.typedPhrase, phrase: 'ssh'),
      ]) {
        final refused =
            await _run(engine, planned, confirmation: confirmation)
                as ActionRefused;
        expect(refused.reason, ActionRefusalReason.confirmationMismatch);
      }
    });
  });

  test('run timer now starts its service, whose journal follows the run '
      '(JOB-08)', () async {
    final engine = await managed('timer-now', [sudoServer, journalServer]);
    await _admin(engine, sudoServer, [await vm.sudoPassword()]);

    final planned = await _plan(
      engine,
      StartTimer(sudoServer, timer: vm.jobTimer),
    );
    expect(planned.preview.followUnit, vm.jobService);
    final step = planned.preview.steps.single as ShellStep;
    expect(step.argv, HostCommands.timerStart(vm.jobService));
    expect(step.elevated, isTrue);

    // Followed as the account in systemd-journal: the sudo account reads
    // no system unit's journal.
    const streamId = 'job';
    engine.send(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: journalServer,
          source: JournalLogSource(unit: vm.jobService),
          window: 0,
          follow: true,
        ),
      ),
    );
    await engine.until<LogStreamState>(
      (e) => e.streamId == streamId && e.status == const LogStreamRunning(),
    );

    _expectFinished(await _run(engine, planned));
    await engine.until<LogBatch>(
      (b) =>
          b.streamId == streamId &&
          b.records.any(
            (r) => r is JournalRecord && r.message == vm.jobMessage,
          ),
      _journalWait,
    );
  });

  test('other users\' crontabs are read through elevation, masked '
      '(JOB-03)', () async {
    final engine = await managed('crontabs', [sudoServer]);

    Future<UserCrontabs> read(String requestId) async {
      engine.send(ReadUserCrontabs(sudoServer, requestId: requestId));
      return engine.until<UserCrontabs>(
        (e) => e.requestId == requestId,
        _runWait,
      );
    }

    expect((await read('off')).failure, UserCrontabsFailure.adminRequired);

    await _admin(engine, sudoServer, [await vm.sudoPassword()]);
    final read2 = await read('on');
    expect(read2.failure, isNull);
    expect(read2.unreadable, isEmpty);
    final rows = read2.jobs.whereType<CronJobEntry>().toList();
    for (final user in vm.crontabUsers) {
      expect(rows.where((r) => r.job.user == user), hasLength(1), reason: user);
    }
    final shown = [for (final r in rows) '${r.job.command} ${r.job.raw}'];
    expect(shown.join('\n'), isNot(contains('secret-')));
    expect(shown.join('\n'), contains('example.invalid'));
  });

  test('another account\'s process is killed only through elevation '
      '(PRC-02)', () async {
    final engine = await managed('kill', [sudoServer]);
    // Linger keeps it running after the SSH session that started it.
    final pid = int.parse(
      (await vm.ssh(
        vm.lingerUser,
        'nohup sleep 600 </dev/null >/dev/null 2>&1 & echo \$!',
      )).trim(),
    );
    final ticks = int.parse(
      (await vm.ssh(
        vm.lingerUser,
        HostCommands.commandLine(
          HostCommands.startTicks(pid),
          quote: quoteShellWord,
        ),
      )).trim(),
    );
    final intent = KillProcess(sudoServer, pid: pid, startTicks: ticks);

    final unelevated = await _plan(engine, intent);
    expect(unelevated.preview.requiredLevel, RequiredLevel.admin);
    expect(unelevated.preview.targetName, 'sleep');
    final refused = await _run(engine, unelevated) as ActionRefused;
    expect(refused.reason, ActionRefusalReason.adminRequired);
    expect(await _alive(pid), isTrue);

    await _admin(engine, sudoServer, [await vm.sudoPassword()]);
    final planned = await _plan(engine, intent);
    expect(planned.preview.runner.identity, 'root');
    expect((planned.preview.steps.single as ShellStep).elevated, isTrue);
    _expectFinished(await _run(engine, planned));

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await _alive(pid)) {
      if (DateTime.now().isAfter(deadline)) fail('$pid still runs');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
}

/// Turns admin mode on for [serverId], answering each elevation prompt
/// with the next of [answers], and returns the state it settles in with
/// the prompts it asked.
Future<(AdminModeState, List<ElevationPromptRequest>)> _admin(
  FixtureEngine engine,
  String serverId,
  List<String> answers,
) async {
  final asked = <ElevationPromptRequest>[];
  engine.send(SetAdminMode(serverId, enabled: true));
  while (true) {
    final event = await engine.until<EngineEvent>(
      (e) => switch (e) {
        Prompt(serverId: final s, request: ElevationPromptRequest()) =>
          s == serverId,
        AdminModeState(serverId: final s, :final phase) =>
          s == serverId &&
              (phase == AdminModePhase.on || phase == AdminModePhase.failed),
        _ => false,
      },
      _adminWait,
    );
    switch (event) {
      case Prompt(:final promptId, request: final ElevationPromptRequest r):
        asked.add(r);
        expect(
          asked.length,
          lessThanOrEqualTo(answers.length),
          reason: 'asked more often than expected',
        );
        engine.send(
          AnswerPrompt(promptId, PromptSecretAnswer(answers[asked.length - 1])),
        );
      case final AdminModeState state:
        return (state, asked);
      default:
        // The test above accepts nothing else.
        break;
    }
  }
}

/// Plans [intent]; a refusal fails the test.
Future<ActionPlanned> _plan(FixtureEngine engine, ActionIntent intent) async {
  engine.send(PlanAction(intent));
  final answer = await engine.until<EngineEvent>(
    (e) => e is ActionPlanned || (e is ActionRefused && e.intent != null),
    _runWait,
  );
  if (answer case ActionRefused(:final reason)) fail('refused: $reason');
  return answer as ActionPlanned;
}

/// Runs [planned] with [confirmation], by default the one its tier asks
/// for, and returns how it finished or why it was refused.
Future<EngineEvent> _run(
  FixtureEngine engine,
  ActionPlanned planned, {
  ActionConfirmation? confirmation,
}) {
  final preview = planned.preview;
  engine.send(
    RunAction(
      planned.planId,
      confirmation ??
          ActionConfirmation(
            tier: preview.requiredTier,
            phrase: preview.requiredTier == ConfirmationTier.typedPhrase
                ? preview.targetName
                : null,
          ),
    ),
  );
  return engine.until<EngineEvent>(
    (e) => switch (e) {
      ActionFinished(:final planId) ||
      ActionRefused(:final planId?) => planId == planned.planId,
      _ => false,
    },
    _runWait,
  );
}

void _expectFinished(EngineEvent event) {
  expect(
    event,
    isA<ActionFinished>().having(
      (f) => (f.outcome, f.failure, f.exitCode),
      'outcome',
      (ActionOutcome.succeeded, null, null),
    ),
  );
}

/// [unit]'s [property] as `systemctl show` prints it, read by the runner
/// out of the engine's sight.
Future<String> _show(String unit, String property) async {
  final result = await Process.run('systemctl', [
    'show',
    '-P',
    property,
    '--',
    unit,
  ]);
  if (result.exitCode != 0) fail('systemctl show: ${result.stderr}');
  return '${result.stdout}'.trim();
}

/// Waits until [unit]'s journal holds [message], read through the
/// runner's sudo.
Future<void> _untilJournal(RunnerVm vm, String unit, String message) async {
  final deadline = DateTime.now().add(_journalWait);
  while (true) {
    final text = await vm.sudo([
      'journalctl',
      '--no-pager',
      '-o',
      'cat',
      '-u',
      unit,
    ]);
    if (text.split('\n').contains(message)) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('$unit\'s journal has no "$message"');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Whether [pid] runs: a zombie has ended.
Future<bool> _alive(int pid) async {
  final ps = await Process.run('ps', ['-o', 'stat=', '-p', '$pid']);
  return ps.exitCode == 0 && !'${ps.stdout}'.trim().startsWith('Z');
}

Future<HostProfile> _profile(FixtureEngine engine, String serverId) async {
  for (final event in engine.seen) {
    if (event is HostProfileChanged && event.serverId == serverId) {
      return event.profile;
    }
  }
  final changed = await engine.until<HostProfileChanged>(
    (e) => e.serverId == serverId,
  );
  return changed.profile;
}
