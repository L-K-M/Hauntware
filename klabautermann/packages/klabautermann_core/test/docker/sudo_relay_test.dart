// The sudo relay, rank 3 of 03 §5.9 (M4 E16, plan M7), over a forwarding
// link double: offered only while admin mode is on, started through the
// session's elevation with `sudo -n` first, labelled root-equivalent, and
// dropped when admin mode ends.
import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/docker/docker_ladder.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ApiVersion, DockerClient, DockerHttpClient, DockerTransportException;
import 'package:klabautermann_docker/testing.dart' show FakeDuplexPair;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ElevatedExecutor, ElevationProbe;
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';

const _srv = 'srv-1';
const _rootful = '/var/run/docker.sock';

/// The exec probe's answer for a socket the user may not write.
const _denied = '0\n1\n1\n';

HostProfile _profile({
  SudoKind sudo = SudoKind.sudo,
  Map<String, String?> tools = const {
    'docker': '/usr/bin/docker',
    'podman': null,
    'socat': null,
  },
}) => HostProfile(
  uid: 1000,
  sudoKind: sudo,
  sudoVersionLine: sudo == SudoKind.none ? null : 'Sudo version 1.9.15p5',
  tools: tools,
  engineSockets: const [
    EngineSocket(path: _rootful, exists: true, writable: false),
  ],
  areaStatuses: const {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

AdminSession _session(ForwardingLink link) => AdminSession.test(
  ElevatedExecutor(
    link,
    const ElevationProbe(sudoVersionLine: 'Sudo version 1.9.15p5'),
  ),
  'hunter2',
);

void main() {
  group('the ladder', () {
    test(
      'a denied socket takes the sudo relay while admin mode is on',
      () async {
        final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
        final route =
            await DockerLadder.resolve(link, _profile(), adminMode: true)
                as DockerRoute;

        expect(route.rank, DockerRank.sudoRelay);
        expect(route.rank.number, 3);
        expect(route.label, DockerRouteLabel.sudoRelay);
        expect(route.rootEquivalence, DockerRootEquivalence.sudoRelay);
        expect(route.relayArgv, [
          'docker',
          '--host',
          'unix://$_rootful',
          'system',
          'dial-stdio',
        ]);
        expect(link.started, isEmpty, reason: 'the ladder starts no relay');
      },
    );

    test('without admin mode it still needs admin mode', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      expect(
        await DockerLadder.resolve(link, _profile()),
        isA<DockerRouteNone>().having(
          (n) => n.reason,
          'reason',
          DockerNoRouteReason.needsAdminMode,
        ),
      );
    });

    test('a host without an engine CLI has no sudo relay', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      expect(
        await DockerLadder.resolve(
          link,
          _profile(tools: const {'docker': null, 'podman': null}),
          adminMode: true,
        ),
        isA<DockerRouteNone>().having(
          (n) => n.reason,
          'reason',
          DockerNoRouteReason.noRelay,
        ),
      );
    });

    test('without sudo, admin mode offers no relay', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      expect(
        await DockerLadder.resolve(
          link,
          _profile(sudo: SudoKind.none),
          adminMode: true,
        ),
        isA<DockerRouteNone>().having(
          (n) => n.reason,
          'reason',
          DockerNoRouteReason.socketDenied,
        ),
      );
    });

    test('an excluded sudo relay gives way to none', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      final route =
          await DockerLadder.resolve(link, _profile(), adminMode: true)
              as DockerRoute;
      expect(
        await DockerLadder.resolve(
          link,
          _profile(),
          adminMode: true,
          excluding: {route},
        ),
        isA<DockerRouteNone>(),
      );
    });
  });

  group('the duplex', () {
    test('each connection is one elevated exec, sudo -n first, and the '
        'engine answers through it', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      final route =
          await DockerLadder.resolve(link, _profile(), adminMode: true)
              as DockerRoute;
      final session = _session(link);
      final client = DockerClient(
        DockerHttpClient(() => openDockerDuplex(link, route, admin: session)),
        apiVersion: const ApiVersion(1, 44),
      );

      await client.ping();
      expect(link.started, hasLength(1));
      expect(
        link.started.single,
        allOf(
          contains("sudo -n -- 'docker' '--host'"),
          contains("'dial-stdio'"),
        ),
      );
      await client.close();
    });

    test('without an admin session a sudo relay does not open', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;
      final route =
          await DockerLadder.resolve(link, _profile(), adminMode: true)
              as DockerRoute;
      final client = DockerClient(
        DockerHttpClient(() => openDockerDuplex(link, route)),
        apiVersion: const ApiVersion(1, 44),
      );
      await expectLater(
        client.ping(),
        throwsA(isA<DockerTransportException>()),
      );
      expect(link.started, isEmpty);
      await client.close();
    });
  });

  group('the router', () {
    late ForwardingLink link;
    late AdminSession? admin;
    late DockerRouter router;
    late StreamController<EngineEvent> events;
    late StreamIterator<EngineEvent> next;

    Future<DockerEndpointState> state() async {
      while (true) {
        expect(
          await next.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        if (next.current case final DockerEndpointState state) return state;
      }
    }

    setUp(() {
      link = ForwardingLink()
        ..probeAnswers[_rootful] = _denied
        ..relayDaemon = EngineDaemon();
      admin = null;
      events = StreamController<EngineEvent>();
      next = StreamIterator(events.stream);
      router = DockerRouter(
        linkFor: (_) => link,
        emit: events.add,
        adminFor: (_) => admin,
        startTimer: FakeClock().startTimer,
      )..retain({_srv});
      addTearDown(() async {
        await next.cancel();
        await router.close();
      });
    });

    Future<void> watch() async {
      // The probe answer first, so the watch resolves at once.
      router.probed(_srv, _profile());
      router.watch(
        const DockerWatch(
          serverId: _srv,
          watchId: 'w-1',
          lists: {DockerWatchList.containers},
        ),
      );
    }

    test('admin mode on finds the sudo relay; its end drops it and the '
        'route needs admin mode again', () async {
      await watch();
      expect((await state()).phase, DockerEndpointPhase.resolving);
      final failed = await state();
      expect(failed.phase, DockerEndpointPhase.failed);
      expect(failed.noRouteReason, DockerNoRouteReason.needsAdminMode);

      admin = _session(link);
      router.adminChanged(_srv);
      expect((await state()).phase, DockerEndpointPhase.resolving);
      final ready = await state();
      expect(ready.phase, DockerEndpointPhase.ready);
      expect(ready.label, DockerRouteLabel.sudoRelay);
      expect(ready.route!.rootEquivalence, DockerRootEquivalence.sudoRelay);
      expect(link.started, isNotEmpty);
      expect(link.started, everyElement(contains('sudo -n -- ')));

      admin = null;
      router.adminChanged(_srv);
      expect((await state()).phase, DockerEndpointPhase.resolving);
      final after = await state();
      expect(after.phase, DockerEndpointPhase.failed);
      expect(after.noRouteReason, DockerNoRouteReason.needsAdminMode);
    });

    test('admin mode ending while the endpoint resolves keeps no sudo '
        'relay, and closes the connection it opened', () async {
      final relay = _HeldDaemon(EngineDaemon());
      link.relayDaemon = relay;
      admin = _session(link);
      await watch();
      expect((await state()).phase, DockerEndpointPhase.resolving);

      // The relay's connection is open and its ping unanswered when
      // admin mode ends.
      await relay.asked.future;
      admin = null;
      router.adminChanged(_srv);
      relay.gate.complete();

      DockerEndpointState settled;
      do {
        settled = await state();
      } while (settled.phase == DockerEndpointPhase.resolving);
      expect(settled.phase, DockerEndpointPhase.failed);
      expect(settled.noRouteReason, DockerNoRouteReason.needsAdminMode);
      await pumpEventQueue();
      expect(relay.closed, relay.connections);
    });

    test('a change that leaves admin mode on keeps the endpoint', () async {
      admin = _session(link);
      await watch();
      expect((await state()).phase, DockerEndpointPhase.resolving);
      expect((await state()).phase, DockerEndpointPhase.ready);
      final opened = link.started.length;

      router.adminChanged(_srv);
      await pumpEventQueue();
      expect(link.started, hasLength(opened));
    });
  });
}

/// [inner] behind a gate: requests wait until [gate] completes, and
/// [asked] completes with the first.
final class _HeldDaemon extends FakeDaemon {
  _HeldDaemon(this.inner);

  final FakeDaemon inner;
  final gate = Completer<void>();
  final asked = Completer<void>();

  @override
  String respond(String requestLine) => inner.respond(requestLine);

  @override
  void handle(String requestLine, FakeDuplexPair connection) {
    if (!asked.isCompleted) asked.complete();
    unawaited(gate.future.then((_) => inner.handle(requestLine, connection)));
  }
}
