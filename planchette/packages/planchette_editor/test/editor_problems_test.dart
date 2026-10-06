import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Two keys set twice: problems on lines 3 and 4.
const _env = 'HOST=a\nPORT=1\nPORT=2\nHOST=b\n';

/// Longer than the controller's pause before it checks again.
const _settle = Duration(milliseconds: 600);

EditorController _controller(String path, String text) {
  final editor = EditorController(displayPath: path, initialText: text);
  addTearDown(editor.dispose);
  return editor;
}

List<String> _flagged(EditorController editor) => [
  for (final problem in editor.problems)
    editor.text.text.substring(problem.start, problem.end),
];

Future<EditorController> _mount(
  WidgetTester tester,
  String path,
  String text, {
  Widget Function(BuildContext, EditorController)? statusBuilder,
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final editor = _controller(path, text);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: PlanchetteEditor(
          controller: editor,
          statusBuilder: statusBuilder,
        ),
      ),
    ),
  );
  await tester.pump();
  return editor;
}

void main() {
  group('controller', () {
    testWidgets('checks the document when it is installed', (tester) async {
      final editor = _controller('/srv/app/.env', _env);
      expect(_flagged(editor), ['PORT', 'HOST']);
      expect(editor.problems.first.relatedLine, 2);
      expect(editor.problemLines, {
        2: TextProblemSeverity.warning,
        3: TextProblemSeverity.warning,
      });
    });

    testWidgets('a plain document is checked only for conflict markers', (
      tester,
    ) async {
      expect(_controller('notes.txt', 'PORT=1\nPORT=2\n').problems, isEmpty);
      expect(
        _controller(
          'notes.txt',
          '<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n',
        ).problems.single.kind,
        TextProblemKind.mergeConflict,
      );
    });

    testWidgets('leaves documents too large to highlight alone', (
      tester,
    ) async {
      final text = 'A=1\n' * (syntaxHighlightingMaxChars ~/ 4 + 1);
      expect(_controller('big.env', text).problems, isEmpty);
    });

    testWidgets('an edit drops the problems it touches at once and the view '
        'checks again once typing pauses', (tester) async {
      final editor = await _mount(tester, 'a.env', _env);

      // Typing on line 1 moves both problems along without a check.
      editor.text.value = TextEditingValue(
        text: 'X$_env',
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(_flagged(editor), ['PORT', 'HOST']);

      // Renaming the second PORT clears its mark immediately, while the
      // other waits for the pause.
      final renamed = editor.text.text.replaceFirst('PORT=2', 'PART=2');
      editor.text.value = TextEditingValue(
        text: renamed,
        selection: TextSelection.collapsed(offset: renamed.indexOf('PART')),
      );
      expect(_flagged(editor), ['HOST']);

      // HOST on line 1 is now XHOST, so the last HOST is no repeat.
      expect(editor.problemsOutdated, isTrue);
      await tester.pump(_settle);
      expect(editor.problemsOutdated, isFalse);
      expect(editor.problems, isEmpty);
    });

    testWidgets('without a view, edits wait for checkProblems', (tester) async {
      final editor = _controller('a.env', 'A=1\n');
      editor.text.value = const TextEditingValue(text: 'A=1\nA=2\n');
      await tester.pump(_settle);
      expect(editor.problems, isEmpty);
      editor.checkProblems();
      expect(_flagged(editor), ['A']);
    });

    testWidgets('a typed problem appears only after the pause', (tester) async {
      final editor = await _mount(tester, 'a.json', '{"a": 1}');
      editor.text.value = const TextEditingValue(
        text: '{"a": 1,}',
        selection: TextSelection.collapsed(offset: 8),
      );
      expect(editor.problems, isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(editor.problems, isEmpty);
      await tester.pump(_settle);
      expect(editor.problems.single.kind, TextProblemKind.jsonTrailingComma);
    });

    testWidgets('a new name can change the rules', (tester) async {
      final editor = _controller('/repo/config.json', '{\n  // note\n}');
      expect(editor.problems.single.kind, TextProblemKind.jsonComment);
      editor.displayPath = '/repo/tsconfig.json';
      expect(editor.problems, isEmpty);
    });

    testWidgets('describes the problem on the caret line', (tester) async {
      final editor = _controller('a.env', _env);
      editor.text.selection = const TextSelection.collapsed(offset: 0);
      expect(editor.problemAtCaret, isNull);
      // Line 3, after the key: still that line's problem.
      editor.text.selection = TextSelection.collapsed(
        offset: _env.indexOf('PORT=2') + 6,
      );
      expect(editor.problemAtCaret?.subject, 'PORT');
    });

    testWidgets('steps through the problems both ways, round the ends', (
      tester,
    ) async {
      final editor = _controller('a.env', _env);
      final port = _env.indexOf('PORT=2');
      final host = _env.indexOf('HOST=b');
      editor.text.selection = const TextSelection.collapsed(offset: 0);

      expect(editor.nextProblem(), isTrue);
      expect(editor.text.selection.baseOffset, port);
      expect(editor.nextProblem(), isTrue);
      expect(editor.text.selection.baseOffset, host);
      expect(editor.nextProblem(), isTrue);
      expect(editor.text.selection.baseOffset, port);
      expect(editor.previousProblem(), isTrue);
      expect(editor.text.selection.baseOffset, host);
      expect(editor.previousProblem(), isTrue);
      expect(editor.text.selection.baseOffset, port);
    });

    testWidgets('a locked document still steps through its problems', (
      tester,
    ) async {
      final editor = _controller('a.env', _env)..setEditingLocked(true);
      expect(editor.canRunCommand(EditorCommand.nextProblem), isTrue);
      expect(await editor.runCommand(EditorCommand.nextProblem), isTrue);
      expect(editor.text.selection.baseOffset, _env.indexOf('PORT=2'));
      expect(await editor.runCommand(EditorCommand.previousProblem), isTrue);

      final clean = _controller('a.env', 'A=1\n');
      expect(clean.canRunCommand(EditorCommand.nextProblem), isFalse);
      expect(clean.nextProblem(), isFalse);
    });
  });

  group('view', () {
    testWidgets('underlines problems in their severity colour', (tester) async {
      final editor = await _mount(tester, 'a.json', '{"a": 1, "a": 2,}');
      final span = editor.text.buildTextSpan(
        context: tester.element(find.byType(PlanchetteEditor)),
        withComposing: false,
      );
      final underlined = <String, Color?>{};
      span.visitChildren((child) {
        final style = child.style;
        if (child is TextSpan &&
            style?.decorationStyle == TextDecorationStyle.wavy) {
          underlined[child.text!] = style!.decorationColor;
        }
        return true;
      });
      expect(underlined, {
        '"a"': EditorSyntaxTheme.light.warning,
        ',': EditorSyntaxTheme.light.warning,
      });
    });

    testWidgets('the status row counts problems and describes the one at '
        'the caret', (tester) async {
      final editor = await _mount(tester, 'a.env', _env);
      editor.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(find.text('2 problems'), findsOneWidget);

      // Tapping the count goes to the next problem, which it then names.
      await tester.tap(find.text('2 problems'));
      await tester.pump();
      expect(editor.text.selection.baseOffset, _env.indexOf('PORT=2'));
      expect(
        find.text('Duplicate key "PORT", first set on line 2'),
        findsOneWidget,
      );
      expect(editor.editorFocus.hasFocus, isTrue);
    });

    testWidgets('the status row gives a message the room the position '
        'leaves, and fits a phone', (tester) async {
      const message = 'Duplicate key "PORT", first set on line 2';
      // The test font's glyphs are an em wide, 6.5 px here with letter
      // spacing: a 215 px position and a 273 px message. At this width the
      // row's lead is 560 px, room for both but not for the message in
      // half of it.
      final editor = await _mount(
        tester,
        'a.env',
        _env,
        theme: ThemeData(
          textTheme: const TextTheme(labelSmall: TextStyle(fontSize: 6)),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1144, 400));
      editor.text.selection = TextSelection.collapsed(
        offset: _env.indexOf('PORT=2'),
      );
      await tester.pump();
      RenderParagraph paragraph() =>
          tester.renderObject<RenderParagraph>(find.text(message));
      expect(paragraph().didExceedMaxLines, isFalse);

      await tester.binding.setSurfaceSize(const Size(320, 400));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Ln 3, Col 1'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('shows no problem segment for a clean document', (
      tester,
    ) async {
      await _mount(tester, 'a.env', 'A=1\n');
      expect(find.byType(EditorProblemStatus), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('a host status row can show the segment', (tester) async {
      await _mount(
        tester,
        'a.json',
        '\n\n{',
        statusBuilder: (context, controller) =>
            EditorProblemStatus(controller: controller),
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('1 problem'), findsOneWidget);
    });

    testWidgets('F8 and Shift+F8 step through the problems', (tester) async {
      final editor = await _mount(tester, 'a.env', _env);
      editor.text.selection = const TextSelection.collapsed(offset: 0);
      editor.editorFocus.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      expect(editor.text.selection.baseOffset, _env.indexOf('PORT=2'));
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      expect(editor.text.selection.baseOffset, _env.indexOf('HOST=b'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(editor.text.selection.baseOffset, _env.indexOf('PORT=2'));
    });

    testWidgets('the gutter marks lines with problems', (tester) async {
      await _mount(tester, 'a.json', '{\n  "a": 1,\n  "a": 2\n}');
      RenderObject? gutter = tester.renderObject(
        find.byKey(const ValueKey('editor-line-gutter')),
      );
      while (gutter != null &&
          !gutter.runtimeType.toString().contains('DocumentDecorations')) {
        gutter = gutter.parent;
      }
      final warning = EditorSyntaxTheme.light.warning.toARGB32();
      var marks = 0;
      expect(
        gutter,
        paints..everything((method, arguments) {
          if (method == #drawRect &&
              (arguments[1] as Paint).color.toARGB32() == warning) {
            marks++;
          }
          return true;
        }),
      );
      expect(marks, 1);
    });
  });

  test('every problem kind has a message', () {
    const strings = EditorStrings();
    for (final kind in TextProblemKind.values) {
      final message = strings.problemMessage(
        TextProblem(
          kind: kind,
          severity: TextProblemSeverity.error,
          start: 0,
          end: 1,
          subject: 'name',
          counterpart: 'other',
          relatedLine: 3,
          detail: 'detail',
        ),
      );
      expect(message, isNot(contains('null')), reason: '$kind');
      expect(message, isNotEmpty, reason: '$kind');
    }
  });
}
