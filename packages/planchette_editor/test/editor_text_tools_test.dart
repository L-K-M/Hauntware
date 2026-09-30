import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(EditorController c) =>
    MaterialApp(home: Scaffold(body: PlanchetteEditor(controller: c)));

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
  await tester.pump(const Duration(milliseconds: 600));
  return editor;
}

Future<TextToolOutcome?> runTool(
  WidgetTester tester,
  EditorController c,
  String id, {
  Map<String, Object?> options = const {},
}) async {
  final run = c.runTextTool(id, options: options);
  await tester.pump(const Duration(milliseconds: 600));
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
        async.elapse(const Duration(milliseconds: 600));

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
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Sort Lines'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(c.text.text, 'b\na');
      // The undo is itself a value change, which clears the notice.
      expect(c.toolReport, isNull);
      expect(find.textContaining('Sort Lines'), findsNothing);
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
}
