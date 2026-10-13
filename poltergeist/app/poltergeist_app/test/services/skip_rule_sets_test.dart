import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/skip_rule_sets.dart';

SkipRuleSet _set(String name, List<String> patterns) =>
    SkipRuleSet(name: name, patterns: patterns);

void main() {
  group('decoding', () {
    test('round-trips through JSON', () {
      final set = _set('Web', ['node_modules/', '*.log']);
      expect(SkipRuleSet.fromJson(set.toJson()), set);
    });

    test('a set with no usable pattern is no set', () {
      for (final patterns in [
        <Object>[],
        [1, true],
        ['', '  '],
        ['# only a comment'],
      ]) {
        expect(
          SkipRuleSet.fromJson({'name': 'Media', 'patterns': patterns}),
          isNull,
          reason: '$patterns',
        );
      }
    });

    test('the name is trimmed however the set is made', () {
      expect(SkipRuleSet(name: '  Web ', patterns: ['*.log']).name, 'Web');
    });

    test('rejects what is not a set and cleans what is', () {
      expect(SkipRuleSet.fromJson('Web'), isNull);
      expect(SkipRuleSet.fromJson({'name': '  ', 'patterns': []}), isNull);
      expect(SkipRuleSet.fromJson({'name': 'Web'}), isNull);
      expect(
        SkipRuleSet.fromJson({'name': 'Web', 'patterns': '*.log'}),
        isNull,
      );
      expect(
        SkipRuleSet.fromJson({
          'name': ' Web ',
          'patterns': [' *.log ', 3, '', 'build/'],
        }),
        _set('Web', ['*.log', 'build/']),
      );
    });

    test('a damaged list keeps every set it still can', () {
      expect(decodeSkipRuleSets('nope'), isEmpty);
      expect(
        decodeSkipRuleSets([
          {
            'name': 'Web',
            'patterns': ['*.log'],
          },
          'junk',
          {
            'name': 'web',
            'patterns': ['other/'],
          },
          {
            'name': 'Docs',
            'patterns': ['_site/'],
          },
        ]),
        [
          _set('Web', ['*.log']),
          _set('Docs', ['_site/']),
        ],
      );
    });
  });

  group('appending a set to a pair', () {
    test('keeps the pair lines and adds only the ones it lacks', () {
      expect(
        appendSkipRules(
          ['*.log', 'build/'],
          ['build/', 'node_modules/', ' *.log ', '.cache/'],
        ),
        ['*.log', 'build/', 'node_modules/', '.cache/'],
      );
    });

    test('never moves a line, so a pair re-include survives', () {
      // A second `*.log` below `!debug.log` would exclude debug.log again.
      expect(appendSkipRules(['*.log', '!debug.log'], ['*.log', 'tmp/']), [
        '*.log',
        '!debug.log',
        'tmp/',
      ]);
    });

    test('drops blank lines on both sides', () {
      expect(appendSkipRules(['', ' a ', ''], ['', 'b']), ['a', 'b']);
    });
  });

  test('lines read as the dialogs save them', () {
    expect(skipRuleLines(' a \n\n  \nb\n'), ['a', 'b']);
  });

  test('comment lines alone are not a pattern', () {
    expect(hasSkipPattern(['# web', '  ']), isFalse);
    expect(hasSkipPattern(['# web', 'node_modules/']), isTrue);
  });

  group('the set list', () {
    final sets = [
      _set('Web', ['*.log']),
      _set('Docs', ['_site/']),
    ];

    test('finds a set by name, ignoring case and spaces', () {
      expect(skipRuleSetNamed(sets, ' docs '), sets[1]);
      expect(skipRuleSetNamed(sets, 'Media'), isNull);
    });

    test('adds a new set at the end', () {
      final media = _set('Media', ['*.mov']);
      expect(putSkipRuleSetInto(sets, media), [...sets, media]);
    });

    test('an edit or a rename keeps the set in place', () {
      final edited = _set('Web', ['*.log', 'dist/']);
      expect(putSkipRuleSetInto(sets, edited, replacing: 'Web'), [
        edited,
        sets[1],
      ]);

      final renamed = _set('Site', ['*.log']);
      expect(putSkipRuleSetInto(sets, renamed, replacing: 'Web'), [
        renamed,
        sets[1],
      ]);
    });

    test('refuses a name another set holds, ignoring case', () {
      expect(
        () => putSkipRuleSetInto(sets, _set('DOCS', ['public/'])),
        throwsA(
          isA<SkipRuleSetNameTaken>().having((e) => e.name, 'name', 'Docs'),
        ),
      );
      expect(
        () => putSkipRuleSetInto(sets, _set('docs', ['x/']), replacing: 'Web'),
        throwsA(isA<SkipRuleSetNameTaken>()),
      );
      // A refused save leaves the list it was given as it was.
      expect(sets, [
        _set('Web', ['*.log']),
        _set('Docs', ['_site/']),
      ]);
      // A set may keep its own name in another case.
      expect(
        putSkipRuleSetInto(sets, _set('WEB', ['*.log']), replacing: 'web'),
        [
          _set('WEB', ['*.log']),
          sets[1],
        ],
      );
    });

    test('removes a set by name', () {
      expect(removeSkipRuleSetFrom(sets, 'web'), [sets[1]]);
      expect(removeSkipRuleSetFrom(sets, 'Media'), sets);
    });
  });
}
