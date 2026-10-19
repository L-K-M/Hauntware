// The Appearance tab's theme editor (M4 E25, X-01): ghost_theme's shared
// section bound to Klabautermann's style and words. A preset, a colour or
// the corners change the app's theme at once and are saved; a change the
// app does not take puts the editor back on the app's appearance.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/stored_appearance.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/appearance_tab.dart';

import 'support/harness.dart';

/// An app that takes no change.
final class _Refusing extends ChangeNotifier implements AppearanceSettings {
  @override
  AppAppearance get value =>
      AppAppearance(palette: klabautermannThemePresets.initial);

  @override
  Future<void> setMode(ThemeModePreference mode) async =>
      throw StateError('read-only');

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async => throw StateError('read-only');
}

Future<void> _pumpTab(
  WidgetTester tester,
  AppearanceSettings appearance,
) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: GhostTheme.light(klabautermannThemeStyle),
      home: Scaffold(body: AppearanceTab(appearance: appearance)),
    ),
  );
  await tester.pumpAndSettle();
}

String _other(ThemePalette current) => klabautermannThemePresets.all
    .firstWhere((p) => p.name != current.name && p.surface != null)
    .name;

void main() {
  testWidgets('a preset picked in Settings re-themes the app and is saved', (
    tester,
  ) async {
    final saved = <AppAppearance>[];
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 4000),
      appearance: AppearanceController(save: (a) async => saved.add(a)),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    final target = _other(harness.appearance.value.palette);
    await tester.tap(find.text(target));
    await tester.pumpAndSettle();

    expect(harness.appearance.value.palette.name, target);
    expect(saved.last.palette.name, target);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.theme?.colorScheme.surface,
      klabautermannThemePresets.all.firstWhere((p) => p.name == target).surface,
    );
  });

  testWidgets("the editor speaks Klabautermann's words, with no terminal "
      'section', (tester) async {
    await _pumpTab(tester, AppearanceController());
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Status colours'), findsOneWidget);
    expect(find.text('Terminal colours'), findsNothing);
    await tester.tap(find.byTooltip('About Theme'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('paste it into Klabautermann on the other device'),
      findsOneWidget,
    );
  });

  testWidgets('a change the app does not take puts the editor back on the '
      "app's appearance and says so", (tester) async {
    await _pumpTab(tester, _Refusing());
    final target = _other(klabautermannThemePresets.initial);
    await tester.tap(find.text(target));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('The theme could not be changed.'), findsOneWidget);
    expect(
      find.text('Using ${klabautermannThemePresets.initial.name}.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a change the app takes but cannot save stays and says so', (
    tester,
  ) async {
    final appearance = AppearanceController(
      save: (_) async => throw const FileSystemException('disk full'),
    );
    await _pumpTab(tester, appearance);
    final target = _other(appearance.value.palette);
    await tester.tap(find.text(target));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The theme changed, but it could not be saved, so it will not be '
        'kept after a restart.',
      ),
      findsOneWidget,
    );
    expect(appearance.value.palette.name, target);
    expect(find.text('Using $target.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  test('an edited palette round-trips through settings.json', () {
    final edited = AppAppearance(
      palette: klabautermannThemePresets.initial
          .copyWith(cornerScale: 0.4)
          .withSlot(ThemeSlot.surface, const Color(0xFF102030)),
      mode: ThemeModePreference.dark,
    );
    expect(decodeStoredAppearance(encodeStoredAppearance(edited)), edited);
  });
}
