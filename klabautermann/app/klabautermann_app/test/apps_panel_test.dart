// DKE-08, DKE-09 and NET-11 (03 §5.11): the Docker tab's Apps sub-tab,
// its port forwards, and the controller that follows them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/docker_notice_controller.dart';
import 'package:klabautermann_app/controllers/port_forwards.dart';
import 'package:klabautermann_app/services/hand_off.dart';
import 'package:klabautermann_app/ui/docker/apps_panel.dart';
import 'package:klabautermann_app/ui/docker/docker_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'access/profiles.dart';
import 'support/docker.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

final _at = DateTime.utc(2026, 10, 27, 12);

/// A web container with a published port, an unpublished one, a UDP port
/// and a Traefik link; a stopped one with a published port.
List<ContainerSummary> _containers() => [
  ContainerSummary(
    id: 'c-web',
    names: const ['/web'],
    state: 'running',
    ports: const [
      ContainerPort(
        ip: '0.0.0.0',
        privatePort: 80,
        publicPort: 8080,
        type: 'tcp',
      ),
      ContainerPort(ip: '::', privatePort: 80, publicPort: 8080, type: 'tcp'),
      ContainerPort(privatePort: 9000, type: 'tcp'),
      ContainerPort(privatePort: 53, type: 'udp'),
    ],
    networks: const {'web_default': '172.18.0.4'},
    labels: {
      'traefik.http.routers.web.rule': MaskedValue.plain(
        'Host(`web.example.com`)',
      ),
    },
  ),
  dockerContainer(
    'c-old',
    name: 'old',
    state: 'exited',
    ports: const [
      ContainerPort(ip: '127.0.0.1', privatePort: 80, publicPort: 8081),
    ],
  ),
];

final class _Launcher implements HandOffLauncher {
  final opened = <Uri>[];

  @override
  bool available(HandOffTarget target) => false;

  @override
  Future<bool> open(Uri link) async {
    opened.add(link);
    return true;
  }
}

/// Selects the Docker tab's Apps sub-tab.
Future<void> _openApps(WidgetTester tester) async {
  final apps = find.descendant(
    of: find.byType(DockerPanel),
    matching: find.text('Apps'),
  );
  await tester.ensureVisible(apps);
  await tester.pumpAndSettle();
  await tester.tap(apps);
  await tester.pumpAndSettle();
}

