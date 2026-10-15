import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';

// flutter_test's font draws every glyph one advance wide, so a glyph
// wider than the two advances the view once allowed for any non-Latin-1
// unit cannot be drawn with it, and its advances add up without rounding
// error. This file loads a font of its own as the monospace stack's
// first family, which every later test in the same process would see,
// so it lives apart from the other log view tests.

/// U+2E3B THREE-EM DASH: 3 em, five advances of [_wideDashFont].
const String _dash = '⸻';

const int _unitsPerEm = 1000;
const int _advanceUnits = 600;
const int _dashUnits = 3000;
const int _firstAscii = 0x20;
const int _lastAscii = 0x7e;

/// A TrueType font of empty glyphs: printable ASCII at a monospace advance
/// of 0.6 em, as in common monospace fonts, and [_dash] at 3 em, as a
/// fallback font draws it. Layout needs only the widths.
ByteData _wideDashFont() {
  const asciiGlyphs = _lastAscii - _firstAscii + 1;
  // .notdef, the dash, then the ASCII glyphs.
  const glyphs = 2 + asciiGlyphs;
  const firstAsciiGlyph = 2;

  ByteData table(int length, void Function(ByteData data) write) {
    final data = ByteData(length);
    write(data);
    return data;
  }

  final head = table(54, (d) {
    d
      ..setUint32(0, 0x00010000) // version
      ..setUint32(4, 0x00010000) // fontRevision
      ..setUint32(12, 0x5f0f3cf5) // magicNumber
      ..setUint16(16, 0x0003) // flags: baseline and left bearing at 0
      ..setUint16(18, _unitsPerEm)
      ..setInt16(38, -200) // yMin
      ..setInt16(40, _dashUnits) // xMax
      ..setInt16(42, 800) // yMax
      ..setUint16(46, 8) // lowestRecPPEM
      ..setInt16(48, 2); // fontDirectionHint; indexToLocFormat 0: short
  });
  final hhea = table(36, (d) {
    d
      ..setUint32(0, 0x00010000)
      ..setInt16(4, 800) // ascender
      ..setInt16(6, -200) // descender
      ..setUint16(10, _dashUnits) // advanceWidthMax
      ..setInt16(18, 1) // caretSlopeRise
      ..setUint16(34, 3); // numberOfHMetrics
  });
  final maxp = table(32, (d) {
    d
      ..setUint32(0, 0x00010000)
      ..setUint16(4, glyphs)
      ..setUint16(14, 1); // maxZones
  });
  // Three full metrics; every later glyph takes the last advance.
  final hmtx = table(3 * 4 + (glyphs - 3) * 2, (d) {
    d
      ..setUint16(0, _advanceUnits)
      ..setUint16(4, _dashUnits)
      ..setUint16(8, _advanceUnits);
  });
  // Format 4: ASCII, the dash, and the closing segment.
  const segments = [
    (_firstAscii, _lastAscii, firstAsciiGlyph - _firstAscii),
    (0x2e3b, 0x2e3b, 1 - 0x2e3b),
    (0xffff, 0xffff, 1),
  ];
  final cmap = table(12 + 16 + segments.length * 8, (d) {
    const count = 3;
    d
      ..setUint16(2, 1) // one encoding record
      ..setUint16(4, 3) // Windows
      ..setUint16(6, 1) // Unicode BMP
      ..setUint32(8, 12)
      ..setUint16(12, 4) // format
      ..setUint16(14, 16 + count * 8) // length
      ..setUint16(18, count * 2)
      ..setUint16(20, 4) // searchRange
      ..setUint16(22, 1) // entrySelector
      ..setUint16(24, count * 2 - 4); // rangeShift
    for (var i = 0; i < count; i++) {
      final (start, end, delta) = segments[i];
      d
        ..setUint16(26 + i * 2, end)
        ..setUint16(28 + count * 2 + i * 2, start)
        ..setInt16(28 + count * 4 + i * 2, delta);
    }
  });
  // Every glyph is empty: all offsets 0, no glyph data.
  final loca = ByteData((glyphs + 1) * 2);
  final glyf = ByteData(0);
  const family = 'Wide Dash';
  final name = table(18 + family.length * 2, (d) {
    d
      ..setUint16(2, 1) // count
      ..setUint16(4, 18) // stringOffset
      ..setUint16(6, 3) // Windows
      ..setUint16(8, 1) // Unicode BMP
      ..setUint16(10, 0x0409) // en-US
      ..setUint16(12, 1) // family name
      ..setUint16(14, family.length * 2);
    for (var i = 0; i < family.length; i++) {
      d.setUint16(18 + i * 2, family.codeUnitAt(i));
    }
  });
  final post = table(32, (d) => d.setUint32(0, 0x00030000));

  final tables = {
    'cmap': cmap,
    'glyf': glyf,
    'head': head,
    'hhea': hhea,
    'hmtx': hmtx,
    'loca': loca,
    'maxp': maxp,
    'name': name,
    'post': post,
  };
  final directory = 12 + tables.length * 16;
  var size = directory;
  for (final data in tables.values) {
    size += (data.lengthInBytes + 3) & ~3;
  }
  final font = ByteData(size)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, tables.length)
    ..setUint16(6, 128) // searchRange: 16 * 8
    ..setUint16(8, 3) // entrySelector
    ..setUint16(10, tables.length * 16 - 128); // rangeShift
  var record = 12;
  var offset = directory;
  for (final MapEntry(key: tag, value: data) in tables.entries) {
    for (var i = 0; i < 4; i++) {
      font.setUint8(record + i, tag.codeUnitAt(i));
    }
    font
      ..setUint32(record + 8, offset)
      ..setUint32(record + 12, data.lengthInBytes);
    for (var i = 0; i < data.lengthInBytes; i++) {
      font.setUint8(offset + i, data.getUint8(i));
    }
    record += 16;
    offset += (data.lengthInBytes + 3) & ~3;
  }
  return font;
}

