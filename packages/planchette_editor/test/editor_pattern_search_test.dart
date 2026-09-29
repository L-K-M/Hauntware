import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Backtracks catastrophically: each extra `a` doubles the time, and this
/// many take minutes, far past any budget used here.
const _catastrophic = r'(a+)+$';
final _catastrophicText = '${'a' * 28}!';

EditorController _editor(String text, {Duration? budget}) {
  final editor = EditorController(
    displayPath: 'test.txt',
    initialText: text,
    patternSearchBudget: budget,
  );
  addTearDown(editor.dispose);
  return editor;
}

/// An open find bar in pattern mode searching for [pattern].
EditorController _searching(String text, String pattern, {Duration? budget}) {
  final editor = _editor(text, budget: budget);
  editor
    ..openSearch(replace: true)
    ..toggleRegularExpression()
    ..search.text = pattern;
  return editor;
}

/// Waits, in real time, for the pattern search on its way to arrive.
Future<void> _settled(EditorController editor) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (editor.patternSearchPending) {
    if (DateTime.now().isAfter(deadline)) fail('The search never settled.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<String> _found(EditorController editor) => [
  for (final match in editor.matches) match.textInside(editor.text.text),
];

(int, int, bool) _counter(EditorController editor) => (
  editor.matchOffset + editor.activeMatch + 1,
  editor.matchOffset + editor.matches.length,
  editor.matchesMayContinue,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pattern search', () {
    test('the toggle searches the query as a regular expression', () async {
      final editor = _editor('a TODO here\nTODO: fix, TODOS');
      editor
        ..openSearch()
        ..search.text = r'\bTODO\b';
      expect(editor.matches, isEmpty, reason: 'literal by default');

      editor.toggleRegularExpression();
      expect(editor.useRegularExpression, isTrue);
      expect(editor.patternSearchPending, isTrue);
      await _settled(editor);
      expect(_found(editor), ['TODO', 'TODO']);
      expect(_counter(editor), (1, 2, false));

      // Off again, the query is literal text at once.
      editor.toggleRegularExpression();
      expect(editor.patternSearchPending, isFalse);
      expect(editor.matches, isEmpty);
    });

    test('a pattern that does not compile says so and finds nothing', () async {
      final editor = _searching('TODO one', '(unclosed');
      expect(editor.patternSearchPending, isFalse);
      expect(editor.matches, isEmpty);
      expect(
        editor.patternFailure,
        isA<PatternUnusable>().having(
          (failure) => failure.message,
          'message',
          'Unterminated group',
        ),
      );

      editor.search.text = 'TODO';
      expect(editor.patternFailure, isNull);
      await _settled(editor);
      expect(_found(editor), ['TODO']);
    });

    test('a match of nothing is skipped and the scan carries on', () async {
      final editor = _searching('aab', 'a*');
      await _settled(editor);
      expect(editor.matches, [const TextRange(start: 0, end: 2)]);

      editor.search.text = 'x*';
      await _settled(editor);
      expect(editor.matches, isEmpty);
      expect(editor.patternFailure, isNull);
    });

    test('the case toggle applies, folding every script', () async {
      final editor = _searching('ΣΑΣ σας', 'σας');
      await _settled(editor);
      expect(_found(editor), ['ΣΑΣ', 'σας']);

      editor.toggleCaseSensitive();
      await _settled(editor);
      expect(_found(editor), ['σας']);
      expect(editor.caseFoldingLimited, isFalse);
    });

    test('whole words skip hits inside a word', () async {
      final editor = _searching('cat concat cats cat', 'c.t');
      await _settled(editor);
      expect(editor.matches, hasLength(4));

      editor.toggleWholeWord();
      await _settled(editor);
      expect(editor.matches, [
        const TextRange(start: 0, end: 3),
        const TextRange(start: 16, end: 19),
      ]);
    });

    test('pages past the highlight cap in both directions', () async {
      final occurrences = searchMatchLimit + 3;
      final editor = _searching(
        List.filled(occurrences, 'hit').join('\n'),
        'h.t',
      );
      await _settled(editor);
      expect(editor.matches, hasLength(searchMatchLimit));
      expect(_counter(editor), (1, searchMatchLimit, true));

      for (var i = 0; i < searchMatchLimit; i++) {
        editor.nextMatch();
      }
      expect(_counter(editor), (occurrences - 2, occurrences, false));
      editor
        ..nextMatch()
        ..nextMatch();
      expect(_counter(editor), (occurrences, occurrences, false));

      // Wraps to the first, then back to the last of the document.
      editor.nextMatch();
      expect(editor.text.selection.baseOffset, 0);
      expect(_counter(editor), (1, searchMatchLimit, true));
      editor.previousMatch();
      expect(_counter(editor), (occurrences, occurrences, false));
    });

    test(
      'an edit keeps the active match while the text is searched again',
      () async {
        final editor = _searching('a1 b22 c333', r'\d+');
        await _settled(editor);
        editor.nextMatch();
        expect(
          editor.matches[editor.activeMatch].textInside(editor.text.text),
          '22',
        );

        editor.text.value = const TextEditingValue(
          text: 'xx a1 b22 c333',
          selection: TextSelection.collapsed(offset: 2),
        );
        // Carried through the edit at once, searched again shortly after.
        expect(editor.patternSearchPending, isTrue);
        expect(
          editor.matches[editor.activeMatch],
          const TextRange(start: 7, end: 9),
        );
        await _settled(editor);
        expect(
          editor.matches[editor.activeMatch],
          const TextRange(start: 7, end: 9),
        );
        expect(_counter(editor), (2, 3, false));

        // A match the edit touched is dropped until the search returns.
        editor.text.value = const TextEditingValue(
          text: 'xx a1 b242 c333',
          selection: TextSelection.collapsed(offset: 9),
        );
        expect(_found(editor), ['1', '333']);
        await _settled(editor);
        expect(_found(editor), ['1', '242', '333']);
      },
    );

    test('an answer for text that has since changed is not applied', () async {
      final editor = _searching('aaa', 'a+');
      await _settled(editor);
      editor.search.text = 'b+';
      // Edited before the new search has answered.
      editor.text.value = const TextEditingValue(
        text: 'b bb',
        selection: TextSelection.collapsed(offset: 0),
      );
      await _settled(editor);
      expect(editor.matches, [
        const TextRange(start: 0, end: 1),
        const TextRange(start: 2, end: 4),
      ]);
    });

    test('Find Next with the bar closed reopens it on the pattern', () async {
      final editor = _searching('cat dog cot', 'c.t');
      await _settled(editor);
      editor.closeSearch();

      // Nothing changed, so the matches are still known.
      editor.nextMatch();
      expect(editor.searchOpen, isTrue);
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      editor.closeSearch();

      // Edited while closed: the step waits for the search.
      editor.text.value = const TextEditingValue(
        text: 'dog cut cat',
        selection: TextSelection.collapsed(offset: 0),
      );
      editor.nextMatch();
      expect(editor.patternSearchPending, isTrue);
      await _settled(editor);
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 4, extentOffset: 7),
      );
      editor.previousMatch();
      await _settled(editor);
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 8, extentOffset: 11),
      );
    });

    test(
      'a selection opens the find bar escaped, to find it as written',
      () async {
        final editor = _editor('a.b axb a.b');
        editor
          ..openSearch()
          ..toggleRegularExpression()
          ..closeSearch();
        editor.text.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 3,
        );
        editor.openSearch();
        expect(editor.search.text, r'a\.b');
        await _settled(editor);
        expect(editor.matches, [
          const TextRange(start: 0, end: 3),
          const TextRange(start: 8, end: 11),
        ]);
      },
    );

    test(r'Replace expands $n in the active match only', () async {
      final editor = _searching('x=1, y=2', r'(\w)=(\d)');
      editor.replacement.text = r'$2:$1$$';
      await _settled(editor);
      editor.replaceCurrent();
      expect(editor.text.text, r'1:x$, y=2');
      await _settled(editor);
      expect(_found(editor), ['y=2']);
      editor.replaceCurrent();
      expect(editor.text.text, r'1:x$, 2:y$');
    });

    test('Replace right after an edit waits for the search', () async {
      final editor = _searching('ab ab', 'a(b)');
      editor.replacement.text = r'[$1]';
      await _settled(editor);
      editor.text.value = const TextEditingValue(
        text: 'ab abab',
        selection: TextSelection.collapsed(offset: 7),
      );
      editor.replaceCurrent();
      expect(editor.text.text, 'ab abab', reason: 'waits for the search');
      await _settled(editor);
      expect(editor.text.text, '[b] abab');
    });

    test(
      r'Replace All covers the whole document and expands ${name}',
      () async {
        final occurrences = searchMatchLimit + 3;
        final editor = _searching(
          List.generate(occurrences, (i) => 'id-$i').join('\n'),
          r'id-(?<n>\d+)',
        );
        editor.replacement.text = r'<${n}>';
        await _settled(editor);
        expect(await editor.replaceAll(), isTrue);
        final lines = editor.text.text.split('\n');
        expect(lines.first, '<0>');
        expect(lines.last, '<${occurrences - 1}>');
        expect(lines.where((line) => line.startsWith('id-')), isEmpty);
        expect(editor.text.selection, const TextSelection.collapsed(offset: 3));
        await _settled(editor);
        expect(editor.matches, isEmpty);
      },
    );

    test('Replace All leaves a document that was edited meanwhile', () async {
      final editor = _searching('a1 a2', r'a(\d)');
      editor.replacement.text = r'b$1';
      await _settled(editor);
      final replacing = editor.replaceAll();
      editor.text.value = const TextEditingValue(
        text: 'a1 a2 a3',
        selection: TextSelection.collapsed(offset: 8),
      );
      expect(await replacing, isFalse);
      expect(editor.text.text, 'a1 a2 a3');
    });

    test('a search past its budget reports it instead of hanging', () async {
      final editor = _searching(
        _catastrophicText,
        _catastrophic,
        budget: const Duration(milliseconds: 50),
      );
      final clock = Stopwatch()..start();
      await _settled(editor);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(editor.patternFailure, isA<PatternTimedOut>());
      expect(editor.matches, isEmpty);

      // Replace All is bounded the same way and changes nothing.
      editor.replacement.text = 'x';
      expect(await editor.replaceAll(), isFalse);
      expect(editor.text.text, _catastrophicText);
      expect(editor.patternFailure, isA<PatternTimedOut>());

      // A usable pattern searches normally again.
      editor.search.text = 'a+';
      expect(editor.patternFailure, isNull);
      await _settled(editor);
      expect(editor.matches, [const TextRange(start: 0, end: 28)]);
    });

    test('literal Replace All still replaces before it returns', () {
      final editor = _editor('cat cat');
      editor
        ..openSearch(replace: true)
        ..search.text = 'cat'
        ..replacement.text = r'$1';
      final replaced = editor.replaceAll();
      expect(editor.text.text, r'$1 $1');
      expect(replaced, completion(isTrue));
    });

    test('disposing with a search on its way is safe', () async {
      final editor = EditorController(
        displayPath: 'test.txt',
        initialText: _catastrophicText,
      );
      editor
        ..openSearch()
        ..toggleRegularExpression()
        ..search.text = _catastrophic;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      editor.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}
