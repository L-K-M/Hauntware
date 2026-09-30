import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget _app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

/// A controller whose tool runs need not wait out the undo merge window.
/// Worker-backed calls still take real time: the count debounce and the
/// isolate round-trip are real, so tests await real delays for them.
EditorController _controller(
  String text, {
  int caret = 0,
  void Function(String)? onNewDocument,
}) {
  final c = EditorController(
    displayPath: 'test.txt',
    initialText: text,
    undoQuiet: Duration.zero,
  );
  addTearDown(c.dispose);
  c.onNewDocument = onNewDocument;
  c.text.selection = TextSelection.collapsed(offset: caret);
  return c;
}

/// Waits out the line count's settle delay and the worker's answer, in a
/// plain test where both run on real time.
Future<void> _settleCount(EditorController c) async {
  for (var i = 0; i < 200 && c.lineCountPending; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(c.lineCountPending, isFalse);
}

/// The same inside a widget test: fake time fires the debounce, real time
/// lets the worker answer.
Future<void> _settleCountInWidgets(
  WidgetTester tester,
  EditorController c,
) async {
  await tester.pump(const Duration(milliseconds: 200));
  for (var i = 0; i < 500 && c.lineCountPending; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(c.lineCountPending, isFalse);
  await tester.pump();
}

void main() {
  group('openFindTool', () {
    test('opens the find bar with the line-action row, focused', () {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('keepLinesMatching');

      expect(c.searchOpen, isTrue);
      expect(c.lineActionsOpen, isTrue);
      expect(c.extractOpen, isFalse);
    });

    test('opens the extraction row for extractMatches', () {
      final c = _controller('one');
      c.openFindTool('extractMatches');

      expect(c.extractOpen, isTrue);
      expect(c.lineActionsOpen, isFalse);
    });

    test('rejects tools that do not use the find bar', () {
      final c = _controller('one');
      expect(() => c.openFindTool('sortLines'), throwsArgumentError);
    });

    test('a plain Find clears the rows again', () {
      final c = _controller('one');
      c.openFindTool('keepLinesMatching');
      c.openSearch();
      expect(c.lineActionsOpen, isFalse);
      expect(c.searchOpen, isTrue);
    });

    test('openTextTool redirects a pattern tool to the find bar', () {
      final c = _controller('one');
      c.openTextTool('deleteLinesMatching');
      expect(c.toolBarOpen, isFalse);
      expect(c.searchOpen, isTrue);
      expect(c.lineActionsOpen, isTrue);
    });

    test('seeds the field and toggles from a recorded run', () {
      final c = _controller('one');
      c.openFindTool(
        'deleteLinesMatching',
        options: {
          'pattern': 'o+',
          'regularExpression': true,
          'caseSensitive': true,
          'wholeWord': true,
        },
      );
      expect(c.search.text, 'o+');
      expect(c.useRegularExpression, isTrue);
      expect(c.caseSensitive, isTrue);
      expect(c.wholeWord, isTrue);
    });

    test('a regular query open ignores a stale recorded pattern', () {
      final c = _controller('one');
      c.openFindTool('keepLinesMatching');
      c.openSearch();
      // openSearch prefilled from nothing: the field stays as it was,
      // with no row armed.
      expect(c.lineActionsOpen, isFalse);
      expect(c.extractOpen, isFalse);
    });
  });

  group('line count', () {
    test('counts matching lines once the debounce settles', () async {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('keepLinesMatching');
      c.search.text = 'o';
      await _settleCount(c);
      expect(c.lineActionCount, 2);
      expect(c.lineCountFailure, isNull);
    });

    test('recounts when the query changes', () async {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('keepLinesMatching');
      c.search.text = 'o';
      await _settleCount(c);
      c.search.text = 'z';
      await _settleCount(c);
      expect(c.lineActionCount, 0);
    });

    test('reports an unusable pattern as the failure', () async {
      final c = _controller('one');
      c.openFindTool('keepLinesMatching');
      c.toggleRegularExpression();
      c.search.text = '(';
      await _settleCount(c);
      expect(c.lineActionCount, isNull);
      expect(c.lineCountFailure, isA<PatternUnusable>());
    });

    test('an empty pattern reports zero matching lines', () async {
      final c = _controller('one\ntwo');
      c.openFindTool('keepLinesMatching');
      await _settleCount(c);
      expect(c.lineActionCount, 0);
    });

    test('counts extraction entries for the extract row', () async {
      final c = _controller('a1 b\nc2 d3');
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'\d';
      await _settleCount(c);
      expect(c.lineActionCount, 3);
      c.setExtractWholeLines(true);
      await _settleCount(c);
      expect(c.lineActionCount, 2);
    });
  });

  group('applyLineFilter', () {
    test('keep drops the non-matching lines', () async {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('keepLinesMatching');
      c.search.text = 'o';
      final outcome = await c.applyLineFilter(keep: true);

      expect(outcome, isA<TextToolChanged>());
      expect(c.text.text, 'one\ntwo');
      expect(c.searchOpen, isFalse);
      expect(c.toolReport?.tool.id, 'keepLinesMatching');
      expect(c.toolReport?.ranOn, TextToolRanOn.document);
      expect(c.toolHistory.last?.toolId, 'keepLinesMatching');
      expect(c.toolHistory.last?.options['pattern'], 'o');
    });

    test('delete drops the matching lines', () async {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('deleteLinesMatching');
      c.search.text = 'o';
      await c.applyLineFilter(keep: false);

      expect(c.text.text, 'three');
      expect(c.toolReport?.tool.id, 'deleteLinesMatching');
    });

    test('ignores the live selection the find left behind', () async {
      final c = _controller('one\ntwo\nthree');
      c.openFindTool('keepLinesMatching');
      c.search.text = 'three';
      // The active match becomes the selection; the filter must still
      // span the document.
      c.nextMatch();
      await c.applyLineFilter(keep: true);
      expect(c.text.text, 'three');
    });

    test('refuses an empty pattern without touching the buffer', () async {
      final c = _controller('one\ntwo');
      c.openFindTool('keepLinesMatching');
      final outcome = await c.applyLineFilter(keep: true);
      expect(
        outcome,
        isA<TextToolRefused>().having(
          (o) => o.reason,
          'reason',
          TextToolRefusal.noPattern,
        ),
      );
      expect(c.text.text, 'one\ntwo');
    });

    test('refuses a pattern that does not compile', () async {
      final c = _controller('one\ntwo');
      c.openFindTool('keepLinesMatching');
      c.toggleRegularExpression();
      c.search.text = '(';
      final outcome = await c.applyLineFilter(keep: true);
      expect(
        outcome,
        isA<TextToolRefused>().having(
          (o) => o.reason,
          'reason',
          TextToolRefusal.invalidPattern,
        ),
      );
    });

    test('literal mode matches the query as text', () async {
      final c = _controller('a.b\naxb');
      c.openFindTool('keepLinesMatching');
      c.search.text = 'a.b';
      await c.applyLineFilter(keep: true);
      expect(c.text.text, 'a.b');
    });
  });

  group('applyExtract', () {
    test('in place replaces the document with the matches', () async {
      final c = _controller('a1 b\nc2');
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'\d';
      final outcome = await c.applyExtract();

      expect(outcome, isA<TextToolChanged>());
      expect(c.text.text, '1\n2');
      expect(c.toolReport?.tool.id, 'extractMatches');
    });

    test('expands each match through the template', () async {
      final c = _controller('a@b c@d');
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'(\w+)@(\w+)';
      c.extraction.text = r'$2/$1';
      await c.applyExtract();

      expect(c.text.text, 'b/a\nd/c');
    });

    test('extracts whole matching lines', () async {
      final c = _controller('a1 b\nc2');
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'\d';
      c.setExtractWholeLines(true);
      await c.applyExtract();

      expect(c.text.text, 'a1 b\nc2');
    });

    test('leaves the buffer alone with no matches', () async {
      final c = _controller('abc');
      c.openFindTool('extractMatches');
      c.search.text = 'z';
      final outcome = await c.applyExtract();
      expect(outcome, isA<TextToolUnchanged>());
      expect(c.text.text, 'abc');
    });

    test('sends the extraction to a new document', () async {
      String? extracted;
      final c = _controller('a1 b\nc2', onNewDocument: (t) => extracted = t);
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'\d';
      c.setExtractTarget('newDocument');
      final outcome = await c.applyExtract();

      expect(extracted, '1\n2');
      expect(c.text.text, 'a1 b\nc2');
      expect(outcome, isA<TextToolUnchanged>());
    });

    test('copies the extraction to the clipboard', () async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final c = _controller('a1 b\nc2');
      c.openFindTool('extractMatches');
      c.toggleRegularExpression();
      c.search.text = r'\d';
      c.setExtractTarget('clipboard');
      await c.applyExtract();

      expect(copied, '1\n2');
      expect(c.text.text, 'a1 b\nc2');
    });
  });

  group('the rows in the find bar', () {
    testWidgets('the line row shows the count and applies Keep', (
      tester,
    ) async {
      final c = EditorController(
        displayPath: 'test.txt',
        initialText: 'one\ntwo\nthree',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      c.openFindTool('keepLinesMatching');
      c.search.text = 'o';
      await _settleCountInWidgets(tester, c);

      expect(find.text('2 matching lines'), findsOneWidget);
      await tester.tap(find.text('Keep matching'));
      // The apply runs its worker on real time.
      for (var i = 0; i < 500 && c.text.text != 'one\ntwo'; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump();
      expect(c.text.text, 'one\ntwo');
      expect(c.searchOpen, isFalse);
    });

    testWidgets('the Lines control toggles the row', (tester) async {
      final c = EditorController(
        displayPath: 'test.txt',
        initialText: 'one',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      c.openSearch();
      await tester.pump();
      expect(c.lineActionsOpen, isFalse);

      await tester.tap(find.byTooltip('Line actions'));
      await tester.pump();
      expect(c.lineActionsOpen, isTrue);
      await tester.tap(find.byTooltip('Line actions'));
      await tester.pump();
      expect(c.lineActionsOpen, isFalse);
    });

    testWidgets('Escape closes the bar and its rows', (tester) async {
      final c = EditorController(
        displayPath: 'test.txt',
        initialText: 'one',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      c.openFindTool('keepLinesMatching');
      await tester.pump();
      expect(c.searchFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.searchOpen, isFalse);
      expect(c.lineActionsOpen, isFalse);
    });

    testWidgets('the extract row offers the destinations', (tester) async {
      final c = EditorController(
        displayPath: 'test.txt',
        initialText: 'a1',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      c.onNewDocument = (_) {};
      await tester.pumpWidget(_app(c));
      c.openFindTool('extractMatches');
      await _settleCountInWidgets(tester, c);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('In place'), findsWidgets);
      expect(find.text('Clipboard'), findsWidgets);
      expect(find.text('New document'), findsWidgets);
    });
  });
}
