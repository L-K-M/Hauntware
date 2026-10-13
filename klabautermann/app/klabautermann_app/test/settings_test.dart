import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

import 'support/harness.dart';

/// 03 §10.2: the settings route carries the seven planned tabs as
/// placeholders; the Appearance tab's theme switch is the part that
/// already works (03 §10.9).
void main() {
  Future<AppHarness> openSettings(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
  }) async {
    final harness = await pumpApp(tester, size: size);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('shows the seven planned tabs', (tester) async {
    await openSettings(tester);

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    for (final tab in [
      'General',
      'Appearance',
      'Sync',
      'Servers',
      'Docker',
      'Safety',
      'Alerts',
    ]) {
      expect(find.text(tab), findsOneWidget);
    }
  });

  testWidgets('the Appearance tab switches the theme mode', (tester) async {
    final harness = await openSettings(tester);
    expect(harness.appearance.themeMode, ThemeMode.system);

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(harness.appearance.themeMode, ThemeMode.dark);
    // The theme pick rebuilds MaterialApp on the dark theme (03 §10.9).
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.darkTheme?.brightness, Brightness.dark);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(harness.appearance.themeMode, ThemeMode.light);
  });

  testWidgets('back returns to the shell', (tester) async {
    await openSettings(tester);

    final back = find.byTooltip('Back');
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    } else {
      // No drawn back affordance (e.g. a desktop shell): pop the route.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }

    expect(find.byType(SettingsPage), findsNothing);
  });
}