Widget _app(LogViewController logs) => MaterialApp(
  theme: GhostTheme.light(
    klabautermannThemeStyle,
    platform: TargetPlatform.linux,
  ),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Material(
    child: LogView(controller: logs, wrap: LogWrap.on),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader(klabautermannThemeStyle.monoFontFamilies.first)
      ..addFont(Future.value(_wideDashFont()));
    await loader.load();
  });

  testWidgets('a glyph wider than two advances does not clip its row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final logs = LogViewController();
    addTearDown(logs.dispose);
    // Two advances a dash fit the 384 px text width; five do not.
    final line = 'abc ${_dash * 10} end';
    logs.add([line, 'after']);

    await tester.pumpWidget(_app(logs));

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text(line, findRichText: true),
    );
    final after = tester.getSize(find.text('after', findRichText: true));
    expect(
      paragraph.textSize.height,
      closeTo(2 * after.height, 0.01),
      reason: 'the font draws the dash five advances wide',
    );
    expect(paragraph.size.height, closeTo(paragraph.textSize.height, 0.01));
  });

  // flutter_test's font sums its advances without error. This font's
  // advance of 0.6 em is a fraction of a pixel at these scales, and the
  // engine's single-precision sum of a line's advances exceeds the advance
  // times its cells, by more as the line grows. Each row is wider than
  // that product by less than the excess, so the engine wraps the line;
  // the last row is wider by more than a fixed slack of 0.01 px.
  for (final (scale, cells, past) in [
    (1.15, 49, 0.0),
    (1.0, 500, 0.0),
    (2.45, 300, 0.015),
  ]) {
    testWidgets('a Latin-1 line a rounding error wider than its row is not '
        'clipped, $cells cells at text scale $scale, row $past px wider', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final logs = LogViewController();
      addTearDown(logs.dispose);
      logs.add(['W']);
      await tester.pumpWidget(_app(logs));
      final advance = tester
          .renderObject<RenderParagraph>(find.text('W', findRichText: true))
          .getMaxIntrinsicWidth(double.infinity);

      // The text width is the row less its padding of 8 px a side.
      tester.view.physicalSize = Size(cells * advance + past + 2 * 8, 200);
      final line = 'a' * cells;
      logs.add([line]);
      await tester.pump();

      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(line, findRichText: true),
      );
      expect(
        paragraph.textSize.height,
        greaterThan(tester.getSize(find.text('W', findRichText: true)).height),
        reason: 'the engine wraps the line',
      );
      expect(paragraph.size.height, closeTo(paragraph.textSize.height, 0.01));
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  }
}
