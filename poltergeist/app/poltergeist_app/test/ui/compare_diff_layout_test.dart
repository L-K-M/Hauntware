import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/compare_diff_layout.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  CompareWrappedLine wrap(String line, int perRow) => wrapCompareLine(
    line,
    0,
    line.length,
    perRow,
    nonLatin: ComparedText.measure(line).isNonLatin(0),
  );

  int visualLines(String line, int perRow) {
    final measured = ComparedText.measure(line);
    return compareVisualLines(
      measured.columnsOf(0),
      perRow,
      nonLatin: measured.isNonLatin(0),
    );
  }

  test('columns per row never drop below the minimum', () {
    expect(compareColumnsPerRow(textWidth: 800, charWidth: 10), 80);
    expect(compareColumnsPerRow(textWidth: 30, charWidth: 10), 8);
    expect(compareColumnsPerRow(textWidth: -5, charWidth: 10), 8);
  });

  test('Latin lines take exactly ceil(columns / perRow) visual lines', () {
    for (final length in [0, 1, 9, 10, 11, 25]) {
      final line = 'x' * length;
      final wrapped = wrap(line, 10);

      expect(wrapped.lineCount, max(1, (length + 9) ~/ 10), reason: '$length');
      expect(visualLines(line, 10), wrapped.lineCount, reason: '$length');
      expect(wrapped.text.replaceAll('\n', ''), line);
    }
  });

  test('non-Latin lines keep slack and stay within their bound', () {
    final random = Random(6);
    const alphabet = ['a', '\t', '日', 'é', 'Ж', '\u{1F600}'];
    for (var round = 0; round < 500; round++) {
      final line = [
        for (var i = 0; i < random.nextInt(80); i++)
          alphabet[random.nextInt(alphabet.length)],
      ].join();
      final perRow = 8 + random.nextInt(40);
      final measured = ComparedText.measure(line);
      final nonLatin = measured.isNonLatin(0);
      final wrapped = wrap(line, perRow);
      final width = compareWrapWidth(perRow, nonLatin: nonLatin);

      expect(
        wrapped.lineCount,
        lessThanOrEqualTo(visualLines(line, perRow)),
        reason: 'round $round',
      );
      for (final chunk in wrapped.text.split('\n')) {
        final columns = ComparedText.measure(chunk).columnsOf(0);
        expect(
          columns,
          lessThanOrEqualTo(max(width, 2)),
          reason: 'round $round',
        );
      }
    }
    expect(compareWrapWidth(80, nonLatin: true), 70);
    expect(compareWrapWidth(80, nonLatin: false), 80);
  });

  test('tabs expand to the next multiple of four from the line start', () {
    expect(wrap('a\tb', 20).text, 'a   b');
    expect(wrap('\t\tx', 20).text, '        x');
    // A tab that crosses a wrap expands into spaces on both chunks.
    expect(wrap('abcdef\tg', 7).text, 'abcdef \n g');
  });

  test('a wide character never splits across visual lines', () {
    final wrapped = wrap('ab日本', 8);
    expect(wrapped.text, 'ab日本');

    final narrow = wrapCompareLine('abc日', 0, 4, 4, nonLatin: false);
    expect(narrow.text, 'abc\n日');
  });

  test('zero-width marks stay with the character before them', () {
    final line = '${'x' * 9}éy';
    final wrapped = wrapCompareLine(line, 0, line.length, 10, nonLatin: false);

    expect(wrapped.text, '${'x' * 9}é\ny');
  });

  test('lines past 10,000 columns report the hidden characters', () {
    final line = 'x' * 12000;
    final wrapped = wrap(line, 100);

    expect(wrapped.hiddenCharacters, 2000);
    expect(wrapped.text.replaceAll('\n', '').length, 10000);
    expect(visualLines(line, 100), 101);
    expect(wrapped.lineCount, 100);
  });

  test('an empty line is one visual line', () {
    expect(wrap('', 10).lineCount, 1);
    expect(wrap('', 10).text, '');
    expect(visualLines('', 10), 1);
  });

  test('row offsets sum the taller half and find rows by visual line', () {
    final left = 'short\n${'l' * 25}\nsame\n';
    const right = 'changed\nsame\n';
    final comparison = compareTexts(left, right) as TextComparisonComputed;
    final rows = alignLineDiff(comparison.diff, LineDiffLayout.sideBySide);

    final offsets = compareRowOffsets(
      rows,
      comparison.left,
      comparison.right,
      10,
    );

    // Row 0 pairs 'short' with 'changed', row 1 is the 25-column line
    // facing a gap, then the two equal lines.
    expect(offsets, [0, 1, 4, 5, 6]);
    expect(compareRowAtVisualLine(offsets, 0), 0);
    expect(compareRowAtVisualLine(offsets, 1), 1);
    expect(compareRowAtVisualLine(offsets, 3), 1);
    expect(compareRowAtVisualLine(offsets, 4), 2);
    expect(compareRowAtVisualLine(offsets, 99), 3);
    expect(compareRowAtVisualLine(offsets, -1), 0);
  });
}
