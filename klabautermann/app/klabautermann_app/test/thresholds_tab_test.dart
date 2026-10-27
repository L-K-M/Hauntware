import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/threshold_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartThresholds;
import 'package:klabautermann_app/ui/threshold_scope.dart';
import 'package:klabautermann_app/ui/thresholds_tab.dart';

/// OV-11: the Alerts tab sets each metric's usage bands.
void main() {
  Future<ThresholdController> pumpTab(
    WidgetTester tester, {
    Future<void> Function(Map<String, List<double>>)? save,
  }) async {
    final thresholds = ThresholdController(save: save);
    addTearDown(thresholds.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ThresholdsTab(thresholds: thresholds)),
      ),
    );
    return thresholds;
  }

  Future<void> type(WidgetTester tester, String label, String value) =>
      tester.enterText(find.widgetWithText(TextField, label), value);

  testWidgets('lists each metric\'s levels and saves new ones from the '
      'dialog', (tester) async {
    final thresholds = await pumpTab(tester);
    const levels = 'Careful from 70%, warning from 80%, critical from 90%';
    expect(find.text(levels), findsNWidgets(3));

    await tester.tap(find.text('Disk'));
    await tester.pumpAndSettle();
    await type(tester, 'Careful from', '60');
    await type(tester, 'Warning from', '75');
    await type(tester, 'Critical from', '95');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      thresholds.value[ThresholdMetric.disk],
      const ChartThresholds(careful: 60, warning: 75, critical: 95),
    );
    expect(
      find.text('Careful from 60%, warning from 75%, critical from 95%'),
      findsOneWidget,
    );
    expect(find.text(levels), findsNWidgets(2));
  });

  testWidgets('levels out of order are refused in place, and Default fills '
      'in the defaults', (tester) async {
    final thresholds = await pumpTab(tester);
    await tester.tap(find.text('CPU'));
    await tester.pumpAndSettle();

    await type(tester, 'Warning from', '95');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Each level must be a whole percent from 1 to 100, and each one '
        'higher than the one before.',
      ),
      findsOneWidget,
    );
    expect(thresholds.value[ThresholdMetric.cpu], kDefaultThresholds);

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Warning from'), findsOneWidget);
    expect(find.text('80'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('levels that cannot be saved stay and say so', (tester) async {
    final thresholds = await pumpTab(
      tester,
      save: (_) async => throw const FileSystemException('disk full'),
    );
    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    await type(tester, 'Careful from', '50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(thresholds.value[ThresholdMetric.memory]?.careful, 50);
    expect(
      find.text(
        'The levels changed but could not be saved. They last until '
        'Klabautermann quits.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });
}
