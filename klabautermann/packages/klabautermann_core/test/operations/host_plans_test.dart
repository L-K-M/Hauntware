// The host action planners (M4 E14): PRC-02's kill reads the process
// over the link and elevates only for another user's, SVC-03's unit
// actions elevate in admin mode, JOB-08's timer names the unit it starts,
// and the runner turns the guarded kill's and polkit's answers into
// typed facts.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CronJob,
        CrontabManager,
        kCrontabPauseMarker,
        kGuardedKillFailed,
        kGuardedKillReused,
        parseCrontabText,
        userCrontabSource;
import 'package:klabautermann_core/src/operations/confirmation.dart'
    show OperationKind;
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/operation_runner.dart';
import 'package:klabautermann_core/src/operations/plans/host_plans.dart';
import 'package:klabautermann_core/src/operations/protected_targets.dart';
import 'package:klabautermann_core/src/sampling/sample_results.dart'
    show maskedCronJobs;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';
const _ok = RemoteCommandResult(exitCode: 0);

/// Answers each command with the first of [answers] whose key it
/// contains, otherwise success, and records it.
final class _Link extends TestLinkBase {
  _Link(this.answers);

  final Map<String, RemoteCommandResult> answers;
  final commands = <String>[];
  Object? failure;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?) throw error;
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return _ok;
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

/// A process 4300 started at tick 9001, run by [uid] as [comm].
_Link _process({int uid = 1000, String comm = 'worker'}) => _Link({
  'klabautermann-ticks': _out('9001\n'),
  'klabautermann-facts': _out('$uid $comm\n'),
});

HostPlanContext _context(
  _Link link, {
  bool adminMode = false,
  ProtectionContext protection = const ProtectionContext(),
}) => (
  link: link,
  profile: HostProfile(uid: 1000, user: 'deploy'),
  protection: protection,
  adminMode: adminMode,
);

const _kill = KillProcess(_server, pid: 4300, startTicks: 9001);

Future<ActionFinished> _run(_Link link, OperationPlan plan) =>
    OperationRunner(linkFor: (_) => link, emit: (_) {}).run('plan-1', plan);

