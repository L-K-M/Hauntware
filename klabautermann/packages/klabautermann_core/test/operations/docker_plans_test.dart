// The Docker action planners (M4 E15) over a fake engine: every plan is
// API steps addressed by full id, removing volumes or an image in use
// needs the typed confirmation, a managed or protected target raises it
// too, a stack acts in its dependency order and refuses a cycle, and the
// runner's API steps and re-validation read the engine's answers.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
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
}) => {
  'Id': id ?? _id(name.codeUnits.map((c) => c.toRadixString(16)).join()),
  'Names': ['/$name'],
  'Image': 'app:1',
  'ImageID': ?imageId,
  'State': state,
  'Labels': labels,
  'Ports': ports,
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
      return _reply(200, [
        for (final c in containers)
          if ((ids == null || ids.any((id) => '${c['Id']}'.startsWith(id))) &&
              (labels == null || labels.every((l) => _hasLabel(c, l))))
            c,
      ]);
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
}) => planDockerAction(intent, (
  client: _client(engine),
  route: _route,
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
