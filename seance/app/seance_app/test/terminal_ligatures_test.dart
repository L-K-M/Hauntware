import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:xterm/xterm.dart';

/// The terminal's ligatures end to end: Séance's own appearance, its bundled
/// default font and the xterm fork's run painting.
void main() {
  final boundary = GlobalKey();

  /// [output] as the terminal draws it with [ligatures], as raw RGBA.
  Future<Uint8List> render(
    WidgetTester tester,
    String output,
    TerminalLigatures ligatures, {
    String family = '',
  }) async {
    final appearance = TerminalAppearance.resolve(
      AppSettings(terminalFontFamily: family, terminalLigatures: ligatures),
      Brightness.dark,
    );
    final terminal = Terminal()..write(output);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 400,
              height: 100,
              child: TerminalView(
                terminal,
                textStyle: appearance.style,
                theme: appearance.theme,
                autofocus: false,
              ),
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

  testWidgets('Iosevka Term joins -> and != with ligatures on', (tester) async {
    const output = r'a -> b != c';
    expect(
      await render(tester, output, TerminalLigatures.on),
      isNot(await render(tester, output, TerminalLigatures.off)),
    );
  });

  testWidgets('text without ligatures looks the same either way', (
    tester,
  ) async {
    // The control: runs are on the grid, so plain words do not move.
    const output = 'ab cd efgh';
    expect(
      await render(tester, output, TerminalLigatures.on),
      await render(tester, output, TerminalLigatures.off),
    );
  });

  for (final font in BundledMonoFont.values) {
    if (!font.hasProgrammingLigatures) continue;

    testWidgets('${font.displayName} ligatures reach the terminal painter', (
      tester,
    ) async {
      const output = 'a -> b != c === d <= e => f';
      expect(
        await render(
          tester,
          output,
          TerminalLigatures.on,
          family: font.displayName,
        ),
        isNot(
          await render(
            tester,
            output,
            TerminalLigatures.off,
            family: font.displayName,
          ),
        ),
      );
    });
  }
}
