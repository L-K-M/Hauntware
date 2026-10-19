import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';

const _sceneKey = ValueKey('admin-chip-scene');

/// Goldens for the admin mode chip (SAF-02), light and dark, with the
/// bundled font, following 03 §11.1's golden layer: off, turning on, on
/// (tinted) and disabled by read-only. Baselines come from the Linux
/// runner.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('the admin chip\'s states in the ${brightness.name} theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = FakeEngineClient();
      final admin = AdminController(engine);
      final safety = SafetyController(
        initial: const SafetyPolicy(
          servers: {
            'off': ServerSafety(management: true),
            'starting': ServerSafety(management: true),
            'on': ServerSafety(management: true),
            'readOnly': ServerSafety(management: true, readOnly: true),
          },
        ),
        apply: (_) {},
      );
      addTearDown(() async {
        admin.dispose();
        safety.dispose();
        await engine.close();
      });
      engine
        ..emit(const AdminModeState('starting', AdminModePhase.validating))
        // A local time, so the label reads the same in every zone.
        ..emit(
          AdminModeState(
            'on',
            AdminModePhase.on,
            expiresAt: DateTime(2026, 10, 18, 12, 45),
          ),
        );
      await tester.runAsync(pumpEventQueue);
      final theme = chartTheme(brightness, fontFamily: goldenFontFamily);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SafetyScope(
            safety: safety,
            child: AdminScope(
              admin: admin,
              child: RepaintBoundary(
                key: _sceneKey,
                child: Material(
                  color: theme.colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        for (final id in ['off', 'starting', 'on', 'readOnly'])
                          AdminModeChip(serverId: id),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/admin_chip_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
