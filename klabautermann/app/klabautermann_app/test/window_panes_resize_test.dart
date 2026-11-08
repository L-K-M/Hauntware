import 'dart:ui' show SemanticsAction, SemanticsActionEvent;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/window_panes.dart';
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';

import 'support/harness.dart';

/// 03 §10.2: the desktop shell's pane seams resize the rail and the
/// inspector, in memory and — through the save callbacks the composition
/// root wires to settings.json — across launches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double railWidth(WidgetTester tester) =>
      tester.getSize(find.byType(FleetRail)).width;

  double inspectorWidth(WidgetTester tester) =>
      tester.getSize(find.byType(InspectorPane)).width;

  double workspaceWidth(WidgetTester tester) {
    final rail = tester.getRect(find.byType(FleetRail));
    final inspector = tester.getRect(find.byType(InspectorPane));
    return inspector.left - rail.right - DesktopShell.seamWidth * 2;
  }

  Future<void> focusHandle(WidgetTester tester, Key key) async {
    final handle = find.byKey(key);
    Focus.of(
      tester.element(
        find.descendant(of: handle, matching: find.byType(GestureDetector)),
      ),
    ).requestFocus();
    await tester.pump();
  }

  group('the pane resize handles', () {
    testWidgets('straddle the rail\'s and the inspector\'s seams', (
      tester,
    ) async {
      await pumpApp(tester, servers: twoServers);

      final rail = tester.getRect(find.byType(FleetRail));
      final inspector = tester.getRect(find.byType(InspectorPane));
      for (final (key, seamCenter) in [
        (
          DesktopShell.sidebarResizeHandleKey,
          rail.right + DesktopShell.seamWidth / 2,
        ),
        (
          DesktopShell.inspectorResizeHandleKey,
          inspector.left - DesktopShell.seamWidth / 2,
        ),
      ]) {
        final rect = tester.getRect(find.byKey(key));
        expect(rect.width, DesktopShell.resizeHandleWidth);
        expect(rect.center.dx, seamCenter);
      }
    });

    testWidgets('dragging the rail seam resizes the rail', (tester) async {
      final panes = WindowPanesController();
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      expect(railWidth(tester), DesktopShell.railWidth);
      await tester.drag(
        find.byKey(DesktopShell.sidebarResizeHandleKey),
        const Offset(60, 0),
      );
      await tester.pump();

      expect(railWidth(tester), 320);
      expect(panes.sidebarWidth, 320);
    });

    testWidgets('dragging the inspector seam resizes the inspector', (
      tester,
    ) async {
      final panes = WindowPanesController();
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await tester.drag(
        find.byKey(DesktopShell.inspectorResizeHandleKey),
        const Offset(-60, 0),
      );
      await tester.pump();

      expect(inspectorWidth(tester), 360);
      expect(panes.inspectorWidth, 360);
    });

    testWidgets('a drag writes its width once, at the end, not per frame', (
      tester,
    ) async {
      final saved = <double>[];
      final panes = WindowPanesController(
        saveSidebarWidth: (width) async => saved.add(width),
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(DesktopShell.sidebarResizeHandleKey)),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      final midDrag = railWidth(tester);
      expect(midDrag, greaterThan(DesktopShell.railWidth));
      expect(saved, isEmpty, reason: 'nothing writes while the drag runs');

      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      final committed = railWidth(tester);
      expect(committed, greaterThan(midDrag));

      await gesture.up();
      await tester.pump();
      expect(saved, [committed]);
    });

    testWidgets('the arrow keys resize a focused handle by 16-pixel '
        'steps', (tester) async {
      final panes = WindowPanesController();
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await focusHandle(tester, DesktopShell.sidebarResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(railWidth(tester), 276);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(railWidth(tester), 260);

      await focusHandle(tester, DesktopShell.inspectorResizeHandleKey);
      // The inspector grows toward the leading edge.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(inspectorWidth(tester), 316);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(inspectorWidth(tester), 300);
      expect(tester.takeException(), isNull);
    });

    testWidgets('each keyboard step persists the width', (tester) async {
      final saved = <double>[];
      final panes = WindowPanesController(
        saveSidebarWidth: (width) async => saved.add(width),
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await focusHandle(tester, DesktopShell.sidebarResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(saved, [276.0]);
      expect(panes.sidebarWidth, 276);
    });

    testWidgets('the panes clamp at their bounds and keep the workspace '
        'usable', (tester) async {
      final panes = WindowPanesController();
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await tester.drag(
        find.byKey(DesktopShell.sidebarResizeHandleKey),
        const Offset(-1000, 0),
      );
      await tester.pump();
      expect(railWidth(tester), DesktopShell.minimumRailWidth);

      // The inspector's own bound is 680, but at this window size its
      // dynamic maximum stops where the workspace keeps its minimum:
      // 1280 less the rail's 260, the workspace's 480 and two seams.
      await tester.drag(
        find.byKey(DesktopShell.inspectorResizeHandleKey),
        const Offset(-1000, 0),
      );
      await tester.pump();
      expect(inspectorWidth(tester), closeTo(538, 0.01));
      expect(
        workspaceWidth(tester),
        closeTo(DesktopShell.minimumWorkspaceWidth, 0.01),
      );
    });

    testWidgets('stored widths too wide for the window keep a usable '
        'workspace and restore as it widens', (tester) async {
      final panes = WindowPanesController(
        sidebarWidth: DesktopShell.maximumRailWidth,
        inspectorWidth: DesktopShell.maximumInspectorWidth,
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      expect(
        workspaceWidth(tester),
        closeTo(DesktopShell.minimumWorkspaceWidth, 0.01),
      );
      expect(railWidth(tester), lessThan(DesktopShell.maximumRailWidth));
      expect(
        inspectorWidth(tester),
        lessThan(DesktopShell.maximumInspectorWidth),
      );

      // The requests themselves were never rewritten, so widening the
      // window renders them again.
      tester.view.physicalSize = const Size(1800, 800);
      await tester.pump();
      expect(railWidth(tester), DesktopShell.maximumRailWidth);
      expect(inspectorWidth(tester), DesktopShell.maximumInspectorWidth);
    });

    testWidgets('a hidden pane drops its handle', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      await harness.windowPanes.setShown(WindowPane.sidebar, false);
      await tester.pump();
      expect(find.byKey(DesktopShell.sidebarResizeHandleKey), findsNothing);
      expect(find.byKey(DesktopShell.inspectorResizeHandleKey), findsOneWidget);

      await harness.windowPanes.setShown(WindowPane.inspector, false);
      await tester.pump();
      expect(find.byKey(DesktopShell.inspectorResizeHandleKey), findsNothing);
    });

    testWidgets('a resized width seeds the next launch', (tester) async {
      double? savedSidebar, savedInspector;
      final panes = WindowPanesController(
        saveSidebarWidth: (width) async => savedSidebar = width,
        saveInspectorWidth: (width) async => savedInspector = width,
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await tester.drag(
        find.byKey(DesktopShell.sidebarResizeHandleKey),
        const Offset(40, 0),
      );
      await tester.drag(
        find.byKey(DesktopShell.inspectorResizeHandleKey),
        const Offset(-40, 0),
      );
      await tester.pump();
      expect(savedSidebar, 300);
      expect(savedInspector, 340);

      // A relaunch seeds the controller from settings.json, which is
      // what those callbacks wrote.
      await pumpApp(
        tester,
        servers: twoServers,
        windowPanes: WindowPanesController(
          sidebarWidth: savedSidebar,
          inspectorWidth: savedInspector,
        ),
      );

      expect(railWidth(tester), 300);
      expect(inspectorWidth(tester), 340);
    });

    testWidgets('a width that cannot be saved says so and stays applied', (
      tester,
    ) async {
      final panes = WindowPanesController(
        saveSidebarWidth: (_) async => throw Exception('disk full'),
      );
      await pumpApp(tester, servers: twoServers, windowPanes: panes);

      await tester.drag(
        find.byKey(DesktopShell.sidebarResizeHandleKey),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();

      expect(railWidth(tester), 300, reason: 'applied in memory');
      expect(
        find.textContaining('could not save your window layout'),
        findsOneWidget,
      );
    });

    testWidgets('screen readers get a labelled slider that resizes its '
        'pane', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpApp(tester, servers: twoServers);

        var node = tester.getSemantics(
          find.bySemanticsLabel(
            'Sidebar width. Use the left and right arrow keys to resize it.',
          ),
        );
        expect(node.getSemanticsData().flagsCollection.isSlider, isTrue);
        expect(node.getSemanticsData().value, '260 pixels');
        expect(node.getSemanticsData().increasedValue, '276 pixels');

        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.increase,
            nodeId: node.id,
            viewId: tester.view.viewId,
          ),
        );
        await tester.pump();
        expect(railWidth(tester), 276);

        node = tester.getSemantics(
          find.bySemanticsLabel(
            'Inspector width. Use the left and right arrow keys to resize '
            'it.',
          ),
        );
        expect(node.getSemanticsData().value, '300 pixels');
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.increase,
            nodeId: node.id,
            viewId: tester.view.viewId,
          ),
        );
        await tester.pump();
        expect(inspectorWidth(tester), 316);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('WindowPanesController widths', () {
    test('ignore widths that cannot be a pane\'s', () async {
      final saved = <double>[];
      final panes = WindowPanesController(
        sidebarWidth: double.nan,
        inspectorWidth: -4,
        saveSidebarWidth: (width) async => saved.add(width),
      );
      expect(panes.sidebarWidth, WindowPanesController.defaultSidebarWidth);
      expect(
        panes.inspectorWidth,
        WindowPanesController.defaultInspectorWidth,
      );

      for (final width in [double.nan, double.infinity, 0.0, -10.0]) {
        await panes.setWidth(WindowPane.sidebar, width);
      }
      expect(saved, isEmpty);
      expect(panes.sidebarWidth, WindowPanesController.defaultSidebarWidth);
    });

    test('default to the layout\'s 260 and 300 until resized', () {
      final panes = WindowPanesController();
      addTearDown(panes.dispose);

      expect(panes.sidebarWidth, 260);
      expect(panes.inspectorWidth, 300);
      expect(panes.widthOf(WindowPane.sidebar), 260);
      expect(panes.widthOf(WindowPane.inspector), 300);
    });

    test(
      'a width applies before it saves, and a failed save retries',
      () async {
        var calls = 0;
        var fail = true;
        final panes = WindowPanesController(
          saveInspectorWidth: (_) async {
            calls++;
            if (fail) throw Exception('disk full');
          },
        );
        addTearDown(panes.dispose);

        await expectLater(
          panes.setWidth(WindowPane.inspector, 340),
          throwsA(isA<WindowPanesNotSavedException>()),
        );
        expect(panes.inspectorWidth, 340, reason: 'applied in memory');

        // Repeating the choice retries the save; an already-saved one does
        // not write again.
        fail = false;
        await panes.setWidth(WindowPane.inspector, 340);
        expect(calls, 2);
        await panes.setWidth(WindowPane.inspector, 340);
        expect(calls, 2);
      },
    );
  });
}
