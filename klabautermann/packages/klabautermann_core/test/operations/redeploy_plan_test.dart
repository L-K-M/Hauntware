// STK-06's pull and redeploy plan (M4 E18) over a fake engine and a stack
// check whose execs the test answers: each refusal, the orphan list and
// the profile warnings, `--host` on every step, the detached command,
// the hash re-validation at run time, and the runner's launch.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/stack_sources.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/detached_runner.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/operation_runner.dart';
import 'package:klabautermann_core/src/operations/plans/redeploy_plan.dart';
import 'package:klabautermann_core/src/operations/protected_targets.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show DetachedRunner;
import 'package:seance_core/seance_core.dart' show RemoteCommandResult;
import 'package:test/test.dart';

import '../support/forwarding_link.dart';
import '../support/scripted_link.dart';

const _server = 'srv-1';
const _socket = '/var/run/docker.sock';
const _compose = '/srv/shop/compose.yaml';
const _envFile = '/srv/shop/prod.env';
const _route = DockerEndpointRoute(
  rank: DockerRank.streamlocal,
  socketPath: _socket,
  runtime: EngineRuntime.docker,
  rootEquivalence: DockerRootEquivalence.rootfulSocket,
);
const _plugin = '0 127\nDocker Compose version v2.29.7\n\n';
const _standalone = '127 0\n\ndocker-compose version 1.29.2, build 5becea4c\n';
const _ok = RemoteCommandResult(exitCode: 0);

Map<String, Object?> _container(
  String name,
  String service, {
  String hash = 'aa11',
  String state = 'running',
  Map<String, String> extra = const {},
}) => {
  'Id': name.codeUnits.map((c) => c.toRadixString(16)).join().padRight(64, '0'),
  'Names': ['/$name'],
  'Image': 'shop/$service:1',
  'State': state,
  'Labels': {
    ComposeLabelKeys.project: 'shop',
    ComposeLabelKeys.service: service,
    ComposeLabelKeys.oneoff: 'False',
    ComposeLabelKeys.projectWorkingDir: '/srv/shop',
    ComposeLabelKeys.projectConfigFiles: _compose,
    ComposeLabelKeys.projectEnvironmentFile: _envFile,
    ComposeLabelKeys.configHash: hash,
    ...extra,
  },
};

/// The container list, filtered by label as the engine filters it.
final class _Engine extends FakeDaemon {
  final containers = <Map<String, Object?>>[];

  @override
  String respond(String requestLine) {
    final uri = Uri.parse('http://engine${requestLine.split(' ')[1]}');
    final filters = uri.queryParameters['filters'];
    final labels =
        ((filters == null ? null : jsonDecode(filters) as Map)?['label']
                as List?)
            ?.cast<String>() ??
        const [];
    final body = utf8.encode(
      jsonEncode([
        for (final c in containers)
          if (labels.every((l) {
            final [key, value] = l.split('=');
            return (c['Labels'] as Map)[key] == value;
          }))
            c,
      ]),
    );
    return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n\r\n${utf8.decode(body)}';
  }
}

/// The stack check's execs: `test -f`, the CLI lookup, `config --hash`
/// and `config --services`, each answered from the fields.
final class _Host {
  String cli = _plugin;
  String hashes = 'web aa11\ndb bb22\n';
  String services = 'web\ndb\n';
  RemoteCommandResult? everyProfile = const RemoteCommandResult(
    exitCode: 0,
    stdout: 'web\ndb\n',
  );
  final commands = <String>[];

  Future<RemoteCommandResult> run(
    String command, {
    required Duration timeout,
    required int maxOutputBytes,
  }) async {
    commands.add(command);
    if (command.contains('test -f')) {
      return const RemoteCommandResult(exitCode: 0, stdout: '0\n');
    }
    if (command.contains('docker-compose version')) {
      return RemoteCommandResult(exitCode: 0, stdout: cli);
    }
    if (command.contains('--hash')) {
      return RemoteCommandResult(exitCode: 0, stdout: hashes);
    }
    if (command.contains('--services') && command.contains('--profile')) {
      return everyProfile ?? const RemoteCommandResult(exitCode: 1);
    }
    if (command.contains('--services')) {
      return RemoteCommandResult(exitCode: 0, stdout: services);
    }
    return const RemoteCommandResult(exitCode: 1);
  }

  StackSources sources() => StackSources(
    socketPath: _socket,
    run: run,
    openFileSystem: () => throw UnsupportedError('no files'),
  );
}

HostProfile _profile({bool systemd = false, String? killUserProcesses}) =>
    HostProfile(
      uid: 1000,
      user: 'deploy',
      systemdDir: systemd,
      killUserProcesses: killUserProcesses,
    );

late _Engine _engine;
late _Host _host;

