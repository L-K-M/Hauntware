import 'dart:convert';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  test('line offsets use UTF-16 and retain a trailing empty line', () {
    expect(lineStartOffsets(''), [0]);
    expect(lineStartOffsets('one'), [0]);
    expect(lineStartOffsets('one\ntwo\n'), [0, 4, 8]);
    expect(lineStartOffsets('\n'), [0, 1]);
    expect(lineStartOffsets('one\r\ntwo'), [0, 5]);
    expect(lineStartOffsets('😀\né'), [0, 3]);
  });

  test('UTF-8 byte count matches encoding including unpaired surrogates', () {
    for (final text in [
      '',
      'plain ascii',
      'aé€😀',
      'line\r\nbreaks\n',
      '\uD83D',
      'x\uDE00y',
      '\uDE00\uD83D',
      '😀' * 3,
    ]) {
      expect(utf8EncodedLength(text), utf8.encode(text).length, reason: text);
    }
  });

  test('search reports UTF-16 ranges without overlapping repeated matches', () {
    expect(findSearchMatches('😀aaaa', 'aa'), [
      const TextMatch(start: 2, end: 4),
      const TextMatch(start: 4, end: 6),
    ]);
    expect(findSearchMatches('x', 'x', limit: 0), isEmpty);
    expect(const TextMatch(start: 2, end: 4).length, 2);
  });

  group('displayColumnFor', () {
    test('plain ASCII matches the UTF-16 column', () {
      expect(displayColumnFor('abc', 0, 3), 4);
      expect(displayColumnFor('abc', 0, 0), 1);
    });

    test('a tab advances to the next multiple of the tab width', () {
      // \t at column 1 covers 1–4 under tabWidth 4; offset 4 sits at 8.
      expect(displayColumnFor('\tindented', 0, 4), 8);
      expect(displayColumnFor('ab\tc', 0, 4), 6);
      expect(displayColumnFor('\ti', 0, 1, tabWidth: 8), 9);
    });

    test('wide CJK and emoji count two columns', () {
      expect(displayColumnFor('中', 0, 1), 3);
      expect(displayColumnFor('a中b', 0, 3), 5);
      expect(displayColumnFor('😀x', 0, 2), 3); // surrogate pair, one point
      expect(displayColumnFor('😀x', 0, 3), 4);
    });

    test('combining marks and joiners count zero', () {
      // 'e' + combining acute (U+0301): the mark adds no column.
      expect(displayColumnFor('é', 0, 2), 2);
      expect(displayColumnFor('🇫🇷x', 0, 5), 4);
      // ZWNJ (U+200C) is as invisible as ZWJ — a Persian-style sequence
      // must not gain a phantom column.
      expect(displayColumnFor('a‌b', 0, 3), 3);
    });

    test('columns count from the line start, not the buffer start', () {
      const text = 'one\n中x';
      expect(displayColumnFor(text, 4, 5), 3);
      expect(displayColumnFor(text, 4, 6), 4);
    });
  });
}
