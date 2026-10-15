import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/failed_units_summary.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show SystemdUnit;

SystemdUnit _failed(String name) =>
    SystemdUnit(unit: name, load: 'loaded', active: 'failed', sub: 'failed');

/// SVC-02's failed units summary on its own, at the text scales 03 §11.1
/// lays panels out at.
void main() {
  for (final textScale in [1.0, 1.5, 2.0, 3.0]) {
    testWidgets('starts every row at one x at ${textScale}x text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GhostTheme.light(klabautermannThemeStyle),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: Scaffold(
              body: FailedUnitsSummary(
                // A name with no unit type opens nothing, so it lists as
                // plain text beside the unit button (CN-10).
                failed: [
                  _failed('nginx.service'),
                  _failed('foo.bar'),
                  _failed('backup.service'),
                ],
                onUnitSelected: (_) {},
                maxShown: 2,
              ),
            ),
          ),
        ),
      );

      final button = find.byType(TextButton);
      final buttonLabel = find.descendant(
        of: button,
        matching: find.text('nginx.service: failed'),
      );
      final buttonX = tester.getTopLeft(buttonLabel).dx;
      expect(tester.getTopLeft(find.text('foo.bar: unknown')).dx, buttonX);
      expect(tester.getTopLeft(find.text('and 1 more')).dx, buttonX);
    });
  }
}
