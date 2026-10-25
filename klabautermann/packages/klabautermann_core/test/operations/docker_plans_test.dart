// The Docker action planners (M4 E15) over a fake engine: every plan is
// API steps addressed by full id, removing volumes or an image in use
// needs the typed confirmation, a managed or protected target raises it
// too, a stack acts in its dependency order and refuses a cycle, and the
// runner's API steps and re-validation read the engine's answers.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/danger.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/plans/docker_plans.dart';
import 'package:klabautermann_core/src/operations/protected_targets.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../support/forwarding_link.dart';

const _server = 'srv-1';
const _route = DockerEndpointRoute(
  rank: DockerRank.streamlocal,
  socketPath: '/var/run/docker.sock',
  runtime: EngineRuntime.docker,
  rootEquivalence: DockerRootEquivalence.rootfulSocket,
);

String _id(String seed) => seed.padRight(64, '0');

/// A container as `GET /containers/json` lists it.
Map<String, Object?> _container(
  String name, {
  String? id,
  String state = 'running',
  String? imageId,
  Map<String, String> labels = const {},
  List<Map<String, Object?>> ports = const [],
  List<String> volumes = const [],
}) => {
  'Id': id ?? _id(name.codeUnits.map((c) => c.toRadixString(16)).join()),
  'Names': ['/$name'],
  'Image': 'app:1',
  'ImageID': ?imageId,
  'State': state,
  'Labels': labels,
  'Ports': ports,
  'Mounts': [
    for (final volume in volumes) {'Type': 'volume', 'Name': volume},
  ],
};

Map<String, String> _compose(
  String project,
  String service, {
  String dependsOn = '',
  bool oneOff = false,
}) => {
  'com.docker.compose.project': project,
  'com.docker.compose.service': service,
  if (dependsOn.isNotEmpty) 'com.docker.compose.depends_on': dependsOn,
  'com.docker.compose.oneoff': oneOff ? 'True' : 'False',
};

/// Enough of the Engine API for planning: the container list with its
/// `id` and `label` filters, inspect by id prefix or name, the image list
/// and inspect, and a status for each action.
final class _Engine extends FakeDaemon {
  _Engine({this.api = '1.52'});

  final String api;
  final containers = <Map<String, Object?>>[];
  final images = <Map<String, Object?>>[];
  final volumes = <Map<String, Object?>>[];
  final networks = <Map<String, Object?>>[];

  /// Statuses by `METHOD path`; actions answer 204 otherwise.
  final statuses = <String, int>{};

  @override
  String respond(String requestLine) {
    final [method, target, ...] = requestLine.split(' ');
    final uri = Uri.parse('http://engine$target');
    final path = uri.path;
    final prefix = '/v$api';
    if (!path.startsWith(prefix)) return _reply(400, {'message': 'version'});
    final rest = path.substring(prefix.length);
    if (statuses['$method $path'] case final status?) {
      // A 304 has no body (RFC 9110 §15.4.5).
      if (status == 304) return 'HTTP/1.1 304 X\r\n\r\n';
      return _reply(status, {'message': 'refused'});
    }

    if (method == 'GET' && rest == '/containers/json') {
      final filters = uri.queryParameters['filters'];
      final decoded = filters == null
          ? const <String, Object?>{}
          : (jsonDecode(filters) as Map).cast<String, Object?>();
      final ids = (decoded['id'] as List?)?.cast<String>();
      final labels = (decoded['label'] as List?)?.cast<String>();
      final mounted = (decoded['volume'] as List?)?.cast<String>();
      return _reply(200, [
        for (final c in containers)
          if ((ids == null || ids.any((id) => '${c['Id']}'.startsWith(id))) &&
              (labels == null || labels.every((l) => _hasLabel(c, l))) &&
              (mounted == null || mounted.every((v) => _mounts(c, v))))
            c,
      ]);
    }
    if (method == 'GET' && rest.startsWith('/networks/')) {
      final key = Uri.decodeComponent(rest.substring('/networks/'.length));
      for (final n in networks) {
        if (n['Id'] == key || n['Name'] == key) return _reply(200, n);
      }
      return _reply(404, {'message': 'network $key not found'});
    }
    if (method == 'GET' && rest.startsWith('/volumes/')) {
      final key = Uri.decodeComponent(rest.substring('/volumes/'.length));
      for (final v in volumes) {
        if (v['Name'] == key) return _reply(200, v);
      }
      return _reply(404, {'message': 'get $key: no such volume'});
    }
    if (method == 'GET' && rest.startsWith('/containers/')) {
      final key = Uri.decodeComponent(rest.split('/')[2]);
      for (final c in containers) {
        if ('${c['Id']}'.startsWith(key) ||
            (c['Names'] as List).contains('/$key')) {
          return _reply(200, {'Id': c['Id'], 'Name': (c['Names'] as List)[0]});
        }
      }
      return _reply(404, {'message': 'No such container: $key'});
    }
    if (method == 'GET' && rest == '/images/json') return _reply(200, images);
    if (method == 'GET' && rest.startsWith('/images/')) {
      final key = Uri.decodeComponent(
        rest.substring('/images/'.length, rest.length - '/json'.length),
      );
      for (final i in images) {
        if (i['Id'] == key || (i['RepoTags'] as List).contains(key)) {
          return _reply(200, {'Id': i['Id'], 'RepoTags': i['RepoTags']});
        }
      }
      return _reply(404, {'message': 'No such image: $key'});
    }
    return 'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n';
  }

