import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  group('leading inline flags', () {
    test('(?i) forces case-insensitive matching', () {
      final pattern = FindPattern('(?i)cat', caseSensitive: true);
      expect(pattern.findAll('CAT cat').length, 2);
    });

    test('(?s) lets dot match line breaks', () {
      expect(FindPattern('a.b').findAll('a\nb'), isEmpty);
      expect(FindPattern('(?s)a.b').findAll('a\nb'), hasLength(1));
    });

    test('(?m) is accepted and anchors still read per line', () {
      expect(FindPattern('(?m)^b').findAll('a\nb'), hasLength(1));
      expect(FindPattern('(?is)^a.b').findAll('A\nB'), hasLength(1));
    });

    test('only leading flags are special', () {
      // A flag group mid-pattern keeps the engine's meaning: Dart rejects a
      // bare (?m) there, proving leading-flag stripping left it alone.
      expect(() => FindPattern('a(?m)b'), throwsA(isA<FormatException>()));
    });
  });

  group('patternHintFor', () {
    test('names each PCRE habit with its Dart form', () {
      expect(patternHintFor('(?P<n>a)'), contains('(?<name>'));
      expect(patternHintFor('(?>a)'), contains('(?:'));
      expect(patternHintFor('a*+'), contains('Possessive'));
      expect(patternHintFor('[[:alpha:]]'), contains('POSIX'));
      expect(patternHintFor(r'\Astart'), contains('^'));
      expect(patternHintFor(r'\x{41}'), contains(r'\u{NNNN}'));
      expect(patternHintFor('(?x) a b'), contains('(?x)'));
      expect(patternHintFor(r'a\rb'), contains(r'\r?\n'));
    });

    test('plain Dart patterns need no hint', () {
      expect(patternHintFor(r'\bTODO\b'), isNull);
      expect(patternHintFor(r'(?<year>\d{4})'), isNull);
    });
  });

  group('buildReplacementPreview', () {
    test('expands the template and lists capture groups', () {
      final match = RegExp(r'(\w+)@(\w+)').firstMatch('a@b')!;
      final preview = buildReplacementPreview(r'$2 at $1', match);
      expect(preview.expanded, 'b at a');
      expect([
        for (final group in preview.groups) group.label,
      ], containsAll([r'$0', r'$1', r'$2']));
      expect(preview.matchStart, 0);
      expect(preview.matchEnd, 3);
    });

    test('truncates long expansions and group values', () {
      final match = RegExp(r'(a+)').firstMatch('a' * 200)!;
      final preview = buildReplacementPreview('${'x' * 200}\$1', match);
      expect(preview.expanded.length, lessThanOrEqualTo(121));
      expect(preview.expanded, endsWith('…'));
      for (final group in preview.groups) {
        expect(
          group.value.length,
          lessThanOrEqualTo(replacementPreviewGroupValueLimit + 1),
        );
      }
    });

    test('bounds the group list', () {
      final match = RegExp('(a)(b)(c)(d)(e)(f)(g)(h)').firstMatch('abcdefgh')!;
      final preview = buildReplacementPreview(r'$0', match);
      expect(
        preview.groups.length,
        lessThanOrEqualTo(replacementPreviewGroupLimit + 1),
      );
    });
  });

  group('replacement backslashes stay literal (owner decision)', () {
    String expand(String source, String text, String template) =>
        expandPatternReplacement(template, RegExp(source).firstMatch(text)!);

    test(r'\n, \t, \1, \U and friends do not expand', () {
      expect(expand(r'(a)(b)', 'ab', r'\n'), r'\n');
      expect(expand(r'(a)(b)', 'ab', r'\1'), r'\1');
      expect(expand(r'(a)(b)', 'ab', r'\U1'), r'\U1');
      expect(expand(r'(a)(b)', 'ab', r'\t$1'), r'\t$1'.replaceAll(r'$1', 'a'));
      expect(expand(r'(a)', 'a', r'&'), '&');
      expect(expand(r'(a)', 'a', r'\P<name>'), r'\P<name>');
    });

    test(r'only dollar forms expand; $$ is a dollar', () {
      expect(expand(r'(a)-(b)', 'a-b', r'$2/$1'), 'b/a');
      expect(expand(r'(a)', 'a', r'$$$1'), r'$a');
      expect(FindPattern(r'(a)-(b)').replaceAll('a-b', r'\n$1')?.text, r'\na');
    });
  });

  group('PatternWorker.previewReplacement', () {
    test('previews the match at the offset with groups', () async {
      final worker = PatternWorker();
      addTearDown(worker.dispose);
      final outcome = await worker.previewReplacement(
        'a@b x',
        r'(\w+)@(\w+)',
        r'$2/$1',
        0,
      );
      expect(outcome, isA<PatternCompleted<ReplacementPreview?>>());
      final preview = (outcome as PatternCompleted<ReplacementPreview?>).value!;
      expect(preview.expanded, 'b/a');
      expect(preview.groups, isNotEmpty);
    });

    test('null when no reportable match starts there', () async {
      final worker = PatternWorker();
      addTearDown(worker.dispose);
      final outcome = await worker.previewReplacement('abc', 'b', 'x', 0);
      expect(outcome, isA<PatternCompleted<ReplacementPreview?>>());
      expect((outcome as PatternCompleted<ReplacementPreview?>).value, isNull);
    });

    test('a bad pattern reports PatternUnusable', () async {
      final worker = PatternWorker();
      addTearDown(worker.dispose);
      final outcome = await worker.previewReplacement(
        'abc',
        '(unclosed',
        'x',
        0,
      );
      expect(
        outcome,
        isA<PatternFailed<ReplacementPreview?>>().having(
          (o) => o.failure,
          'failure',
          isA<PatternUnusable>(),
        ),
      );
    });
  });
}
