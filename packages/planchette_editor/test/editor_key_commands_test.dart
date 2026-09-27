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
    });

    test('keeps unindented lines intact', () {
      final controller = TextEditingController(text: 'ab');
      addTearDown(controller.dispose);
      outdentSelection(controller);
      expect(controller.text, 'ab');
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
    });

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
    });

    testWidgets('Enter preserves the line indent', (tester) async {
      final controller = await pumpEditor(tester);
      controller.text.value = const TextEditingValue(
        text: '  ab',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.text.text, '  ab\n  ');
    });

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
    });

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
    });

    testWidgets('locked editor leaves Tab to focus traversal', (
      tester,
    ) async {
      final controller = await pumpEditor(tester);
      controller.setEditingLocked(true);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(controller.text.text, 'ab');
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
    });
  });
}
