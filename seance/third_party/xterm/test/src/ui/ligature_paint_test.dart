import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show TextScaler;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

// [seance fork] With ligatures on, the painter shapes runs of cells together
// (painter.dart#paintLine). Fonts without ligatures, and faces whose run
// would leave the grid, must look exactly as they do cell by cell.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const columns = 40;

  /// Every line of [output], painted with [style] and each line's [recolor]
  /// spans, as raw RGBA.
  Future<Uint8List> paint(
    String output,
    TerminalStyle style, {
    List<CellRecolor>? recolor,
  }) async {
    final terminal = Terminal()..resize(columns, 8);
    terminal.write(output);
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: style,
      textScaler: TextScaler.noScaling,
    );
    final cell = painter.cellSize;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var y = 0; y < terminal.buffer.height; y++) {
      painter.paintLine(
        canvas,
        ui.Offset(0, y * cell.height),
        terminal.buffer.lines[y],
        recolor,
      );
    }
    final image = await recorder.endRecording().toImage(
          (columns * cell.width).ceil(),
          (terminal.buffer.height * cell.height).ceil(),
        );
    final bytes = await image.toByteData();
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  // Runs of every kind the grouping treats differently: plain operators,
  // colours and flags that split runs, a hyperlink (which must not), wide
  // and non-ASCII characters, and a token longer than the run cap.
  final output = [
    'a -> b != c === d <= e',
    '\x1b[31mred->\x1b[32m=>green\x1b[0m!=',
    '\x1b[1mbold->\x1b[0m \x1b[3mitalic->\x1b[0m \x1b[2mfaint->\x1b[0m',
    '\x1b[4munder->line\x1b[0m \x1b[7minverse->\x1b[0m',
    '\x1b[44mon-blue->bg\x1b[0m',
    '\x1b]8;;https://a.example\x1b\\li->nk\x1b]8;;\x1b\\->',
    '中文->é->ü',
    'x' * 70,
  ].join('\r\n');

  test('a face without ligatures paints the same either way', () async {
    // The test font has no ligatures and one advance for every glyph.
    expect(
      await paint(output, const TerminalStyle(ligatures: TerminalLigatures.on)),
      await paint(output, const TerminalStyle()),
    );
  });

  test('search hits split runs and keep their colours', () async {
    // Spans over part of a run, over a whole one and across a space. Bold
    // and italic are left out: their glyphs reach past the cell, and on a
    // coloured background a run draws them whole where cell by cell the
    // next cell's background cut them off.
    final upright = output.replaceAll('\x1b[1m', '').replaceAll('\x1b[3m', '');
    const spans = [
      CellRecolor(2, 4, 0xFFFFFF00, 0xFF000000),
      CellRecolor(9, 14, 0xFF00FFFF, 0xFF880000),
    ];
    expect(
      await paint(
        upright,
        const TerminalStyle(ligatures: TerminalLigatures.on),
        recolor: spans,
      ),
      await paint(upright, const TerminalStyle(), recolor: spans),
    );
  });

  group('a proportional face', () {
    const cells = TerminalStyle(fontFamily: 'Roboto');
    final runs = cells.copyWith(ligatures: TerminalLigatures.on);

    setUpAll(() async {
      final roboto = File(
        '${Platform.environment['FLUTTER_ROOT']}'
        '/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      );
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(roboto.readAsBytesSync())));
      await loader.load();
    });

    test('is still drawn cell by cell', () async {
      // Shaped as one run, Roboto's narrow and wide letters would drift off
      // the grid; the width check keeps each on its cell.
      const text = 'iiiiWWWW->llll mmmm';
      expect(await paint(text, runs), await paint(text, cells));
    });

    test('stays on the grid when off-grid widths cancel out', () async {
      // Letters a little wider than the cell, then a narrow one, can add up
      // to whole cells while the last starts well off its cell: the total
      // alone would pass ('@@@@@w' in Roboto). Found rather than
      // hard-coded, so a Roboto update keeps the case.
      final cell = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: cells,
        textScaler: TextScaler.noScaling,
      ).cellSize.width;
      double width(String text) {
        final style = cells.toTextStyle();
        final builder = ui.ParagraphBuilder(style.getParagraphStyle())
          ..pushStyle(style.getTextStyle())
          ..addText(text);
        final paragraph = builder.build()
          ..layout(const ui.ParagraphConstraints(width: double.infinity));
        return paragraph.maxIntrinsicWidth;
      }

      final letters = [
        for (var c = 0x21; c < 0x7F; c++) String.fromCharCode(c),
      ];
      String? found;
      search:
      for (final wide in letters.where((l) => width(l) > cell)) {
        for (var count = 2; count <= 10; count++) {
          final lead = wide * count;
          if (width(lead) - count * cell < 1) continue;
          for (final narrow in letters) {
            final text = '$lead$narrow';
            if ((width(text) - text.length * cell).abs() < 0.5) {
              found = text;
              break search;
            }
          }
        }
      }
      expect(found, isNotNull, reason: 'no cancelling run in Roboto');

      expect(await paint(found!, runs), await paint(found, cells));
    });
  });

  test('copyWith keeps the ligature mode', () {
    const style = TerminalStyle(ligatures: TerminalLigatures.on);
    expect(style.copyWith(fontSize: 20).ligatures, TerminalLigatures.on);
    expect(const TerminalStyle().ligatures, TerminalLigatures.off);
  });
}
