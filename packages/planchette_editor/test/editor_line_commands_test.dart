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
  final editor = EditorController(displayPath: 'notes.txt', initialText: text);
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

/// Presses [key] with Command on Apple platforms or Control elsewhere when
/// [primary] is set, plus any other modifiers asked for.
Future<void> press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool primary = false,
  bool shift = false,
  bool alt = false,
}) async {
  final apple = defaultTargetPlatform == TargetPlatform.macOS;
  final modifiers = [
    if (primary)
      apple ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ];
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

void main() {
  testWidgets('line commands are bound in the document', (tester) async {
    final editor = await pumpEditor(tester, 'one\ntwo\nthree', caret: 1);

    await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    expect(editor.text.text, 'two\none\nthree');
    expect(editor.text.selection, const TextSelection.collapsed(offset: 5));

    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);
    expect(editor.text.text, 'one\ntwo\nthree');

    await press(tester, LogicalKeyboardKey.keyD, primary: true, shift: true);
    expect(editor.text.text, 'one\none\ntwo\nthree');
    expect(editor.caretLineColumn, (2, 2));

    await press(tester, LogicalKeyboardKey.keyK, primary: true, shift: true);
    expect(editor.text.text, 'one\ntwo\nthree');
    expect(editor.caretLineColumn, (2, 2));

    await press(tester, LogicalKeyboardKey.keyJ, primary: true);
    expect(editor.text.text, 'one\ntwo three');
    expect(editor.isDirty, isTrue);
  }, variant: desktop);

  testWidgets('a line command at the edge consumes its key', (tester) async {
    final editor = await pumpEditor(tester, 'one\ntwo', caret: 2);

    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);

    expect(editor.text.text, 'one\ntwo');
    expect(editor.text.selection, const TextSelection.collapsed(offset: 2));
  }, variant: desktop);

  testWidgets('a locked document leaves the keys to the text field', (
    tester,
  ) async {
    final editor = await pumpEditor(
      tester,
      'one\ntwo',
      caret: 5,
      editingLocked: true,
    );

    expect(editor.canEditText, isFalse);
    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);
    await press(tester, LogicalKeyboardKey.keyK, primary: true, shift: true);

    expect(editor.text.text, 'one\ntwo');
    expect(editor.moveLines(LineDirection.up), isFalse);
  }, variant: desktop);

  testWidgets('the find field keeps its own arrow keys', (tester) async {
    final editor = await pumpEditor(tester, 'one\ntwo', caret: 5);
    editor.openSearch();
    await tester.pump();
    expect(editor.searchFocus.hasFocus, isTrue);

    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);

    expect(editor.text.text, 'one\ntwo');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  test('an input method composition blocks line commands', () {
    final editor = EditorController(
      displayPath: 'notes.txt',
      initialText: 'one\ntwo',
    );
    addTearDown(editor.dispose);
    editor.text.value = const TextEditingValue(
      text: 'one\ntwo',
      selection: TextSelection.collapsed(offset: 7),
      composing: TextRange(start: 4, end: 7),
    );

    expect(editor.canEditText, isFalse);
    expect(editor.duplicateLines(), isFalse);
    expect(editor.text.text, 'one\ntwo');
  });

  testWidgets('moving a line past the bottom scrolls it into view', (
    tester,
  ) async {
    final lines = [for (var i = 0; i < 200; i++) 'line $i'];
    final editor = await pumpEditor(tester, lines.join('\n'));
    expect(editor.scroll.offset, 0);

    for (var i = 0; i < 60; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    }
    await tester.pump();

    expect(editor.caretLineColumn.$1, 61);
    expect(editor.scroll.offset, greaterThan(0));
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(editor.text.selection.extent);
    expect(caret.top, greaterThanOrEqualTo(0));
    expect(caret.bottom, lessThanOrEqualTo(editable.size.height));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a line command can be undone', (tester) async {
    final editor = await pumpEditor(tester, 'one\ntwo', caret: 1);
    await tester.pump(const Duration(seconds: 1));

    await press(tester, LogicalKeyboardKey.arrowDown, alt: true);
    await tester.pump(const Duration(seconds: 1));
    expect(editor.text.text, 'two\none');

    await press(tester, LogicalKeyboardKey.keyZ, primary: true);
    expect(editor.text.text, 'one\ntwo');
  }, variant: desktop);
}
