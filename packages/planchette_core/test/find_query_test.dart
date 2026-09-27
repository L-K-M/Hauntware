import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  group('literal queries', () {
    test('find every occurrence, left to right', () {
      final query = FindQuery.literal('cat');
      expect(query.findIn('cat CAT cat', caseSensitive: true), [
        const TextMatch(start: 0, end: 3),
        const TextMatch(start: 8, end: 11),
      ]);
      expect(query.findIn('cat CAT cat'), hasLength(3));
      expect(query.error, isNull);
    });

    test('case sensitivity is a flag, not a different query', () {
      final query = FindQuery.literal('cat');
      expect(query.findIn('cat CAT', caseSensitive: true), hasLength(1));
      expect(query.findIn('cat CAT'), hasLength(2));
    });

    test('an empty query matches nothing rather than everything', () {
      // Every position would match, which would light the whole document up.
      expect(FindQuery.literal('').findIn('abc'), isEmpty);
      expect(FindQuery.literal('').findIn(''), isEmpty);
      expect(FindQuery.pattern('').findIn('abc'), isEmpty);
    });

    test('occurrences do not overlap', () {
      expect(FindQuery.literal('aa').findIn('aaaa'), [
        const TextMatch(start: 0, end: 2),
        const TextMatch(start: 2, end: 4),
      ]);
    });
  });

  group('patterns', () {
    test('match what the pattern says', () {
      final query = FindQuery.pattern(r'\bTODO\b');
      expect(query.error, isNull);
      expect(query.findIn('a TODO here\nTODO: fix'), hasLength(2));
    });

    test('a pattern with no match is not an error', () {
      final query = FindQuery.pattern('zzz');
      expect(query.error, isNull);
      expect(query.findIn('abc'), isEmpty);
    });

    test('an unusable pattern reports why instead of matching nothing', () {
      // The difference matters: a typo should say so rather than looking like
      // the file has no occurrences.
      final query = FindQuery.pattern('(unclosed');
      expect(query.error, isNotNull);
      expect(query.error, isNotEmpty);
      expect(query.findIn('anything'), isEmpty);
    });

    test('a match of nothing is skipped, and the search carries on', () {
      // Every position matches here, and none of them is something the bar
      // could highlight or replace.
      expect(FindQuery.pattern('x*').findIn('abc'), isEmpty);
      // A real match before an empty one is kept, and so is one after it.
      expect(FindQuery.pattern('a*').findIn('aab'), [
        const TextMatch(start: 0, end: 2),
      ]);
    });

    test('patterns respect the match cap', () {
      final query = FindQuery.pattern('.');
      expect(query.findIn('a' * 50, limit: 10), hasLength(10));
    });

    test('a pattern anchors to a line, not to the whole buffer', () {
      final query = FindQuery.pattern(r'^#');
      expect(query.findIn('# one\ntwo\n# three'), hasLength(2));
    });
  });
}
