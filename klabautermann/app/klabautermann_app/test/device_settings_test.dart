import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/stored_appearance.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/settings_issue_notice.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

const _appearanceKey = 'klabautermann.appearance';

/// A writer that finishes inside the widget test's fake clock. The store
/// is opened outside it (`tester.runAsync`), so [_finishSaves] lets its
/// write queue move once; the atomic writer itself is covered by
/// `klabautermann_core`'s store tests.
Future<void> _writeNow(File target, List<int> bytes) async =>
    target.writeAsBytesSync(bytes, flush: true);

Future<void> _finishSaves(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

/// The settings route's Appearance tab, as a user reaches it.
Future<void> _openAppearance(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Appearance'));
  await tester.pumpAndSettle();
}

ThemeModePreference _selectedMode(WidgetTester tester) => tester
    .widget<SegmentedButton<ThemeModePreference>>(
      find.byType(SegmentedButton<ThemeModePreference>),
    )
    .selected
    .single;

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('klab-app-settings-');
    file = File('${directory.path}/$deviceSettingsFileName');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, Object?> document() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  group('the stored appearance', () {
    test('round-trips every preset in every mode', () {
      for (final palette in klabautermannThemePresets.all) {
        for (final mode in ThemeModePreference.values) {
          final appearance = AppAppearance(palette: palette, mode: mode);
          final json = jsonDecode(
            jsonEncode(encodeStoredAppearance(appearance)),
          );

          expect(
            decodeStoredAppearance(json as Map<String, Object?>),
            appearance,
            reason: '${palette.name} ${mode.name}',
          );
        }
      }
    });

    test('nothing stored is the brand preset following the system', () {
      final fresh = AppearanceController();
      addTearDown(fresh.dispose);

      expect(decodeStoredAppearance(null), fresh.value);
    });

    test('a damaged value costs only itself', () {
      final appearance = decodeStoredAppearance({
        'palette': 'not a palette',
        'mode': 'sepia',
      });

      expect(appearance.palette, klabautermannThemePresets.initial);
      expect(appearance.mode, ThemeModePreference.system);
    });
  });

  testWidgets('the stored appearance is restored at startup', (tester) async {
    final stored = AppAppearance(
      palette: klabautermannThemePresets.midnight,
      mode: ThemeModePreference.dark,
    );
    final settings = (await tester.runAsync(() async {
      final previousLaunch = await DeviceSettingsStore.open(file);
      await previousLaunch.setAppearance(encodeStoredAppearance(stored));
      return DeviceSettingsStore.open(file);
    }))!;

    final harness = await pumpApp(
      tester,
      appearance: appearanceFromSettings(settings),
    );

    expect(harness.appearance.value, stored);
    // The first frame is drawn in the stored palette, not the brand preset.
    final drawn = GhostTheme.forAppearance(klabautermannThemeStyle, stored);
    final fresh = GhostTheme.forAppearance(
      klabautermannThemeStyle,
      AppAppearance(palette: klabautermannThemePresets.initial),
    );
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, drawn.themeMode);
    expect(app.theme?.colorScheme, drawn.theme.colorScheme);
    expect(app.theme?.colorScheme, isNot(fresh.theme.colorScheme));
    await _openAppearance(tester);
    expect(_selectedMode(tester), ThemeModePreference.dark);
  });

  testWidgets('a theme picked in Settings is saved through the app\'s store '
      'and survives a restart', (tester) async {
    final settings = (await tester.runAsync(
      () => DeviceSettingsStore.open(file, writer: _writeNow),
    ))!;
    final deviceId = settings.deviceId;
    await pumpApp(tester, appearance: appearanceFromSettings(settings));

    await _openAppearance(tester);
    await tester.tap(find.text('Dark'));
    await _finishSaves(tester);

    final saved = document();
    expect((saved[_appearanceKey]! as Map)['mode'], 'dark');
    expect(saved['klabautermann.sync.deviceId'], deviceId);

    final nextLaunch = (await tester.runAsync(
      () => DeviceSettingsStore.open(file),
    ))!;
    expect(nextLaunch.issue, isNull);
    expect(nextLaunch.deviceId, deviceId);
    expect(
      decodeStoredAppearance(nextLaunch.appearance).mode,
      ThemeModePreference.dark,
    );
  });

  testWidgets('a theme change the store cannot save stays, and says '
      'so', (tester) async {
    file.writeAsStringSync(
      jsonEncode({
        'klabautermann.settings.version': deviceSettingsSchemaVersion + 1,
        'klabautermann.sync.deviceId': 'device-b',
      }),
    );
    final bytes = file.readAsBytesSync();
    final settings = (await tester.runAsync(
      () => DeviceSettingsStore.open(file),
    ))!;
    expect(settings.issue?.kind, DeviceSettingsIssueKind.newerVersion);

    final harness = await pumpApp(
      tester,
      appearance: appearanceFromSettings(settings),
      settingsIssue: settings.issue,
    );
    expect(
      find.textContaining('saved by a newer version of Klabautermann'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    await _openAppearance(tester);
    await tester.tap(find.text('Dark'));
    await _finishSaves(tester);

    expect(harness.appearance.mode, ThemeModePreference.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(find.textContaining('could not be saved'), findsOneWidget);
    expect(file.readAsBytesSync(), bytes);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a damaged settings file is reported once, naming the kept '
      'copy', (tester) async {
    file.writeAsStringSync('{"klabautermann.settings.version":');
    final settings = (await tester.runAsync(
      () => DeviceSettingsStore.open(file, writer: _writeNow),
    ))!;
    final kept = File(settings.issue!.preservedAs!).uri.pathSegments.last;
    expect(kept, startsWith('$deviceSettingsFileName.corrupt-'));

    final harness = await pumpApp(
      tester,
      appearance: appearanceFromSettings(settings),
      settingsIssue: settings.issue,
    );
    expect(find.textContaining(kept), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.textContaining(kept), findsNothing);

    // Re-theming rebuilds the MaterialApp; the notice does not come back.
    unawaited(harness.appearance.setMode(ThemeModePreference.dark));
    await _finishSaves(tester);
    expect(harness.appearance.mode, ThemeModePreference.dark);
    expect(find.textContaining(kept), findsNothing);
  });

  test('every settings issue has its own sentence', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    String message(DeviceSettingsIssueKind kind) => settingsIssueMessage(
      l10n,
      DeviceSettingsIssue(
        kind,
        preservedAs: '/support/settings.json.corrupt-20261013T230529Z',
      ),
    );

    expect(
      message(DeviceSettingsIssueKind.recovered),
      contains('settings.json.corrupt-20261013T230529Z'),
    );
    // Unreadable and impossible to set aside mean the same to the user:
    // the file is left as it is and nothing is saved.
    expect(
      message(DeviceSettingsIssueKind.unpreserved),
      message(DeviceSettingsIssueKind.unreadable),
    );
    expect(
      {for (final kind in DeviceSettingsIssueKind.values) message(kind)}.length,
      DeviceSettingsIssueKind.values.length - 1,
    );
  });
}
