import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  group('indentSelection', () {
    test('inserts a tab at the caret', () {
      final controller = TextEditingController(text: 'hello');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 5);
      indentSelection(controller);
      expect(controller.text, 'hello\t');
      expect(controller.selection.baseOffset, 6);
    });

    test('replaces an intra-line selection', () {
      final controller = TextEditingController(text: 'hello');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 3,
      );
      indentSelection(controller);
      expect(controller.text, 'h\tlo');
      expect(controller.selection.isCollapsed, isTrue);
      expect(controller.selection.baseOffset, 2);
    });

    test('indents every touched line and shifts the selection', () {
      final controller = TextEditingController(text: 'ab\ncd\nef');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 7,
      );
      indentSelection(controller);
      expect(controller.text, 'ab\n\tcd\n\tef');
      expect(controller.selection.baseOffset, 4);
      expect(controller.selection.extentOffset, 9);
    });

    test('indents touched lines for a reversed selection', () {
      final controller = TextEditingController(text: 'ab\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 4,
        extentOffset: 0,
      );
      indentSelection(controller);
      expect(controller.text, '\tab\n\tcd');
      // Direction survives: base still marks the later offset.
      expect(controller.selection.baseOffset, 6);
      expect(controller.selection.extentOffset, 1);
    });
  });

  group('outdentSelection', () {
    test('removes one leading tab per line', () {
      final controller = TextEditingController(text: '\tab\n\tcd\n ef');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 9,
      );
      outdentSelection(controller);
      expect(controller.text, 'ab\ncd\nef');
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, 6);
    });

    test('removes up to four leading spaces', () {
      final controller = TextEditingController(text: '      two');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 0);
      outdentSelection(controller);
      expect(controller.text, '  two');
      expect(controller.selection.baseOffset, 0);
    });

    test('keeps unindented lines intact', () {
      final controller = TextEditingController(text: 'ab');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 1);
      outdentSelection(controller);
      expect(controller.text, 'ab');
      expect(controller.selection.baseOffset, 1);
    });

    test('keeps a reversed selection reversed while outdenting', () {
      final controller = TextEditingController(text: '\tab\n\tcd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 5,
        extentOffset: 0,
      );
      outdentSelection(controller);
      expect(controller.text, 'ab\ncd');
      expect(controller.selection.baseOffset, 3);
      expect(controller.selection.extentOffset, 0);
    });
  });

  group('insertNewlineWithIndent', () {
    test('carries the previous line indent over', () {
      final controller = TextEditingController(text: '\t\tab cd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 7);
      insertNewlineWithIndent(controller);
      expect(controller.text, '\t\tab cd\n\t\t');
      expect(controller.selection.baseOffset, controller.text.length);
    });

    test('uses the first selected line indent in both directions', () {
      const text = '  a\n    b\n  c';
      for (final (name, selection, expected) in [
        (
          'forward',
          const TextSelection(baseOffset: 0, extentOffset: 12),
          '\n  c',
        ),
        (
          'reversed',
          const TextSelection(baseOffset: 12, extentOffset: 0),
          '\n  c',
        ),
        (
          'ending at a line boundary',
          const TextSelection(baseOffset: 0, extentOffset: 7),
          '\n   b\n  c',
        ),
      ]) {
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        controller.selection = selection;
        insertNewlineWithIndent(controller);
        expect(controller.text, expected, reason: name);
      }
    });

    test('replaces the selection with the indented newline', () {
      final controller = TextEditingController(text: '  abcd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 6,
      );
      insertNewlineWithIndent(controller);
      expect(controller.text, '  \n  ');
      expect(controller.selection.baseOffset, 5);
    });

    test('does not inherit indent from beyond the caret', () {
      final controller = TextEditingController(text: 'ab  cd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 2);
      insertNewlineWithIndent(controller);
      expect(controller.text, 'ab\n  cd');
    });
  });

  group('moveSelectionLines', () {
    test('swaps with the line above and keeps the selection', () {
      final controller = TextEditingController(text: 'ab\nXY\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      moveSelectionLines(controller, direction: LineMoveDirection.up);
      expect(controller.text, 'XY\nab\ncd');
      expect(controller.selection.baseOffset, 1);
    });

    test('swaps with the line below', () {
      final controller = TextEditingController(text: 'ab\nXY\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      moveSelectionLines(controller, direction: LineMoveDirection.down);
      expect(controller.text, 'ab\ncd\nXY');
      expect(controller.selection.baseOffset, 7);
    });

    test('moves a multi-line block over a shorter neighbor', () {
      final controller = TextEditingController(text: 'a\nXX\nYY\nbcd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 7,
      );
      moveSelectionLines(controller, direction: LineMoveDirection.up);
      expect(controller.text, 'XX\nYY\na\nbcd');
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, 5);
    });

    test('preserves trailing newline when moving the last line up', () {
      final controller = TextEditingController(text: 'ab\nXY');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      moveSelectionLines(controller, direction: LineMoveDirection.up);
      expect(controller.text, 'XY\nab');
    });

    test('preserves trailing newline when moving a line below the last', () {
      final controller = TextEditingController(text: 'ab\nXY\n');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      moveSelectionLines(controller, direction: LineMoveDirection.down);
      expect(controller.text, 'ab\n\nXY');
      expect(controller.selection.baseOffset, 5);
    });

    test('is a no-op at document edges', () {
      final controller = TextEditingController(text: 'ab\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      moveSelectionLines(controller, direction: LineMoveDirection.down);
      expect(controller.text, 'ab\ncd');
      controller.selection = const TextSelection.collapsed(offset: 0);
      moveSelectionLines(controller, direction: LineMoveDirection.up);
      expect(controller.text, 'ab\ncd');
    });

    test('moves CRLF lines without stranding carriage returns', () {
      final up = TextEditingController(text: 'x\r\nb');
      addTearDown(up.dispose);
      up.selection = const TextSelection.collapsed(offset: 3);
      moveSelectionLines(up, direction: LineMoveDirection.up);
      expect(up.text, 'b\r\nx');

      final down = TextEditingController(text: 'a\r\nb\r\nc');
      addTearDown(down.dispose);
      down.selection = const TextSelection.collapsed(offset: 0);
      moveSelectionLines(down, direction: LineMoveDirection.down);
      expect(down.text, 'b\r\na\r\nc');
    });

    test('keeps the selection direction while moving', () {
      final controller = TextEditingController(text: 'ab\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 4,
        extentOffset: 3,
      );
      moveSelectionLines(controller, direction: LineMoveDirection.up);
      expect(controller.text, 'cd\nab');
      expect(controller.selection.baseOffset, 1);
      expect(controller.selection.extentOffset, 0);
    });
  });

  group('duplicateSelectionLines', () {
    test('copies the touched lines below and selects the copy', () {
      final controller = TextEditingController(text: 'ab\nXY\ncd');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      duplicateSelectionLines(controller);
      expect(controller.text, 'ab\nXY\nXY\ncd');
      expect(controller.selection.baseOffset, 6);
      expect(controller.selection.extentOffset, 8);
    });

    test('appends after a final line without newline', () {
      final controller = TextEditingController(text: 'ab\nXY');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 4);
      duplicateSelectionLines(controller);
      expect(controller.text, 'ab\nXY\nXY');
      expect(controller.selection.baseOffset, 6);
      expect(controller.selection.extentOffset, 8);
    });

    test('duplicates a multi-line block as one unit', () {
      final controller = TextEditingController(text: 'X\nY\nZ');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );
      duplicateSelectionLines(controller);
      expect(controller.text, 'X\nY\nX\nY\nZ');
      expect(controller.selection.baseOffset, 4);
      expect(controller.selection.extentOffset, 7);
    });
  });

  group('document key handling', () {
    // The chords must survive every desktop platform's default text-editing
    // shortcut map, so each key test runs per platform.
    const desktopVariant = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });

    Future<EditorController> pumpEditor(WidgetTester tester) async {
      final controller = EditorController(
        displayPath: 'notes.txt',
        initialText: 'ab',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanchetteEditor(controller: controller),
          ),
        ),
      );
      await tester.pump();
      controller.editorFocus.requestFocus();
      await tester.pump();
      return controller;
    }

    testWidgets('Tab types a tab character and keeps focus', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.selection = const TextSelection.collapsed(offset: 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text.text, 'ab\t');
      expect(controller.editorFocus.hasFocus, isTrue);
    }, variant: desktopVariant);

    testWidgets('Shift+Tab outdents the caret line', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: '\tab',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(controller.text.text, 'ab');
    }, variant: desktopVariant);

    testWidgets('Alt+Tab never indents', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.selection = const TextSelection.collapsed(offset: 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.text.text, 'ab');
    }, variant: desktopVariant);

    testWidgets('Enter preserves the line indent', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: '  ab',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text.text, '  ab\n  ');
    }, variant: desktopVariant);

    testWidgets('Alt+ArrowUp moves the caret line up', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: 'ab\ncd',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.text.text, 'cd\nab');
    }, variant: desktopVariant);

    testWidgets('Alt+ArrowDown moves the caret line down', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: 'ab\ncd',
        selection: TextSelection.collapsed(offset: 0),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.text.text, 'cd\nab');
    }, variant: desktopVariant);

    testWidgets('Shift+Alt+ArrowDown duplicates the caret line', (
      tester,
    ) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: 'ab\ncd',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(controller.text.text, 'ab\ncd\ncd');
    }, variant: desktopVariant);

    testWidgets('locked editor leaves Tab to focus traversal', (
      tester,
    ) async {
      final controller = EditorController(
        displayPath: 'notes.txt',
        initialText: 'ab',
      );
      addTearDown(controller.dispose);
      final outsideNode = FocusNode(debugLabel: 'outside');
      addTearDown(outsideNode.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(focusNode: outsideNode, child: const SizedBox()),
                Expanded(child: PlanchetteEditor(controller: controller)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      controller.editorFocus.requestFocus();
      await tester.pump();
      controller.setEditingLocked(true);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text.text, 'ab');
      // Tab must actually leave the locked editor, not just insert nothing.
      expect(controller.editorFocus.hasFocus, isFalse);
    });

    testWidgets('composing text keeps Tab away from the document', (
      tester,
    ) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text.text, 'ab');
      // The in-progress composition must survive the key event untouched.
      expect(controller.text.value.composing, const TextRange(start: 0, end: 2));
    });
  });
}
