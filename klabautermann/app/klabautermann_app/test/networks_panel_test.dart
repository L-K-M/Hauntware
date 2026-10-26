import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/networks_panel.dart';
import 'package:klabautermann_app/ui/docker/networks_view.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

const _wide = Size(1000, 600);
const _phone = Size(390, 900);

final _now = DateTime(2026, 10, 15, 14, 30);

/// The engine's own bridge, two user-defined networks (one with two
/// running containers on it, one empty) and host (DNW-01).
const _networks = [
  NetworkSummary(
    id: 'n-bridge',
    name: 'bridge',
    driver: 'bridge',
    scope: 'local',
    ipam: [NetworkIpamConfig(subnet: '172.17.0.0/16')],
  ),
  NetworkSummary(
    id: 'n-shop',
    name: 'shop_default',
    driver: 'bridge',
    scope: 'local',
    ipam: [NetworkIpamConfig(subnet: '172.20.0.0/16', gateway: '172.20.0.1')],
  ),
  NetworkSummary(id: 'n-old', name: 'old_net', driver: 'bridge'),
  NetworkSummary(id: 'n-host', name: 'host', driver: 'host', scope: 'local'),
];

final _containers = [
  dockerContainer('a1', name: 'web', networks: {'shop_default': '172.20.0.2'}),
  dockerContainer('a2', name: 'db', networks: {'shop_default': '172.20.0.3'}),
  dockerContainer('b1', name: 'proxy', networks: {'bridge': '172.17.0.2'}),
];

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  List<DockerWatch> get watches => engine.sentOfType<DockerWatch>().cast();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> list(WidgetTester tester) async {
    await emit(tester, dockerNetworkList(_serverId, _networks, at: _now));
    await emit(tester, dockerContainerList(_serverId, _containers, at: _now));
  }
}

Future<_Panel> _pump(WidgetTester tester, {Size size = _wide}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final visible = ValueNotifier(true);
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(klabautermannThemeStyle),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: visible,
          builder: (context, shows, _) => NetworksPanel(
            monitoring: monitoring,
            serverId: _serverId,
            visible: shows,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible);
}

const _prefix = 'networks.row.';

List<String> _order(WidgetTester tester) {
  final rows = [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(_prefix))
        (
          id: value.substring(_prefix.length),
          top: tester.getTopLeft(find.byWidget(element.widget)).dy,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final row in rows) row.id];
}

String _label(WidgetTester tester, String id) =>
    tester.getSemantics(find.byKey(ValueKey('$_prefix$id'))).label;

/// 03 §10.4's Networks sub-tab (DNW-01) over the network watch.
void main() {
  test('counts the containers on each network by name', () {
    expect(containersByNetwork(_containers), {'shop_default': 2, 'bridge': 1});
  });

  test('a built-in network is never unused', () {
    final entries = networkEntries(
      _networks,
      containers: const [],
      filter: NetworkFilter.unused,
      terms: const [],
    );
    expect(
      [for (final e in entries) e.network.name],
      ['shop_default', 'old_net'],
    );
  });

  testWidgets('watches the networks and containers while it shows', (
    tester,
  ) async {
    final panel = await _pump(tester);
    expect(panel.watches.single.lists, {
      DockerWatchList.networks,
      DockerWatchList.containers,
    });
    expect(find.text('Reading the networks…'), findsOneWidget);
  });

  testWidgets('shows name, driver, scope, subnet and use, marks the '
      'built-in ones, and filters the unused', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);

    expect(_order(tester), ['n-bridge', 'n-host', 'n-old', 'n-shop']);
    expect(
      _label(tester, 'n-shop'),
      allOf(
        contains('shop_default'),
        contains('bridge'),
        contains('local'),
        contains('172.20.0.0/16'),
        contains('172.20.0.1'),
        contains('2 containers on it'),
      ),
    );
    expect(_label(tester, 'n-bridge'), contains('bridge, built-in'));
    expect(_label(tester, 'n-host'), contains('Subnet: None'));
    expect(_label(tester, 'n-old'), contains('Unused'));
    expect(find.text('Built-in'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Unused'));
    await tester.pumpAndSettle();
    expect(_order(tester), ['n-old']);
  });

  testWidgets('the Unused filter lists every network until a container list '
      'says which are unused', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(tester, dockerNetworkList(_serverId, _networks, at: _now));

    final unused = find.widgetWithText(ChoiceChip, 'Unused');
    expect(tester.widget<ChoiceChip>(unused).onSelected, isNull);
    await tester.tap(unused);
    await tester.pumpAndSettle();
    expect(_order(tester), ['n-bridge', 'n-host', 'n-old', 'n-shop']);

    await panel.emit(
      tester,
      dockerContainerList(_serverId, _containers, at: _now),
    );
    await tester.tap(unused);
    await tester.pumpAndSettle();
    expect(_order(tester), ['n-old']);
  });

  testWidgets('says why the list failed and keeps the last one', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    await panel.emit(
      tester,
      DockerListChanged(
        serverId: _serverId,
        list: DockerWatchList.networks,
        payload: const DockerQueryFailed(DockerQueryFailure.daemonError),
        at: _now,
      ),
    );
    expect(
      find.text('The engine refused or failed to list the networks.'),
      findsOneWidget,
    );
    expect(_order(tester), hasLength(4));
  });

  testWidgets('a phone lists two-line rows with a sort menu', (tester) async {
    final panel = await _pump(tester, size: _phone);
    await panel.list(tester);

    expect(find.byType(DropdownButton<NetworkColumn>), findsOneWidget);
    expect(_label(tester, 'n-shop'), contains('Scope: local'));
  });
}