Future<PlanAttempt> _plan({
  bool removeOrphans = false,
  HostProfile? profile,
  ProtectionContext protection = const ProtectionContext(),
  DockerEndpointRoute route = _route,
  bool adminMode = false,
  Future<bool> Function(String program)? sudoAllows,
}) => planRedeploy(
  RedeployStack(_server, project: 'shop', removeOrphans: removeOrphans),
  (
    client: DockerClient(
      DockerHttpClient(() async => _engine.connect().client),
      apiVersion: ApiVersion.tryParse('1.52')!,
    ),
    route: route,
    stacks: _host.sources(),
    profile: profile ?? _profile(),
    adminMode: adminMode,
    sudoAllows: sudoAllows ?? (_) async => true,
    protection: protection,
    loginUser: 'deploy',
  ),
);

OperationPlan _planned(PlanAttempt attempt) {
  expect(attempt.refusal, isNull);
  return attempt.plan!;
}

List<String> _argv(OperationPlan plan, int step) =>
    (plan.steps[step] as ShellStep).argv;

void main() {
  setUp(() {
    _engine = _Engine()
      ..containers.addAll([
        _container('shop-web-1', 'web'),
        _container('shop-db-1', 'db', hash: 'bb22'),
      ]);
    _host = _Host();
  });

  group('the plan', () {
    test('config -q, pull and up -d, each through the endpoint', () async {
      final plan = _planned(await _plan());

      expect(plan.kind, OperationKind.redeploy);
      expect(plan.tier, ConfirmationTier.acknowledge);
      expect(plan.detachedRunner, DetachedRunner.loginSetsid);
      expect(plan.steps, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(_argv(plan, i).sublist(0, 7), [
          'docker',
          '--host',
          'unix://$_socket',
          'compose',
          '-p',
          'shop',
          '--project-directory',
        ]);
        expect(
          _argv(plan, i),
          containsAllInOrder(['-f', _compose, '--env-file', _envFile]),
        );
      }
      expect(_argv(plan, 0).sublist(_argv(plan, 0).length - 2), [
        'config',
        '-q',
      ]);
      expect((plan.steps[0] as ShellStep).discardOutput, isTrue);
      expect(plan.steps[0].display, endsWith(' >/dev/null 2>&1'));
      expect(_argv(plan, 1), containsAllInOrder(['--ansi', 'never', 'pull']));
      expect(
        _argv(plan, 2),
        containsAllInOrder(['--progress', 'plain', 'up', '-d']),
      );
      expect(_argv(plan, 2), isNot(contains('--remove-orphans')));

      expect(plan.runner.identity, 'deploy');
      expect(plan.runner.engine, 'docker $_socket');
      expect(plan.hostWrites, [
        HostWriteRow.engineState,
        HostWriteRow.userOperationRecords,
      ]);
      expect(plan.impact?.kind, ImpactKind.stopsContainers);
      expect(plan.impact?.count, 2);
      expect(plan.orphans, isEmpty);
      expect(plan.warnings, isEmpty);
      expect(plan.preview.detached, isTrue);

      final [target, config] = plan.revalidate;
      expect(
        target,
        isA<DockerTargetUnchanged>()
            .having((c) => c.kind, 'kind', DockerTargetKind.stack)
            .having((c) => c.target, 'target', 'shop'),
      );
      config as StackConfigUnchanged;
      expect(config.hashes, {'web': 'aa11', 'db': 'bb22'});
      expect(config.hashArgv, containsAllInOrder(['config', '--hash', '*']));
      expect(
        config.hashArgv,
        containsAllInOrder(['--host', 'unix://$_socket']),
      );
    });

    test('the detached command runs each step after the one before', () async {
      final plan = _planned(await _plan());
      final [shell, flag, script] = detachedArgv(plan);
      expect([shell, flag], ['/bin/sh', '-c']);
      expect(
        script,
        [for (final s in plan.steps) (s as ShellStep).commandLine].join(' && '),
      );
      expect(script, contains("'config' '-q' >/dev/null 2>&1 && "));
    });

    test('the systemd user row writes its unit too', () async {
      final plan = _planned(
        await _plan(
          profile: HostProfile(
            uid: 1000,
            user: 'deploy',
            systemdDir: true,
            lingerEnabled: true,
            xdgRuntimeDir: '/run/user/1000',
          ),
        ),
      );
      expect(plan.detachedRunner, DetachedRunner.loginSystemdUser);
      expect(plan.hostWrites, contains(HostWriteRow.transientUnit));
    });

    test('over the sudo relay it runs as root, so only in admin mode '
        '(rank 3, E16)', () async {
      const relay = DockerEndpointRoute(
        rank: DockerRank.sudoRelay,
        socketPath: _socket,
        runtime: EngineRuntime.docker,
        rootEquivalence: DockerRootEquivalence.rootfulSocket,
      );
      final plan = _planned(await _plan(route: relay, adminMode: true));
      expect(plan.requiredLevel, RequiredLevel.admin);
      expect(plan.detachedRunner, DetachedRunner.rootSetsid);
      expect(plan.runner.identity, 'root');
      expect(plan.runner.credentials, RunnerCredentials.adminPassword);

      expect(
        (await _plan(route: relay)).refusal,
        ActionRefusalReason.adminRequired,
      );
    });

    test('without a sudo rule for the elevated program, a root operation '
        'is refused and a login one elevates nothing (D66)', () async {
      const relay = DockerEndpointRoute(
        rank: DockerRank.sudoRelay,
        socketPath: _socket,
        runtime: EngineRuntime.docker,
        rootEquivalence: DockerRootEquivalence.rootfulSocket,
      );
      final asked = <String>[];
      Future<bool> scoped(String program) async {
        asked.add(program);
        return false;
      }

      expect(
        (await _plan(
          route: relay,
          adminMode: true,
          sudoAllows: scoped,
        )).refusal,
        ActionRefusalReason.sudoRightMissing,
      );
      expect(asked, ['sh'], reason: "the root setsid row elevates sh");

      asked.clear();
      final login = _planned(
        await _plan(
          adminMode: true,
          sudoAllows: scoped,
          profile: HostProfile(
            uid: 1000,
            user: 'deploy',
            systemdDir: true,
            lingerEnabled: true,
            xdgRuntimeDir: '/run/user/1000',
          ),
        ),
      );
      expect(asked, ['systemd-run']);
      expect(login.detachedRunner, DetachedRunner.loginSystemdUser);

      asked.clear();
      final plain = _planned(await _plan(sudoAllows: scoped));
      expect(asked, isEmpty, reason: 'a row that elevates nothing asks not');
      expect(plain.detachedRunner, DetachedRunner.loginSetsid);
    });

    test('a setsid operation under KillUserProcesses warns', () async {
      final plan = _planned(
        await _plan(profile: _profile(killUserProcesses: 'yes')),
      );
      expect(plan.warnings, {PlanWarning.mayDieAtLogout});
    });

    test('a protected stack needs the typed confirmation', () async {
      final plan = _planned(
        await _plan(protection: const ProtectionContext(marks: {'shop'})),
      );
      expect(plan.protected, ProtectedReason.userMarked);
      expect(plan.tier, ConfirmationTier.typedPhrase);
    });
  });

  group('orphans and profiles', () {
    test('a service the files no longer name is an orphan, and removing '
        'orphans adds the flag and the typed confirmation', () async {
      _engine.containers.add(_container('shop-cache-1', 'cache', hash: 'cc33'));
      final kept = _planned(await _plan());
      expect(kept.orphans, ['shop-cache-1']);
      expect(_argv(kept, 2), isNot(contains('--remove-orphans')));

      final removing = _planned(await _plan(removeOrphans: true));
      expect(removing.kind, OperationKind.redeployRemovingOrphans);
      expect(removing.tier, ConfirmationTier.typedPhrase);
      expect(_argv(removing, 2).sublist(_argv(removing, 2).length - 3), [
        'up',
        '-d',
        '--remove-orphans',
      ]);
    });

    test(
      'a running service only a profile names is no orphan, and warns',
      () async {
        _engine.containers.add(
          _container('shop-debug-1', 'debug', hash: 'dd44'),
        );
        _host.everyProfile = const RemoteCommandResult(
          exitCode: 0,
          stdout: 'web\ndb\ndebug\n',
        );
        final plan = _planned(await _plan());
        expect(plan.orphans, isEmpty);
        expect(plan.warnings, {PlanWarning.profileGatedServices});
        expect(
          _host.commands.where((c) => c.contains('--services')).last,
          contains("'--profile' '*' 'config' '--services'"),
        );
      },
    );

    test(
      'without every profile listed, an orphan may be profile-gated',
      () async {
        _engine.containers.add(
          _container('shop-debug-1', 'debug', hash: 'dd44'),
        );
        _host.everyProfile = null;
        final plan = _planned(await _plan());
        expect(plan.orphans, ['shop-debug-1']);
        expect(plan.warnings, {PlanWarning.profilesUnknown});
      },
    );
  });

  group('refusals', () {
    test('a project without containers is no target', () async {
      _engine.containers.clear();
      expect((await _plan()).refusal, ActionRefusalReason.invalidTarget);
    });

    test('a managed stack is refused, with no act anyway', () async {
      _engine.containers
        ..clear()
        ..add(
          _container('shop-web-1', 'web', extra: {'coolify.managed': 'true'}),
        );
      expect((await _plan()).refusal, ActionRefusalReason.stackManaged);
      expect(_host.commands, isEmpty, reason: 'refused before any exec');
    });

    test('a stack whose files hash otherwise is unverified', () async {
      _host.hashes = 'web ffff\ndb bb22\n';
      expect((await _plan()).refusal, ActionRefusalReason.stackUnverified);
    });

    test('the legacy docker-compose alone is refused', () async {
      _host.cli = _standalone;
      expect((await _plan()).refusal, ActionRefusalReason.legacyComposeOnly);
    });

    test(
      'a stack none of whose services the files print is unverified',
      () async {
        _host.hashes = 'other ee55\n';
        expect((await _plan()).refusal, ActionRefusalReason.stackUnverified);
      },
    );

    test('a config whose services cannot be listed is unverified', () async {
      _host.services = 'not a service name\n';
      expect((await _plan()).refusal, ActionRefusalReason.stackUnverified);
    });
  });

  group('re-validation', () {
    test('the hashes the preview saw pass; a changed or unreadable run '
        'does not', () async {
      final plan = _planned(await _plan());
      final check = plan.revalidate.whereType<StackConfigUnchanged>().single;
      final stacks = _host.sources();
      expect(await revalidateStackConfig(stacks, check), isNull);
      expect(_host.commands.last, contains("'--hash' '*'"));

      _host.hashes = 'web aa11\ndb 9999\n';
      expect(
        await revalidateStackConfig(stacks, check),
        RevalidationFailure.targetChanged,
      );
      _host.hashes = 'Error: no such file\n';
      expect(
        await revalidateStackConfig(stacks, check),
        RevalidationFailure.unreadable,
      );
    });
  });

  group('the runner', () {
    late List<ActionProgress> progress;
    late List<String> launches;

    OperationRunner runner({
      RevalidationFailure? changed,
      LaunchResult? launched,
    }) {
      progress = [];
      launches = [];
      return OperationRunner(
        linkFor: (_) => _NoLink(),
        emit: (event) {
          if (event is ActionProgress) progress.add(event);
        },
        docker: (_, check) async =>
            check is StackConfigUnchanged ? changed : null,
        launch: (serverId, plan, session) async {
          launches.add(serverId);
          return launched ??
              (
                id: '0123456789abcdef',
                dir: '/home/deploy/.local/state/klabautermann/ops',
                pid: 4242,
                failure: null,
                exitCode: 0,
              );
        },
      );
    }

    test('a detached plan launches once and reports its operation', () async {
      final plan = _planned(await _plan());
      final finished = await runner().run('plan-1', plan);
      expect(finished.outcome, ActionOutcome.succeeded);
      expect(finished.operationId, '0123456789abcdef');
      expect(launches, [_server]);
      expect(progress, isEmpty, reason: 'the host runs the steps');
    });

    test('a hash that changed since the preview launches nothing', () async {
      final plan = _planned(await _plan());
      final finished = await runner(
        changed: RevalidationFailure.targetChanged,
      ).run('plan-1', plan);
      expect(finished.failure, ActionFailure.revalidation);
      expect(finished.revalidation, RevalidationFailure.targetChanged);
      expect(launches, isEmpty);
    });

    test('a launcher that failed is reported with its status', () async {
      final plan = _planned(await _plan());
      final finished = await runner(
        launched: (
          id: '0123456789abcdef',
          dir: null,
          pid: null,
          failure: LaunchFailure.failed,
          exitCode: 1,
        ),
      ).run('plan-1', plan);
      expect(finished.failure, ActionFailure.launchFailed);
      expect(finished.exitCode, 1);
    });

    test(
      'a row that needs elevation without admin mode does not launch',
      () async {
        final plan = _planned(
          await _plan(
            profile: HostProfile(uid: 1000, user: 'deploy', systemdDir: true),
          ),
        );
        final elevated = OperationPlan(
          intent: plan.intent,
          kind: plan.kind,
          targetName: plan.targetName,
          steps: plan.steps,
          requiredLevel: plan.requiredLevel,
          runner: plan.runner,
          detachedRunner: DetachedRunner.loginSystemdUid,
        );
        final finished = await runner().run('plan-1', elevated);
        expect(finished.failure, ActionFailure.elevationRefused);
        expect(launches, isEmpty);
      },
    );
  });

  test('the plan runs nothing on the host before the launch', () async {
    await _plan();
    expect(_host.commands, everyElement(isNot(contains("'pull'"))));
    expect(_host.commands, everyElement(isNot(contains("'up'"))));
    expect(_host.commands, everyElement(isNot(contains("'-q'"))));
  });
}

/// A link the runner holds but the detached path never runs on.
final class _NoLink extends TestLinkBase {
  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async => _ok;
}
