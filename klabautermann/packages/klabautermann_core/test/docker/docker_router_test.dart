// The engine's Docker sessions over a forwarding link double and fake
// engines (03 §5.8, §5.9, §8.9; M7, M9, M13): negotiation, the refusal
// paths and the route passed over, the runtime the engine reports, the
// route found again for a new probe answer, masking, the query answers,
// the relays' idle close, and the sessions' ends.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart' show RemoteCommandResult, SshLink;
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';

const _srv = 'srv-1';
const _rootful = '/var/run/docker.sock';
const _podman = '/run/podman/podman.sock';

/// The exec probe's answer for a reachable socket without `nc`.
const _disabled = '0\n0\n1\n';

HostProfile _profile(
  List<String> present, {
  Map<String, String?> tools = const {
    'docker': null,
    'podman': null,
    'socat': null,
  },
}) => HostProfile(
  uid: 1000,
  sudoKind: SudoKind.none,
  tools: tools,
  engineSockets: [
    for (final path in [_rootful, _podman])
      EngineSocket(path: path, exists: present.contains(path), writable: true),
  ],
  areaStatuses: {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

/// A router over one server's link, whose events a test reads in order.
final class _Harness {
  _Harness() {
    router = DockerRouter(
      linkFor: (_) => link,
      emit: _events.add,
      startTimer: clock.startTimer,
    )..retain({_srv});
  }

  final clock = FakeClock();
  final forwarding = ForwardingLink();
  late SshLink? link = forwarding;
  late final DockerRouter router;
  final _events = StreamController<EngineEvent>();
  late final _next = StreamIterator(_events.stream);
  var _queries = 0;

  Future<EngineEvent> next() async {
    expect(await _next.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    return _next.current;
  }

  /// Sends a query and returns its id.
  String query(DockerQuerySpec spec, {String serverId = _srv}) {
    final id = 'q-${_queries++}';
    router.query(DockerQuery(serverId: serverId, queryId: id, query: spec));
    return id;
  }

  Future<DockerEndpointState> state() async =>
      await next() as DockerEndpointState;

  Future<DockerPayload> result(String queryId) async {
    final result = await next() as DockerResult;
    expect(result.queryId, queryId);
    expect(result.serverId, _srv);
    return result.payload;
  }

  /// Answers [profile] and reads the endpoint through resolving.
  Future<DockerEndpointState> resolve(HostProfile profile) async {
    router.probed(_srv, profile);
    expect((await state()).phase, DockerEndpointPhase.resolving);
    return state();
  }

  /// A session that a first query opened, waiting for the probe.
  Future<void> open() async {
    final id = query(const DockerEngineQuery());
    expect(
      await result(id),
      isA<DockerQueryFailed>().having(
        (f) => f.failure,
        'failure',
        DockerQueryFailure.profileUnknown,
      ),
    );
    expect((await state()).phase, DockerEndpointPhase.waiting);
  }
}

TypeMatcher<DockerQueryFailed> _failed(DockerQueryFailure failure) =>
    isA<DockerQueryFailed>().having((f) => f.failure, 'failure', failure);

void main() {
  group('negotiation (03 §5.8)', () {
    test('a 1.52 engine over streamlocal: ready at 1.52, and queries use '
        'versioned paths', () async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon()
        ..routes['/v1.52/info'] = jsonEncode({
          'Name': 'web',
          'ServerVersion': '29.0.0',
          'SecurityOptions': ['name=seccomp'],
        });
      await h.open();

      final ready = await h.resolve(_profile([_rootful]));
      expect(ready.phase, DockerEndpointPhase.ready);
      expect(ready.negotiatedApi, const ApiVersion(1, 52));
      expect(ready.label, DockerRouteLabel.socketForward);
      expect(ready.lowSession, isFalse);
      final route = ready.route!;
      expect(route.rank, DockerRank.streamlocal);
      expect(route.socketPath, _rootful);
      expect(route.runtime, EngineRuntime.docker);
      expect(route.mode, EngineMode.rootful);
      expect(route.rootEquivalence, DockerRootEquivalence.rootfulSocket);

      final id = h.query(const DockerEngineQuery());
      final payload = await h.result(id) as DockerEnginePayload;
      expect(payload.info.name, 'web');
      expect(payload.version.version, '29.0.0');
      expect(daemon.requests, [
        'HEAD /_ping HTTP/1.1',
        'GET /version HTTP/1.1',
        'GET /v1.52/info HTTP/1.1',
      ]);
    });

    test('an engine newer than 1.55 is spoken to at 1.55', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon(apiVersion: '1.56');
      await h.open();

      expect(
        (await h.resolve(_profile([_rootful]))).negotiatedApi,
        const ApiVersion(1, 55),
      );
    });

    test('an engine below the 1.41 floor fails with its route, and the '
        'queries waiting for it are answered', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon(apiVersion: '1.40');
      h.router.probed(_srv, _profile([_rootful]));
      final id = h.query(const DockerContainersQuery());

      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      // The state that explains the failure goes out before the answers.
      final failed = await h.state();
      expect(failed.phase, DockerEndpointPhase.failed);
      expect(failed.failure, DockerEndpointFailure.belowClientFloor);
      expect(failed.route?.rank, DockerRank.streamlocal);
      expect(failed.negotiatedApi, isNull);
      expect(
        await h.result(id),
        _failed(DockerQueryFailure.endpointUnavailable),
      );
    });

    test('an engine whose minimum is above 1.55 fails', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon(
        apiVersion: '1.60',
        minApiVersion: '1.56',
      );
      await h.open();

      expect(
        (await h.resolve(_profile([_rootful]))).failure,
        DockerEndpointFailure.belowServerMinimum,
      );
    });

    test('Podman behind the Docker path is named Podman (M13)', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon(
        apiVersion: '1.41',
        libpodApiVersion: '4.9.3',
      );
      await h.open();

      final ready = await h.resolve(_profile([_rootful]));
      expect(ready.negotiatedApi, const ApiVersion(1, 41));
      expect(ready.route!.runtime, EngineRuntime.podman);
      expect(ready.route!.mode, EngineMode.rootful);
    });
  });

  group('refusals and routes passed over (03 §5.3, §5.9)', () {
    test('no socket fails with the ladder\'s reason', () async {
      final h = _Harness();
      await h.open();

      final failed = await h.resolve(_profile(const []));
      expect(failed.failure, DockerEndpointFailure.noRoute);
      expect(failed.noRouteReason, DockerNoRouteReason.noSocket);
      expect(failed.label, DockerRouteLabel.none);
    });

    test('a socket that opens but does not answer is passed over for the '
        'next one', () async {
      final h = _Harness();
      final broken = h.forwarding.daemons[_rootful] = EngineDaemon()
        ..failures['/_ping'] = (500, 'not an engine');
      h.forwarding.daemons[_podman] = EngineDaemon(libpodApiVersion: '5.2.0');
      await h.open();

      final ready = await h.resolve(_profile([_rootful, _podman]));
      expect(ready.route!.socketPath, _podman);
      expect(ready.route!.runtime, EngineRuntime.podman);
      // The broken socket's channels are closed again.
      expect(broken.closed, broken.connections);
    });

    test(
      'a CLI relay that cannot reach the daemon gives way to socat',
      () async {
        final h = _Harness();
        h.forwarding
          ..probeAnswers[_rootful] = _disabled
          ..failingRelays.add('docker')
          ..relayDaemon = EngineDaemon();
        await h.open();

        final ready = await h.resolve(
          _profile(
            [_rootful],
            tools: const {
              'docker': '/usr/bin/docker',
              'podman': null,
              'socat': '/usr/bin/socat',
            },
          ),
        );
        expect(ready.route!.rank, DockerRank.socketRelay);
        expect(ready.label, DockerRouteLabel.socatRelay);
        expect(h.forwarding.started.first, contains(" 'docker' "));
        expect(h.forwarding.started.last, contains(" 'socat' "));
      },
    );

    test('no route that answers fails as unreachable', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon()
        ..failures['/version'] = (500, 'broken');
      await h.open();

      expect(
        (await h.resolve(_profile([_rootful]))).failure,
        DockerEndpointFailure.unreachable,
      );
    });

    test('a failure stands until a query asks again', () async {
      final h = _Harness();
      await h.open();
      expect(
        (await h.resolve(_profile(const []))).phase,
        DockerEndpointPhase.failed,
      );

      // The same probe answer resolves nothing new.
      h.router.probed(_srv, _profile(const []));
      h.forwarding.daemons[_rootful] = EngineDaemon();
      final id = h.query(const DockerImagesQuery());
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      // The ladder reads the profile, which still lists no socket.
      expect((await h.state()).failure, DockerEndpointFailure.noRoute);
      expect(
        await h.result(id),
        _failed(DockerQueryFailure.endpointUnavailable),
      );
    });
  });

  group('link and probe answers', () {
    test(
      'without a link a query fails at once and the endpoint waits',
      () async {
        final h = _Harness()..link = null;
        final id = h.query(const DockerEngineQuery());
        expect(await h.result(id), _failed(DockerQueryFailure.linkUnavailable));
        expect((await h.state()).phase, DockerEndpointPhase.waiting);
      },
    );

    test('a probe answer with other sockets finds the route again; the '
        'same answer does not', () async {
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..daemons[_podman] = EngineDaemon(libpodApiVersion: '5.2.0');
      await h.open();
      expect(
        (await h.resolve(_profile([_rootful]))).route!.socketPath,
        _rootful,
      );

      h.router.probed(_srv, _profile([_rootful]));
      final again = await h.resolve(_profile([_podman]));
      expect(again.route!.socketPath, _podman);
    });

    test('a new link finds the route again, and losing it waits', () async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));

      h
        ..link = null
        ..router.update(_srv);
      expect((await h.state()).phase, DockerEndpointPhase.waiting);
      await pumpEventQueue();
      expect(daemon.closed, daemon.connections);

      h
        ..link = (ForwardingLink()..daemons[_rootful] = daemon)
        ..router.update(_srv);
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).phase, DockerEndpointPhase.ready);
    });
  });

  group('queries', () {
    Future<(_Harness, EngineDaemon)> ready() async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));
      return (h, daemon);
    }

    test('an inspect crosses with its command line and health output '
        'masked (03 §8.9)', () async {
      final (h, daemon) = await ready();
      daemon.routes['/v1.52/containers/db/json'] = jsonEncode({
        'Id': 'abc',
        'Name': '/db',
        'Path': 'docker-entrypoint.sh',
        'Args': ['mysqld', '--password=hunter2'],
        'State': {
          'Status': 'running',
          'Running': true,
          'Health': {
            'Status': 'unhealthy',
            'FailingStreak': 2,
            'Log': [
              {'ExitCode': 1, 'Output': 'TOKEN=s3cret rejected'},
              {'ExitCode': 0, 'Output': 'ok'},
            ],
          },
        },
        'Config': {
          'Image': 'mysql:8',
          'Tty': true,
          'Env': ['MYSQL_PASSWORD=hunter2', 'TZ=UTC'],
          'Entrypoint': ['docker-entrypoint.sh', '--token'],
          'Cmd': ['s3cret', 'mysqld'],
          'Labels': {'api_key': 'k', 'tier': 'db'},
        },
        'HostConfig': {'NetworkMode': 'bridge'},
      });

      final id = h.query(const DockerContainerQuery('db'));
      final details = (await h.result(id) as DockerContainerPayload).container;

      expect(details.name, 'db');
      expect(details.path, 'docker-entrypoint.sh');
      expect(
        [for (final a in details.args) a.display],
        ['mysqld', '--password=${MaskedValue.maskToken}'],
      );
      expect(details.args.last.reveal(), '--password=hunter2');
      final config = details.config!;
      expect(config.tty, isTrue);
      expect(
        [for (final a in config.entrypoint) a.display],
        ['docker-entrypoint.sh', '--token'],
      );
      // The value of the entrypoint's last option is the Cmd's first word.
      expect(
        [for (final a in config.cmd) a.display],
        [MaskedValue.maskToken, 'mysqld'],
      );
      expect(config.env.first.value.display, MaskedValue.maskToken);
      expect(config.labels['api_key']!.display, MaskedValue.maskToken);
      expect(config.labels['tier']!.display, 'db');
      final health = details.state!.health!;
      expect(health.status, HealthStatus.unhealthy);
      expect(
        health.log.first.output!.display,
        'TOKEN=${MaskedValue.maskToken}',
      );
      expect(health.log.first.output!.reveal(), 'TOKEN=s3cret rejected');
      expect(health.log.last.output!.display, 'ok');
      expect(details.hostConfig!.networkMode, 'bridge');
    });

    test('the history of an image crosses with each instruction masked '
        '(IMG-04)', () async {
      final (h, daemon) = await ready();
      // The client percent-encodes the reference's colon.
      daemon.routes['/v1.52/images/app%3A1/history'] = jsonEncode([
        {
          'Id': 'sha256:${'a' * 64}',
          'Created': 1760000000,
          'CreatedBy': '/bin/sh -c #(nop)  ENV API_TOKEN=s3cret',
          'Size': 0,
          'Tags': ['app:1'],
          'Comment': '',
        },
        {
          'Id': '<missing>',
          'Created': 1750000000,
          'CreatedBy': 'RUN |1 VERSION=2 /bin/sh -c make install',
          'Size': 4096,
          'Tags': null,
          'Comment': 'buildkit.dockerfile.v0',
        },
      ]);

      final id = h.query(const DockerImageHistoryQuery('app:1'));
      final layers = (await h.result(id) as DockerImageHistoryPayload).layers;
      expect(layers, hasLength(2));
      expect(
        layers.first.createdBy.display,
        '/bin/sh -c #(nop)  ENV API_TOKEN=${MaskedValue.maskToken}',
      );
      expect(
        layers.first.createdBy.reveal(),
        '/bin/sh -c #(nop)  ENV API_TOKEN=s3cret',
      );
      expect(layers.first.tags, ['app:1']);
      expect(layers.first.comment, isNull);
      expect(
        (layers.last.id, layers.last.size, layers.last.comment),
        (null, 4096, 'buildkit.dockerfile.v0'),
      );
      expect(layers.last.createdBy.isMasked, isFalse);

      final empty = h.query(const DockerImageHistoryQuery(''));
      expect(await h.result(empty), _failed(DockerQueryFailure.invalidQuery));
    });

    test('the container list drops each command line; images keep their '
        'masked labels', () async {
      final (h, daemon) = await ready();
      daemon
        ..routes['/v1.52/containers/json'] = jsonEncode([
          {
            'Id': 'abc',
            'Names': ['/db'],
            'Command': 'mysqld --password=hunter2',
            'State': 'running',
            'Status': 'Up 2 hours (healthy)',
            'Labels': {'secret_token': 't'},
          },
        ])
        ..routes['/v1.52/images/json'] = jsonEncode([
          {
            'Id': 'sha256:1',
            'RepoTags': ['mysql:8'],
            'Labels': {'password': 'p'},
          },
        ]);

      final list = h.query(const DockerContainersQuery());
      final containers =
          (await h.result(list) as DockerContainersPayload).containers;
      expect(containers.single.name, 'db');
      expect(containers.single.command, isNull);
      expect(containers.single.health, HealthStatus.healthy);
      expect(
        containers.single.labels['secret_token']!.display,
        MaskedValue.maskToken,
      );
      expect(
        daemon.requests,
        contains('GET /v1.52/containers/json?all=1 HTTP/1.1'),
      );

      final images = h.query(const DockerImagesQuery());
      final image =
          (await h.result(images) as DockerImagesPayload).images.single;
      expect(image.repoTags, ['mysql:8']);
      expect(image.labels['password']!.display, MaskedValue.maskToken);
    });

    test('disk use reads /system/df in the negotiated shape (OV-05)', () async {
      final (h, daemon) = await ready();
      daemon.routes['/v1.52/system/df'] = jsonEncode({
        'ImageUsage': {
          'TotalCount': 3,
          'ActiveCount': 1,
          'TotalSize': 3000,
          'Reclaimable': 2000,
        },
        'ContainerUsage': {
          'TotalCount': 2,
          'ActiveCount': 1,
          'TotalSize': 40,
          'Reclaimable': 10,
        },
        'VolumeUsage': {
          'TotalCount': 1,
          'ActiveCount': 1,
          'TotalSize': 500,
          'Reclaimable': 0,
        },
        'BuildCacheUsage': {
          'TotalCount': 0,
          'ActiveCount': 0,
          'TotalSize': 0,
          'Reclaimable': 0,
        },
      });

      final id = h.query(const DockerSystemDfQuery());
      final df = (await h.result(id) as DockerSystemDfPayload).df;
      expect(df.images!.activeCount, 1);
      expect(df.reclaimable, 2010);
      expect(daemon.requests, contains('GET /v1.52/system/df HTTP/1.1'));

      daemon.failures['/v1.52/system/df'] = (500, 'busy');
      final failed = h.query(const DockerSystemDfQuery());
      expect(
        await h.result(failed),
        _failed(
          DockerQueryFailure.daemonError,
        ).having((f) => f.detail, 'detail', 'busy'),
      );
    });

    test('a gone container, a daemon error, an empty id and a server '
        'outside the fleet are answered as such', () async {
      final (h, daemon) = await ready();
      daemon.failures['/v1.52/containers/broken/json'] = (500, 'boom');

      final gone = h.query(const DockerContainerQuery('gone'));
      expect(
        await h.result(gone),
        _failed(
          DockerQueryFailure.notFound,
        ).having((f) => f.detail, 'detail', 'page not found'),
      );
      final broken = h.query(const DockerContainerQuery('broken'));
      expect(
        await h.result(broken),
        _failed(
          DockerQueryFailure.daemonError,
        ).having((f) => f.detail, 'detail', 'boom'),
      );
      final empty = h.query(const DockerContainerQuery(''));
      expect(await h.result(empty), _failed(DockerQueryFailure.invalidQuery));

      h.router.query(
        const DockerQuery(
          serverId: 'elsewhere',
          queryId: 'x',
          query: DockerEngineQuery(),
        ),
      );
      final outside = await h.next() as DockerResult;
      expect(outside.serverId, 'elsewhere');
      expect(outside.payload, _failed(DockerQueryFailure.notInFleet));
    });

    test('queries waiting on a resolution run once it is ready', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon()
        ..routes['/v1.52/images/json'] = '[]';
      h.router.probed(_srv, _profile([_rootful]));
      final first = h.query(const DockerImagesQuery());
      final second = h.query(const DockerImagesQuery());

      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).phase, DockerEndpointPhase.ready);
      expect(await h.result(first), isA<DockerImagesPayload>());
      expect(await h.result(second), isA<DockerImagesPayload>());
    });
  });

  group('endpoint users (M4 E15)', () {
    test('outside the fleet or before a probe answer there is none', () async {
      final h = _Harness();
      await expectLater(
        h.router.useEndpoint('elsewhere', (_, _) async => 0),
        throwsA(
          isA<DockerEndpointUnavailable>().having(
            (e) => e.failure,
            'failure',
            DockerQueryFailure.notInFleet,
          ),
        ),
      );
      await expectLater(
        h.router.useEndpoint(_srv, (_, _) async => 0),
        throwsA(
          isA<DockerEndpointUnavailable>().having(
            (e) => e.failure,
            'failure',
            DockerQueryFailure.profileUnknown,
          ),
        ),
      );
    });

    test('runs on the negotiated client once the endpoint resolves', () async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon();
      h.router.probed(_srv, _profile([_rootful]));
      final used = h.router.useEndpoint(
        _srv,
        (client, route) async =>
            (client.apiVersion.pathSegment, route.socketPath),
      );
      expect(await used, ('v1.52', _rootful));
      expect(daemon.requests.last, startsWith('GET /version'));
    });

    test('a failed resolution answers the waiting user', () async {
      final h = _Harness();
      h.router.probed(_srv, _profile(const []));
      await expectLater(
        h.router.useEndpoint(_srv, (_, _) async => 0),
        throwsA(
          isA<DockerEndpointUnavailable>().having(
            (e) => e.failure,
            'failure',
            DockerQueryFailure.endpointUnavailable,
          ),
        ),
      );
    });
  });

  group('relays (M9)', () {
    const tools = {'docker': '/usr/bin/docker', 'podman': null, 'socat': null};

    test('close their connections after 30 s without a query, and open one '
        'again without negotiating', () async {
      final h = _Harness();
      final daemon = h.forwarding.relayDaemon = EngineDaemon()
        ..routes['/v1.52/images/json'] = '[]';
      h.forwarding.probeAnswers[_rootful] = _disabled;
      await h.open();
      expect(
        (await h.resolve(_profile([_rootful], tools: tools))).route!.rank,
        DockerRank.cliRelay,
      );
      expect(h.forwarding.relays, hasLength(1));

      await h.clock.elapse(const Duration(seconds: 29));
      expect(h.forwarding.relays.single.closeCalls, 0);
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.forwarding.relays.single.closeCalls, 1);

      final id = h.query(const DockerImagesQuery());
      expect(await h.result(id), isA<DockerImagesPayload>());
      expect(h.forwarding.relays, hasLength(2));
      expect(daemon.requests.where((r) => r.contains('_ping')), hasLength(1));
    });

    test('a relay that stops working is answered as a failed connection, '
        'and the endpoint is found again', () async {
      final h = _Harness();
      h.forwarding
        ..relayDaemon = EngineDaemon()
        ..probeAnswers[_rootful] = _disabled;
      await h.open();
      await h.resolve(_profile([_rootful], tools: tools));
      await h.clock.elapse(const Duration(seconds: 30));

      h.forwarding.failingRelays.add('docker');
      final id = h.query(const DockerImagesQuery());
      expect(await h.result(id), _failed(DockerQueryFailure.connectionFailed));
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).failure, DockerEndpointFailure.unreachable);
    });
  });

  group('endpoint choice (CN-09, D54)', () {
    test('a choice resolves a ready endpoint again over its socket, the '
        'states carry it, and auto goes back', () async {
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..daemons[_podman] = EngineDaemon(libpodApiVersion: '5.2.0');
      await h.open();
      final auto = await h.resolve(_profile([_rootful, _podman]));
      expect(auto.route!.socketPath, _rootful);
      expect(auto.choice, const DockerEndpointAuto());

      const chosen = DockerEndpointDetected(_podman);
      h.router.setEndpoint(
        const SetDockerEndpoint(serverId: _srv, choice: chosen),
      );
      final resolving = await h.state();
      expect(resolving.phase, DockerEndpointPhase.resolving);
      expect(resolving.choice, chosen);
      final ready = await h.state();
      expect(ready.phase, DockerEndpointPhase.ready);
      expect(ready.route!.socketPath, _podman);
      expect(ready.route!.runtime, EngineRuntime.podman);
      expect(ready.choice, chosen);
      expect(h.forwarding.opens.last, _podman);

      h.router.setEndpoint(
        const SetDockerEndpoint(serverId: _srv, choice: DockerEndpointAuto()),
      );
      expect((await h.state()).choice, const DockerEndpointAuto());
      final back = await h.state();
      expect(back.route!.socketPath, _rootful);
      expect(back.choice, const DockerEndpointAuto());
    });

    test('a custom path outside 03 §5.4 is tried first and reads '
        'unclassified', () async {
      const custom = '/srv/engine/api.sock';
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..daemons[custom] = EngineDaemon();
      h.router.setEndpoint(
        const SetDockerEndpoint(
          serverId: _srv,
          choice: DockerEndpointCustom(custom),
        ),
      );
      await h.open();

      final ready = await h.resolve(_profile([_rootful]));
      expect(ready.route!.socketPath, custom);
      expect(ready.route!.mode, isNull);
      expect(ready.route!.rootEquivalence, DockerRootEquivalence.unclassified);
      expect(h.forwarding.opens.first, custom);
    });

    test('a chosen socket that answers on no rung gives way to the '
        'detected ones, which the state tells apart', () async {
      const gone = '/srv/gone.sock';
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..probeAnswers[gone] = '1\n1\n1\n';
      h.router.setEndpoint(
        const SetDockerEndpoint(
          serverId: _srv,
          choice: DockerEndpointCustom(gone),
        ),
      );
      await h.open();

      final ready = await h.resolve(_profile([_rootful]));
      expect(ready.choice, const DockerEndpointCustom(gone));
      expect(ready.route!.socketPath, _rootful);
    });

    test('a path that is no socket path fails as an invalid choice without '
        'running the ladder', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));
      final opened = h.forwarding.opens.length;

      for (final bad in ['run/docker.sock', '/a\nb.sock', '']) {
        h.router.setEndpoint(
          SetDockerEndpoint(serverId: _srv, choice: DockerEndpointCustom(bad)),
        );
        expect((await h.state()).phase, DockerEndpointPhase.resolving);
        final failed = await h.state();
        expect(failed.phase, DockerEndpointPhase.failed, reason: bad);
        expect(failed.failure, DockerEndpointFailure.invalidChoice);
        expect(failed.choice, DockerEndpointCustom(bad));
        expect(failed.label, DockerRouteLabel.none);
      }
      expect(h.forwarding.opens, hasLength(opened));
      expect(h.forwarding.commands, isEmpty);

      final id = h.query(const DockerEngineQuery());
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).failure, DockerEndpointFailure.invalidChoice);
      expect(
        await h.result(id),
        _failed(DockerQueryFailure.endpointUnavailable),
      );
    });

    test('the same choice again, or one for a server outside the fleet, '
        'changes nothing', () async {
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..daemons[_podman] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful, _podman]));
      const chosen = SetDockerEndpoint(
        serverId: _srv,
        choice: DockerEndpointDetected(_podman),
      );
      h.router.setEndpoint(chosen);
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).phase, DockerEndpointPhase.ready);

      h.router
        ..setEndpoint(chosen)
        ..setEndpoint(
          const SetDockerEndpoint(
            serverId: 'srv-elsewhere',
            choice: DockerEndpointDetected(_rootful),
          ),
        );
      // The next event is the query's answer: no state went out between.
      h.query(const DockerEngineQuery());
      expect(await h.next(), isA<DockerResult>());
    });

    test('a waiting endpoint says the new choice, and a disconnect keeps '
        'it', () async {
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..daemons[_podman] = EngineDaemon();
      await h.open();
      const chosen = DockerEndpointDetected(_podman);
      h.router.setEndpoint(
        const SetDockerEndpoint(serverId: _srv, choice: chosen),
      );
      final waiting = await h.state();
      expect(waiting.phase, DockerEndpointPhase.waiting);
      expect(waiting.choice, chosen);
      expect(
        (await h.resolve(_profile([_rootful, _podman]))).route!.socketPath,
        _podman,
      );

      h.router.disconnect(_srv);
      expect((await h.state()).choice, chosen);
      h.query(const DockerEngineQuery());
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      final ready = await h.state();
      expect(ready.route!.socketPath, _podman);
      expect(ready.choice, chosen);
    });

    test('an endpoint change (SYN-08) or leaving the fleet forgets the '
        'choice', () async {
      for (final drop in <void Function(DockerRouter)>[
        (router) => router.forget({_srv}),
        (router) => router
          ..retain(const {})
          ..retain({_srv}),
      ]) {
        final h = _Harness();
        h.forwarding
          ..daemons[_rootful] = EngineDaemon()
          ..daemons[_podman] = EngineDaemon();
        h.router.setEndpoint(
          const SetDockerEndpoint(
            serverId: _srv,
            choice: DockerEndpointDetected(_podman),
          ),
        );
        await h.open();
        expect(
          (await h.resolve(_profile([_rootful, _podman]))).route!.socketPath,
          _podman,
        );

        drop(h.router);
        expect((await h.state()).phase, DockerEndpointPhase.waiting);
        h.router.probed(_srv, _profile([_rootful, _podman]));
        h.query(const DockerEngineQuery());
        final resolving = await h.state();
        expect(resolving.phase, DockerEndpointPhase.resolving);
        expect(resolving.choice, const DockerEndpointAuto());
        expect((await h.state()).route!.socketPath, _rootful);
      }
    });

    test('a compose query reads the CLIs once per endpoint', () async {
      final h = _Harness();
      h.forwarding
        ..daemons[_rootful] = EngineDaemon()
        ..answer = (command) => command.contains('docker-compose version')
            ? Future.value(
                const RemoteCommandResult(
                  stdout:
                      '0 0\nDocker Compose version v2.29.7\n'
                      'docker-compose version 1.29.2, build 5becea4c\n',
                  exitCode: 0,
                ),
              )
            : null;
      await h.open();
      await h.resolve(_profile([_rootful]));

      for (var round = 0; round < 2; round++) {
        final id = h.query(const DockerComposeQuery());
        final cli = (await h.result(id) as DockerComposePayload).composeCli;
        expect(cli.pluginVersion, '2.29.7');
        expect(cli.standaloneVersion, '1.29.2');
        expect(cli.standaloneLegacy, isTrue);
      }
      expect(h.forwarding.commands, hasLength(1));
      expect(
        h.forwarding.commands.single,
        contains("'--host' 'unix:///var/run/docker.sock' 'compose'"),
      );
    });

    test('a compose check that fails is answered as a failed command, and '
        'tried again next time', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));
      var answers = 0;
      h.forwarding.answer = (_) => Future.value(
        answers++ == 0
            ? const RemoteCommandResult(stderr: 'boom', exitCode: 2)
            : const RemoteCommandResult(stdout: '127 127\n\n\n', exitCode: 0),
      );

      final failed = h.query(const DockerComposeQuery());
      expect(
        await h.result(failed),
        _failed(DockerQueryFailure.connectionFailed),
      );
      final id = h.query(const DockerComposeQuery());
      final cli = (await h.result(id) as DockerComposePayload).composeCli;
      expect((cli.pluginVersion, cli.standaloneVersion), (null, null));
    });
  });

  group('session ends', () {
    test('a server leaving the fleet ends its session and forgets its '
        'probe answer', () async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));

      h.router.retain(const {});
      expect((await h.state()).phase, DockerEndpointPhase.waiting);
      await pumpEventQueue();
      expect(daemon.closed, daemon.connections);

      h.router.retain({_srv});
      final id = h.query(const DockerEngineQuery());
      expect(await h.result(id), _failed(DockerQueryFailure.profileUnknown));
    });

    test('an endpoint change (SYN-08) forgets the probe answer, and '
        'Disconnect keeps it', () async {
      final h = _Harness();
      h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));

      h.router.disconnect(_srv);
      expect((await h.state()).phase, DockerEndpointPhase.waiting);
      h.query(const DockerEngineQuery());
      expect((await h.state()).phase, DockerEndpointPhase.resolving);
      expect((await h.state()).phase, DockerEndpointPhase.ready);
      expect(await h.next(), isA<DockerResult>());

      h.router.forget({_srv});
      expect((await h.state()).phase, DockerEndpointPhase.waiting);
      final id = h.query(const DockerEngineQuery());
      expect(await h.result(id), _failed(DockerQueryFailure.profileUnknown));
    });

    test('close ends every session and waits for its connections', () async {
      final h = _Harness();
      final daemon = h.forwarding.daemons[_rootful] = EngineDaemon();
      await h.open();
      await h.resolve(_profile([_rootful]));

      await h.router.close();
      expect((await h.state()).phase, DockerEndpointPhase.waiting);
      expect(daemon.closed, daemon.connections);
    });
  });
}
