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
}
