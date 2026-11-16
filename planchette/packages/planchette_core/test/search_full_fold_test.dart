import 'dart:io';
import 'dart:isolate';

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

  group('the folded document is reused (P1)', () {
    test('for the identical text and fold, and refolded otherwise', () {
      final folded = <String>[];
      String counting(String value) {
        folded.add(value);
        return value.toLowerCase();
      }

      final text = 'Alpha Beta ${'x' * 8}';
      searchText(text, 'alpha', fold: counting);
      searchText(text, 'beta', fold: counting);
      expect(folded, [text, 'alpha', 'beta']);

      final edited = '$text!';
      expect(searchText(edited, 'BETA', fold: counting).matches, [
        const TextMatch(start: 6, end: 10),
      ]);
      expect(folded.where((value) => value == edited), hasLength(1));

      // Another fold never sees the first fold's result.
      expect(searchText(edited, 'beta', fold: (value) => value).matches, []);
    });
  });

  group('Unicode full case folding (B37)', () {
    test('strasse finds Straße with the default fold, with mapped ranges', () {
      const text = 'Die Straße und die STRASSE';
      expect(searchText(text, 'strasse').matches, [
        const TextMatch(start: 4, end: 10),
        const TextMatch(start: 19, end: 26),
      ]);
      expect(text.substring(4, 10), 'Straße');
    });

    test('every ligature and expansion from the table matches', () {
      // Latin, Armenian, Greek with iota subscript, and ŉ.
      expect(searchText('ﬀ ﬅ ﬆ', 'ST').matches, [
        const TextMatch(start: 2, end: 3),
        const TextMatch(start: 4, end: 5),
      ]);
      expect(searchText('ﬓ', 'մն').matches, [
        const TextMatch(start: 0, end: 1),
      ]);
      expect(searchText('ᾳ', 'αι').matches, [
        const TextMatch(start: 0, end: 1),
      ]);
      expect(searchText('ΑΙ', 'ᾳ').matches, [
        const TextMatch(start: 0, end: 2),
      ]);
      expect(searchText('ŉ', 'ʼN').matches, [
        const TextMatch(start: 0, end: 1),
      ]);
    });

    test('a highlight after many expansions still covers its word', () {
      final text = '${'ß' * 50} target ﬁ';
      final match = searchText(text, 'TARGET').matches.single;
      expect(text.substring(match.start, match.end), 'target');
      final ligature = searchText(text, 'FI').matches.single;
      expect(text.substring(ligature.start, ligature.end), 'ﬁ');
    });

    test('final sigma, Cherokee and Deseret fold without a host fold', () {
      expect(searchText('σοφος', 'ΣΟΦΟΣ').matches, [
        const TextMatch(start: 0, end: 5),
      ]);
      expect(searchText('ꭰ', 'Ꭰ').matches, [const TextMatch(start: 0, end: 1)]);
      // U+10400 DESERET CAPITAL LONG I folds to U+10428.
      expect(searchText('x\u{10428}', '\u{10400}').matches, [
        const TextMatch(start: 1, end: 3),
      ]);
    });

    test('a case-sensitive search does not fold', () {
      expect(searchText('Straße', 'strasse', caseSensitive: true).matches, []);
    });

    test('unicodeCaseFold keeps length and leaves unchanged text alone', () {
      const plain = 'already folded text';
      expect(identical(unicodeCaseFold(plain), plain), isTrue);
      expect(unicodeCaseFold('ÀΣ\u{10400}\ud800'), 'àσ\u{10428}\ud800');
      // Turkic tailoring is not applied; İ expands in the search instead.
      expect(unicodeCaseFold('I'), 'i');
    });

    test(
      'matches the pinned CaseFolding.txt for every C and F mapping',
      () async {
        final library = await Isolate.resolvePackageUri(
          Uri.parse('package:planchette_core/'),
        );
        final source = File.fromUri(
          library!.resolve(
            '../tool/unicode/CaseFolding-$unicodeCaseFoldingVersion.txt',
          ),
        );
        var common = 0;
        var full = 0;
        for (final line in source.readAsLinesSync()) {
          if (line.isEmpty || line.startsWith('#')) continue;
          final fields = line.split(';').map((field) => field.trim()).toList();
          final from = String.fromCharCode(int.parse(fields[0], radix: 16));
          final to = String.fromCharCodes([
            for (final value in fields[2].split(' '))
              int.parse(value, radix: 16),
          ]);
          switch (fields[1]) {
            case 'C':
              expect(unicodeCaseFold(from), to, reason: fields[0]);
              common++;
            case 'F':
              expect(
                foldDocumentForSearch(from, unicodeCaseFold)!.text,
                to,
                reason: fields[0],
              );
              expect(searchText(from, to).matches, [
                TextMatch(start: 0, end: from.length),
              ], reason: fields[0]);
              full++;
          }
        }
        expect(common, greaterThan(1400));
        expect(full, 104);
      },
    );
  });
}
