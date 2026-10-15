import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// The editor's ligature choice end to end, in its bundled JetBrains Mono.
void main() {
  final boundary = GlobalKey();

  /// [text] as the editor draws it with [ligatures], as raw RGBA.
  Future<Uint8List> render(
    WidgetTester tester,
    String text,
    EditorLigatures ligatures,
  ) async {
    final c = EditorController(displayPath: 'a.txt', initialText: text);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: PlanchetteEditor(
              controller: c,
              isActive: false,
              showStatus: false,
              ligatures: ligatures,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bytes = await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData();
      image.dispose();
      return data!.buffer.asUint8List();
    });
    return bytes!;
  }

  setUp(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(loadBundledMonoFonts);
  });

  testWidgets('JetBrains Mono joins -> and != with ligatures on', (
    tester,
  ) async {
    const text = 'a -> b != c';
    expect(
      await render(tester, text, EditorLigatures.on),
      isNot(await render(tester, text, EditorLigatures.off)),
    );
  });

  testWidgets('text without ligatures looks the same either way', (
    tester,
  ) async {
    // The control: only the ligatures change, not the face or the spacing.
    const text = 'ab cd efgh';
    expect(
      await render(tester, text, EditorLigatures.on),
      await render(tester, text, EditorLigatures.off),
    );
  });

  test('a stored name reads back, and anything else is on', () {
    expect(EditorLigatures.named('off'), EditorLigatures.off);
    expect(EditorLigatures.named('on'), EditorLigatures.on);
    for (final other in [null, '', 'OFF', 'nonsense', 0, false]) {
      expect(
        EditorLigatures.named(other),
        EditorLigatures.on,
        reason: '$other',
      );
    }
  });

  test('off keeps the features a style already has', () {
    const tabular = FontFeature.tabularFigures();
    const style = TextStyle(fontFeatures: [tabular]);
    expect(EditorLigatures.on.applyTo(style), same(style));
    expect(EditorLigatures.off.applyTo(style).fontFeatures, [
      tabular,
      const FontFeature.disable('calt'),
      const FontFeature.disable('liga'),
    ]);
  });
}
