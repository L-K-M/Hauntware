import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Past the undo-merge window a tool run waits out — the default quiet
/// period plus margin, so the tests follow the constant, not a copy of it.
final _undoWait =
    EditorController.defaultUndoQuiet + const Duration(milliseconds: 100);

Widget app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

// A tool run waits out the controller's undo-quiet window — the undo
// history's 500 ms merge window — so tests that are not about the wait run
// with a zero quiet period. The view tests instead settle the window with
// one pump before they run a tool.
Future<EditorController> pumpEditor(
  WidgetTester tester,
  String text, {
  int caret = 0,
}) async {
  final editor = EditorController(displayPath: 'notes.txt', initialText: text);
  addTearDown(editor.dispose);
  await tester.pumpWidget(app(editor));
  await tester.pump();
  editor.text.selection = TextSelection.collapsed(offset: caret);
  await tester.pump(_undoWait);
  return editor;
}

Future<TextToolOutcome?> runTool(
  WidgetTester tester,
  EditorController c,
  String id, {
  Map<String, Object?> options = const {},
}) async {
  final run = c.runTextTool(id, options: options);
  await tester.pump(_undoWait);
  return run;
}

void main() {
  group('runTextTool', () {
    EditorController controller(
      String text, {
      int caret = 0,
      int? maximumBytes,
    }) {
      final c = EditorController(
        displayPath: 'a.txt',
        initialText: text,
        maximumBytes: maximumBytes ?? defaultTextDocumentMaximumBytes,
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      c.text.selection = TextSelection.collapsed(offset: caret);
      return c;
    }

    test('applies a changed outcome and reports it', () async {
      final c = controller('b\na');

      final outcome = await c.runTextTool('sortLines');

      expect(c.text.text, 'a\nb');
      expect(outcome, isA<TextToolChanged>());
      expect(c.toolReport?.tool.id, 'sortLines');
      expect(c.toolReport?.ranOn, TextToolRanOn.document);
    });

    test('throws for a tool that is not in the catalog', () {
      final c = controller('x');
      expect(c.runTextTool('notATool'), throwsArgumentError);
    });

    test('refuses while locked or composing, without a report', () async {
      final c = controller('b\na');
      c.setEditingLocked(true);
      expect(await c.runTextTool('sortLines'), isNull);
      expect(c.toolReport, isNull);

      c.setEditingLocked(false);
      c.text.value = const TextEditingValue(
        text: 'b\na',
        selection: TextSelection.collapsed(offset: 0),
        composing: TextRange(start: 0, end: 1),
      );
      expect(await c.runTextTool('sortLines'), isNull);
      expect(c.toolReport, isNull);
    });

    test('keeps a selection and reports the selection scope', () async {
      final c = controller('hello');
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 5);

      final outcome = await c.runTextTool('uppercase');

      expect(c.text.text, 'HELLO');
      expect(
        c.text.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      expect(outcome, isA<TextToolChanged>());
      expect(c.toolReport?.ranOn, TextToolRanOn.selection);
    });

    test('a refusal reports the reason and leaves the text', () async {
      // No word touches a caret on the space.
      final c = controller('a  b', caret: 2);

      final outcome = await c.runTextTool('uppercase');

      expect(c.text.text, 'a  b');
      expect(
        outcome,
        isA<TextToolRefused>().having(
          (r) => r.reason,
          'reason',
          TextToolRefusal.noWordAtCaret,
        ),
      );
      expect(c.toolReport?.outcome, isA<TextToolRefused>());
    });

    test('an unchanged run reports nothing to change', () async {
      final c = controller('a\nb');

      final outcome = await c.runTextTool('sortLines');

      expect(c.text.text, 'a\nb');
      expect(outcome, isA<TextToolUnchanged>());
    });

    test('a refused run does not reach the history', () async {
      // No selection and a tool that needs one — the refusal must not
      // earn a Repeat/Recent slot.
      final c = controller('a  b', caret: 2);

      await c.runTextTool('uppercase');

      expect(c.toolReport?.outcome, isA<TextToolRefused>());
      expect(c.toolHistory.recent, isEmpty);
    });

    test('an unchanged run still records — it is a real run', () async {
      final c = controller('a\nb');

      await c.runTextTool('sortLines');

      expect(c.toolHistory.last?.toolId, 'sortLines');
    });

    test('the record remembers a whole-document run', () async {
      final c = controller('a\nb');
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 1);

      await c.runTextTool('sortLines', wholeDocument: true);

      expect(c.toolHistory.last?.wholeDocument, isTrue);
      expect(c.toolHistory.last?.toolId, 'sortLines');
    });

    test('an option outside its option\'s contract drops to safe', () async {
      final c = controller('b\na');
      // A caller's override can name a choice the current catalog does
      // not offer — the run falls back to the default rather than
      // throwing.
      final outcome = await c.runTextTool(
        'sortLines',
        options: {'order': 'spiral'},
      );
      expect(c.text.text, 'a\nb');
      expect(outcome, isA<TextToolChanged>());

      // An integer below the declared minimum clamps rather than running
      // a degenerate run.
      final numbered = controller('x\ny');
      await numbered.runTextTool('numberLines', options: {'step': 0});
      expect(numbered.text.text, '1. x\n2. y');
    });

    test('a run that would grow past maximumBytes is refused', () async {
      final c = controller('a\x07b', maximumBytes: 3);
      // Escaping the gremlin grows the buffer past the byte limit.
      final outcome = await c.runTextTool(
        'zapGremlins',
        options: {'action': 'escape'},
      );
      expect(c.text.text, 'a\x07b');
      expect(
        outcome,
        isA<TextToolRefused>().having(
          (r) => r.reason,
          'reason',
          TextToolRefusal.tooLarge,
        ),
      );
    });

    test('a same-length result that grows in bytes is refused', () async {
      // \x85 is one UTF-16 unit but two UTF-8 bytes; ♥ is one unit but
      // three bytes. The replacement keeps the buffer's code-unit length
      // while growing it past the byte limit — the preflight measures
      // bytes, not units.
      final c = controller('\x85\x85', maximumBytes: 5);
      final outcome = await c.runTextTool(
        'zapGremlins',
        options: {'action': 'replace', 'character': '♥'},
      );
      expect(c.text.text, '\x85\x85');
      expect(
        outcome,
        isA<TextToolRefused>().having(
          (r) => r.reason,
          'reason',
          TextToolRefusal.tooLarge,
        ),
      );
    });

    test('waits out the undo-quiet window before applying', () {
      fakeAsync((async) {
        final c = EditorController(
          displayPath: 'a.txt',
          initialText: 'b\na',
          undoQuiet: const Duration(milliseconds: 500),
        );
        addTearDown(c.dispose);
        async.flushMicrotasks();
        // A field change restarts the window; only changes that could open
        // an undo step count, so stamp one now.
        c.text.value = const TextEditingValue(
          text: 'c\nb\na',
          selection: TextSelection.collapsed(offset: 0),
        );

        var done = false;
        c.runTextTool('sortLines').then((_) => done = true);
        async.elapse(const Duration(milliseconds: 499));
        expect(done, isFalse);
        expect(c.text.text, 'c\nb\na');

        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
        expect(c.text.text, 'a\nb\nc');
      });
    });

    test('a selection-only change does not hold a tool run back', () {
      fakeAsync((async) {
        final c = EditorController(
          displayPath: 'a.txt',
          initialText: 'b\na',
          undoQuiet: const Duration(milliseconds: 500),
        );
        addTearDown(c.dispose);
        async.flushMicrotasks();
        c.text.value = const TextEditingValue(
          text: 'c\nb\na',
          selection: TextSelection.collapsed(offset: 0),
        );
        async.elapse(_undoWait);

        var done = false;
        c.text.selection = const TextSelection.collapsed(offset: 4);
        c.runTextTool('sortLines').then((_) => done = true);
        async.elapse(Duration.zero);
        expect(done, isTrue);
        expect(c.text.text, 'a\nb\nc');
      });
    });

    test('the report clears on the next field change', () async {
      final c = controller('b\na');
      await c.runTextTool('sortLines');
      expect(c.toolReport, isNotNull);

      c.text.value = const TextEditingValue(
        text: 'z',
        selection: TextSelection.collapsed(offset: 0),
      );
      expect(c.toolReport, isNull);
      // A selection-only change keeps it: it never opens an undo step.
      await c.runTextTool('sortLines');
      expect(c.toolReport, isNotNull);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      expect(c.toolReport, isNotNull);
    });

    test('an indentation tool adopts its setting', () async {
      final c = controller('\tone');
      await c.runTextTool('convertIndentationToSpaces');
      expect(c.text.text, '    one');
      expect(c.indentation, const Indentation.spaces(4));
    });
  });

  group('result notice', () {
    testWidgets('shows the report and offers an Undo button', (tester) async {
      final c = await pumpEditor(tester, 'b\na');
      c.editorFocus.requestFocus();
      await tester.pump();

      await runTool(tester, c, 'sortLines');
      expect(c.text.text, 'a\nb');
      await tester.pump(_undoWait);
      expect(find.textContaining('Sort Lines'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(c.text.text, 'b\na');
      // The undo is itself a value change, which clears the notice.
      expect(c.toolReport, isNull);
      expect(find.textContaining('Sort Lines'), findsNothing);
    });

    testWidgets('a tap on the notice dismisses it', (tester) async {
      // The pill covers the document's bottom edge; it must not swallow
      // taps there — it dismisses instead.
      final c = await pumpEditor(tester, 'b\na');
      c.editorFocus.requestFocus();
      await tester.pump();

      await runTool(tester, c, 'sortLines');
      await tester.pump(_undoWait);
      expect(c.toolReport, isNotNull);

      await tester.tap(find.textContaining('Sort Lines'));
      await tester.pump();
      expect(c.toolReport, isNull);
      expect(find.textContaining('Sort Lines'), findsNothing);
      // The text it replaced is untouched.
      expect(c.text.text, 'a\nb');
    });

    testWidgets('a refusal shows the reason and no Undo', (tester) async {
      final c = await pumpEditor(tester, 'a  b', caret: 2);
      c.editorFocus.requestFocus();
      await tester.pump();

      await runTool(tester, c, 'uppercase');
      expect(find.textContaining('no word at the caret'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect(c.editorFocus.hasFocus, isTrue);
    });

    testWidgets('the notice leaves with the next edit', (tester) async {
      final c = await pumpEditor(tester, 'b\na');

      await runTool(tester, c, 'sortLines');
      await tester.pump();
      expect(find.textContaining('Sort Lines'), findsOneWidget);

      c.text.value = const TextEditingValue(text: 'z');
      await tester.pump();
      expect(find.textContaining('Sort Lines'), findsNothing);
    });
  });

  group('tool bar', () {
    testWidgets('opens with declared options and a dry-run count', (
      tester,
    ) async {
      final c = await pumpEditor(tester, 'b\na\nc');

      c.openTextTool('sortLines');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(c.toolBarOpen, isTrue);
      expect(c.toolBarTool?.id, 'sortLines');
      expect(c.toolBarOptions['order'], 'ascending');
      expect(find.text('Order'), findsOneWidget);
      expect(find.text('Applies to'), findsOneWidget);
      expect(find.text('2 of 3 lines will move'), findsOneWidget);
    });

    testWidgets('changing an option re-runs the preview', (tester) async {
      final c = await pumpEditor(tester, 'x\nc\na\nb');
      c.openTextTool('sortLines');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('4 of 4 lines will move'), findsOneWidget);

      // 'Leave first line in place' pins x; c, a and b still reorder.
      await tester.tap(find.text('Leave first line in place'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(c.toolBarOptions['keepFirstLine'], isTrue);
      expect(find.text('3 of 4 lines will move'), findsOneWidget);
    });

    testWidgets('a text option feeds the run', (tester) async {
      final c = await pumpEditor(tester, 'a\nb');
      c.openTextTool('prefixSuffixLines');
      await tester.pump();

      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Text',
        ),
        '> ',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(c.toolBarOptions['text'], '> ');
      expect(find.text('will change 2 of 2 lines'), findsOneWidget);

      await tester.tap(find.text('Apply'));
      await tester.pump(_undoWait);
      expect(c.text.text, '> a\n> b');
      expect(c.toolBarOpen, isFalse);
    });

    testWidgets('the scope radio reruns on the whole document', (tester) async {
      final c = await pumpEditor(tester, 'c\nb\na');
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      c.openTextTool('sortLines');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('2 lines selected'), findsOneWidget);
      expect(c.toolBarWholeDocument, isFalse);

      await tester.tap(find.text('Whole document, 3 lines'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(c.toolBarWholeDocument, isTrue);

      await tester.tap(find.text('Apply'));
      await tester.pump(_undoWait);
      expect(c.text.text, 'a\nb\nc');
    });

    testWidgets('opens pre-filled with the options the tool last ran', (
      tester,
    ) async {
      final c = await pumpEditor(tester, 'b\na');
      c.toolHistory.record('sortLines', {'order': 'descending'});

      c.openTextTool('sortLines');
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.toolBarOptions['order'], 'descending');
    });

    testWidgets('opening find or go to line closes the bar', (tester) async {
      final c = await pumpEditor(tester, 'b\na');
      c.openTextTool('sortLines');
      await tester.pump();
      c.openSearch();
      await tester.pump();
      expect(c.toolBarOpen, isFalse);

      c.openTextTool('sortLines');
      await tester.pump();
      c.openGoToLine();
      await tester.pump();
      expect(c.toolBarOpen, isFalse);
    });

    testWidgets('Escape closes the bar and returns focus to the document', (
      tester,
    ) async {
      final c = await pumpEditor(tester, 'b\na');
      c.editorFocus.requestFocus();
      await tester.pump();
      c.openTextTool('sortLines');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.toolBarOpen, isFalse);
      expect(c.editorFocus.hasFocus, isTrue);
    });

    testWidgets('Escape from a bar field still closes the bar', (tester) async {
      final c = await pumpEditor(tester, 'a\nb');
      c.openTextTool('numberLines');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.toolBarOpen, isFalse);
    });

    testWidgets('Apply stays disabled while the run is refused', (
      tester,
    ) async {
      // uppercase is word/selection scoped; a caret on a space refuses.
      final c = await pumpEditor(tester, 'a  b', caret: 2);
      c.openTextTool('uppercase');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('not applied, no word at the caret'), findsOneWidget);

      final apply = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Apply'),
      );
      expect(apply.onPressed, isNull);
    });

    testWidgets('Enter in a field honours the same refused gate', (
      tester,
    ) async {
      // joinLinesWith needs a selection; without one the preview refuses
      // and a field's Enter must decline exactly like the button.
      final c = await pumpEditor(tester, 'a\nb');
      c.openTextTool('joinLinesWith');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('not applied'), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(_undoWait);
      await tester.pump();

      expect(c.toolBarOpen, isTrue);
      expect(c.toolReport, isNull);
    });

    testWidgets('the first text field takes the focus', (tester) async {
      final c = await pumpEditor(tester, 'a');
      c.openTextTool('numberLines');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final field = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Start at',
        ),
      );
      expect(field.focusNode?.hasFocus, isTrue);
      // The bar's fields count as document focus for clipboard routing.
      expect(c.textFocusNodes, contains(field.focusNode));
    });
  });

  group('history', () {
    testWidgets('a run is recorded for Repeat and Recent', (tester) async {
      final c = await pumpEditor(tester, 'b\na');
      await runTool(tester, c, 'sortLines', options: {'order': 'descending'});

      expect(c.toolHistory.last?.toolId, 'sortLines');
      expect(c.toolHistory.last?.options['order'], 'descending');
    });

    test('a shared history sees runs from every controller', () async {
      final history = TextToolHistory();
      for (final text in ['b\na', 'x']) {
        final c = EditorController(
          displayPath: 'a.txt',
          initialText: text,
          toolHistory: history,
          undoQuiet: Duration.zero,
        );
        addTearDown(c.dispose);
        await c.runTextTool('uppercase');
      }
      expect(history.recent.length, 1);
      expect(history.last?.toolId, 'uppercase');
    });
  });

  group('unicode and JSON tools', () {
    EditorController makeController(String text, {int? maximumBytes}) {
      final c = EditorController(
        displayPath: 'a.txt',
        initialText: text,
        maximumBytes: maximumBytes ?? defaultTextDocumentMaximumBytes,
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'a JSON format that would grow past maximumBytes is refused',
      () async {
        final c = makeController('{"a":1}', maximumBytes: 8);
        final outcome = await c.runTextTool('formatJson');
        expect(c.text.text, '{"a":1}');
        expect(
          outcome,
          isA<TextToolRefused>().having(
            (r) => r.reason,
            'reason',
            TextToolRefusal.tooLarge,
          ),
        );
      },
    );

    test('invalid JSON refuses with its line and column', () async {
      final c = makeController('{"a":1,}');
      final outcome = await c.runTextTool('formatJson');
      expect(c.text.text, '{"a":1,}');
      expect(
        outcome,
        isA<TextToolRefused>()
            .having((r) => r.reason, 'reason', TextToolRefusal.invalidJson)
            .having((r) => r.detail, 'detail', contains('line 1')),
      );
      expect(c.toolReport?.ranOn, TextToolRanOn.document);
    });

    test('formatJson pretty-prints with two-space indent', () async {
      final c = makeController('{"a":1}');
      final outcome = await c.runTextTool('formatJson');
      expect(c.text.text, '{\n  "a": 1\n}');
      expect(outcome, isA<TextToolChanged>());
    });

    test('minifyJson compacts a pretty document', () async {
      final c = makeController('{\n  "a": [1, 2]\n}');
      final outcome = await c.runTextTool('minifyJson');
      expect(c.text.text, '{"a":[1,2]}');
      expect(outcome, isA<TextToolChanged>());
    });

    test('convertToAscii reports kept characters in its detail', () async {
      final c = makeController('caf\u00e9 \u65e5');
      final outcome = await c.runTextTool('convertToAscii');
      expect(c.text.text, 'cafe \u65e5');
      expect(
        outcome,
        isA<TextToolChanged>().having((r) => r.detail, 'detail', 'unmapped:1'),
      );
    });

    test('a unicode run applies and reports its scope', () async {
      // NFD input: 'e' plus combining acute; NFC expectation: precomposed.
      final c = makeController('e\u0301');
      final outcome = await c.runTextTool('composeAccents');
      expect(c.text.text, '\u00e9');
      expect(outcome, isA<TextToolChanged>());
      expect(c.toolReport?.ranOn, TextToolRanOn.document);
    });
  });
}
