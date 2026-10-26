// NET-04: the System tab's listening ports, one row per port the same
// processes hold, each with its processes and their unit or container.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/listening_ports.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';
const _container =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

ListeningSocket _socket(
  int port,
  String address, {
  PortProtocol protocol = PortProtocol.tcp,
  List<PortProcess> processes = const [],
}) => ListeningSocket(
  protocol: protocol,
  address: address,
  port: port,
  processes: processes,
);

const _sshd = PortProcess(name: 'sshd', pid: 812);
const _nginx = PortProcess(name: 'nginx', pid: 1200);

ListeningPortsRead _read() => ListeningPortsRead(
  tool: PortsTool.ss,
  sockets: [
    _socket(22, '0.0.0.0', processes: const [_sshd]),
    _socket(22, '::', processes: const [_sshd]),
    _socket(22, '::', processes: const [_sshd]),
    _socket(53, '127.0.0.53%lo', protocol: PortProtocol.udp),
    _socket(8080, '127.0.0.1', processes: const [_nginx]),
  ],
  owners: const {
    812: ProcessAttribution(unit: 'ssh.service'),
    1200: ProcessAttribution(
      unit: 'docker.service',
      containerId: _container,
      runtime: ContainerRuntime.docker,
    ),
  },
);

void main() {
  test('sockets the same processes hold on one port share a row', () {
    final rows = portRows(_read());
    expect(
      [
        for (final r in rows)
          (r.protocol, r.port, r.addresses.join(' '), r.everyAddress),
      ],
      [
        (PortProtocol.tcp, 22, '0.0.0.0 ::', true),
        (PortProtocol.udp, 53, '127.0.0.53%lo', false),
        (PortProtocol.tcp, 8080, '127.0.0.1', false),
      ],
    );
  });

  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester, {String server = _server}) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListeningPortsSection(
                monitoring: monitoring,
                serverId: server,
              ),
            ),
          ),
        ),
      );

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  Future<void> answer(
    WidgetTester tester,
    HostPayload payload, {
    HostQuery? query,
  }) async {
    final asked = query ?? queries().last;
    engine.emit(
      HostResult(
        serverId: asked.serverId,
        queryId: asked.queryId,
        payload: payload,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('lists each port with its processes and owner', (tester) async {
    await pump(tester);
    expect(find.text('Reading the listening ports…'), findsOneWidget);
    expect(queries().single.query, isA<ListeningPortsQuery>());

    await answer(tester, ListeningPorts(_read()));
    expect(find.text('TCP 22 on every address'), findsOneWidget);
    expect(find.text('sshd (PID 812)'), findsOneWidget);
    expect(find.text('Unit ssh.service'), findsOneWidget);
    expect(find.text('UDP 53 on 127.0.0.53%lo'), findsOneWidget);
    expect(find.text('Held by another user\'s process'), findsOneWidget);
    expect(find.text('TCP 8080 on 127.0.0.1'), findsOneWidget);
    expect(find.text('Container 0123456789ab'), findsOneWidget);
    expect(find.textContaining('only root may see'), findsOneWidget);

    final button = find.widgetWithText(OutlinedButton, 'Read again');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(queries(), hasLength(2));
  });

  testWidgets('a server with neither tool or nothing listening says so', (
    tester,
  ) async {
    await pump(tester);
    await answer(
      tester,
      ListeningPorts(
        ListeningPortsRead(tool: PortsTool.none, sockets: [], owners: {}),
      ),
    );
    expect(find.textContaining('neither ss nor netstat'), findsOneWidget);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    await answer(
      tester,
      ListeningPorts(
        ListeningPortsRead(tool: PortsTool.ss, sockets: [], owners: {}),
      ),
    );
    expect(find.text('Nothing listens on this server.'), findsOneWidget);
  });

  testWidgets('a failed read says why', (tester) async {
    await pump(tester);
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(find.text('Not connected to the server.'), findsOneWidget);
  });

  testWidgets('a server switch reads the new server\'s and drops the old', (
    tester,
  ) async {
    await pump(tester);
    final first = queries().single;
    await pump(tester, server: 'srv-2');
    expect(queries(), hasLength(2));
    expect(queries().last.serverId, 'srv-2');

    await answer(tester, ListeningPorts(_read()), query: first);
    expect(find.text('TCP 22 on every address'), findsNothing);
    expect(find.text('Reading the listening ports…'), findsOneWidget);
  });
}
