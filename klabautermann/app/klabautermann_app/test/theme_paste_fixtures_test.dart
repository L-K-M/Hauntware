// X-01 (M5 plan M32): a theme copied in Séance or Poltergeist pastes into
// Klabautermann's Appearance tab. Each fixture is the exact text the
// sibling's Copy theme put on the clipboard (`JsonEncoder.withIndent`
// over its palette's `toJson`), generated from that app's own presets
// and edits; test/fixtures/theme_paste/README.md says how.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/appearance_tab.dart';

const _fixtures = 'test/fixtures/theme_paste';

/// Each fixture by name, as the sibling copied it.
const _copied = [
  'seance-terminal',
  'seance-custom',
  'poltergeist-vapor',
  'poltergeist-custom',
];

String _read(String name) => File('$_fixtures/$name.json').readAsStringSync();

/// What Klabautermann keeps of [copied]: every key but Séance's terminal
/// block, which its palettes do not carry (`hasTerminal` is false).
Map<String, Object?> _kept(String copied) =>
    (jsonDecode(copied) as Map<String, Object?>)..remove('terminal');

void main() {
  const codec = GhostThemeCodec(klabautermannThemeStyle);

  for (final name in _copied) {
    test('$name keeps its name, colours, font and corners', () {
      final copied = _read(name);
      final pasted = codec.tryParse(copied);

      expect(pasted, isNotNull);
      expect(pasted!.toJson(), _kept(copied));
      // And it round trips as Klabautermann copies it in turn.
      final again = codec.tryParse(
        const JsonEncoder.withIndent('  ').convert(pasted.toJson()),
      );
      expect(again, pasted);
    });
  }

  testWidgets('Paste theme adopts a theme copied in Séance', (tester) async {
    final copied = _read('seance-custom');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': copied}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);
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

    await tester.tap(find.text('Paste theme'));
    await tester.pumpAndSettle();

    expect(appearance.value.palette.toJson(), _kept(copied));
  });
}
