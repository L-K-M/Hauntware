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

  testWidgets('review fix: Shift+Tab with nothing to outdent keeps focus', (
    tester,
  ) async {
    // Focus traversal took the declined key; in the app it landed on a
    // tab's close button, where the next Enter closed that tab.
    final c = await mount(
      tester,
      'alpha',
      selection: const TextSelection.collapsed(offset: 2),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(c.editorFocus.hasFocus, isTrue);
    expect(c.text.text, 'alpha');
  }, variant: TargetPlatformVariant.desktop());

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

  // Ported from the duplicate indentation PRs (#24, #34, #21) and from review
  // probes; #14 is the implementation that was kept.

  testWidgets(
    'Alt+Tab never indents',
    (tester) async {
      final c = await mount(tester, 'x');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(c.text.text, 'x');
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('a locked document leaves Tab to focus traversal', (
    tester,
  ) async {
    final c = await mount(tester, 'x', locked: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text.text, 'x');
    expect(c.editorFocus.hasFocus, isFalse);
  });

  testWidgets('Tab during a composition keeps focus in the document', (
    tester,
  ) async {
    final c = await mount(tester, 'ab');
    c.text.value = const TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // The input method owns the key: no indent, and no traversal either.
    expect(c.text.text, 'ab');
    expect(c.editorFocus.hasFocus, isTrue);
  });

  testWidgets('Tab moves on from the find and replace fields', (tester) async {
    final c = await mount(tester, 'cat');
    c.openSearch(replace: true);
    await tester.pump();
    expect(c.searchFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.searchFocus.hasFocus, isFalse);
    expect(c.text.text, 'cat');

    c.replacementFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.replacementFocus.hasFocus, isFalse);
    expect(c.text.text, 'cat');
  });

  testWidgets('Tab moves on from a button in the host banner', (tester) async {
    final c = EditorController(displayPath: 'a.txt', initialText: 'cat');
    addTearDown(c.dispose);
    final button = FocusNode();
    addTearDown(button.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: c,
            banner: TextButton(
              focusNode: button,
              onPressed: () {},
              child: const Text('Reload'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(button.hasFocus, isFalse);
    expect(c.text.text, 'cat');
  });

  testWidgets('a colon opens a block only where the language says so', (
    tester,
  ) async {
    for (final (path, line) in [
      ('notes.md', '  Note: see below'),
      ('main.dart', '  x ? a :'),
      ('page.xml', '  <a:b'),
    ]) {
      final c = await mount(
        tester,
        line,
        path: path,
        selection: TextSelection.collapsed(offset: line.length),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.text.text, '$line\n  ', reason: path);
    }
  });

  testWidgets('a pasted block is left exactly as it arrived', (tester) async {
    final c = await mount(tester, '    x');
    // Text the platform inserts (a paste or a software keyboard) is not a
    // hardware Enter, so none of it is re-indented.
    const pasted = '    x\nfirst\n  second\n';
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: pasted,
        selection: TextSelection.collapsed(offset: pasted.length),
      ),
    );
    await tester.pump();
    expect(c.text.text, pasted);
  });

  testWidgets('undo removes an automatic indent', (tester) async {
    final c = await mount(
      tester,
      '    foo',
      selection: const TextSelection.collapsed(offset: 7),
    );
    // Undo history batches changes 500 ms apart; pause like a person would.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(c.text.text, '    foo\n    ');
    await tester.pump(const Duration(milliseconds: 600));
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, '    foo');
  });

  testWidgets('the caret stays in view after repeated Enter', (tester) async {
    // A key edit is programmatic, and the field only scrolls to the caret for
    // typing; without a reveal the caret walks off the bottom of the view.
    await tester.binding.setSurfaceSize(const Size(500, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final text = List.generate(40, (i) => 'line $i').join('\n');
    final c = await mount(
      tester,
      text,
      selection: TextSelection.collapsed(offset: text.indexOf('line 21') + 7),
    );
    for (var i = 0; i < 15; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText));
    final caret = field.renderEditable.getLocalRectForCaret(
      c.text.selection.extent,
    );
    expect(caret.top, greaterThanOrEqualTo(0));
    expect(caret.bottom, lessThanOrEqualTo(field.renderEditable.size.height));
  });
}
