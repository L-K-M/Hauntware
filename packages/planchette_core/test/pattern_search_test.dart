import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Backtracks catastrophically: every way of splitting the run of `a` among
/// the groups is tried before the `!` rules each one out, so each extra `a`
/// doubles the time. Twenty-eight of them take far longer than any budget
/// below.
const _catastrophic = r'(a+)+$';
final _catastrophicText = '${'a' * 28}!';

List<TextMatch> _all(PatternMatches matches) => [
  for (var i = 0; i < matches.length; i++) matches[i],
];

List<TextMatch> _find(
  String source,
  String text, {
  bool caseSensitive = false,
  bool wholeWord = false,
  int limit = patternMatchLimit,
}) => _all(
  FindPattern(
    source,
    caseSensitive: caseSensitive,
  ).findAll(text, wholeWord: wholeWord, limit: limit),
);

String _expand(String source, String text, String template) =>
    expandPatternReplacement(template, RegExp(source).firstMatch(text)!);

void main() {
  group('FindPattern', () {
    test('matches what the pattern says', () {
      expect(_find(r'\bTODO\b', 'a TODO here\nTODO: fix, TODOS'), [
        const TextMatch(start: 2, end: 6),
        const TextMatch(start: 12, end: 16),
      ]);
    });

    test('honours the case setting', () {
      expect(_find('todo', 'TODO fix'), hasLength(1));
      expect(_find('todo', 'TODO fix', caseSensitive: true), isEmpty);
      expect(_find('todo', 'todo fix', caseSensitive: true), hasLength(1));
    });

    test('folds case in every script', () {
      // Unicode mode folds Σ, σ and the final ς to one letter, which
      // lowercasing alone does not.
      expect(_find('ΣΑΣ', 'σας'), hasLength(1));
      expect(_find('ΣΑΣ', 'σας', caseSensitive: true), isEmpty);
    });

    test('anchors to lines, not to the whole buffer', () {
      expect(_find('^#', '# one\ntwo\n# three'), hasLength(2));
      expect(_find(r'e$', 'one\nthree'), hasLength(2));
    });

    test('reads characters, not halves of surrogate pairs', () {
      expect(_find('^.\$', '😀'), [const TextMatch(start: 0, end: 2)]);
    });

    test('an invalid pattern throws a FormatException that says why', () {
      expect(
        () => FindPattern('(unclosed'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            isNotEmpty,
          ),
        ),
      );
    });

    test('a match of nothing is skipped, and the search carries on', () {
      // Every position matches here, and none of them is something the bar
      // could highlight or replace.
      expect(_find('x*', 'abc'), isEmpty);
      expect(_find('^', 'a\nb'), isEmpty);
      // A real match before an empty one is kept, and so is one after it.
      expect(_find('a*', 'aab'), [const TextMatch(start: 0, end: 2)]);
      expect(_find('a*', 'baab'), [const TextMatch(start: 1, end: 3)]);
    });

    test('whole words filter the way literal search does', () {
      expect(_find('cat', 'cat concat cats cat', wholeWord: true), [
        const TextMatch(start: 0, end: 3),
        const TextMatch(start: 16, end: 19),
      ]);
      // A rejected hit can hide a whole word that starts inside it, as in
      // literal search: `a a` in `aa a a` is rejected at 1 and found at 3.
      expect(_find('a a', 'aa a a', wholeWord: true), [
        const TextMatch(start: 3, end: 6),
      ]);
      // Letters of any script are word content.
      expect(_find('кот', 'котик кот', wholeWord: true), [
        const TextMatch(start: 6, end: 9),
      ]);
    });

    test('stops at the limit and says there were more', () {
      final capped = FindPattern('.').findAll('a' * 50, limit: 10);
      expect(capped.length, 10);
      expect(capped.capped, isTrue);
      final exact = FindPattern('.').findAll('a' * 10, limit: 10);
      expect(exact.length, 10);
      expect(exact.capped, isFalse);
    });

    test('matchAt only accepts a match find would report', () {
      final pattern = FindPattern(r'\w+');
      expect(pattern.matchAt('cat dog', 4)?.group(0), 'dog');
      expect(pattern.matchAt('cat dog', 3), isNull);
      expect(FindPattern('x*').matchAt('abc', 0), isNull);
      expect(FindPattern('at').matchAt('cat', 1), isNotNull);
      expect(FindPattern('at').matchAt('cat', 1, wholeWord: true), isNull);
    });

    test('replaceAll expands every match and reports the first', () {
      final replaced = FindPattern(
        r'(\w+)@(\w+)',
      ).replaceAll('x a@b y c@d', r'$2 at $1');
      expect(replaced?.text, 'x b at a y d at c');
      expect(replaced?.count, 2);
      expect(replaced?.firstEnd, 'x b at a'.length);
      expect(FindPattern('zzz').replaceAll('abc', 'q'), isNull);
    });

    test('replaceAll skips empty matches and honours whole words', () {
      expect(FindPattern('a*').replaceAll('baab', '-')?.text, 'b-b');
      expect(
        FindPattern(
          'cat',
        ).replaceAll('cat concat', 'dog', wholeWord: true)?.text,
        'dog concat',
      );
    });
  });

  group('expandPatternReplacement', () {
    test(r'numbered groups: $n, ${n} and $0 for the whole match', () {
      expect(_expand(r'(\d+)-(\d+)', '12-34', r'$2-$1'), '34-12');
      expect(_expand(r'(\d+)-(\d+)', '12-34', r'${2}0'), '340');
      expect(_expand(r'(\d+)-(\d+)', '12-34', r'[$0]'), '[12-34]');
    });

    test(r'named groups: ${name}', () {
      expect(
        _expand(
          r'(?<year>\d{4})-(?<month>\d\d)',
          '2026-09',
          r'${month}/${year}',
        ),
        '09/2026',
      );
    });

    test(r'$$ is a literal dollar sign', () {
      expect(_expand(r'(\d+)', '5', r'$$$1'), r'$5');
    });

    test('two digits name a group only when it exists', () {
      final twelve = '(a)' * 12;
      expect(_expand(twelve, 'a' * 12, r'$12'), 'a');
      // With one group, `$12` is group 1 followed by a literal 2.
      expect(_expand('(a)', 'a', r'$12'), 'a2');
    });

    test('references to groups that do not exist stay as typed', () {
      expect(
        _expand('(a)', 'a', r'$2 ${nope} ${9} $x $'),
        r'$2 ${nope} ${9} $x $',
      );
    });

    test('a group that did not take part expands to nothing', () {
      expect(_expand('(a)|(b)', 'b', r'[$1][$2]'), '[][b]');
    });

    test('a template without a dollar sign is used as it stands', () {
      expect(_expand('a', 'a', r'\n'), r'\n');
    });
  });

  group('PatternMatches.afterEdit', () {
    final matches = FindPattern('ab').findAll('ab ab ab ab');

    test('keeps matches before, shifts matches after, drops touched ones', () {
      // Replace ' a' at 5..7 with 'XYZ': 'ab abXYZb ab'.
      final mapped = matches.afterEdit(start: 5, end: 7, delta: 1);
      expect(_all(mapped), [
        const TextMatch(start: 0, end: 2),
        const TextMatch(start: 3, end: 5),
        const TextMatch(start: 10, end: 12),
      ]);
    });

    test('an insertion at a match edge keeps the match', () {
      final mapped = matches.afterEdit(start: 2, end: 2, delta: 3);
      expect(_all(mapped).take(2), [
        const TextMatch(start: 0, end: 2),
        const TextMatch(start: 6, end: 8),
      ]);
    });

    test('indexAtOrAfter finds a page by binary search', () {
      expect(matches.indexAtOrAfter(0), 0);
      expect(matches.indexAtOrAfter(1), 1);
      expect(matches.indexAtOrAfter(9), 3);
      expect(matches.indexAtOrAfter(10), 4);
    });
  });

  group('PatternWorker', () {
    test('finds matches off the calling isolate', () async {
      final worker = PatternWorker();
      addTearDown(worker.dispose);
      final outcome = await worker.findAll('cat CAT cat', 'cat');
      expect(outcome, isA<PatternCompleted<PatternMatches>>());
      final matches = (outcome as PatternCompleted<PatternMatches>).value;
      expect(matches.length, 3);
    });

    test(
      'a pattern that runs past the budget is stopped and reported',
      () async {
        final worker = PatternWorker(budget: const Duration(milliseconds: 50));
        addTearDown(worker.dispose);
        final clock = Stopwatch()..start();
        final outcome = await worker.findAll(_catastrophicText, _catastrophic);
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        expect(outcome, isA<PatternFailed<PatternMatches>>());
        expect(
          (outcome as PatternFailed<PatternMatches>).failure,
          isA<PatternTimedOut>(),
        );

        // The killed worker is replaced for the next search.
        final next = await worker.findAll('abc', 'b');
        expect(next, isA<PatternCompleted<PatternMatches>>());
      },
    );

    test('replaceAll runs under the budget too', () async {
      final worker = PatternWorker(budget: const Duration(milliseconds: 50));
      addTearDown(worker.dispose);
      final slow = await worker.replaceAll(
        _catastrophicText,
        _catastrophic,
        'x',
      );
      expect(
        (slow as PatternFailed<PatternReplacement?>).failure,
        isA<PatternTimedOut>(),
      );
      final done = await worker.replaceAll('a1b2', r'(\d)', r'<$1>');
      expect(
        (done as PatternCompleted<PatternReplacement?>).value?.text,
        'a<1>b<2>',
      );
    });

    test('a newer request cancels the one still running', () async {
      final worker = PatternWorker(budget: const Duration(seconds: 2));
      addTearDown(worker.dispose);
      final stale = worker.findAll(_catastrophicText, _catastrophic);
      // Let the first request reach the worker before superseding it.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final fresh = worker.findAll('abc', 'b');
      expect(await stale, isA<PatternCancelled<PatternMatches>>());
      expect(await fresh, isA<PatternCompleted<PatternMatches>>());
    });

    test('an invalid pattern is reported, not thrown', () async {
      final worker = PatternWorker();
      addTearDown(worker.dispose);
      final outcome = await worker.findAll('abc', '(unclosed');
      expect(
        (outcome as PatternFailed<PatternMatches>).failure,
        isA<PatternUnusable>(),
      );
    });

    test('dispose while the worker starts reports only the cancel', () async {
      final worker = PatternWorker();
      final starting = worker.findAll('abc', 'b');
      worker.dispose();
      expect(await starting, isA<PatternCancelled<PatternMatches>>());
      // Let the spawn finish, so an error it left unobserved would surface.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    test('dispose cancels a running request', () async {
      final worker = PatternWorker(budget: const Duration(seconds: 2));
      final running = worker.findAll(_catastrophicText, _catastrophic);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      worker.dispose();
      expect(await running, isA<PatternCancelled<PatternMatches>>());
      expect(
        await worker.findAll('abc', 'b'),
        isA<PatternCancelled<PatternMatches>>(),
      );
    });
  });

  group('FindPattern line operations', () {
    test('counts the lines that hold a match', () {
      expect(FindPattern(r'^#').countMatchingLines('# one\ntwo\n# three'), 2);
      expect(FindPattern('nope').countMatchingLines('a\nb'), 0);
    });

    test('matches literal text when the escape constructor builds it', () {
      expect(FindPattern.literal('a.b').countMatchingLines('a.b\naxb'), 1);
    });

    test('a pattern with a line break never matches a line', () {
      expect(FindPattern(r'a\nb').countMatchingLines('a\nb'), 0);
    });

    test('keeps only matching lines, separators intact', () {
      final filtered = FindPattern(
        'o',
      ).filterMatchingLines('one\ntwo\nthree', keep: true);
      expect(filtered.text, 'one\ntwo');
      expect(filtered.matched, 2);
      expect(filtered.total, 3);
    });

    test('delete keeps the rest and sheds the dead last break', () {
      final filtered = FindPattern(
        'o',
      ).filterMatchingLines('one\ntwo\nthree', keep: false);
      expect(filtered.text, 'three');
      expect(filtered.matched, 2);
    });

    test('keeps the buffer\'s own trailing break', () {
      expect(
        FindPattern('o').filterMatchingLines('one\ntwo\n', keep: true).text,
        'one\ntwo\n',
      );
      expect(
        FindPattern(
          'z',
        ).filterMatchingLines('one\ntwo\nzone\n', keep: true).text,
        'zone\n',
      );
    });

    test('preserves mixed line endings', () {
      expect(
        FindPattern(
          'o',
        ).filterMatchingLines('one\r\ntwo\nthree', keep: true).text,
        'one\r\ntwo',
      );
    });

    test('deleting everything leaves an empty buffer', () {
      final filtered = FindPattern(
        'o',
      ).filterMatchingLines('one\ntwo', keep: false);
      expect(filtered.text, '');
      expect(filtered.matched, 2);
      expect(filtered.total, 2);
    });

    group('scoped', () {
      const text = 'cat one\ncat two\ncat three';
      //                    0123456789012345678901234
      // 'cat' lines at 0-6, 8-14 and 16-24.

      test('only the touched lines are filtered', () {
        // Keep's in-scope filter leaves the pass-through lines alone.
        final kept = FindPattern(
          'cat',
        ).filterMatchingLines(text, keep: true, scope: (start: 8, end: 15));
        expect(kept.text, text);
        expect(kept.matched, 1);
        expect(kept.total, 1);
        // The in-scope delete drops the line and its break together.
        final dropped = FindPattern(
          'cat',
        ).filterMatchingLines(text, keep: false, scope: (start: 8, end: 15));
        expect(dropped.text, 'cat one\ncat three');
        expect(dropped.matched, 1);
        expect(dropped.total, 1);
      });

      test('a partial selection still covers whole lines', () {
        // From inside 'one' to inside 'two': both lines are covered.
        final kept = FindPattern(
          'cat',
        ).filterMatchingLines(text, keep: true, scope: (start: 2, end: 12));
        expect(kept.text, 'cat one\ncat two\ncat three');
        expect(kept.matched, 2);
        expect(kept.total, 2);
      });

      test('a scope reaching the buffer end sheds the dead last break', () {
        final dropped = FindPattern('cat').filterMatchingLines(
          'cat one\ncat two',
          keep: false,
          scope: (start: 8, end: 15),
        );
        expect(dropped.text, 'cat one');
      });

      test('counting and extraction honour the scope', () {
        expect(
          FindPattern(
            'cat',
          ).countMatchingLines(text, scope: (start: 8, end: 15)),
          1,
        );
        // wholeLines takes the lines the scope touches; a single match
        // inside keeps the line.
        expect(
          FindPattern(
            'two',
          ).extractMatches(text, scope: (start: 8, end: 15), wholeLines: true),
          ['cat two'],
        );
      });
    });

    test('extracts each match', () {
      expect(FindPattern(r'\d+').extractMatches('a1 b22\nc333'), [
        '1',
        '22',
        '333',
      ]);
    });

    test('extracts whole matching lines instead', () {
      expect(FindPattern(r'\d+').extractMatches('a1 b\nc2', wholeLines: true), [
        'a1 b',
        'c2',
      ]);
    });

    test('expands each match through a template', () {
      expect(
        FindPattern(
          r'(\w+)@(\w+)',
        ).extractMatches('a@b x c@d', template: r'$2/$1'),
        ['b/a', 'd/c'],
      );
    });

    test('honours whole words on lines and matches', () {
      expect(FindPattern('cat').countMatchingLines('cat\nconcat\ncat!'), 3);
      expect(
        FindPattern(
          'cat',
        ).countMatchingLines('cat\nconcat\ncat!', wholeWord: true),
        2,
      );
      expect(
        FindPattern('cat').extractMatches('cat concat cat!', wholeWord: true),
        ['cat', 'cat'],
      );
    });
  });

  group('PatternWorker line and extract requests', () {
    test('counts matching lines off the calling isolate', () async {
      final worker = PatternWorker();
      try {
        final outcome = await worker.countMatchingLines(
          '# one\ntwo\n# three',
          '^#',
        );
        expect(
          outcome,
          isA<PatternCompleted<int>>().having((o) => o.value, 'value', 2),
        );
      } finally {
        worker.dispose();
      }
    });

    test('filters lines, keeping or deleting matches', () async {
      final worker = PatternWorker();
      try {
        final kept = await worker.filterLines(
          'one\ntwo\nthree',
          'o',
          keep: true,
        );
        expect(kept, isA<PatternCompleted<PatternLineFilter>>());
        expect(
          (kept as PatternCompleted<PatternLineFilter>).value.text,
          'one\ntwo',
        );
        final dropped = await worker.filterLines(
          'one\ntwo\nthree',
          'o',
          keep: false,
        );
        expect(
          (dropped as PatternCompleted<PatternLineFilter>).value.text,
          'three',
        );
      } finally {
        worker.dispose();
      }
    });

    test('extracts matches and whole lines', () async {
      final worker = PatternWorker();
      try {
        final matches = await worker.extractMatches('a1 b\nc2', r'\d+');
        expect((matches as PatternCompleted<List<String>>).value, ['1', '2']);
        final lines = await worker.extractMatches(
          'a1 b\nc2',
          r'\d+',
          wholeLines: true,
        );
        expect((lines as PatternCompleted<List<String>>).value, ['a1 b', 'c2']);
      } finally {
        worker.dispose();
      }
    });

    test('literal requests match the source as text', () async {
      final worker = PatternWorker();
      try {
        final outcome = await worker.countMatchingLines(
          'a.b\naxb',
          'a.b',
          literal: true,
        );
        expect((outcome as PatternCompleted<int>).value, 1);
      } finally {
        worker.dispose();
      }
    });

    test('a bad pattern reports PatternUnusable for line requests', () async {
      final worker = PatternWorker();
      try {
        final outcome = await worker.filterLines('a\nb', '(', keep: true);
        expect(
          outcome,
          isA<PatternFailed<PatternLineFilter>>().having(
            (o) => o.failure,
            'failure',
            isA<PatternUnusable>(),
          ),
        );
      } finally {
        worker.dispose();
      }
    });

    test('a newer count cancels the older request', () async {
      final worker = PatternWorker();
      try {
        final first = worker.countMatchingLines(
          _catastrophicText,
          _catastrophic,
        );
        final second = await worker.countMatchingLines('a\nb', 'a');
        expect(second, isA<PatternCompleted<int>>());
        expect(await first, isA<PatternCancelled<int>>());
      } finally {
        worker.dispose();
      }
    });

    test('requests honour a stored scope', () async {
      final worker = PatternWorker();
      try {
        //                                012345678901234567890123
        const text = 'cat one\ncat two\ncat three';
        const scope = (start: 8, end: 15); // the 'cat two' line
        final counted = await worker.countMatchingLines(
          text,
          'cat',
          scope: scope,
        );
        expect((counted as PatternCompleted<int>).value, 1);

        final filtered = await worker.filterLines(
          text,
          'cat',
          keep: false,
          scope: scope,
        );
        expect(
          (filtered as PatternCompleted<PatternLineFilter>).value.text,
          'cat one\ncat three',
        );

        final extracted = await worker.extractMatches(
          'cat one cat two cat',
          'cat',
          scope: (start: 4, end: 17),
        );
        // 8-11 is in; 16-19 straddles the scope's end and stays out.
        expect((extracted as PatternCompleted<List<String>>).value, ['cat']);

        final replaced = await worker.replaceAll(
          'cat one cat two cat',
          'cat',
          'dog',
          scope: (start: 4, end: 19),
        );
        expect(
          (replaced as PatternCompleted<PatternReplacement?>).value?.text,
          'cat one dog two dog',
        );
      } finally {
        worker.dispose();
      }
    });
  });
}
