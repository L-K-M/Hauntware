import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// The editor's ligature choice end to end, in its bundled JetBrains Mono.
void main() {
  final boundary = GlobalKey();

  /// [text] as the editor draws it with [ligatures], as raw RGBA.
  Future<Uint8List> render(
    WidgetTester tester,
    String text,
    EditorLigatures ligatures, {
    String? family,
  }) async {
    await tester.runAsync(loadBundledMonoFonts);
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
              textStyle: TextStyle(fontFamily: family),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final style = tester
        .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
        .style!;
    final metrics = TextPainter(
      text: TextSpan(text: 'm', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(metrics.width, lessThan(style.fontSize!));
    metrics.dispose();

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

  for (final font in [
    BundledMonoFont.monaspaceNeon,
    BundledMonoFont.geistMono,
    BundledMonoFont.intelOneMono,
    BundledMonoFont.commitMono,
  ]) {
    testWidgets('${font.displayName} coding sets reach the editor', (
      tester,
    ) async {
      const text = 'a -> b != c';
      expect(
        await render(
          tester,
          text,
          EditorLigatures.on,
          family: font.displayName,
        ),
        isNot(
          await render(
            tester,
            text,
            EditorLigatures.off,
            family: font.displayName,
          ),
        ),
      );
    });
  }

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
