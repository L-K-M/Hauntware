import 'dart:math';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  group('diffLines', () {
    test('identical inputs have no regions and stay minimal', () {
      final diff = diffLines(['a', 'b', 'c'], ['a', 'b', 'c']);

      expect(diff.regions, isEmpty);
      expect(diff.minimal, isTrue);
      expect(diff.leftLineCount, 3);
      expect(diff.rightLineCount, 3);
    });

    test('empty against empty is identical', () {
      expect(diffLines(const [], const []).regions, isEmpty);
    });

    test('one changed middle line is one paired region', () {
      expect(diffLines(['a', 'b', 'c'], ['a', 'x', 'c']).regions, [
        _region(1, 1, 1, 1),
      ]);
    });

    test('pure inserts at the start, middle and end', () {
      expect(diffLines(['b', 'c'], ['a', 'b', 'c']).regions, [
        _region(0, 0, 0, 1),
      ]);
      expect(diffLines(['a', 'c'], ['a', 'b', 'c']).regions, [
        _region(1, 0, 1, 1),
      ]);
      expect(diffLines(['a', 'b'], ['a', 'b', 'c']).regions, [
        _region(2, 0, 2, 1),
      ]);
      expect(diffLines(const [], ['a', 'b']).regions, [_region(0, 0, 0, 2)]);
    });

    test('pure deletes at the start, middle and end', () {
      expect(diffLines(['a', 'b', 'c'], ['b', 'c']).regions, [
        _region(0, 1, 0, 0),
      ]);
      expect(diffLines(['a', 'b', 'c'], ['a', 'c']).regions, [
        _region(1, 1, 1, 0),
      ]);
      expect(diffLines(['a', 'b', 'c'], ['a', 'b']).regions, [
        _region(2, 1, 2, 0),
      ]);
      expect(diffLines(['a', 'b'], const []).regions, [_region(0, 2, 0, 0)]);
    });

    test('the paper\'s ABCABBA example has edit distance 5', () {
      final left = 'ABCABBA'.split('');
      final right = 'CBABAC'.split('');
      final diff = diffLines(left, right);

      expect(diff.minimal, isTrue);
      expect(_editCount(diff), 5);
      _expectValid(left, right, diff);
    });

    test('regions are ordered and separated by an equal line', () {
      final left = ['a', 'x', 'b', 'c', 'y', 'z', 'd'];
      final right = ['a', 'b', 'q', 'c', 'd', 'w'];
      final diff = diffLines(left, right);

      _expectValid(left, right, diff);
      expect(diff.regions.length, greaterThan(1));
    });

    test('matches an LCS oracle on seeded random inputs', () {
      final random = Random(20261012);
      for (var round = 0; round < 3000; round++) {
        final left = _randomLines(random, random.nextInt(41), alphabet: 3);
        final right = _randomLines(random, random.nextInt(41), alphabet: 3);
        final diff = diffLines(left, right);

        expect(diff.minimal, isTrue, reason: 'round $round');
        expect(
          _editCount(diff),
          left.length + right.length - 2 * _lcsLength(left, right),
          reason: 'round $round: $left vs $right',
        );
        _expectValid(left, right, diff, reason: 'round $round');
      }
    });

    test('lines on one side only keep the result minimal', () {
      final random = Random(7);
      for (var round = 0; round < 500; round++) {
        final left = [
          for (final line in _randomLines(random, 30, alphabet: 4))
            random.nextInt(4) == 0
                ? 'left-only $round ${random.nextInt(9)}'
                : line,
        ];
        final right = [
          for (final line in _randomLines(random, 30, alphabet: 4))
            random.nextInt(4) == 0 ? 'right-only $round' : line,
        ];
        final diff = diffLines(left, right);

        expect(
          _editCount(diff),
          left.length + right.length - 2 * _lcsLength(left, right),
          reason: 'round $round',
        );
        expect(diff.minimal, isTrue, reason: 'round $round');
        _expectValid(left, right, diff, reason: 'round $round');
      }
    });

    test('tiny cost limits stay valid and report non-minimal results', () {
      final random = Random(99);
      var sawSimplified = false;
      for (final costLimit in [1, 2, 3, 5]) {
        for (var round = 0; round < 300; round++) {
          final left = _randomLines(random, random.nextInt(60), alphabet: 4);
          final right = _randomLines(random, random.nextInt(60), alphabet: 4);
          final diff = diffLines(left, right, costLimit: costLimit);
          final optimal =
              left.length + right.length - 2 * _lcsLength(left, right);

          _expectValid(left, right, diff, reason: 'limit $costLimit/$round');
          if (diff.minimal) {
            expect(_editCount(diff), optimal, reason: 'limit $costLimit');
          } else {
            sawSimplified = true;
            expect(_editCount(diff), greaterThanOrEqualTo(optimal));
          }
        }
      }
      expect(sawSimplified, isTrue);
    });

    test('a block moved past the cost limit stays one move either way', () {
      final lines = [for (var i = 0; i < 20000; i++) 'line $i'];
      for (final size in [1025, 2000, 5000]) {
        final block = lines.sublist(0, size);
        final rest = lines.sublist(size);
        for (final (left, right) in [
          ([...block, ...rest], [...rest, ...block]),
          ([...rest, ...block], [...block, ...rest]),
        ]) {
          final diff = diffLines(left, right);

          _expectValid(left, right, diff);
          expect(_editCount(diff), 2 * size, reason: 'block of $size');
          expect(diff.regions, hasLength(2), reason: 'block of $size');
        }
      }
    }, timeout: _heavyTimeout);

    test('a block moved among repeated lines keeps to its anchors', () {
      // Source-like text: every fifth line blank, many closing braces.
      final lines = [
        for (var i = 0; i < 9500; i++)
          i % 5 == 4 ? '' : (i % 7 == 3 ? '}' : 'statement $i;'),
      ];
      final block = lines.sublist(2000, 3500);
      final moved = [
        ...lines.sublist(0, 2000),
        ...lines.sublist(3500),
        ...block,
      ];
      for (final (left, right) in [(lines, moved), (moved, lines)]) {
        final diff = diffLines(left, right);

        _expectValid(left, right, diff);
        expect(_editCount(diff), lessThanOrEqualTo(2 * block.length));
      }
    });

    test('a block of repeated lines moved past the cost limit takes the '
        'nearer edge', () {
      // No line is unique, so there are no anchors: the frontier split has
      // to cross the moved block along the edge whose first match is
      // nearer, from either end.
      final ys = List.filled(1500, 'y');
      final xs = List.filled(3000, 'x');
      for (final (left, right) in [
        ([...ys, ...xs], [...xs, ...ys]),
        ([...xs, ...ys], [...ys, ...xs]),
      ]) {
        final diff = diffLines(left, right);

        _expectValid(left, right, diff);
        expect(_editCount(diff), 2 * ys.length);
      }

      final aLines = List.filled(10000, 'a');
      final bLines = List.filled(10000, 'b');
      final swapped = diffLines([...aLines, ...bLines], [...bLines, ...aLines]);
      expect(_editCount(swapped), 20000);
    }, timeout: _heavyTimeout);

    test('a cost limit below 1 is refused', () {
      expect(() => diffLines(['a'], ['b'], costLimit: 0), throwsArgumentError);
    });

    test('two unrelated 20,000-line inputs become one region', () {
      final left = [for (var i = 0; i < 20000; i++) 'left $i'];
      final right = [for (var i = 0; i < 20000; i++) 'right $i'];
      final diff = diffLines(left, right);

      expect(diff.regions, [_region(0, 20000, 0, 20000)]);
      expect(diff.minimal, isTrue);
    }, timeout: _heavyTimeout);

    test('adversarial inputs at the cap finish and stay valid', () {
      final ascending = [for (var i = 0; i < 20000; i++) 'line $i'];
      final reversed = ascending.reversed.toList();
      _expectValid(ascending, reversed, diffLines(ascending, reversed));

      final ab = [
        for (var i = 0; i < 10000; i++) 'a',
        for (var i = 0; i < 10000; i++) 'b',
      ];
      final ba = [
        for (var i = 0; i < 10000; i++) 'b',
        for (var i = 0; i < 10000; i++) 'a',
      ];
      _expectValid(ab, ba, diffLines(ab, ba));

      final random = Random(4);
      for (final alphabet in [4, 1000]) {
        final left = _randomLines(random, 20000, alphabet: alphabet);
        final right = _randomLines(random, 20000, alphabet: alphabet);
        _expectValid(left, right, diffLines(left, right));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('alignLineDiff', () {
    final left = ['a', 'b', 'c', 'd', 'e'];
    final right = ['a', 'x', 'y', 'c', 'e', 'f'];
    late LineDiff diff;

    setUp(() => diff = diffLines(left, right));

    test('side by side pairs removed with added lines and pads with gaps', () {
      final rows = alignLineDiff(diff, LineDiffLayout.sideBySide);

      expect(_describe(rows), [
        '0 0 unchanged',
        '1 1 changed',
        '- 2 rightOnly',
        '2 3 unchanged',
        '3 - leftOnly',
        '4 4 unchanged',
        '- 5 rightOnly',
      ]);
    });

    test('unified lists left-only rows before right-only rows', () {
      final rows = alignLineDiff(diff, LineDiffLayout.unified);

      expect(_describe(rows), [
        '0 0 unchanged',
        '1 - leftOnly',
        '- 1 rightOnly',
        '- 2 rightOnly',
        '2 3 unchanged',
        '3 - leftOnly',
        '4 4 unchanged',
        '- 5 rightOnly',
      ]);
    });

    test('row counts follow the region sizes', () {
      final random = Random(11);
      for (var round = 0; round < 200; round++) {
        final l = _randomLines(random, random.nextInt(30), alphabet: 3);
        final r = _randomLines(random, random.nextInt(30), alphabet: 3);
        final d = diffLines(l, r);
        final changedLeft = d.regions.fold(0, (s, x) => s + x.leftCount);
        final equal = l.length - changedLeft;

        expect(
          alignLineDiff(d, LineDiffLayout.sideBySide).length,
          equal +
              d.regions.fold(0, (s, x) => s + max(x.leftCount, x.rightCount)),
        );
        expect(
          alignLineDiff(d, LineDiffLayout.unified).length,
          equal + d.regions.fold(0, (s, x) => s + x.leftCount + x.rightCount),
        );
      }
    });

    test('region starts and line rows round-trip', () {
      for (final layout in LineDiffLayout.values) {
        final rows = alignLineDiff(diff, layout);

        expect(rows.regionCount, diff.regions.length);
        for (var region = 0; region < rows.regionCount; region++) {
          final first = rows.regionFirstRow(region);
          expect(rows.regionAt(first), region);
          if (first > 0) expect(rows.regionAt(first - 1), isNot(region));
        }
        for (var line = 0; line < left.length; line++) {
          expect(rows.leftLineAt(rows.rowOfLeftLine(line)), line);
        }
        for (var line = 0; line < right.length; line++) {
          expect(rows.rightLineAt(rows.rowOfRightLine(line)), line);
        }
        for (var row = 0; row < rows.length; row++) {
          final unchanged = rows.kindAt(row) == LineDiffRowKind.unchanged;
          expect(rows.regionAt(row) == -1, unchanged);
        }
      }
    });

    test('identical inputs align as unchanged rows only', () {
      final rows = alignLineDiff(
        diffLines(['a', 'b'], ['a', 'b']),
        LineDiffLayout.sideBySide,
      );

      expect(_describe(rows), ['0 0 unchanged', '1 1 unchanged']);
      expect(rows.regionCount, 0);
    });
  });
}

/// Room for the tests that diff inputs at the 20,000-line cap.
const _heavyTimeout = Timeout(Duration(seconds: 60));

LineDiffRegion _region(int ls, int lc, int rs, int rc) => LineDiffRegion(
  leftStart: ls,
  leftCount: lc,
  rightStart: rs,
  rightCount: rc,
);

int _editCount(LineDiff diff) =>
    diff.regions.fold(0, (sum, r) => sum + r.leftCount + r.rightCount);

List<String> _randomLines(Random random, int length, {required int alphabet}) =>
    [for (var i = 0; i < length; i++) 'l${random.nextInt(alphabet)}'];

int _lcsLength(List<String> a, List<String> b) {
  var previous = List.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    final current = List.filled(b.length + 1, 0);
    for (var j = 1; j <= b.length; j++) {
      current[j] = a[i - 1] == b[j - 1]
          ? previous[j - 1] + 1
          : max(previous[j], current[j - 1]);
    }
    previous = current;
  }
  return previous[b.length];
}

/// The regions must be ordered, separated by equal lines, pair equal lines
/// between them, and turn the left side into the right side.
void _expectValid(
  List<String> left,
  List<String> right,
  LineDiff diff, {
  String? reason,
}) {
  expect(diff.leftLineCount, left.length, reason: reason);
  expect(diff.rightLineCount, right.length, reason: reason);

  final rebuilt = <String>[];
  var l = 0;
  var r = 0;
  LineDiffRegion? previous;
  for (final region in diff.regions) {
    expect(
      region.leftCount + region.rightCount,
      greaterThan(0),
      reason: reason,
    );
    final gap = region.leftStart - l;
    expect(gap, greaterThanOrEqualTo(0), reason: reason);
    expect(region.rightStart - r, gap, reason: reason);
    if (previous != null) expect(gap, greaterThan(0), reason: reason);
    for (var k = 0; k < gap; k++) {
      expect(left[l + k], right[r + k], reason: reason);
      rebuilt.add(left[l + k]);
    }
    rebuilt.addAll(
      right.sublist(region.rightStart, region.rightStart + region.rightCount),
    );
    l = region.leftStart + region.leftCount;
    r = region.rightStart + region.rightCount;
    previous = region;
  }
  expect(left.length - l, right.length - r, reason: reason);
  for (var k = 0; k < left.length - l; k++) {
    expect(left[l + k], right[r + k], reason: reason);
  }
  rebuilt.addAll(left.sublist(l));
  expect(rebuilt, right, reason: reason);
}

List<String> _describe(LineDiffRows rows) => [
  for (var row = 0; row < rows.length; row++)
    '${_line(rows.leftLineAt(row))} ${_line(rows.rightLineAt(row))} '
        '${rows.kindAt(row).name}',
];

String _line(int line) => line < 0 ? '-' : '$line';