  static bool _mounts(Map<String, Object?> container, String volume) =>
      (container['Mounts'] as List? ?? const []).any(
        (m) => (m as Map)['Name'] == volume,
      );

  static bool _hasLabel(Map<String, Object?> container, String filter) {
    final [key, value] = filter.split('=');
    return (container['Labels'] as Map)[key] == value;
  }

  static String _reply(int status, Object body) {
    final bytes = utf8.encode(jsonEncode(body));
    return 'HTTP/1.1 $status X\r\nContent-Type: application/json\r\n'
        'Content-Length: ${bytes.length}\r\n\r\n${utf8.decode(bytes)}';
  }
}

DockerClient _client(_Engine engine) => DockerClient(
  DockerHttpClient(() async => engine.connect().client),
  apiVersion: ApiVersion.tryParse(engine.api)!,
);

Future<PlanAttempt> _plan(
  ActionIntent intent,
  _Engine engine, {
  ProtectionContext protection = const ProtectionContext(),
  DockerEndpointRoute route = _route,
}) => planDockerAction(intent, (
  client: _client(engine),
  route: route,
  protection: protection,
  loginUser: 'ops',
));

OperationPlan _planned(PlanAttempt attempt) {
  expect(attempt.refusal, isNull);
  return attempt.plan!;
}

ApiStep _step(OperationPlan plan, [int index = 0]) =>
    plan.steps[index] as ApiStep;

