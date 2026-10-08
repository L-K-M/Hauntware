// Ported from Séance app/seance_app/test/server_color_picker_test.dart @ f4d2f71; see docs/PORTS.md.
// Divergence: the app is wrapped in AppLocalizations, which the picker's
// ARB strings need. Since 2026-10-08 the picker is ghost_marks' and the
// full suite lives there; this keeps the wrapper's cases.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/server_appearance.dart';
import 'package:poltergeist_app/ui/server_color_picker.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Choosing a colour of one's own for a server. The dialog holds the colour
/// two ways — exactly, and as the sliders — and the tests are mostly about the
/// two staying in step.
void main() {
  /// What the picker returned, as a list so "not closed yet" and "dismissed"
  /// stay distinguishable.
  final picked = <Color?>[];

  setUp(picked.clear);

  const initial = Color(0xFF2F6FED);

  Future<void> open(WidgetTester tester, {Color start = initial}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showServerColorPicker(
                  context,
                  initial: start,
                  mark: const ServerGlyphMark(ServerIcon.rocket),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The colour the preview line is drawn with right now.
  Color preview(WidgetTester tester) =>
      tester.widget<ServerAccentBar>(find.byType(ServerAccentBar)).tint.custom!;

  Future<void> use(WidgetTester tester) async {
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the colour handed in and returns it as it was', (
    tester,
  ) async {
    await open(tester);
    expect(preview(tester), initial);
    expect(find.text('2F6FED'), findsOneWidget);
    // The mark is previewed on the colour, not a bare swatch: the whole
    // question is what this badge will look like.
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
    // This app's words and monospace stack, through the wrapper.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.serverColorPickerTitle), findsOneWidget);
    expect(find.text(l10n.serverColorPickerHint), findsOneWidget);
    final hexStyle = tester.widget<TextField>(find.byType(TextField)).style;
    expect(hexStyle?.fontFamily, poltergeistMonoTextStyle.fontFamily);
    expect(
      hexStyle?.fontFamilyFallback,
      poltergeistMonoTextStyle.fontFamilyFallback,
    );
    await use(tester);
    // Exactly, not after a trip through the sliders' floating point.
    expect(picked.single, initial);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });
}
