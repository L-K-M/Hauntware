// FL-11: the connection tree on the fleet board (03 §10.3): servers open
// to their stacks and containers, read while a node is open, and a
// container opens in the workspace's Docker tab.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/fleet_density.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/fleet_board.dart';
import 'package:klabautermann_app/ui/fleet_tree.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart' show ServerPanel;
import 'package:klabautermann_app/ui/workspace_navigation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

final _now = DateTime.utc(2026, 10, 27, 12);

void main() {
  testWidgets('a server opens to its stacks and containers while its node '
      'is open, and a container opens in the Docker tab', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeEngineClient();
    final fleet = FleetController(
      engine,
      servers: const [
        FleetServer(id: 'srv-1', displayName: 'alpha'),
        FleetServer(id: 'srv-2', displayName: 'bravo'),
      ],
    );
    final monitoring = MonitoringController(engine);
    final navigation = WorkspaceNavigation(fleet);
    final layout = FleetDensityController(density: FleetDensity.tree);
    addTearDown(() async {
      layout.dispose();
      navigation.dispose();
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkspaceNavigationScope(
            navigation: navigation,
            child: FleetBoard(
              fleet: fleet,
              monitoring: monitoring,
              density: layout,
              invitation: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(FleetTree), findsOneWidget);
    engine.emit(dockerReady('srv-1'));
    await tester.pump();
    List<DockerWatch> containerWatches() => [
      for (final watch in engine.sentOfType<DockerWatch>().cast<DockerWatch>())
        if (watch.lists.contains(DockerWatchList.containers)) watch,
    ];
    expect(containerWatches(), isEmpty, reason: 'nothing open yet');

    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(containerWatches(), hasLength(1));
    expect(find.text('Reading containers…'), findsOneWidget);

    engine.emit(
      dockerContainerList('srv-1', [
        dockerContainer('c1', name: 'web', project: 'shop'),
        dockerContainer('c2', name: 'db', project: 'shop', state: 'exited'),
        dockerContainer('c3', name: 'cron'),
      ], at: _now),
    );
    await tester.pumpAndSettle();
    expect(find.text('shop'), findsOneWidget);
    expect(find.text('1 of 2 running'), findsOneWidget);
    expect(find.text('cron'), findsOneWidget);
    expect(find.text('web'), findsNothing, reason: 'the stack is closed');

    await tester.tap(find.text('shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web'));
    await tester.pumpAndSettle();
    expect(fleet.selectedServer?.id, 'srv-1');
    expect(navigation.request?.panel, ServerPanel.docker);
    expect(navigation.container?.container.id, 'c1');

    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(
      engine.sentOfType<DockerUnwatch>(),
      isNotEmpty,
      reason: 'closing the node gives the watch back',
    );
  });

  testWidgets('a server whose engine search failed says so', (tester) async {
    final engine = FakeEngineClient();
    final fleet = FleetController(
      engine,
      servers: const [FleetServer(id: 'srv-1', displayName: 'alpha')],
    );
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
          body: FleetTree(fleet: fleet, monitoring: monitoring),
        ),
      ),
    );
    engine.emit(dockerNoRoute('srv-1', DockerNoRouteReason.values.first));
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(
      find.text('No Docker engine answers on this server.'),
      findsOneWidget,
    );
  });
}
