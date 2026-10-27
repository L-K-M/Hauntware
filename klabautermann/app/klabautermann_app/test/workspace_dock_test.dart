// OV-10: the desktop workspace's bottom dock, which keeps a server's
// logs, run output and shells in sight under whichever panel shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/run_output_sheet.dart';
import 'package:klabautermann_app/ui/workspace_dock.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

void main() {
  group('WorkspaceDock', () {
    test('opens an item once, brings it forward, and expands', () {
      final dock = WorkspaceDock();
      addTearDown(dock.dispose);
      const logs = DockedLogs('srv-1');
      const output = DockedRunOutput('srv-1', 'backup.service');

      dock
        ..show(logs)
        ..show(output)
        ..show(logs);
      expect(dock.itemsFor('srv-1'), [logs, output]);
      expect(dock.selectedFor('srv-1'), logs);
      expect(dock.expanded, isTrue);

      dock.setExpanded(false);
      dock.select(output);
      expect(dock.selectedFor('srv-1'), output);
      expect(dock.expanded, isTrue, reason: 'picking a tab shows it');
    });

    test('each server keeps its own items and selection', () {
      final dock = WorkspaceDock();
      addTearDown(dock.dispose);
      dock
        ..show(const DockedLogs('srv-1'))
        ..show(const DockedLogs('srv-2'));
      expect(dock.selectedFor('srv-1'), const DockedLogs('srv-1'));
      expect(dock.itemsFor('srv-2'), [const DockedLogs('srv-2')]);

      dock.forgetServer('srv-2');
      expect(dock.items, [const DockedLogs('srv-1')]);
      expect(dock.selectedFor('srv-2'), isNull);
    });

    test('closing the shown item shows the one opened before it, or after '
        'when it was the first', () {
      final dock = WorkspaceDock();
      addTearDown(dock.dispose);
      const a = DockedLogs('srv-1');
      const b = DockedRunOutput('srv-1', 'a.service');
      const c = DockedRunOutput('srv-1', 'b.service');
      dock
        ..show(a)
        ..show(b)
        ..show(c)
        ..select(b)
        ..close(b);
      expect(dock.selectedFor('srv-1'), a);

      dock.close(a);
      expect(dock.selectedFor('srv-1'), c);
      dock.close(c);
      expect(dock.selectedFor('srv-1'), isNull);
      expect(dock.items, isEmpty);
    });
  });

  testWidgets('run output goes to the dock where there is one, not a sheet', (
    tester,
  ) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    final dock = WorkspaceDock();
    addTearDown(() async {
      dock.dispose();
      monitoring.dispose();
      await engine.close();
    });
    late BuildContext inner;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceDockScope(
          dock: dock,
          child: Builder(
            builder: (context) {
              inner = context;
              return const Scaffold();
            },
          ),
        ),
      ),
    );

    await showRunOutput(
      inner,
      monitoring: monitoring,
      serverId: 'srv-1',
      unit: 'backup.service',
    );
    await tester.pumpAndSettle();

    expect(dock.items, [const DockedRunOutput('srv-1', 'backup.service')]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the desktop workspace docks the server\'s logs, keeps them '
      'across a change of server, and closes them', (tester) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    Finder tab(String label) => find.widgetWithText(InputChip, label);
    expect(tab('Logs'), findsNothing);

    await tester.tap(find.byTooltip('Show the dock'));
    await tester.pumpAndSettle();
    expect(tab('Logs'), findsOneWidget);
    expect(find.byTooltip('Hide the dock'), findsWidgets);

    harness.fleet.select('srv-2');
    await tester.pumpAndSettle();
    expect(tab('Logs'), findsNothing, reason: "db-1's dock holds nothing");

    harness.fleet.select('srv-1');
    await tester.pumpAndSettle();
    expect(tab('Logs'), findsOneWidget);

    await tester.tap(find.byTooltip('Close Logs'));
    await tester.pumpAndSettle();
    expect(tab('Logs'), findsNothing);
  });

  testWidgets('the dock\'s edge resizes from assistive technology, and a '
      'short window gives the dock its share without overflowing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, size: const Size(1280, 800), servers: twoServers);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show the dock'));
    await tester.pumpAndSettle();

    final edge = find.semantics.byLabel(RegExp('^Dock height'));
    double height() => tester
        .getSize(
          find
              .descendant(
                of: find.byType(WorkspaceDockPane),
                matching: find.byType(IndexedStack),
              )
              .first,
        )
        .height;
    final before = height();
    tester.semantics.increase(edge);
    await tester.pumpAndSettle();
    expect(height(), greaterThan(before));

    tester.view.physicalSize = const Size(1280, 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
