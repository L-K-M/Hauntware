// NET-02 and NET-03: the System tab's interfaces section, which folds the
// loopback and unaddressed software interfaces away, shows live rates
// from the `core` stream and counts the TCP sockets by state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/interfaces.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

const _global = NetAddress(
  family: NetAddressFamily.ipv4,
  address: '192.0.2.10',
  prefixLength: 24,
  scope: 'global',
);
const _linkLocal = NetAddress(
  family: NetAddressFamily.ipv6,
  address: 'fe80::1',
  prefixLength: 64,
  scope: 'link',
);

NetInterface _link(
  String name, {
  bool physical = false,
  NetLinkState state = NetLinkState.up,
  List<NetAddress> addresses = const [],
  int? speed,
}) => NetInterface(
  name: name,
  state: state,
  physical: physical,
  addresses: addresses,
  mtu: 1500,
  speedMbps: speed,
  rxErrors: 0,
  txErrors: 1,
  rxDropped: 12,
  txDropped: 0,
);

InterfacesRead _read({bool addressesRead = true}) => InterfacesRead(
  interfaces: [
    _link(
      'docker0',
      addresses: addressesRead ? const [_global] : const [],
      state: NetLinkState.down,
    ),
    _link(
      'eth0',
      physical: true,
      addresses: addressesRead ? const [_global, _linkLocal] : const [],
      speed: 2500,
    ),
    _link('lo', state: NetLinkState.unknown),
    _link('veth12ab', addresses: addressesRead ? const [_linkLocal] : const []),
  ],
  addressesRead: addressesRead,
  sockets: SocketCounts(
    tcp: {
      TcpState.established: 18,
      TcpState.listen: 3,
      TcpState.synSent: 1,
      TcpState.finWait1: 2,
    },
    used: 523,
    udp: 6,
  ),
);

/// The facts as `label=value`.
final _shown = <String>[];

Widget _fact(String label, String value) {
  _shown.add('$label=$value');
  return Text('$label: $value');
}

void main() {
  test('the loopback and unaddressed software interfaces fold', () {
    final (:shown, :folded) = shownInterfaces(_read(), showAll: false);
    expect(shown.map((link) => link.name), ['eth0', 'docker0']);
    expect(folded, 2);
    expect(
      shownInterfaces(_read(), showAll: true).shown.map((link) => link.name),
      ['eth0', 'docker0', 'lo', 'veth12ab'],
    );

    // Without addresses nothing tells a veth from a bond.
    final bare = shownInterfaces(_read(addressesRead: false), showAll: false);
    expect(bare.shown.map((link) => link.name), [
      'eth0',
      'docker0',
      'veth12ab',
    ]);
    expect(bare.folded, 1);
  });

  late FakeEngineClient engine;
  late MonitoringController monitoring;
  late ValueNotifier<Sample?> core;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
    core = ValueNotifier(null);
    _shown.clear();
  });

  tearDown(() async {
    core.dispose();
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
              child: InterfacesSection(
                monitoring: monitoring,
                serverId: server,
                core: core,
                fact: _fact,
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

  testWidgets('lists the interfaces and counts the connections', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Reading the network interfaces…'), findsOne);
    expect(queries().single.query, isA<InterfacesQuery>());

    await answer(tester, NetInterfaces(_read()));
    expect(find.text('eth0: up'), findsOne);
    expect(find.text('docker0: down'), findsOne);
    expect(find.text('192.0.2.10/24'), findsNWidgets(2));
    expect(find.text('fe80::1/64'), findsOne);
    expect(find.text('Link speed 2.5 Gb/s'), findsOne);
    expect(find.text('MTU 1500'), findsNWidgets(2));
    expect(
      find.text('Errors: 0 in, 1 out. Dropped: 12 in, 0 out.'),
      findsNWidgets(2),
    );
    expect(find.textContaining('lo:'), findsNothing);
    expect(
      tester.getTopLeft(find.text('eth0: up')).dy,
      lessThan(tester.getTopLeft(find.text('docker0: down')).dy),
    );
    expect(_shown, [
      'TCP established=18',
      'TCP listening=3',
      'TCP time wait=0',
      'TCP close wait=0',
      'TCP in other states=3',
      'UDP sockets=6',
      'All sockets=523',
    ]);

    await tester.tap(find.text('Show loopback and virtual interfaces (2)'));
    await tester.pump();
    expect(find.text('lo: state not reported'), findsOne);
    expect(find.text('veth12ab: up'), findsOne);

    final button = find.widgetWithText(OutlinedButton, 'Read again');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(queries(), hasLength(2));
  });

  testWidgets('each interface shows its rate from the core stream', (
    tester,
  ) async {
    await pump(tester);
    await answer(tester, NetInterfaces(_read()));
    expect(find.textContaining('Receiving'), findsNothing);

    core.value = Sample(
      serverId: _server,
      stream: SampleStream.core,
      seq: 1,
      at: DateTime.utc(2026, 10, 26),
      result: CoreResult(
        network: {
          'eth0': const NetRate(rxBytesPerSecond: 2048, txBytesPerSecond: 512),
        },
      ),
    );
    await tester.pump();
    expect(find.text('Receiving 2 KiB/s, sending 512 B/s'), findsOne);
  });

  testWidgets('without ip the addresses are said to be missing', (
    tester,
  ) async {
    await pump(tester);
    await answer(tester, NetInterfaces(_read(addressesRead: false)));
    expect(
      find.text(
        'The server has no ip command that lists addresses, so none are '
        'shown.',
      ),
      findsOne,
    );
    expect(find.text('veth12ab: up'), findsOne);
    expect(find.text('Show loopback and virtual interfaces (1)'), findsOne);
  });

  testWidgets('a failed read says why', (tester) async {
    await pump(tester);
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(find.text('Not connected to the server.'), findsOne);
  });

  testWidgets('a server switch reads the new server\'s and drops the old', (
    tester,
  ) async {
    await pump(tester);
    final first = queries().single;
    await pump(tester, server: 'srv-2');
    expect(queries(), hasLength(2));
    expect(queries().last.serverId, 'srv-2');

    await answer(tester, NetInterfaces(_read()), query: first);
    expect(find.text('eth0: up'), findsNothing);
    expect(find.text('Reading the network interfaces…'), findsOne);
  });
}
