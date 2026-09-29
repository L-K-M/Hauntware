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
      final worker = PatternWorker(budget: const Duration(seconds: 30));
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

    test('dispose cancels a running request', () async {
      final worker = PatternWorker(budget: const Duration(seconds: 30));
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
}