void main() {
  group('kill (PRC-02)', () {
    test('the login user\'s own process runs unelevated', () async {
      final attempt = await planHostAction(_kill, _context(_process()));
      final preview = attempt.plan!.preview;

      expect(preview.targetName, 'worker');
      expect(preview.requiredLevel, RequiredLevel.login);
      expect(preview.runner.identity, 'deploy');
      expect(preview.requiredTier, ConfirmationTier.acknowledge);
      expect(preview.impact?.kind, ImpactKind.interruptsTarget);
      final step = preview.steps.single as ShellStep;
      expect(step.elevated, isFalse);
      expect(step.argv, contains('klabautermann-kill'));
      expect(step.argv.sublist(step.argv.length - 3), ['4300', '9001', 'TERM']);
    });

    test('another user\'s process needs admin and runs as root', () async {
      final attempt = await planHostAction(_kill, _context(_process(uid: 33)));
      final preview = attempt.plan!.preview;

      expect(preview.requiredLevel, RequiredLevel.admin);
      expect(preview.runner.identity, 'root');
      expect(preview.runner.credentials, RunnerCredentials.adminPassword);
      expect((preview.steps.single as ShellStep).elevated, isTrue);
    });

    test('a protected process needs the typed confirmation', () async {
      final daemon = await planHostAction(
        _kill,
        _context(_process(uid: 0, comm: 'dockerd')),
      );
      expect(daemon.plan!.preview.protected, ProtectedReason.builtIn);
      expect(daemon.plan!.preview.requiredTier, ConfirmationTier.typedPhrase);

      final session = await planHostAction(
        _kill,
        _context(
          _process(comm: 'sh'),
          protection: const ProtectionContext(sessionPids: {4300}),
        ),
      );
      expect(session.plan!.preview.protected, ProtectedReason.sessionPath);
      expect(session.plan!.preview.impact?.kind, ImpactKind.dropsSession);
    });

    test('a PID that names another process, or none, is refused', () async {
      final reused = _Link({'klabautermann-ticks': _out('9100\n')});
      final gone = _Link({
        'klabautermann-ticks': const RemoteCommandResult(exitCode: 3),
      });
      final vanished = _Link({
        'klabautermann-ticks': _out('9001\n'),
        'klabautermann-facts': const RemoteCommandResult(exitCode: 3),
      });
      for (final link in [reused, gone, vanished]) {
        final attempt = await planHostAction(_kill, _context(link));
        expect(attempt.plan, isNull);
        expect(attempt.refusal, ActionRefusalReason.targetChanged);
      }
    });

    test('the guarded kill\'s reused status is a re-validation', () async {
      final link = _process();
      final plan = (await planHostAction(_kill, _context(link))).plan!;
      link.answers['klabautermann-kill'] = const RemoteCommandResult(
        exitCode: kGuardedKillReused,
      );

      final finished = await _run(link, plan);
      expect(finished.failure, ActionFailure.revalidation);
      expect(finished.revalidation, RevalidationFailure.processReused);
      expect(finished.failedStep, 0);

      link.answers['klabautermann-kill'] = const RemoteCommandResult(
        exitCode: kGuardedKillFailed,
      );
      expect((await _run(link, plan)).failure, ActionFailure.stepFailed);
    });
  });

  group('unit actions (SVC-03)', () {
    UnitAction action(SystemctlVerb verb, [String unit = 'nginx.service']) =>
        UnitAction(_server, unit: unit, verb: verb);

    test('outside admin mode it asks polkit, never for a password', () async {
      final link = _Link({});
      final preview = (await planHostAction(
        action(SystemctlVerb.restart),
        _context(link),
      )).plan!.preview;

      final step = preview.steps.single as ShellStep;
      expect(step.argv, [
        'systemctl',
        '--no-ask-password',
        'restart',
        '--',
        'nginx.service',
      ]);
      expect(step.elevated, isFalse);
      expect(preview.requiredLevel, RequiredLevel.login);
      expect(preview.impact?.kind, ImpactKind.interruptsTarget);
      expect(link.commands, isEmpty, reason: 'planning reads nothing');
    });

    test('in admin mode it runs elevated', () async {
      final preview = (await planHostAction(
        action(SystemctlVerb.stop, 'sshd.service'),
        _context(_Link({}), adminMode: true),
      )).plan!.preview;

      expect((preview.steps.single as ShellStep).elevated, isTrue);
      expect(preview.requiredLevel, RequiredLevel.admin);
      expect(preview.protected, ProtectedReason.sessionPath);
      expect(preview.requiredTier, ConfirmationTier.typedPhrase);
      expect(preview.impact?.kind, ImpactKind.dropsSession);
    });

    test('start interrupts nothing', () async {
      final preview = (await planHostAction(
        action(SystemctlVerb.start),
        _context(_Link({})),
      )).plan!.preview;
      expect(preview.impact, isNull);
    });

    test(
      'a verb that is no action and invalid unit names are refused',
      () async {
        for (final intent in [
          action(SystemctlVerb.show),
          action(SystemctlVerb.restart, 'nginx'),
          action(SystemctlVerb.restart, 'a b.service'),
        ]) {
          final attempt = await planHostAction(intent, _context(_Link({})));
          expect(attempt.refusal, ActionRefusalReason.invalidTarget);
        }
      },
    );

    test('polkit\'s refusal says admin mode is needed', () async {
      final link = _Link({
        'LoadState': _out('loaded\n'),
        "'restart'": const RemoteCommandResult(
          exitCode: 1,
          stderr:
              'Failed to restart nginx.service: '
              'Interactive authentication required.\n',
        ),
      });
      final plan = (await planHostAction(
        action(SystemctlVerb.restart),
        _context(link),
      )).plan!;

      final finished = await _run(link, plan);
      expect(finished.failure, ActionFailure.adminRequired);
      expect(finished.exitCode, 1);
    });
  });

  group('v1 unit verbs and user units (SVC-05, SVC-06, SVC-09)', () {
    test('enable, disable, unmask and reset-failed name no impact; mask '
        'does, and a protected unit needs the typed confirmation', () async {
      for (final verb in [
        SystemctlVerb.enable,
        SystemctlVerb.disable,
        SystemctlVerb.unmask,
        SystemctlVerb.resetFailed,
      ]) {
        final preview = (await planHostAction(
          UnitAction(_server, unit: 'nginx.service', verb: verb),
          _context(_Link({})),
        )).plan!.preview;
        expect(preview.impact, isNull, reason: verb.name);
        expect(preview.requiredTier, ConfirmationTier.acknowledge);
        expect((preview.steps.single as ShellStep).argv[2], verb.wireName);
      }

      final plain = (await planHostAction(
        const UnitAction(
          _server,
          unit: 'nginx.service',
          verb: SystemctlVerb.mask,
        ),
        _context(_Link({})),
      )).plan!.preview;
      expect(plain.impact?.kind, ImpactKind.interruptsTarget);
      expect(plain.requiredTier, ConfirmationTier.acknowledge);

      final protected = (await planHostAction(
        const UnitAction(
          _server,
          unit: 'ssh.service',
          verb: SystemctlVerb.mask,
        ),
        _context(_Link({})),
      )).plan!.preview;
      expect(protected.requiredTier, ConfirmationTier.typedPhrase);
    });

    test("a user unit's verb runs as the login user even in admin mode, "
        "in the user's manager", () async {
      final link = _Link({'LoadState': _out('loaded\n')});
      final plan = (await planHostAction(
        const UnitAction(
          _server,
          unit: 'syncthing.service',
          verb: SystemctlVerb.restart,
          scope: UnitScope.user,
        ),
        (
          link: link,
          profile: HostProfile(
            uid: 1000,
            user: 'deploy',
            xdgRuntimeDir: '/run/user/1000',
          ),
          protection: const ProtectionContext(),
          adminMode: true,
        ),
      )).plan!;
      final preview = plan.preview;

      final step = preview.steps.single as ShellStep;
      expect(step.elevated, isFalse);
      expect(step.argv, [
        'systemctl',
        '--user',
        '--no-ask-password',
        'restart',
        '--',
        'syncthing.service',
      ]);
      expect(preview.requiredLevel, RequiredLevel.login);
      expect(preview.runner.identity, 'deploy');

      // The re-validation reads the user's manager too.
      await _run(link, plan);
      expect(
        link.commands.first,
        contains("'systemctl' '--user' 'show' '--property=LoadState'"),
      );
    });

    test('a session without XDG_RUNTIME_DIR gets systemd\'s own', () async {
      final preview = (await planHostAction(
        const UnitAction(
          _server,
          unit: 'syncthing.service',
          verb: SystemctlVerb.stop,
          scope: UnitScope.user,
        ),
        (
          link: _Link({}),
          profile: HostProfile(uid: 1000, user: 'deploy'),
          protection: const ProtectionContext(),
          adminMode: false,
        ),
      )).plan!.preview;
      expect((preview.steps.single as ShellStep).argv.take(4), [
        'env',
        'XDG_RUNTIME_DIR=/run/user/1000',
        'systemctl',
        '--user',
      ]);
    });

    test(
      "a user timer starts in the user's manager and follows nothing",
      () async {
        final link = _Link({'--property=Unit': _out('backup.service\n')});
        final preview = (await planHostAction(
          const StartTimer(
            _server,
            timer: 'backup.timer',
            scope: UnitScope.user,
          ),
          _context(link, adminMode: true),
        )).plan!.preview;

        expect(link.commands.single, contains("'--user'"));
        final step = preview.steps.single as ShellStep;
        expect(step.elevated, isFalse);
        expect(step.argv, contains('--user'));
        expect(preview.followUnit, isNull);
      },
    );
  });

  group('run timer now (JOB-08)', () {
    const timer = StartTimer(_server, timer: 'backup.timer');

    test('starts the unit the timer activates and follows it', () async {
      final link = _Link({'--property=Unit': _out('backup.service\n')});
      final preview = (await planHostAction(
        timer,
        _context(link),
      )).plan!.preview;

      expect(preview.targetName, 'backup.timer');
      expect(preview.followUnit, 'backup.service');
      expect((preview.steps.single as ShellStep).argv, [
        'systemctl',
        '--no-ask-password',
        'start',
        '--',
        'backup.service',
      ]);
      expect(preview.requiredTier, ConfirmationTier.acknowledge);
    });

    test('a timer without a unit, or activating a timer, is refused', () async {
      for (final answer in [
        _out('\n'),
        const RemoteCommandResult(exitCode: 1),
        _out('other.timer\n'),
      ]) {
        final link = _Link({'--property=Unit': answer});
        final attempt = await planHostAction(timer, _context(link));
        expect(attempt.refusal, ActionRefusalReason.invalidTarget);
      }
    });
  });

  group('refresh package lists (PKG-05)', () {
    const refresh = RefreshPackageLists(_server);

    test('the found manager\'s lists refresh as root, in admin mode '
        'only', () async {
      final link = _Link({'command -v': _out('apt\n')});
      expect(
        (await planHostAction(refresh, _context(link))).refusal,
        ActionRefusalReason.adminRequired,
      );
      expect(link.commands, isEmpty);

      final preview = (await planHostAction(
        refresh,
        _context(link, adminMode: true),
      )).plan!.preview;
      expect(preview.targetName, 'apt');
      final step = preview.steps.single as ShellStep;
      expect(step.argv, ['apt-get', '-q', 'update']);
      expect(step.elevated, isTrue);
      expect(preview.requiredLevel, RequiredLevel.admin);
      expect(preview.hostWrites, contains(HostWriteRow.packageLists));
      expect(preview.requiredTier, ConfirmationTier.acknowledge);
    });

    test('pacman, or no manager, is refused', () async {
      for (final answer in [
        _out('pacman\n'),
        const RemoteCommandResult(exitCode: 1),
      ]) {
        final link = _Link({'command -v': answer});
        final attempt = await planHostAction(
          refresh,
          _context(link, adminMode: true),
        );
        expect(attempt.refusal, ActionRefusalReason.invalidTarget);
      }
    });
  });

  test('a link that fails while planning refuses with noLink', () async {
    final link = _process()
      ..failure = const RemoteCommandException('channel closed');
    final attempt = await planHostAction(_kill, _context(link));
    expect(attempt.refusal, ActionRefusalReason.noLink);
  });

  group('run a cron line now (JOB-19)', () {
    const own = '0 3 * * * /usr/local/bin/backup --password=hunter2 --all';
    // The jobs list shows the line masked, and so does the intent.
    final shownRaw = maskedCronJobs([
      CronJob(source: 'crontab', schedule: '', command: own, raw: own),
    ]).values.single.raw;

    ShellStep stepOf(PlanAttempt attempt) =>
        attempt.plan!.steps.single as ShellStep;

    test("an own crontab's line runs as the login user, its output kept, "
        'its secret masked in the preview', () async {
      final link = _Link({'crontab': _out('# backups\n$own\n')});
      final attempt = await planHostAction(
        RunCronJob(_server, source: 'crontab', raw: shownRaw),
        _context(link),
      );

      final plan = attempt.plan!;
      expect(plan.kind, OperationKind.cronRunNow);
      expect(plan.requiredLevel, RequiredLevel.login);
      final step = stepOf(attempt);
      expect(step.elevated, isFalse);
      expect(step.captureOutput, isTrue);
      expect(step.argv, [
        'sh',
        '-c',
        '/usr/local/bin/backup --password=hunter2 --all',
      ]);
      expect(step.display, isNot(contains('hunter2')));
      expect(plan.preview.targetName, isNot(contains('hunter2')));
    });

    test('a paused line runs its held command, as shown masked with its '
        'state and manager kept (JOB-07, JOB-09)', () async {
      const paused =
          '${kCrontabPauseMarker}2026-10-21T03:00:00Z 0 3 * * * /bin/backup';
      final shown = maskedCronJobs(
        parseCrontabText(
          '# dokku\n$paused\n',
          source: 'crontab',
          systemTable: false,
        ),
      ).values.single;
      expect(shown.paused, isTrue);
      expect(shown.managedBy, CrontabManager.dokku);

      final link = _Link({'crontab': _out('# dokku\n$paused\n')});
      final attempt = await planHostAction(
        RunCronJob(_server, source: 'crontab', raw: shown.raw),
        _context(link),
      );
      expect(stepOf(attempt).argv, ['sh', '-c', '/bin/backup']);
    });

    test("a line's % text is fed to the command", () async {
      const line = '0 9 * * 1 mail -s report ops%Weekly report%Thanks';
      final link = _Link({'crontab': _out('$line\n')});
      final attempt = await planHostAction(
        RunCronJob(_server, source: 'crontab', raw: line),
        _context(link),
      );

      expect(stepOf(attempt).argv.last, contains('printf %s'));
      expect(stepOf(attempt).argv.last, contains("'Weekly report\nThanks'"));
    });

    test("a system table's line runs as its user through elevation", () async {
      const line = '*/5 * * * * www-data php /srv/app/cron.php';
      final link = _Link({'cron.d/app': _out('$line\n')});
      final attempt = await planHostAction(
        RunCronJob(_server, source: '/etc/cron.d/app', raw: line),
        _context(link),
      );

      final step = stepOf(attempt);
      expect(step.elevated, isTrue);
      expect(step.argv.take(4), ['runuser', '-u', 'www-data', '--']);
      expect(attempt.plan!.requiredLevel, RequiredLevel.admin);
    });

    test("another user's crontab needs admin mode to read", () async {
      const line = '0 * * * * /home/alice/bin/sync';
      final source = userCrontabSource('alice');
      final refused = await planHostAction(
        RunCronJob(_server, source: source, raw: line),
        _context(_Link({})),
      );
      expect(refused.refusal, ActionRefusalReason.adminRequired);

      final read = <List<String>>[];
      final planned = await planHostAction(
        RunCronJob(_server, source: source, raw: line),
        _context(_Link({})),
        elevated: (argv) async {
          read.add(argv);
          return _out('$line\n');
        },
      );
      expect(read.single, ['crontab', '-l', '-u', 'alice']);
      expect(stepOf(planned).argv.take(3), ['runuser', '-u', 'alice']);
    });

    test("the login user's crontab, listed by name, is read without -u, "
        'which cronie refuses anyone but root', () async {
      // Admin mode lists every spooled crontab by name, the login user's
      // too; reading it as that user must not pass -u.
      const line = '0 * * * * /home/deploy/bin/sync';
      final link = _Link({
        '-u': const RemoteCommandResult(
          exitCode: 1,
          stderr: 'must be privileged to use -u\n',
        ),
        'crontab': _out('$line\n'),
      });
      final attempt = await planHostAction(
        RunCronJob(_server, source: userCrontabSource('deploy'), raw: line),
        _context(link),
      );

      expect(attempt.refusal, isNull);
      expect(link.commands.single, isNot(contains('-u')));
      expect(stepOf(attempt).elevated, isFalse);
      expect(stepOf(attempt).argv, ['sh', '-c', '/home/deploy/bin/sync']);
    });

    test('the run reports what the command printed, masked, and a failed '
        "one's exit status with it", () async {
      const line = '0 3 * * * /usr/local/bin/report';
      final plan = (await planHostAction(
        const RunCronJob(_server, source: 'crontab', raw: line),
        _context(_Link({'crontab': _out('$line\n')})),
      )).plan!;

      final ok = await _run(
        _Link({'report': _out('sent; token=ghp_${'a' * 36}\n')}),
        plan,
      );
      expect(ok.outcome, ActionOutcome.succeeded);
      expect(ok.exitCode, 0);
      expect(ok.output?.stdout, startsWith('sent;'));
      expect(ok.output?.stdout, isNot(contains('a' * 36)));

      final failed = await _run(
        _Link({
          'report': const RemoteCommandResult(
            exitCode: 2,
            stderr: 'no recipients\n',
          ),
        }),
        plan,
      );
      expect(failed.outcome, ActionOutcome.failed);
      expect(failed.exitCode, 2);
      expect(failed.output?.stderr, 'no recipients\n');
    });

    test('a line no longer there, or a source cron does not read, is '
        'refused', () async {
      final gone = await planHostAction(
        const RunCronJob(_server, source: 'crontab', raw: '* * * * * old'),
        _context(_Link({'crontab': _out('0 1 * * * new\n')})),
      );
      expect(gone.refusal, ActionRefusalReason.targetChanged);

      final elsewhere = await planHostAction(
        const RunCronJob(_server, source: '/etc/passwd', raw: 'x'),
        _context(_Link({})),
      );
      expect(elsewhere.refusal, ActionRefusalReason.invalidTarget);
    });
  });

  test('Docker intents are not host plans', () async {
    final attempt = await planHostAction(
      const RemoveImage(_server, image: 'busybox:1'),
      _context(_Link({})),
    );
    expect(attempt.refusal, ActionRefusalReason.notImplemented);
  });
}