void main() {
  group('containers (CTR-02, CTR-06)', () {
    late _Engine engine;
    setUp(() => engine = _Engine()..containers.add(_container('web-1')));

    String webId() => '${engine.containers.single['Id']}';

    test('a stop addresses the full id and re-validates it', () async {
      final plan = _planned(
        await _plan(
          ContainerAction(
            _server,
            containerId: webId().substring(0, 12),
            verb: ContainerVerb.stop,
          ),
          engine,
        ),
      );
      expect(plan.targetName, 'web-1');
      expect(plan.kind, OperationKind.stop);
      expect(plan.tier, ConfirmationTier.acknowledge);
      expect(_step(plan).display, 'POST /v1.52/containers/${webId()}/stop');
      expect(plan.runner.identity, 'ops');
      expect(plan.runner.engine, 'docker /var/run/docker.sock');
      expect(plan.hostWrites, [HostWriteRow.engineState]);
      expect(plan.impact?.kind, ImpactKind.interruptsTarget);
      final check = plan.revalidate.single as DockerTargetUnchanged;
      expect(
        (check.kind, check.target, check.id),
        (DockerTargetKind.container, 'web-1', webId()),
      );
    });

    test('over the sudo relay the steps run as root, in admin mode '
        '(rank 3, E16)', () async {
      final plan = _planned(
        await _plan(
          ContainerAction(
            _server,
            containerId: 'web-1',
            verb: ContainerVerb.stop,
          ),
          engine,
          route: const DockerEndpointRoute(
            rank: DockerRank.sudoRelay,
            socketPath: '/var/run/docker.sock',
            runtime: EngineRuntime.docker,
            rootEquivalence: DockerRootEquivalence.rootfulSocket,
          ),
        ),
      );
      expect(plan.requiredLevel, RequiredLevel.admin);
      expect(plan.runner.identity, 'root');
      expect(plan.runner.credentials, RunnerCredentials.adminPassword);
    });

    test(
      'a kill carries its signal; a signal on another verb is refused',
      () async {
        final plan = _planned(
          await _plan(
            ContainerAction(
              _server,
              containerId: 'web-1',
              verb: ContainerVerb.kill,
              signal: KillSignal.sigterm,
            ),
            engine,
          ),
        );
        expect(_step(plan).query, {'signal': 'TERM'});

        final refused = await _plan(
          ContainerAction(
            _server,
            containerId: 'web-1',
            verb: ContainerVerb.stop,
            signal: KillSignal.sigterm,
          ),
          engine,
        );
        expect(refused.refusal, ActionRefusalReason.invalidTarget);
      },
    );

    test('removing with its volumes needs the typed confirmation', () async {
      final plain = _planned(
        await _plan(RemoveContainer(_server, containerId: 'web-1'), engine),
      );
      expect(plain.tier, ConfirmationTier.acknowledge);
      expect(_step(plain).query, {'v': '0', 'force': '0'});

      final withVolumes = _planned(
        await _plan(
          RemoveContainer(_server, containerId: 'web-1', volumes: true),
          engine,
        ),
      );
      expect(withVolumes.kind, OperationKind.removeContainerWithVolumes);
      expect(withVolumes.tier, ConfirmationTier.typedPhrase);
      expect(withVolumes.impact?.kind, ImpactKind.removesVolumes);
      expect(_step(withVolumes).method, 'DELETE');
      expect(_step(withVolumes).query, {'v': '1', 'force': '0'});
    });

    test(
      'a managed container needs the act-anyway step naming its owner',
      () async {
        engine.containers
          ..clear()
          ..add(_container('web-1', labels: {'coolify.managed': 'true'}));
        final plan = _planned(
          await _plan(
            ContainerAction(
              _server,
              containerId: 'web-1',
              verb: ContainerVerb.restart,
            ),
            engine,
          ),
        );
        expect(plan.ownership?.manager, 'Coolify');
        expect(plan.tier, ConfirmationTier.typedPhrase);
      },
    );

    test('a container publishing the SSH port is protected and drops the '
        'session', () async {
      engine.containers
        ..clear()
        ..add(
          _container(
            'sshd',
            ports: [
              {'PrivatePort': 22, 'PublicPort': 2222, 'Type': 'tcp'},
            ],
          ),
        );
      final plan = _planned(
        await _plan(
          ContainerAction(
            _server,
            containerId: 'sshd',
            verb: ContainerVerb.stop,
          ),
          engine,
          protection: const ProtectionContext(sshPort: 2222),
        ),
      );
      expect(plan.protected, ProtectedReason.publishesSessionPort);
      expect(plan.impact?.kind, ImpactKind.dropsSession);
      expect(plan.tier, ConfirmationTier.typedPhrase);
    });

    test('a container that is gone is a changed target', () async {
      final attempt = await _plan(
        ContainerAction(
          _server,
          containerId: 'nope',
          verb: ContainerVerb.start,
        ),
        engine,
      );
      expect(attempt.refusal, ActionRefusalReason.targetChanged);
    });
  });

  group('one-off commands (CTX-08)', () {
    late _Engine engine;
    setUp(() => engine = _Engine()..containers.add(_container('web-1')));

    String webId() => '${engine.containers.single['Id']}';

    test('a command is one exec step the preview shows as the request, '
        'acknowledged and re-validated', () async {
      final plan = _planned(
        await _plan(
          ContainerExec(
            _server,
            containerId: 'web-1',
            argv: const ['sh', '-c', 'ls /srv'],
            user: 'app',
          ),
          engine,
        ),
      );
      expect(plan.kind, OperationKind.containerExec);
      expect(plan.targetName, 'web-1');
      expect(plan.tier, ConfirmationTier.acknowledge);
      final step = plan.steps.single as ExecStep;
      expect(step.containerId, webId());
      expect(step.argv, ['sh', '-c', 'ls /srv']);
      expect(
        step.display,
        'POST /v1.52/containers/${webId()}/exec '
        '{"Cmd":["sh","-c","ls /srv"],"User":"app","Tty":false}',
      );
      expect(identical(plan.preview.steps, plan.steps), isTrue);
      expect(plan.danger, isEmpty);
      final check = plan.revalidate.single as DockerTargetUnchanged;
      expect(check.id, webId());
    });

    test('the linter reads the argv', () async {
      final plan = _planned(
        await _plan(
          ContainerExec(
            _server,
            containerId: 'web-1',
            argv: const ['rm', '-rf', '/'],
          ),
          engine,
        ),
      );
      expect(plan.danger, isNotEmpty);
    });

    test(
      'a protected or managed container needs the typed confirmation',
      () async {
        engine.containers
          ..clear()
          ..add(_container('web-1', labels: {'coolify.managed': 'true'}));
        final managed = _planned(
          await _plan(
            ContainerExec(_server, containerId: 'web-1', argv: const ['id']),
            engine,
          ),
        );
        expect(managed.tier, ConfirmationTier.typedPhrase);
      },
    );

    test('refuses an empty command or user, a stopped container and a gone '
        'one', () async {
      Future<ActionRefusalReason?> refusal(ContainerExec intent) async =>
          (await _plan(intent, engine)).refusal;

      expect(
        await refusal(
          ContainerExec(_server, containerId: 'web-1', argv: const []),
        ),
        ActionRefusalReason.invalidTarget,
      );
      expect(
        await refusal(
          ContainerExec(
            _server,
            containerId: 'web-1',
            argv: const ['id'],
            user: '',
          ),
        ),
        ActionRefusalReason.invalidTarget,
      );
      expect(
        await refusal(
          ContainerExec(_server, containerId: 'nope', argv: const ['id']),
        ),
        ActionRefusalReason.targetChanged,
      );
      engine.containers
        ..clear()
        ..add(_container('web-1', state: 'exited'));
      expect(
        await refusal(
          ContainerExec(_server, containerId: 'web-1', argv: const ['id']),
        ),
        ActionRefusalReason.invalidTarget,
      );
    });
  });

  group('images (IMG-02)', () {
    final imageId = 'sha256:${_id('feed')}';

    _Engine withImage({required String api, required int users}) {
      final engine = _Engine(api: api)
        ..images.add({
          'Id': imageId,
          'RepoTags': ['app:1'],
          'Containers': api == '1.52' ? users : -1,
        });
      for (var i = 0; i < users; i++) {
        engine.containers.add(_container('user-$i', imageId: imageId));
      }
      return engine;
    }

    test(
      'an unused image is removed by its tag after a plain confirmation',
      () async {
        final plan = _planned(
          await _plan(
            const RemoveImage(_server, image: 'app:1'),
            withImage(api: '1.52', users: 0),
          ),
        );
        expect(plan.kind, OperationKind.removeUnusedImage);
        expect(plan.tier, ConfirmationTier.acknowledge);
        expect(_step(plan).display, startsWith('DELETE /v1.52/images/app%3A1'));
        final check = plan.revalidate.single as DockerTargetUnchanged;
        expect((check.kind, check.id), (DockerTargetKind.image, imageId));
      },
    );

    test('an image in use is refused unless forced, then typed', () async {
      for (final api in ['1.52', '1.50']) {
        final engine = withImage(api: api, users: 2);
        final refused = await _plan(
          const RemoveImage(_server, image: 'app:1'),
          engine,
        );
        expect(refused.refusal, ActionRefusalReason.imageInUse, reason: api);

        final forced = _planned(
          await _plan(
            const RemoveImage(_server, image: 'app:1', force: true),
            engine,
          ),
        );
        expect(forced.kind, OperationKind.forceRemoveImageInUse);
        expect(forced.tier, ConfirmationTier.typedPhrase);
        expect(forced.impact?.count, 2, reason: api);
        expect(_step(forced).query['force'], '1');
      }
    });
  });

  group('volumes (VOL-02)', () {
    const created = '2026-10-20T08:00:00Z';

    _Engine withVolume({List<String> mountedBy = const []}) {
      final engine = _Engine()
        ..volumes.add({
          'Name': 'pgdata',
          'Driver': 'local',
          'CreatedAt': created,
        });
      for (final name in mountedBy) {
        engine.containers.add(
          _container(name, state: 'exited', volumes: ['pgdata']),
        );
      }
      return engine;
    }

    test('a new volume is one create request after a plain confirmation, '
        'its body shown as sent', () async {
      final plan = _planned(
        await _plan(
          const CreateVolume(_server, name: 'cache', driver: 'local'),
          withVolume(),
        ),
      );
      expect(plan.kind, OperationKind.createVolume);
      expect(plan.tier, ConfirmationTier.acknowledge);
      expect(
        _step(plan).display,
        'POST /v1.52/volumes/create {"Name":"cache","Driver":"local"}',
      );
      expect(plan.revalidate, isEmpty);

      final engineDefault = _planned(
        await _plan(const CreateVolume(_server, name: 'cache'), withVolume()),
      );
      expect(_step(engineDefault).json, {'Name': 'cache'});
    });

    test('a taken name or one Docker refuses is not planned', () async {
      final engine = withVolume();
      expect(
        (await _plan(
          const CreateVolume(_server, name: 'pgdata'),
          engine,
        )).refusal,
        ActionRefusalReason.volumeExists,
      );
      for (final (name, driver) in [
        ('a', null),
        ('-data', null),
        ('da ta', null),
        ('data', 'lo/cal'),
      ]) {
        expect(
          (await _plan(
            CreateVolume(_server, name: name, driver: driver),
            engine,
          )).refusal,
          ActionRefusalReason.invalidTarget,
          reason: '$name $driver',
        );
      }
    });

    test('removing a volume deletes its data behind the typed confirmation '
        'and re-validates its creation time', () async {
      final plan = _planned(
        await _plan(const RemoveVolume(_server, name: 'pgdata'), withVolume()),
      );
      expect(plan.kind, OperationKind.removeVolume);
      expect(plan.tier, ConfirmationTier.typedPhrase);
      expect(plan.impact?.kind, ImpactKind.deletesVolumeData);
      expect(_step(plan).display, 'DELETE /v1.52/volumes/pgdata');
      final check = plan.revalidate.single as DockerTargetUnchanged;
      expect(check.kind, DockerTargetKind.volume);
      expect(check.id, DateTime.parse(created).toIso8601String());
    });

    test('a volume a container mounts is refused, and a gone one is a '
        'changed target', () async {
      expect(
        (await _plan(
          const RemoveVolume(_server, name: 'pgdata'),
          withVolume(mountedBy: ['db']),
        )).refusal,
        ActionRefusalReason.volumeInUse,
      );
      expect(
        (await _plan(
          const RemoveVolume(_server, name: 'pgdata'),
          _Engine(),
        )).refusal,
        ActionRefusalReason.targetChanged,
      );
    });

    test('re-validation sees a volume created again under its name', () async {
      final engine = withVolume();
      final client = _client(engine);
      final check = DockerTargetUnchanged(
        DockerTargetKind.volume,
        'pgdata',
        DateTime.parse(created).toIso8601String(),
      );
      expect(await revalidateDockerTarget(client, check), isNull);

      engine.volumes.single['CreatedAt'] = '2026-10-21T09:00:00Z';
      expect(
        await revalidateDockerTarget(client, check),
        RevalidationFailure.targetChanged,
      );
    });

    test('the linter reads a create as docker volume create', () {
      expect(
        cliEquivalent(
          ApiStep(
            method: 'POST',
            path: '/v1.52/volumes/create',
            json: {'Name': 'cache', 'Driver': 'nfs'},
          ),
        ),
        'docker volume create --driver nfs cache',
      );
    });
  });

  group('networks (DNW-02)', () {
    final netId = _id('ne7');

    _Engine withNetwork({
      String name = 'shop_default',
      Map<String, Object?> containers = const {},
    }) => _Engine()
      ..networks.add({
        'Id': netId,
        'Name': name,
        'Driver': 'bridge',
        'Containers': containers,
      });

    test('a network no container is on is removed by its id after a plain '
        'confirmation, re-validated by that id', () async {
      final plan = _planned(
        await _plan(RemoveNetwork(_server, networkId: netId), withNetwork()),
      );
      expect(plan.kind, OperationKind.removeNetwork);
      expect(plan.tier, ConfirmationTier.acknowledge);
      expect(plan.targetName, 'shop_default');
      expect(_step(plan).display, 'DELETE /v1.52/networks/$netId');
      final check = plan.revalidate.single as DockerTargetUnchanged;
      expect((check.kind, check.id), (DockerTargetKind.network, netId));
      expect(cliEquivalent(_step(plan)), 'docker network rm $netId');
    });

    test('a built-in network, one a container is on and a gone one are '
        'refused', () async {
      for (final name in ['bridge', 'host', 'none']) {
        expect(
          (await _plan(
            RemoveNetwork(_server, networkId: netId),
            withNetwork(name: name),
          )).refusal,
          ActionRefusalReason.builtinNetwork,
          reason: name,
        );
      }
      expect(
        (await _plan(
          RemoveNetwork(_server, networkId: netId),
          withNetwork(
            containers: {
              _id('c1'): {'Name': 'shop-web-1'},
            },
          ),
        )).refusal,
        ActionRefusalReason.networkInUse,
      );
      expect(
        (await _plan(
          RemoveNetwork(_server, networkId: netId),
          _Engine(),
        )).refusal,
        ActionRefusalReason.targetChanged,
      );
    });
  });

  group('stacks (STK-03)', () {
    _Engine shop({String dbDependsOn = ''}) => _Engine()
      ..containers.addAll([
        _container(
          'shop-web-1',
          labels: _compose('shop', 'web', dependsOn: 'db:service_started:true'),
        ),
        _container(
          'shop-db-1',
          labels: _compose('shop', 'db', dependsOn: dbDependsOn),
          state: 'exited',
        ),
        _container('shop-cache-1', labels: _compose('shop', 'cache')),
        _container('shop-run-1', labels: _compose('shop', 'web', oneOff: true)),
        _container('other-1', labels: _compose('other', 'web')),
      ]);

    List<String> targets(OperationPlan plan, _Engine engine) => [
      for (final step in plan.steps)
        for (final c in engine.containers)
          if ((step as ApiStep).path.contains('${c['Id']}'))
            (c['Names'] as List).single.toString().substring(1),
    ];

    test(
      'starts dependencies first and stops them last, without one-offs',
      () async {
        final engine = shop();
        final start = _planned(
          await _plan(
            const StackAction(_server, project: 'shop', verb: StackVerb.start),
            engine,
          ),
        );
        expect(targets(start, engine), [
          'shop-cache-1',
          'shop-db-1',
          'shop-web-1',
        ]);
        expect(start.impact, isNull);

        final stop = _planned(
          await _plan(
            const StackAction(_server, project: 'shop', verb: StackVerb.stop),
            engine,
          ),
        );
        expect(targets(stop, engine), [
          'shop-web-1',
          'shop-db-1',
          'shop-cache-1',
        ]);
        expect(stop.kind, OperationKind.stackStop);
        expect(stop.impact?.count, 2, reason: 'two of the three are running');
        expect(
          (stop.revalidate.single as DockerTargetUnchanged).kind,
          DockerTargetKind.stack,
        );
      },
    );

    test('one service acts on its own containers alone (STK-23)', () async {
      final engine = shop();
      final restart = _planned(
        await _plan(
          const StackAction(
            _server,
            project: 'shop',
            verb: StackVerb.restart,
            service: 'db',
          ),
          engine,
        ),
      );
      expect(targets(restart, engine), ['shop-db-1']);
      expect(restart.kind, OperationKind.stackRestart);
      expect(restart.targetName, 'shop/db');

      final missing = await _plan(
        const StackAction(
          _server,
          project: 'shop',
          verb: StackVerb.stop,
          service: 'mail',
        ),
        engine,
      );
      expect(missing.refusal, ActionRefusalReason.invalidTarget);
    });

    test('a dependency cycle is refused', () async {
      final attempt = await _plan(
        const StackAction(_server, project: 'shop', verb: StackVerb.restart),
        shop(dbDependsOn: 'web:service_started:true'),
      );
      expect(attempt.refusal, ActionRefusalReason.dependencyCycle);
    });

    test('a project with no containers is no target', () async {
      final attempt = await _plan(
        const StackAction(_server, project: 'gone', verb: StackVerb.start),
        shop(),
      );
      expect(attempt.refusal, ActionRefusalReason.invalidTarget);
    });

    test('dependencyOrder ignores services outside the project', () {
      expect(
        dependencyOrder({
          'web': {'db', 'ghost'},
          'db': {},
          'worker': {'web'},
        }),
        ['db', 'web', 'worker'],
      );
      expect(
        dependencyOrder({
          'a': {'b'},
          'b': {'a'},
        }),
        isNull,
      );
    });
  });

  group('running the steps', () {
    test('a step names the container or the images it changes', () {
      expect(
        apiStepChanges(
          ApiStep(method: 'POST', path: '/v1.44/containers/c1/pause'),
        ),
        (container: 'c1', images: false, volumes: false, networks: false),
      );
      expect(
        apiStepChanges(
          ApiStep(
            method: 'DELETE',
            path: '/v1.44/containers/c1',
            query: {'v': '1'},
          ),
        ),
        (container: 'c1', images: false, volumes: false, networks: false),
      );
      expect(
        apiStepChanges(
          ApiStep(method: 'DELETE', path: '/v1.44/images/nginx%3Alatest'),
        ),
        (container: null, images: true, volumes: false, networks: false),
      );
      expect(
        apiStepChanges(ApiStep(method: 'POST', path: '/v1.44/volumes/create')),
        (container: null, images: false, volumes: true, networks: false),
      );
      expect(
        apiStepChanges(ApiStep(method: 'DELETE', path: '/v1.44/networks/n1')),
        (container: null, images: false, volumes: false, networks: true),
      );
      expect(
        apiStepChanges(ApiStep(method: 'DELETE', path: '/v1.44/volumes/data')),
        (container: null, images: false, volumes: true, networks: false),
      );
    });

    late _Engine engine;
    setUp(() => engine = _Engine()..containers.add(_container('web-1')));

    String webId() => '${engine.containers.single['Id']}';

    ApiStep stop() =>
        ApiStep(method: 'POST', path: '/v1.52/containers/${webId()}/stop');

    test(
      'an API step answers its status; not modified counts as done',
      () async {
        final client = _client(engine);
        expect(await runApiStep(client, stop()), 204);

        engine.statuses['POST /v1.52/containers/${webId()}/stop'] = 304;
        expect(await runApiStep(client, stop()), 200);

        engine.statuses['POST /v1.52/containers/${webId()}/stop'] = 409;
        expect(await runApiStep(client, stop()), 409);
      },
    );

    test('re-validation follows the name to the id it has now', () async {
      final client = _client(engine);
      final check = DockerTargetUnchanged(
        DockerTargetKind.container,
        'web-1',
        webId(),
      );
      expect(await revalidateDockerTarget(client, check), isNull);

      // Recreated under the same name.
      engine.containers
        ..clear()
        ..add(_container('web-1', id: _id('beef')));
      expect(
        await revalidateDockerTarget(client, check),
        RevalidationFailure.targetChanged,
      );

      engine.containers.clear();
      expect(
        await revalidateDockerTarget(client, check),
        RevalidationFailure.targetChanged,
      );
    });

    test('a stack changes when a container joins it', () async {
      engine.containers
        ..clear()
        ..add(_container('shop-web-1', labels: _compose('shop', 'web')));
      final client = _client(engine);
      final check = DockerTargetUnchanged(
        DockerTargetKind.stack,
        'shop',
        stackFingerprint(
          parseContainerSummaries([engine.containers.single]).value,
        ),
      );
      expect(await revalidateDockerTarget(client, check), isNull);

      engine.containers.add(
        _container('shop-db-1', labels: _compose('shop', 'db')),
      );
      expect(
        await revalidateDockerTarget(client, check),
        RevalidationFailure.targetChanged,
      );
    });
  });
}
