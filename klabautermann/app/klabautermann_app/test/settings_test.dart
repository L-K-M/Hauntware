import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;
import 'package:klabautermann_app/app_identity.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/controllers/cadence_controller.dart';
import 'package:klabautermann_app/controllers/log_display.dart';
import 'package:klabautermann_app/controllers/time_display.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

import 'support/fake_engine.dart';
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
    List<FleetServer> servers = const [],
  }) async {
    final harness = await pumpApp(
      tester,
      size: size,
      announcements: announcements,
      appVersion: appVersion,
      servers: servers,
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

  Future<void> pumpGeneralTab(
    WidgetTester tester,
    CadenceController cadence,
  ) async {
    final announcements = AnnouncementController();
    addTearDown(announcements.dispose);
    addTearDown(cadence.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GeneralTab(
            announcements: announcements,
            cadence: cadence,
            appVersion: null,
          ),
        ),
      ),
    );
  }

  Future<void> pumpLogDisplay(
    WidgetTester tester,
    LogDisplayController logDisplay,
  ) async {
    final announcements = AnnouncementController();
    addTearDown(announcements.dispose);
    addTearDown(logDisplay.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GeneralTab(
            announcements: announcements,
            logDisplay: logDisplay,
            appVersion: null,
          ),
        ),
      ),
    );
  }

  testWidgets('the General tab picks the log text size and wrapping '
      '(A11Y-12)', (tester) async {
    final logDisplay = LogDisplayController();
    await pumpLogDisplay(tester, logDisplay);
    expect(find.text('13 px'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    expect(find.text('10 px'), findsWidgets);
    expect(find.text('18 px'), findsWidgets);
    await tester.tap(find.text('17 px').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrap long log lines'));
    await tester.pumpAndSettle();

    expect(logDisplay.value, LogDisplay(textSize: 17, wrap: LogWrap.on));
  });

  testWidgets('a log display that cannot be saved stays and says so', (
    tester,
  ) async {
    final logDisplay = LogDisplayController(
      save: (_, _) async => throw const FileSystemException('disk full'),
    );
    await pumpLogDisplay(tester, logDisplay);

    await tester.tap(find.text('Wrap long log lines'));
    await tester.pumpAndSettle();

    expect(logDisplay.value.wrap, LogWrap.on);
    expect(
      find.text(
        'The log display changed but could not be saved. It lasts until '
        'Klabautermann quits.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('the General tab switches server times to the server\'s zone, '
      'and one that cannot be saved stays and says so (A11Y-07)', (
    tester,
  ) async {
    final announcements = AnnouncementController();
    final timeDisplay = TimeDisplayController(
      save: (_) async => throw const FileSystemException('disk full'),
    );
    addTearDown(() {
      announcements.dispose();
      timeDisplay.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GeneralTab(
            announcements: announcements,
            timeDisplay: timeDisplay,
            appVersion: null,
          ),
        ),
      ),
    );

    await tester.tap(find.text("Show server times in the server's zone"));
    await tester.pumpAndSettle();

    expect(timeDisplay.value, TimeDisplay.server);
    expect(
      find.text(
        'The time display changed but could not be saved. It lasts until '
        'Klabautermann quits.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  Future<void> pickCadence(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButton<CadencePreset>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('the General tab picks the polling budget and explains its '
      'rates (SAF-19)', (tester) async {
    final cadence = CadenceController();
    await pumpGeneralTab(tester, cadence);
    expect(find.text('How often servers are read'), findsOneWidget);
    expect(
      find.text(
        'Desktop rates on a computer, phone rates on a phone or tablet.',
      ),
      findsOneWidget,
    );

    await pickCadence(tester, 'Cellular saver');

    expect(cadence.value, CadencePreset.cellularSaver);
    expect(find.textContaining('every 30 s'), findsOneWidget);
  });

  testWidgets('a polling budget that cannot be saved stays and says so', (
    tester,
  ) async {
    final cadence = CadenceController(
      save: (_) async => throw const FileSystemException('disk full'),
    );
    await pumpGeneralTab(tester, cadence);

    await pickCadence(tester, 'Phone');

    expect(cadence.value, CadencePreset.phone);
    expect(
      find.text(
        'The refresh rate changed but could not be saved. It lasts until '
        'Klabautermann quits.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('without a polling budget the General tab leaves it out', (
    tester,
  ) async {
    await openSettings(tester);

    expect(find.text('How often servers are read'), findsNothing);
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
      "Klabautermann's own code is public domain (Unlicense). It includes "
          'third-party components that keep their own licenses, listed under '
          'View licenses.',
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

  testWidgets('the Servers tab switches a server into the monitor set on a '
      'phone, which starts with none (FL-21)', (tester) async {
    final harness = await openSettings(
      tester,
      size: const Size(400, 800),
      servers: twoServers,
    );
    // The tab bar scrolls at phone width.
    await tester.ensureVisible(find.text('Servers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(find.text('0 of 10 servers monitored'), findsOneWidget);

    await tester.tap(find.text('db-1'));
    await tester.pumpAndSettle();

    expect(harness.fleet.monitoredServerIds, {'srv-2'});
    expect(find.text('1 of 10 servers monitored'), findsOneWidget);
  });

  testWidgets('the Servers tab limits a server\'s refresh, and says when '
      'the limit could not be saved (SAF-19)', (tester) async {
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: twoServers);
    final caps = CadenceCapsController(
      save: (_, _) async => throw const FileSystemException('disk full'),
    );
    addTearDown(() async {
      caps.dispose();
      fleet.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ServersTab(
            monitorSet: fleet.monitorSettings,
            cadenceCaps: caps,
          ),
        ),
      ),
    );
    expect(find.text('Refresh limits'), findsOneWidget);
    expect(find.text('No limit'), findsNWidgets(2));

    await tester.tap(find.text('No limit').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone').last);
    await tester.pumpAndSettle();

    expect(caps.value, {twoServers.last.id: CadenceCap.phone});
    expect(find.text('No limit'), findsOneWidget);
    expect(
      find.text(
        'The refresh limit changed but could not be saved. It lasts until '
        'Klabautermann quits.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('without caps the Servers tab leaves refresh limits out', (
    tester,
  ) async {
    await openSettings(tester, servers: twoServers);
    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();

    expect(find.text('Refresh limits'), findsNothing);
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
