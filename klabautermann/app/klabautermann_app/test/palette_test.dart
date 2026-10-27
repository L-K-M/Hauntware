// PLT-07: the command palette over the app's commands, the fleet, the
// selected server's tabs, containers, units and stacks (03 §10.6).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/ui/docker/stacks_panel.dart'
    show StackOverview;
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart' show ServerPanel;
import 'package:klabautermann_app/ui/system_panel.dart';
import 'package:klabautermann_app/ui/workspace_navigation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _query = ValueKey('planchette.palette.query');

Future<void> _openPalette(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  test('the palette is a desktop command, offered only with a navigation', () {
    final engine = FakeEngineClient();
    addTearDown(engine.close);
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    List<String> ids(TargetPlatform platform, {required bool palette}) => [
      for (final command in buildAppCommands(
        platform: platform,
        fleet: fleet,
        onOpenSettings: () {},
        appVersion: null,
        onOpenPalette: palette ? (_) async {} : null,
      ))
        command.id,
    ];
    expect(
      ids(TargetPlatform.linux, palette: true),
      contains(kAppCommandPaletteCommandId),
    );
    expect(
      ids(TargetPlatform.linux, palette: false),
      isNot(contains(kAppCommandPaletteCommandId)),
    );
    expect(
      ids(TargetPlatform.android, palette: true),
      isNot(contains(kAppCommandPaletteCommandId)),
    );
  });

  testWidgets(
    'Ctrl+K lists commands, servers, tabs and containers; a row goes there',
    (tester) async {
      final harness = await pumpApp(tester, servers: twoServers, palette: true);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      harness.engine
        ..emit(dockerReady('srv-1'))
        ..emit(
          dockerContainerList('srv-1', [
            dockerContainer('c-api', name: 'api', image: 'ghcr.io/acme/api:2'),
          ], at: DateTime.utc(2026, 10, 26, 12)),
        );
      await tester.pumpAndSettle();

      await _openPalette(tester);
      expect(find.byKey(_query), findsOne);
      final palette = find.byType(Dialog);
      Finder inPalette(String text) =>
          find.descendant(of: palette, matching: find.text(text));
      expect(inPalette('Settings…'), findsOne);
      expect(inPalette('Command Palette…'), findsNothing, reason: 'itself');
      expect(inPalette('db-1'), findsOne);

      // A colon narrows to one provider.
      await tester.enterText(find.byKey(_query), ':tabs sys');
      await tester.pump();
      expect(inPalette('System'), findsOne);
      expect(inPalette('db-1'), findsNothing);
      await tester.tap(inPalette('System'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(SystemPanel), findsOne, reason: 'the tab switched');

      await _openPalette(tester);
      await tester.enterText(find.byKey(_query), ':containers api');
      await tester.pump();
      expect(inPalette('Running · ghcr.io/acme/api:2'), findsOne);
      await tester.tap(inPalette('api'));
      await tester.pumpAndSettle();
      expect(find.byType(SystemPanel), findsNothing, reason: 'Docker tab');
      expect(
        find.text('api'),
        findsWidgets,
        reason: 'the inspector names the container',
      );

      await _openPalette(tester);
      await tester.enterText(find.byKey(_query), 'db-1');
      await tester.pump();
      // The field holds the query too; the row is the last match.
      await tester.tap(inPalette('db-1').last);
      await tester.pumpAndSettle();
      expect(harness.fleet.selectedServerId, 'srv-2');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('unit and stack rows open the unit and the stack in their tabs', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers, palette: true);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    SystemdUnit unit(String name, String description) => SystemdUnit(
      unit: name,
      load: 'loaded',
      active: 'active',
      sub: 'running',
      description: description,
    );
    final units = [
      unit('cron.service', 'Regular background jobs'),
      unit('nginx.service', 'A high performance web server'),
      // A misread text row names no unit, so the palette leaves it out.
      unit('●', 'misread'),
    ];
    harness.engine
      ..emit(
        Sample(
          serverId: 'srv-1',
          stream: SampleStream.units,
          seq: 1,
          at: DateTime.utc(2026, 10, 26, 12),
          result: UnitsResult(
            UnitsSnapshot(
              units: units,
              failed: const [],
              format: UnitListFormat.json,
            ),
          ),
        ),
      )
      ..emit(dockerReady('srv-1'))
      ..emit(
        dockerStackList('srv-1', [
          dockerStack('api', const []),
          dockerStack('web', const []),
        ], at: DateTime.utc(2026, 10, 26, 12)),
      );
    await tester.pumpAndSettle();

    final palette = find.byType(Dialog);
    Finder inPalette(String text) =>
        find.descendant(of: palette, matching: find.text(text));

    await _openPalette(tester);
    await tester.enterText(find.byKey(_query), ':units');
    await tester.pump();
    expect(inPalette('cron.service'), findsOne);
    expect(inPalette('●'), findsNothing);
    await tester.enterText(find.byKey(_query), ':units nginx');
    await tester.pump();
    expect(inPalette('A high performance web server'), findsOne);
    await tester.tap(inPalette('nginx.service'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byTooltip('Close unit details'),
      findsOne,
      reason: "the Services tab opened the unit's page",
    );

    await _openPalette(tester);
    await tester.enterText(find.byKey(_query), ':stacks web');
    await tester.pump();
    await tester.tap(inPalette('web').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<StackOverview>(find.byType(StackOverview)).project,
      'web',
      reason: 'the Stacks sub-tab shows the stack, not the first',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'a tab asked for on another server shows once its workspace does',
    (tester) async {
      await pumpApp(tester, servers: twoServers, palette: true);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      final navigation = WorkspaceNavigationScope.maybeOf(
        tester.element(find.byType(TabBar)),
      )!;

      navigation.openPanel('srv-2', ServerPanel.system);
      await tester.pumpAndSettle();

      expect(find.byType(SystemPanel), findsOne);
      expect(navigation.request, isNull, reason: 'consumed');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'a narrow window offers no tab or container rows, which it cannot show',
    (tester) async {
      final harness = await pumpApp(
        tester,
        size: const Size(800, 900),
        servers: twoServers,
        palette: true,
      );
      harness.fleet.select('srv-1');
      await tester.pumpAndSettle();

      await _openPalette(tester);
      expect(find.byKey(_query), findsOne);
      final palette = find.byType(Dialog);
      expect(
        find.descendant(of: palette, matching: find.text('db-1')),
        findsOne,
      );
      // The list builds the rows in view only, so narrow it to the tabs.
      await tester.enterText(find.byKey(_query), ':tabs sys');
      await tester.pump();
      expect(
        find.descendant(of: palette, matching: find.text('System')),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
