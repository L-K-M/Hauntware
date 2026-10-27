// FL-08: the fleet board's layouts and the desktop workspace that shows
// it while no server is open (03 §10.3).
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/fleet_density.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/fleet_board.dart';
import 'package:klabautermann_app/ui/server_workspace.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

List<FleetServer> _servers(int count) => [
  for (var i = 0; i < count; i++)
    FleetServer(id: 'srv-$i', displayName: 'host-$i'),
];

void main() {
  test('auto shows cards for a small fleet and a grid for a large one; a '
      'stored name parses to its layout', () {
    expect(FleetDensity.auto.resolve(kFleetGridFrom - 1), FleetDensity.cards);
    expect(FleetDensity.auto.resolve(kFleetGridFrom), FleetDensity.grid);
    expect(FleetDensity.rows.resolve(100), FleetDensity.rows);
    for (final density in FleetDensity.values) {
      expect(FleetDensity.parse(density.name), density);
    }
    expect(FleetDensity.parse('mosaic'), FleetDensity.auto);
    expect(FleetDensity.parse(null), FleetDensity.auto);
  });

  test(
    'a layout the store refused stays and is saved when picked again',
    () async {
      var fail = true;
      final saved = <String>[];
      final density = FleetDensityController(
        save: (name) async {
          if (fail) throw const FileSystemException('disk full');
          saved.add(name);
        },
      );
      addTearDown(density.dispose);

      await expectLater(
        density.setDensity(FleetDensity.grid),
        throwsA(isA<FleetDensityNotSavedException>()),
      );
      expect(density.value, FleetDensity.grid);
      fail = false;
      await density.setDensity(FleetDensity.grid);
      await density.setDensity(FleetDensity.grid);
      expect(saved, ['grid'], reason: 'retried once, then a no-op');
    },
  );

  Future<(FleetController, FleetDensityController)> pumpWorkspace(
    WidgetTester tester, {
    required int servers,
    FleetDensity density = FleetDensity.auto,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: _servers(servers));
    final monitoring = MonitoringController(engine);
    final layout = FleetDensityController(density: density);
    addTearDown(() async {
      layout.dispose();
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: FleetDensityScope(
            density: layout,
            child: ServerWorkspace(fleet: fleet, monitoring: monitoring),
          ),
        ),
      ),
    );
    return (fleet, layout);
  }

  testWidgets('the workspace shows the fleet as cards, opens a tapped one, '
      'and switches layouts from its picker', (tester) async {
    final (fleet, layout) = await pumpWorkspace(tester, servers: 3);
    expect(find.byType(FleetTile), findsNWidgets(3));
    expect(
      tester.getSize(find.byType(FleetTile).first).width,
      FleetBoard.cardWidth,
    );
    expect(find.text('Select a server'), findsNothing);

    await tester.tap(find.text('Grid'));
    await tester.pumpAndSettle();
    expect(layout.value, FleetDensity.grid);
    expect(
      tester.getSize(find.byType(FleetTile).first).width,
      FleetBoard.gridWidth,
    );

    await tester.tap(find.text('Rows'));
    await tester.pumpAndSettle();
    expect(find.byType(FleetTile), findsNothing);
    expect(find.text('Select a server'), findsOneWidget);

    await tester.tap(find.text('Cards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('host-1'));
    await tester.pumpAndSettle();
    expect(fleet.selectedServer?.id, 'srv-1');
    // The opened workspace's timers end with it.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('auto packs a large fleet as a grid', (tester) async {
    await pumpWorkspace(tester, servers: kFleetGridFrom);
    expect(
      tester.getSize(find.byType(FleetTile).first).width,
      FleetBoard.gridWidth,
    );
  });

  testWidgets('a card shows the reading in figures and is one named button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: _servers(1));
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: FleetBoard.cardWidth,
            child: FleetTile(
              server: fleet.servers.single,
              fleet: fleet,
              monitoring: monitoring,
            ),
          ),
        ),
      ),
    );
    engine.emit(
      Sample(
        serverId: 'srv-0',
        stream: SampleStream.overview,
        seq: 1,
        at: monitoring.clock.value,
        result: OverviewResult(
          cpu: CpuPercentages(const [], 23),
          memory: const MemoryUsage(usedBytes: 1 << 30, totalBytes: 4 << 30),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CPU 23 % · Memory 25 %'), findsOneWidget);
    final node = tester.getSemantics(find.byType(FleetTile));
    expect(node.label, startsWith('host-0'));
    expect(node.flagsCollection.isButton, isTrue);
    handle.dispose();
  });
}
