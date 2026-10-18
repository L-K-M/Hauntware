import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;
import 'package:klabautermann_app/app_identity.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

import 'support/harness.dart';

/// 03 §10.2: the settings route carries the seven planned tabs as
/// placeholders; the Appearance tab's theme switch is the part that
/// already works (03 §10.9).
void main() {
  Future<AppHarness> openSettings(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    AnnouncementController? announcements,
    String? appVersion,
  }) async {
    final harness = await pumpApp(
      tester,
      size: size,
      announcements: announcements,
      appVersion: appVersion,
    );
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
    expect(harness.appearance.mode, ThemeModePreference.system);

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(harness.appearance.mode, ThemeModePreference.dark);
    // The theme pick rebuilds MaterialApp on the dark theme (03 §10.9).
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.darkTheme?.brightness, Brightness.dark);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(harness.appearance.mode, ThemeModePreference.light);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('the General tab switches threshold announcements (A11Y-15, '
      'D60)', (tester) async {
    final harness = await openSettings(tester);
    expect(harness.announcements.value, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.text('Announce threshold changes'));
    await tester.pumpAndSettle();

    expect(harness.announcements.value, isFalse);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('an announcement change that cannot be saved stays and says '
      'so', (tester) async {
    await openSettings(
      tester,
      announcements: AnnouncementController(
        save: (_) async => throw const FileSystemException('disk full'),
      ),
    );

    await tester.tap(find.text('Announce threshold changes'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The setting changed, but it could not be saved, so it will not be '
        'kept after a restart.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    // The toast leaves on its own.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('an announcement change that does not apply leaves the '
      'switch and says so', (tester) async {
    final announcements = _RefusingAnnouncements();
    addTearDown(announcements.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GeneralTab(announcements: announcements, appVersion: null),
        ),
      ),
    );

    await tester.tap(find.text('Announce threshold changes'));
    await tester.pumpAndSettle();

    expect(find.text('The setting could not be changed.'), findsOneWidget);
    expect(find.textContaining('could not be saved'), findsNothing);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('the General tab\'s about row shows the title with its '
      'preview label and the version, and opens About (M16)', (tester) async {
    // A phone: no About command, so this row is the way to the dialog.
    await openSettings(tester, size: const Size(400, 800), appVersion: '1.2.3');

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Klabautermann $kPreviewLabel'), findsOneWidget);
    await tester.tap(find.text('Version 1.2.3'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AboutDialog);
    expect(dialog, findsOneWidget);
    for (final text in [
      'Klabautermann $kPreviewLabel',
      'Version 1.2.3',
      'Klabautermann is free and unencumbered software released into the '
          'public domain under the Unlicense.',
    ]) {
      expect(
        find.descendant(of: dialog, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  testWidgets('the about row says so when the version is unknown', (
    tester,
  ) async {
    await openSettings(tester);

    expect(find.text('Version unknown'), findsOneWidget);
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

/// A11Y-15's switch as a lost settings link answers it: no change
/// applies.
final class _RefusingAnnouncements extends ValueNotifier<bool>
    implements AnnouncementSettings {
  _RefusingAnnouncements() : super(true);

  @override
  Future<void> setAnnounceThresholdBands(bool announce) async =>
      throw Exception('The settings link is gone.');
}
