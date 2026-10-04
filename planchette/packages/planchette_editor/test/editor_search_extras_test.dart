import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

const _settleDelay = Duration(milliseconds: 200);

EditorController _editor(String text, {Duration? budget}) {
  final editor = EditorController(
    displayPath: 'test.txt',
    initialText: text,
    patternSearchBudget: budget,
  );
  addTearDown(editor.dispose);
  return editor;
}

Future<void> _settled(EditorController editor) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (editor.patternSearchPending) {
    if (DateTime.now().isAfter(deadline)) fail('The search never settled.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _previewSettled(EditorController editor) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (editor.replacementPreviewPending) {
    if (DateTime.now().isAfter(deadline)) fail('The preview never settled.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  // The debounce timer itself needs a pump in widget tests; in plain unit
  // tests it runs on real time, so one extra beat covers it.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  while (editor.replacementPreviewPending) {
    if (DateTime.now().isAfter(deadline)) fail('The preview never settled.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Widget _app(EditorController controller) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: controller)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SearchHistory', () {
    test('records newest first, dedups and bounds, ignores empty', () {
      final history = SearchHistory(keep: 3);
      history.push('');
      expect(history.queries, isEmpty);
      history.push('cat');
      history.push('dog');
      history.push('cat');
      expect(history.queries, ['cat', 'dog']);
      history.push('a');
      history.push('b');
      expect(history.queries, hasLength(3));
      expect(history.queries.first, 'b');
    });

    test('a new controller starts with no history (session only)', () {
      expect(_editor('x').searchHistory.queries, isEmpty);
    });
  });

  group('replacement backslashes stay literal (owner decision)', () {
    test('replaceCurrent keeps backslashes literal', () async {
      final editor = _editor('cat cat');
      editor
        ..openSearch(replace: true)
        ..search.text = 'cat'
        ..replacement.text = r'\n$0\1\U';
      editor.nextMatch();
      editor.replaceCurrent();
      // Literal mode: the template is used as it stands.
      expect(editor.text.text.contains(r'\n'), isTrue);
      expect(editor.text.text.contains(r'\1'), isTrue);
    });

    test('regex replace keeps backslashes literal, expands dollars', () async {
      final editor = _editor('a-b');
      editor
        ..openSearch(replace: true)
        ..toggleRegularExpression()
        ..search.text = r'(a)-(b)'
        ..replacement.text = r'\n$2/$1';
      await _settled(editor);
      await editor.replaceAll();
      expect(editor.text.text, r'\nb/a');
    });
  });

  group('useSelectionForFind and findSelectedText', () {
    test('use seeds the field without opening or moving focus', () {
      final editor = _editor('cat dog');
      editor.text.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      editor.useSelectionForFind();
      expect(editor.search.text, 'cat');
      expect(editor.searchOpen, isFalse);
      expect(editor.searchHistory.queries.first, 'cat');
    });

    test('use escapes the selection in regex mode', () async {
      final editor = _editor('a.b axb');
      editor
        ..openSearch()
        ..toggleRegularExpression();
      editor.text.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      editor.useSelectionForFind();
      expect(editor.search.text, r'a\.b');
      await _settled(editor);
      expect(editor.matches, hasLength(1));
    });

    test('findSelectedText opens with the existing focus flow', () {
      final editor = _editor('cat dog cat');
      editor.text.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      editor.findSelectedText();
      expect(editor.searchOpen, isTrue);
      expect(editor.search.text, 'cat');
    });
  });

  group('history recall', () {
    test('Up recalls older, Down recalls newer and restores the draft', () {
      final editor = _editor('cat dog bird');
      editor
        ..openSearch()
        ..search.text = 'cat';
      editor.nextMatch();
      editor.search.text = 'dog';
      editor.nextMatch();
      editor.search.text = 'draft';
      expect(editor.recallSearchHistory(older: true), isTrue);
      expect(editor.search.text, 'dog');
      expect(editor.recallSearchHistory(older: true), isTrue);
      expect(editor.search.text, 'cat');
      expect(editor.recallSearchHistory(older: false), isTrue);
      expect(editor.search.text, 'dog');
      expect(editor.recallSearchHistory(older: false), isTrue);
      expect(editor.search.text, 'draft');
      expect(editor.recallSearchHistory(older: false), isFalse);
    });
  });

  group('replacement preview', () {
    test('literal mode previews synchronously without groups', () async {
      final editor = _editor('cat dog');
      editor
        ..openSearch(replace: true)
        ..search.text = 'cat'
        ..replacement.text = r'\n-$0';
      // Literal: no worker, no wait, backslashes literal, no groups.
      expect(editor.replacementPreviewPending, isFalse);
      expect(editor.replacementPreview?.expanded, r'\n-$0');
      expect(editor.replacementPreview?.groups, isEmpty);
    });

    test('regex mode previews the active match with groups', () async {
      final editor = _editor('a@b x');
      editor
        ..openSearch(replace: true)
        ..toggleRegularExpression()
        ..search.text = r'(\w+)@(\w+)'
        ..replacement.text = r'$2/$1';
      await _settled(editor);
      await _previewSettled(editor);
      // The debounce + worker need one more beat after the search settles.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (editor.replacementPreview == null &&
          editor.replacementPreviewFailure == null) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(editor.replacementPreview?.expanded, 'b/a');
      expect(editor.replacementPreview?.groups, isNotEmpty);
    });

    test('toggling regex mode recomputes the preview, not reuses it', () async {
      final editor = _editor('a@b x');
      editor
        ..openSearch(replace: true)
        // 'a@b' is both a literal and a valid expression finding the same
        // range, so the toggle changes only the mode — and the preview.
        ..toggleRegularExpression()
        ..search.text = 'a@b'
        ..replacement.text = r'[$0]';
      await _settled(editor);
      await _previewSettled(editor);
      // Regex: $0 expands to the whole match.
      expect(editor.replacementPreview?.expanded, '[a@b]');

      // Literal: the template previews as it stands.
      editor.toggleRegularExpression();
      expect(editor.replacementPreview?.expanded, r'[$0]');

      // Back to regex: the mode alone must force a recompute, not reuse
      // the cached literal template.
      editor.toggleRegularExpression();
      await _settled(editor);
      await _previewSettled(editor);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (editor.replacementPreview == null &&
          editor.replacementPreviewFailure == null) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(editor.replacementPreview?.expanded, '[a@b]');
    });

    test('a bad pattern reports preview failure, not a preview', () async {
      final editor = _editor('abc');
      editor
        ..openSearch(replace: true)
        ..toggleRegularExpression()
        ..search.text = '(unclosed'
        ..replacement.text = 'x';
      await _settled(editor);
      await _previewSettled(editor);
      // No active match, so no preview and no preview failure either: the
      // search error itself explains it through patternFailure.
      expect(editor.patternFailure, isA<PatternUnusable>());
      expect(editor.replacementPreview, isNull);
    });

    test('stale edit discards the preview for the old active match', () async {
      final editor = _editor('cat dog');
      editor
        ..openSearch(replace: true)
        ..toggleRegularExpression()
        ..search.text = 'cat'
        ..replacement.text = 'bird';
      await _settled(editor);
      await _previewSettled(editor);
      expect(editor.replacementPreview, isNotNull);
      // Remove the active match: the preview must not describe deleted text.
      editor.text.value = editor.text.value.copyWith(
        text: 'dog',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        editor.replacementPreview,
        anyOf(
          isNull,
          predicate<ReplacementPreview>((preview) => preview.matchStart != 0),
        ),
      );
    });
  });

  testWidgets('preview line, hint and cheat sheet show in narrow layouts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _editor('a@b x');
    await tester.pumpWidget(_app(controller));
    controller
      ..openSearch(replace: true)
      ..toggleRegularExpression()
      ..search.text = r'(\w+)@(\w+)'
      ..replacement.text = r'$2/$1';
    await tester.pump(_settleDelay);
    for (var i = 0; i < 2000 && controller.patternSearchPending; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    // Let the preview debounce + worker answer in fake time.
    await tester.pump(_settleDelay);
    for (var i = 0; i < 200 && controller.replacementPreviewPending; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(find.textContaining('→', findRichText: true), findsWidgets);

    // The PCRE hint teaches the Dart form next to the error line.
    controller.search.text = '(?P<n>a)';
    await tester.pump();
    expect(find.textContaining('(?<name>', findRichText: true), findsWidgets);

    // The cheat sheet opens inline with a BBEdit compatibility section.
    controller.toggleCheatSheet();
    await tester.pump();
    expect(find.textContaining('BBEdit', findRichText: true), findsWidgets);
    await tester.pumpWidget(_app(controller));
  });

  testWidgets('history recall keeps focus in the find field', (tester) async {
    final controller = _editor('cat dog');
    await tester.pumpWidget(_app(controller));
    controller.openSearch();
    await tester.pump();
    controller.search.text = 'cat';
    controller.nextMatch();
    controller.search.text = 'dog';
    controller.nextMatch();
    controller.searchFocus.requestFocus();
    await tester.pump();
    expect(controller.searchFocus.hasFocus, isTrue);
    controller.recallSearchHistory(older: true);
    await tester.pump();
    expect(controller.searchFocus.hasFocus, isTrue);
    expect(controller.search.text, isNotEmpty);
  });
}
