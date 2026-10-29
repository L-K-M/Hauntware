import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show macosTrafficLightsInset;
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoHistory;
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/window_panes.dart';
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';
import 'package:klabautermann_app/ui/menus/app_commands.dart';
import 'package:klabautermann_app/ui/server_workspace.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    LogicalKeyboardKey alt = LogicalKeyboardKey.altLeft,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(alt);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(alt);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  group('the desktop panes (K1)', () {
    testWidgets('opening container details reveals a hidden inspector', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.fleet.select('srv-1');
      await tester.pumpAndSettle();
      final container = dockerContainer('container-1');

      for (var attempt = 0; attempt < 2; attempt++) {
        await harness.windowPanes.setShown(WindowPane.inspector, false);
        await tester.pump();
        openContainerDetails(
          tester.element(find.byType(ServerWorkspace)),
          monitoring: harness.monitoring,
          serverId: 'srv-1',
          container: container,
        );
        await tester.pump();
        expect(harness.windowPanes.inspectorShown, isTrue);
        expect(find.byType(ContainerInspectorBody), findsOneWidget);
      }
    });

    testWidgets('the rail and inspector show at start; the rail is 260 '
        'and the inspector 300', (tester) async {
      await pumpApp(tester, servers: twoServers);
      expect(find.byType(FleetRail), findsOneWidget);
      expect(find.byType(InspectorPane), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(InspectorPane)).dx,
        1280 - DesktopShell.inspectorWidth,
      );
    });

    testWidgets('the band toggles hide their panes, and the header shows '
        'them again', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      await tester.tap(find.byKey(DesktopShell.sidebarToggleKey));
      await tester.pumpAndSettle();
      expect(find.byType(FleetRail), findsNothing);
      expect(harness.windowPanes.sidebarShown, isFalse);
      // The hidden rail's toggle moves into the header.
      await tester.tap(find.byKey(DesktopShell.sidebarToggleKey));
      await tester.pumpAndSettle();
      expect(find.byType(FleetRail), findsOneWidget);

      await tester.tap(find.byKey(DesktopShell.inspectorToggleKey));
      await tester.pumpAndSettle();
      expect(find.byType(InspectorPane), findsNothing);
      expect(harness.windowPanes.inspectorShown, isFalse);
      await tester.tap(find.byKey(DesktopShell.inspectorToggleKey));
      await tester.pumpAndSettle();
      expect(find.byType(InspectorPane), findsOneWidget);
    });

    testWidgets('Ctrl+Alt+S and Ctrl+Alt+I toggle the panes', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);
      await chord(tester, LogicalKeyboardKey.keyS);
      expect(harness.windowPanes.sidebarShown, isFalse);
      await chord(tester, LogicalKeyboardKey.keyS);
      expect(harness.windowPanes.sidebarShown, isTrue);

      await chord(tester, LogicalKeyboardKey.keyI);
      expect(harness.windowPanes.inspectorShown, isFalse);
      await chord(tester, LogicalKeyboardKey.keyI);
      expect(harness.windowPanes.inspectorShown, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('AltGr, reported as Ctrl+right-Alt, is not the chord', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);
      await chord(
        tester,
        LogicalKeyboardKey.keyS,
        alt: LogicalKeyboardKey.altRight,
      );
      expect(harness.windowPanes.sidebarShown, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('a choice that cannot be saved says so and stays', (
      tester,
    ) async {
      // pumpApp's teardown disposes the controllers it is given.
      final panes = WindowPanesController(
        saveSidebar: (_) async => throw Exception('disk full'),
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await tester.tap(find.byKey(DesktopShell.sidebarToggleKey));
      await tester.pumpAndSettle();
      expect(find.byType(FleetRail), findsNothing);
      expect(
        find.textContaining('could not save your window layout'),
        findsOneWidget,
      );
    });

    testWidgets('leading controls start at the edge off macOS', (tester) async {
      await pumpApp(tester, servers: twoServers);
      expect(
        tester.getTopLeft(find.byKey(DesktopShell.sidebarToggleKey)).dx,
        8,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('under the macOS band, leading controls start past the '
        'traffic lights', (tester) async {
      await pumpApp(
        tester,
        servers: twoServers,
        toolbarBand: ValueNotifier(true),
      );
      expect(
        tester.getTopLeft(find.byKey(DesktopShell.sidebarToggleKey)).dx,
        macosTrafficLightsInset,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('WindowPanesController', () {
    test('applies before it saves and retries a failed save', () async {
      var calls = 0;
      var fail = true;
      final panes = WindowPanesController(
        saveSidebar: (_) async {
          calls++;
          if (fail) throw Exception('disk full');
        },
      );
      addTearDown(panes.dispose);

      await expectLater(
        panes.setShown(WindowPane.sidebar, false),
        throwsA(isA<WindowPanesNotSavedException>()),
      );
      // Hidden though not saved: the next run starts where the store
      // left it, not where this attempt did.
      expect(panes.sidebarShown, isFalse);

      fail = false;
      await panes.setShown(WindowPane.sidebar, false);
      expect(calls, 2);
    });
  });

  group('the pane commands (K2)', () {
    test('carry the suite chords and a checked state that follows the '
        'panes', () {
      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      final panes = WindowPanesController();
      addTearDown(() {
        fleet.dispose();
        panes.dispose();
      });

      final commands = buildAppCommands(
        platform: TargetPlatform.linux,
        fleet: fleet,
        onOpenSettings: () {},
        appVersion: null,
        panes: panes,
        undoHistory: GhostUndoHistory(),
      );
      final sidebar = commands.firstWhere(
        (command) => command.id == kViewToggleSidebarCommandId,
      );
      final inspector = commands.firstWhere(
        (command) => command.id == kViewToggleInspectorCommandId,
      );

      expect(sidebar.activators(TargetPlatform.linux), [
        const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          alt: true,
        ),
      ]);
      expect(inspector.activators(TargetPlatform.linux), [
        const SingleActivator(
          LogicalKeyboardKey.keyI,
          control: true,
          alt: true,
        ),
      ]);
      expect(sidebar.leftAltOnly, isTrue);
      expect(inspector.leftAltOnly, isTrue);

      expect(sidebar.checked!(), isTrue);
      expect(inspector.checked!(), isTrue);
      panes.setShown(WindowPane.sidebar, false);
      expect(sidebar.checked!(), isFalse);
    });
  });
}
