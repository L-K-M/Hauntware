import 'package:planchette_core/planchette_core.dart' show lineStartOffsets;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  test('countComparedLines counts newlines plus an unterminated last line', () {
    expect(countComparedLines(''), 0);
    expect(countComparedLines('a'), 1);
    expect(countComparedLines('a\n'), 1);
    expect(countComparedLines('a\nb'), 2);
    expect(countComparedLines('\n'), 1);
    expect(countComparedLines('\n\n'), 2);
  });

  test('exactly 20,000 lines compare with or without a final newline', () {
    final lines = [for (var i = 0; i < compareMaximumLines; i++) 'line $i'];
    final terminated = '${lines.join('\n')}\n';
    final unterminated = lines.join('\n');

    expect(
      compareTexts(terminated, unterminated),
      isA<TextComparisonComputed>(),
    );
  });

  test('20,001 lines on either side report both counts and the cap', () {
    final over = List.filled(compareMaximumLines + 1, 'x').join('\n');

    final leftOver = compareTexts(over, 'a\nb\n');
    expect(leftOver, isA<TextComparisonOverLineCap>());
    leftOver as TextComparisonOverLineCap;
    expect(leftOver.leftLines, compareMaximumLines + 1);
    expect(leftOver.rightLines, 2);
    expect(leftOver.maximumLines, compareMaximumLines);

    final rightOver = compareTexts('a', over) as TextComparisonOverLineCap;
    expect(rightOver.leftLines, 1);
    expect(rightOver.rightLines, compareMaximumLines + 1);
  });

  test('a caller cap applies to both sides', () {
    final outcome = compareTexts('a\nb\nc\nd\n', 'a\nb\n', maximumLines: 3);

    expect(outcome, isA<TextComparisonOverLineCap>());
    outcome as TextComparisonOverLineCap;
    expect(
      (outcome.leftLines, outcome.rightLines, outcome.maximumLines),
      (4, 2, 3),
    );
  });

  test('a missing final newline is one right-only empty line', () {
    final outcome = compareTexts('a\nb', 'a\nb\n') as TextComparisonComputed;

    expect(outcome.diff.regions, [
      const LineDiffRegion(
        leftStart: 2,
        leftCount: 0,
        rightStart: 2,
        rightCount: 1,
      ),
    ]);
    expect(outcome.left.lineCount, 2);
    expect(outcome.right.lineCount, 3);
  });

  test('identical texts compute no regions', () {
    final outcome = compareTexts('a\nb\n', 'a\nb\n') as TextComparisonComputed;

    expect(outcome.diff.regions, isEmpty);
    expect(outcome.diff.minimal, isTrue);
  });

  test('a caller cost limit reaches the diff', () {
    final left = [for (var i = 0; i < 200; i++) 'l${i % 7}'].join('\n');
    final right = [for (var i = 0; i < 200; i++) 'l${(i * 3) % 5}'].join('\n');

    final outcome =
        compareTexts(left, right, costLimit: 1) as TextComparisonComputed;

    expect(outcome.diff.minimal, isFalse);
  });

  group('ComparedText', () {
    test('line starts and ends match lineStartOffsets', () {
      const text = 'one\n\nthree\nfour';
      final measured = ComparedText.measure(text);
      final starts = lineStartOffsets(text);

      expect(measured.lineCount, starts.length);
      for (var line = 0; line < starts.length; line++) {
        expect(measured.lineStart(line), starts[line]);
      }
      expect(
        [
          for (var line = 0; line < measured.lineCount; line++)
            text.substring(measured.lineStart(line), measured.lineEnd(line)),
        ],
        ['one', '', 'three', 'four'],
      );
      expect(ComparedText.measure('a\n').lineCount, 2);
      expect(ComparedText.measure('').lineCount, 1);
    });

    test('columns expand tabs to four and count wide and zero-width '
        'characters', () {
      final measured = ComparedText.measure('a\tb\n日本\né\n\t\t\n');

      expect(measured.columnsOf(0), 5);
      expect(measured.columnsOf(1), 4);
      expect(measured.columnsOf(2), 1);
      expect(measured.columnsOf(3), 8);
      expect(measured.columnsOf(4), 0);
    });

    test('fallback glyphs mark non-Latin lines and controls other than '
        'tab', () {
      final measured = ComparedText.measure(
        'plain ascii\ncaf\u00e9\ne\u0301\n\u0416\n\u{1F600}\n'
        'a\tb\nform\u000cfeed\nvertical\u000btab\nline\u2028sep\n'
        'del\u007f\nnext\u0085line\n',
      );

      expect(
        [
          for (var line = 0; line < measured.lineCount; line++)
            measured.mayUseFallbackGlyphs(line),
        ],
        [
          ...[false, false, true, true, true, false],
          ...[true, true, true, true, true, false],
        ],
      );
    });
  });
}
