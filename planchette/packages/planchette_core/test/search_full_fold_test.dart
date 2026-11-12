import 'package:planchette_core/planchette_core.dart';
import 'package:planchette_core/src/search_fold.dart';
import 'package:test/test.dart';

String _lower(String value) => value.toLowerCase();

void main() {
  group('a case-insensitive search folds ß and ligatures', () {
    test('STRASSE finds straße, and straße finds STRASSE', () {
      expect(searchText('Die Straße', 'STRASSE').matches, [
        const TextMatch(start: 4, end: 10),
      ]);
      expect(searchText('DIE STRASSE', 'straße').matches, [
        const TextMatch(start: 4, end: 11),
      ]);
      expect(
        searchText('Die Straße', 'STRASSE').caseFolding,
        CaseFolding.exact,
      );
    });

    test('capital sharp s and ligatures fold too', () {
      expect(searchText('GROẞ', 'gross').matches, [
        const TextMatch(start: 0, end: 4),
      ]);
      expect(searchText('a ﬁle', 'FILE').matches, [
        const TextMatch(start: 2, end: 5),
      ]);
      expect(searchText('oﬃce', 'office').matches, [
        const TextMatch(start: 0, end: 4),
      ]);
    });

    test('offsets after an expansion still address the original', () {
      const text = 'ß x ß x';
      expect(searchText(text, 'x').matches, [
        const TextMatch(start: 2, end: 3),
        const TextMatch(start: 6, end: 7),
      ]);
    });

    test('a match inside one expansion covers the whole character once', () {
      // "s" is found twice in the fold "ss" of one ß; both are that ß.
      expect(findSearchMatches('ß', 's'), [const TextMatch(start: 0, end: 1)]);
      expect(findSearchMatches('ßs', 's'), [
        const TextMatch(start: 0, end: 1),
        const TextMatch(start: 1, end: 2),
      ]);
      expect(findSearchMatches('ß', 's', reverse: true), [
        const TextMatch(start: 0, end: 1),
      ]);
    });

    test('start, scope, reverse and whole word use original offsets', () {
      const text = 'Maß ss Maß';
      expect(findSearchMatches(text, 'MASS', start: 1), [
        const TextMatch(start: 7, end: 10),
      ]);
      expect(findSearchMatches(text, 'mass', scope: (start: 0, end: 6)), [
        const TextMatch(start: 0, end: 3),
      ]);
      expect(findSearchMatches(text, 'mass', start: 7, reverse: true), [
        const TextMatch(start: 0, end: 3),
      ]);
      expect(findSearchMatches(text, 'ss', wholeWord: true), [
        const TextMatch(start: 4, end: 6),
      ]);
    });

    test('Greek final sigma keeps working through a host fold', () {
      expect(
        searchText(
          'η σοφος ß',
          'ΣΟΦΟΣ',
          fold: (value) => value.toLowerCase().replaceAll('ς', 'σ'),
        ).matches,
        [const TextMatch(start: 2, end: 7)],
      );
    });

    test('text with nothing to expand matches as before', () {
      expect(findSearchMatches('ÄÖÜ äöü', 'äöü'), [
        const TextMatch(start: 0, end: 3),
        const TextMatch(start: 4, end: 7),
      ]);
    });
  });

  group('foldDocumentForSearch', () {
    test('builds no map for a document with no expanding character', () {
      final folded = foldDocumentForSearch('Plain ASCII and Ünïcode', _lower);
      expect(folded!.isMapped, isFalse);
      expect(folded.text, 'plain ascii and ünïcode');
    });

    test('maps folded offsets back across expansions', () {
      final folded = foldDocumentForSearch('aßbﬃc', _lower)!;
      expect(folded.text, 'assbffic');
      expect(folded.isMapped, isTrue);
      expect(folded.folded(2), 3);
      expect(folded.folded(4), 7);
      expect(folded.originalStart(2), 1);
      expect(folded.originalEnd(2), 2);
      expect(folded.originalStart(7), 4);
      expect(folded.originalEnd(8), 5);
    });

    test('gives up on a host fold that changes a run\'s length', () {
      expect(
        foldDocumentForSearch(
          'ß and x',
          (value) => value.replaceAll('x', 'xx'),
        ),
        isNull,
      );
    });
  });
}