void main() {
  group('containerApps', () {
    test('lists running containers with their links and TCP ports once, '
        'each with the target a forward takes', () {
      final [web] = containerApps(_containers());

      expect(web.container.id, 'c-web');
      expect(web.links.single.uri.host, 'web.example.com');
      expect(web.ports, [
        const AppPort(
          privatePort: 80,
          publicPort: 8080,
          forwardHost: '127.0.0.1',
        ),
        const AppPort(privatePort: 9000, forwardHost: '172.18.0.4'),
      ]);
      expect(web.ports.first.forwardPort, 8080);
      expect(web.ports.last.forwardPort, 9000);
    });

    test('a port bound to one address forwards there; host networking '
        'reaches unpublished ports on loopback', () {
      final apps = containerApps([
        dockerContainer(
          'bound',
          ports: const [
            ContainerPort(ip: '10.0.0.5', privatePort: 80, publicPort: 81),
          ],
        ),
        const ContainerSummary(
          id: 'host-net',
          state: 'running',
          networkMode: 'host',
          ports: [ContainerPort(privatePort: 3000, type: 'tcp')],
        ),
      ]);

      expect(apps[0].ports.single.forwardHost, '10.0.0.5');
      expect(apps[0].ports.single.hostIp, '10.0.0.5');
      expect(apps[1].ports.single.forwardHost, '127.0.0.1');
    });
  });

  group('PortForwardsController', () {
    test('follows a forward from opening to listening to its end, keeps it '
        'until dismissed, and an engine that stops ends it', () async {
      final engine = FakeEngineClient();
      final forwards = PortForwardsController(engine);
      addTearDown(forwards.dispose);

      final id = forwards.open('srv-1', host: '172.18.0.4', port: 9000);
      final sent =
          engine.sentOfType<OpenPortForward>().single as OpenPortForward;
      expect((sent.forwardId, sent.host, sent.port), (id, '172.18.0.4', 9000));
      expect(forwards.forwardsFor('srv-1').single.localPort, isNull);

      engine.emit(
        PortForwardState(
          serverId: 'srv-1',
          forwardId: id,
          host: '172.18.0.4',
          port: 9000,
          localPort: 54321,
        ),
      );
      await pumpEventQueue();
      expect(forwards.forwardsFor('srv-1').single.localPort, 54321);

      forwards.closeServer('srv-1');
      expect(engine.sentOfType<ClosePortForward>(), hasLength(1));
      engine.emit(
        PortForwardState(
          serverId: 'srv-1',
          forwardId: id,
          host: '172.18.0.4',
          port: 9000,
          ended: PortForwardEnd.closed,
        ),
      );
      await pumpEventQueue();
      expect(forwards.forwardsFor('srv-1').single.ended, PortForwardEnd.closed);
      forwards.dismiss(id);
      expect(forwards.forwardsFor('srv-1'), isEmpty);

      forwards.open('srv-1', host: 'db', port: 5432);
      await engine.close();
      await pumpEventQueue();
      expect(forwards.forwardsFor('srv-1').single.ended, PortForwardEnd.closed);
    });

    test('a second open of a live forward reuses it', () {
      final engine = FakeEngineClient();
      addTearDown(engine.close);
      final forwards = PortForwardsController(engine);
      addTearDown(forwards.dispose);

      final id = forwards.open('srv-1', host: '127.0.0.1', port: 8080);
      expect(forwards.open('srv-1', host: '127.0.0.1', port: 8080), id);
      expect(engine.sentOfType<OpenPortForward>(), hasLength(1));
      expect(
        forwards.open('srv-1', host: '127.0.0.1', port: 8081),
        isNot(id),
        reason: 'another target',
      );
    });

    test(
      'a forward opened after the engine stopped is announced ended',
      () async {
        final engine = FakeEngineClient();
        final forwards = PortForwardsController(engine);
        addTearDown(forwards.dispose);
        await engine.close();
        await pumpEventQueue();

        final heard = <PortForwardEnd?>[];
        forwards.addListener(
          () => heard.add(forwards.forwardsFor('srv-1').lastOrNull?.ended),
        );
        forwards.open('srv-1', host: 'db', port: 5432);
        expect(heard, [PortForwardEnd.closed]);
      },
    );
  });

  testWidgets('the Apps sub-tab forwards a port, opens it once it listens, '
      'and stops it', (tester) async {
    final launcher = _Launcher();
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
      dockerNotice: DockerNoticeController(dismissed: true),
      handOff: launcher,
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    final dockerTab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Docker'),
    );
    await tester.ensureVisible(dockerTab.first);
    await tester.tap(dockerTab.first);
    await tester.pumpAndSettle();
    Future<void> emit(EngineEvent event) async {
      harness.engine.emit(event);
      await tester.pumpAndSettle();
    }

    await emit(HostProfileChanged('srv-1', debianHost()));
    await emit(const LinkState('srv-1', LinkReady()));
    await emit(dockerReady('srv-1'));
    // The Containers sub-tab's watch reads the list first.
    await emit(dockerContainerList('srv-1', _containers(), at: _at));
    await _openApps(tester);

    expect(find.text('web'), findsWidgets);
    expect(find.text('*:8080 → 80/tcp'), findsOneWidget);
    expect(find.text('9000/tcp, not published'), findsOneWidget);
    expect(find.text('old'), findsNothing, reason: 'not running');

    await tester.tap(find.bySemanticsLabel('Forward 9000/tcp, not published'));
    await tester.pumpAndSettle();
    final open =
        harness.engine.sentOfType<OpenPortForward>().single as OpenPortForward;
    expect(
      (open.serverId, open.host, open.port),
      ('srv-1', '172.18.0.4', 9000),
    );
    expect(find.text('172.18.0.4:9000: opening a local port…'), findsOneWidget);

    await emit(
      PortForwardState(
        serverId: 'srv-1',
        forwardId: open.forwardId,
        host: '172.18.0.4',
        port: 9000,
        localPort: 54321,
      ),
    );
    expect(launcher.opened, [Uri.parse('http://127.0.0.1:54321')]);
    expect(find.text('127.0.0.1:54321 → 172.18.0.4:9000'), findsOneWidget);
    expect(find.text('No connections'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop forwarding 172.18.0.4:9000'));
    await tester.pumpAndSettle();
    expect(harness.engine.sentOfType<ClosePortForward>(), hasLength(1));
    await emit(
      PortForwardState(
        serverId: 'srv-1',
        forwardId: open.forwardId,
        host: '172.18.0.4',
        port: 9000,
        ended: PortForwardEnd.closed,
      ),
    );
    expect(find.text('172.18.0.4:9000: stopped'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss the forward to 172.18.0.4:9000'));
    await tester.pumpAndSettle();
    expect(find.text('172.18.0.4:9000: stopped'), findsNothing);
  });

  testWidgets('the forward dialog checks the target as the engine does', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
      dockerNotice: DockerNoticeController(dismissed: true),
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    final dockerTab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Docker'),
    );
    await tester.ensureVisible(dockerTab.first);
    await tester.tap(dockerTab.first);
    await tester.pumpAndSettle();
    harness.engine
      ..emit(HostProfileChanged('srv-1', debianHost()))
      ..emit(const LinkState('srv-1', LinkReady()))
      ..emit(dockerReady('srv-1'))
      ..emit(dockerContainerList('srv-1', const [], at: _at));
    await tester.pumpAndSettle();
    await _openApps(tester);

    await tester.tap(find.text('Forward a port…'));
    await tester.pumpAndSettle();
    final port = find.widgetWithText(TextField, 'Port');
    await tester.enterText(port, '70000');
    await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
    expect(harness.engine.sentOfType<OpenPortForward>(), isEmpty);

    await tester.enterText(port, '5432');
    await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
    await tester.pumpAndSettle();
    final open =
        harness.engine.sentOfType<OpenPortForward>().single as OpenPortForward;
    expect((open.host, open.port), ('127.0.0.1', 5432));
  });
}
