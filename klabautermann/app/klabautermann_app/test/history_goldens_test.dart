import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/history_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/history_card.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';
import 'support/history.dart';

const _sceneKey = ValueKey('history-scene');

/// Goldens for the History card, light and dark, with the bundled font
/// (03 §11.1, Y4): 48 hours with a band for each gap reason, the trailing
/// one open to the chart's edge. Baselines come from the Linux runner.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('the History card in the ${brightness.name} theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = FakeEngineClient();
      final reads = HistoryReads(engine);
      addTearDown(() async {
        reads.dispose();
        await engine.close();
      });
      final theme = chartTheme(brightness, fontFamily: goldenFontFamily);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: _sceneKey,
            child: Material(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HistoryCard(
                  reads: reads,
                  serverId: 'srv-1',
                  now: () => historyNow,
                ),
              ),
            ),
          ),
        ),
      );
      final request = engine.sentOfType<ReadHistory>().single as ReadHistory;
      engine.emit(
        HistoryRead(
          requestId: request.requestId,
          serverId: request.serverId,
          tier: request.tier,
          range: historySample(),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/history_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
