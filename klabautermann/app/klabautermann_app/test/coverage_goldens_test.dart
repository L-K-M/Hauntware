import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/coverage.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _sceneKey = ValueKey('coverage-scene');

/// 03 §11.1's golden row for the coverage surfaces, light and dark, with
/// the bundled font: the first-run card over the fleet header's chip, and
/// the coverage sheet's body. Baselines come from the Linux runner.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('the coverage card, chip and sheet in the ${brightness.name} '
        'theme', (tester) async {
      tester.view.physicalSize = const Size(920, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      final coverage = CoverageController();
      addTearDown(() async {
        fleet.dispose();
        coverage.dispose();
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    SizedBox(
                      width: 380,
                      child: Column(
                        children: [
                          // It scrolls its words within a bounded height.
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 300),
                            child: FirstRunCoverageCard(
                              coverage: coverage,
                              fleet: fleet,
                            ),
                          ),
                          FleetCoverageChip(fleet: fleet),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Material(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(28),
                        child: CoverageSheet(fleet: fleet),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/coverage_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
