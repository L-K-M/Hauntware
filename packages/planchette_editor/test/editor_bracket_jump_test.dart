import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

final desktop = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

Future<EditorController> pumpEditor(
  WidgetTester tester,
  String text, {
  int caret = 0,
  bool editingLocked = false,
}) async {
  final editor = EditorController(displayPath: 'main.js', initialText: text);
  addTearDown(editor.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlanchetteEditor(
          controller: editor,
          editingLocked: editingLocked,
        ),
      ),
    ),
  );
  await tester.pump();
  editor.text.selection = TextSelection.collapsed(offset: caret);
  await tester.pump();
  return editor;
}

/// Presses Command+B on Apple platforms or Control+B elsewhere.
Future<void> pressJump(WidgetTester tester, {bool shift = false}) async {
  final primary = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(primary);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(primary);
  await tester.pump();
}

void main() {
  testWidgets('the key jumps to the partner and back', (tester) async {
    final editor = await pumpEditor(tester, 'f((a))', caret: 1);

    await pressJump(tester);
    expect(editor.text.selection, const TextSelection.collapsed(offset: 5));

    // Offset 5 also follows the inner `)`; the second jump still returns.
    await pressJump(tester);
    expect(editor.text.selection, const TextSelection.collapsed(offset: 1));
    expect(editor.isDirty, isFalse);
  }, variant: desktop);

  testWidgets('Shift selects to the partner', (tester) async {
    final editor = await pumpEditor(tester, 'if (x) {\n  y;\n}', caret: 8);

    await pressJump(tester, shift: true);

    expect(
      editor.text.selection,
      const TextSelection(baseOffset: 8, extentOffset: 15),
    );
  }, variant: desktop);

  testWidgets('a locked document still jumps', (tester) async {
    final editor = await pumpEditor(
      tester,
      'f(a, b)',
      caret: 2,
      editingLocked: true,
    );

    await pressJump(tester);

    expect(editor.text.selection, const TextSelection.collapsed(offset: 7));
  }, variant: desktop);

  testWidgets('the find field keeps its own keys', (tester) async {
    final editor = await pumpEditor(tester, 'f(a)', caret: 2);
    editor.openSearch();
    await tester.pump();
    expect(editor.searchFocus.hasFocus, isTrue);

    await pressJump(tester);

    expect(editor.text.selection, const TextSelection.collapsed(offset: 2));
    expect(editor.searchFocus.hasFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a jump past the bottom scrolls the partner into view', (
    tester,
  ) async {
    final body = [for (var i = 0; i < 200; i++) '  line $i;'];
    final editor = await pumpEditor(
      tester,
      'f() {\n${body.join('\n')}\n}',
      caret: 5,
    );
    expect(editor.scroll.offset, 0);

    await pressJump(tester);
    await tester.pump();

    expect(editor.caretLineColumn, (202, 2));
    expect(editor.scroll.offset, greaterThan(0));
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(editor.text.selection.extent);
    expect(caret.top, greaterThanOrEqualTo(0));
    expect(caret.bottom, lessThanOrEqualTo(editable.size.height));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  group('goToMatchingBracket', () {
    EditorController controller(String text, int caret) {
      final editor = EditorController(
        displayPath: 'main.js',
        initialText: text,
      );
      addTearDown(editor.dispose);
      editor.text.selection = TextSelection.collapsed(offset: caret);
      return editor;
    }

    test('skips brackets in strings', () {
      final editor = controller('f(")")', 1);

      expect(editor.goToMatchingBracket(), isTrue);
      expect(editor.text.selection, const TextSelection.collapsed(offset: 5));
    });

    test('with nowhere to go, changes nothing', () {
      final editor = controller('plain text', 3);
      final reveal = editor.caretRevealRequest;

      expect(editor.goToMatchingBracket(), isFalse);
      expect(editor.text.selection, const TextSelection.collapsed(offset: 3));
      expect(editor.caretRevealRequest, reveal);
    });

    test('an input method composition blocks the jump', () {
      final editor = controller('f(a)', 2);
      editor.text.value = const TextEditingValue(
        text: 'f(a)',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 2, end: 3),
      );

      expect(editor.canMoveCaret, isFalse);
      expect(editor.goToMatchingBracket(), isFalse);
    });
  });

  test('commands see tokens past the highlighting cap', () {
    final text = '${'x' * syntaxHighlightingMaxChars}")"';
    final code = CodeEditingController(language: syntaxLanguageFor('a.js'))
      ..text = text;
    addTearDown(code.dispose);

    expect(code.syntaxTokens, isNotEmpty);
    expect(code.syntaxTokens.last.type, SyntaxTokenType.string);
  });
}
