// Poltergeist's Appearance editor is ghost_theme's shared section over a
// fake model; see docs/PORTS.md. These tests cover what is Poltergeist's
// own: the model adapter, the ARB words and preset names, the font field,
// a Séance theme pasted with its terminal block, a failed write, and the
// phone-sized Settings dialog. The shared section's controls and writes
// are tested in ghost_theme.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/settings/appearance_settings.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';

/// The Appearance section's model, recording every write. It starts from
/// Poltergeist, the all-Automatic preset, rather than the Vapor a new
/// device starts in: most of these tests are about Automatic colours and
/// the mode they follow.
final class _FakeAppearance extends ChangeNotifier
    implements AppearanceSettingsModel {
  _FakeAppearance([AppAppearance? initial])
    : value = initial ?? AppAppearance(palette: ThemePresets.poltergeist);

  @override
  AppAppearance value;

  /// Every theme written, in order.
  final List<AppAppearance> writes = [];

  /// Thrown by every write while set.
  Object? failWith;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    writes.add(AppAppearance(palette: palette, mode: mode));
    final failure = failWith;
    if (failure != null) throw failure;
    value = AppAppearance(palette: palette, mode: mode);
    notifyListeners();
  }
}

void main() {
  late _FakeAppearance model;
  setUp(() => model = _FakeAppearance());

  ThemePalette lastPalette() => model.writes.last.palette;

  /// Tall enough that the whole section is built at once.
  Future<void> pumpSection(WidgetTester tester, {AppAppearance? start}) async {
    if (start != null) model = _FakeAppearance(start);
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AppearanceSection(model: model),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// What the clipboard holds, as the platform channel answers for it.
  String? clipboard;
  setUp(() => clipboard = null);

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return clipboard == null ? null : {'text': clipboard};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('every preset is named from the ARB', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final strings = PoltergeistAppearanceStrings(l10n);
    // English shows the stored names, which is what makes them safe to
    // store: a translation changes what is shown, never what is written.
    for (final preset in ThemePresets.all) {
      expect(strings.presetLabel(preset.name), preset.name);
    }
    await pumpSection(tester);
    for (final preset in ThemePresets.all) {
      expect(find.byTooltip('Use the ${preset.name} theme'), findsOneWidget);
    }
  });

  testWidgets('picking a preset writes that preset', (tester) async {
    await pumpSection(tester);
    expect(find.text('Using Poltergeist.'), findsOneWidget);

    await tester.tap(find.byTooltip('Use the Midnight theme'));
    await tester.pumpAndSettle();

    expect(model.writes, [AppAppearance(palette: ThemePresets.midnight)]);
    expect(find.text('Using Midnight.'), findsOneWidget);
    // A surface of its own decides the brightness, so the mode is moot.
    final mode = tester.widget<SegmentedButton<ThemeModePreference>>(
      find.byType(SegmentedButton<ThemeModePreference>),
    );
    expect(mode.onSelectionChanged, isNull);
    expect(find.textContaining('always dark'), findsOneWidget);
  });

  testWidgets('the interface font writes on submit, blank for the default', (
    tester,
  ) async {
    await pumpSection(tester);
    final font = find.byKey(const ValueKey('appearance.fontFamily'));

    await tester.enterText(font, '  Inter ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPalette().fontFamily, 'Inter');

    await tester.enterText(font, ' ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPalette().fontFamily, isNull);
    expect(lastPalette(), ThemePresets.poltergeist);
  });

  testWidgets('a low-contrast accent names its adjustment from the ARB', (
    tester,
  ) async {
    await pumpSection(
      tester,
      start: AppAppearance(
        palette: ThemePresets.poltergeist.copyWith(
          accent: const Color(0xFFFFD600),
        ),
      ),
    );

    expect(
      find.text('Low contrast: links and indicators use an adjusted colour.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Chosen accent'), findsOneWidget);
    expect(find.bySemanticsLabel('Adjusted interface colour'), findsOneWidget);
    expect(find.text('Use adjusted colour'), findsOneWidget);
  });

  testWidgets('a theme copied in Séance pastes, all but its terminal', (
    tester,
  ) async {
    mockClipboard(tester);
    // Séance's Copy theme for a Custom theme of its own: every key this
    // app knows, plus the terminal block it has no use for.
    clipboard = const JsonEncoder.withIndent('  ').convert({
      'name': 'Custom',
      'accent': '#FF8A4C',
      'surface': '#101418',
      'text': '#EEF2F6',
      'hairline': '#FFFFFF40',
      'offline': '#FF5252',
      'terminal': {
        'background': '#000000',
        'foreground': '#FFFFFF',
        'cursor': '#FF8A4C',
        'selection': '#FF8A4C40',
        'ansi': List.filled(16, '#808080'),
      },
      'fontFamily': 'Inter',
      'cornerScale': 0.6,
    });
    await pumpSection(tester);

    await tester.tap(find.text('Paste theme'));
    await tester.pumpAndSettle();

    final pasted = lastPalette();
    expect(pasted.accent, const Color(0xFFFF8A4C));
    expect(pasted.surface, const Color(0xFF101418));
    expect(pasted.text, const Color(0xFFEEF2F6));
    expect(pasted.hairline, const Color(0x40FFFFFF));
    expect(pasted.offline, const Color(0xFFFF5252));
    expect(pasted.sidebar, isNull);
    expect(pasted.fontFamily, 'Inter');
    expect(pasted.cornerScale, 0.6);
    expect(pasted.toJson().containsKey('terminal'), isFalse);
    // The section shows what it pasted.
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('appearance.fontFamily')),
          )
          .controller!
          .text,
      'Inter',
    );
  });

  testWidgets('a failed write says so', (tester) async {
    model.failWith = StateError('disk full');
    await pumpSection(tester);

    await tester.tap(find.byTooltip('Use the Graphite theme'));
    await tester.pumpAndSettle();

    expect(
      find.text('Appearance not saved: Bad state: disk full'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('fits a phone\'s Settings dialog, after General', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.android,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGeneralSettingsDialog(
              context,
              settings: GeneralSettings(
                checkForUpdates: true,
                onCheckForUpdatesChanged: (_) async {},
              ),
              appearance: model,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // General first, then the theme.
    final general = tester.getRect(
      find.byKey(const ValueKey('updates.checkEnabled')),
    );
    final first = find.byTooltip('Use the Poltergeist theme');
    expect(tester.getRect(first).top, greaterThan(general.bottom));
    // Scroll to the end: every part laid out without overflowing.
    await tester.scrollUntilVisible(
      find.text('Reset to Vapor'),
      200,
      // The dialog's own scroll view: its fields hold scrollables too.
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Reset to Vapor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
