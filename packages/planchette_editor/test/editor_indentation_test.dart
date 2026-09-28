import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(
  EditorController c, {
  bool locked = false,
  EditorTabKeyBehavior tabKeyBehavior = EditorTabKeyBehavior.indent,
}) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        TextButton(onPressed: () {}, child: const Text('Elsewhere')),
        Expanded(
          child: PlanchetteEditor(
            controller: c,
            editingLocked: locked,
            tabKeyBehavior: tabKeyBehavior,
          ),
        ),
      ],
    ),
  ),
);

Future<EditorController> mount(
  WidgetTester tester,
  String text, {
  String path = 'notes.txt',
  TextSelection selection = const TextSelection.collapsed(offset: 0),
  bool locked = false,
  EditorTabKeyBehavior tabKeyBehavior = EditorTabKeyBehavior.indent,
}) async {
  final c = EditorController(displayPath: path, initialText: text);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    app(c, locked: locked, tabKeyBehavior: tabKeyBehavior),
  );
  await tester.pump();
  c.editorFocus.requestFocus();
  await tester.pump();
  c.text.selection = selection;
  await tester.pump();
  return c;
}

void main() {
  testWidgets('Tab indents at the caret and keeps focus in the document', (
    tester,
  ) async {
    final c = await mount(
      tester,
      'a\n  b',
      selection: const TextSelection.collapsed(offset: 4),
    );
    expect(c.indentation, const Indentation.spaces(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text.text, 'a\n    b');
    expect(c.text.selection, const TextSelection.collapsed(offset: 6));
    expect(c.editorFocus.hasFocus, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(c.text.text, 'a\n  b');
    expect(c.text.selection, const TextSelection.collapsed(offset: 4));
    expect(c.editorFocus.hasFocus, isTrue);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Tab indents a block and one undo restores it', (tester) async {
    final c = await mount(
      tester,
      'one\ntwo\nthree',
      selection: const TextSelection(baseOffset: 0, extentOffset: 7),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text.text, '    one\n    two\nthree');
    expect(
      c.text.selection,
      const TextSelection(baseOffset: 0, extentOffset: 15),
    );
    await tester.pump(const Duration(milliseconds: 600));
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'one\ntwo\nthree');
  });

  testWidgets('Enter carries indentation and opens bracket blocks', (
    tester,
  ) async {
    final c = await mount(
      tester,
      '    if (x) {}',
      path: 'main.c',
      selection: const TextSelection.collapsed(offset: 12),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.text.text, '    if (x) {\n        \n    }');
    expect(c.text.selection, const TextSelection.collapsed(offset: 21));
  });

  testWidgets('Enter indents after a colon only in Python and YAML', (
    tester,
  ) async {
    final python = await mount(
      tester,
      'def f():',
      path: 'a.py',
      selection: const TextSelection.collapsed(offset: 8),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(python.text.text, 'def f():\n    ');

    final yaml = await mount(
      tester,
      'key:',
      path: 'a.yaml',
      selection: const TextSelection.collapsed(offset: 4),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(yaml.text.text, 'key:\n    ');

    final prose = await mount(
      tester,
      'Note:',
      selection: const TextSelection.collapsed(offset: 5),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(prose.text.text, 'Note:\n');
  });

  // Flutter's own Backspace mapping (DefaultTextEditingShortcuts) sits in
  // WidgetsApp, above the editor, so the editor's binding is consulted first
  // on every platform; the variants pin that down.
  testWidgets('Backspace removes a level of space indentation', (tester) async {
    final c = await mount(
      tester,
      'a\n    b\n        c',
      selection: const TextSelection.collapsed(offset: 16),
    );
    expect(c.indentation, const Indentation.spaces(4));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text.text, 'a\n    b\n    c');
    expect(c.text.selection, const TextSelection.collapsed(offset: 12));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text.text, 'a\n    b\nc');
    c.text.text = 'ab';
    c.text.selection = const TextSelection.collapsed(offset: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text.text, 'a', reason: 'ordinary Backspace still deletes');
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('input method composition keeps Enter and Tab', (tester) async {
    final c = await mount(tester, 'ab');
    c.text.value = const TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    expect(c.insertNewline(), isFalse);
    expect(c.indent(), isFalse);
    expect(c.text.text, 'ab');
  });

  testWidgets('locked documents and moveFocus hosts leave Tab alone', (
    tester,
  ) async {
    final locked = await mount(tester, 'x', locked: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(locked.text.text, 'x');

    final traversing = await mount(
      tester,
      'x',
      tabKeyBehavior: EditorTabKeyBehavior.moveFocus,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(traversing.text.text, 'x');
    expect(traversing.editorFocus.hasFocus, isFalse);
  });

  testWidgets('Tab in the find field does not edit the document', (
    tester,
  ) async {
    final c = await mount(tester, 'cat');
    c.openSearch(replace: true);
    await tester.pump();
    expect(c.searchFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text.text, 'cat');
  });

  testWidgets('status shows the indentation and follows new documents', (
    tester,
  ) async {
    final c = await mount(tester, '', path: 'Makefile');
    expect(find.textContaining('Tab Size: 4'), findsOneWidget);
    c.text.text = 'all:\n  cc main.c\n';
    await tester.pump();
    expect(c.indentation, const Indentation.spaces(2));
    expect(find.textContaining('Spaces: 2'), findsOneWidget);
  });

  testWidgets('tabs render as wide as the indentation', (tester) async {
    final c = await mount(tester, 'x\tx', path: 'Makefile');
    final span = c.text.buildTextSpan(
      context: tester.element(find.byType(PlanchetteEditor)),
      style: const TextStyle(fontSize: 10),
      withComposing: false,
    );
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    addTearDown(painter.dispose);
    // Two glyphs plus one tab of four spaces, in a 10 px square test font.
    expect(painter.width, 60);
    expect(span.toPlainText(), 'x\tx');
  });
}
