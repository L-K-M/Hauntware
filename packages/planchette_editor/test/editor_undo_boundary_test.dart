import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(
  EditorController c, {
  bool active = true,
  bool locked = false,
  EditorStrings strings = const EditorStrings(),
}) => MaterialApp(
  home: Scaffold(
    body: PlanchetteEditor(
      controller: c,
      isActive: active,
      editingLocked: locked,
      strings: strings,
    ),
  ),
);

// From #19, which found the bug; the fix is a remount of the document field
// rather than #19's replacement of the text controller.
void main() {
  testWidgets('a confirmed reload clears undo at the buffer boundary', (
    tester,
  ) async {
    final c = EditorController(
      displayPath: 'test',
      loadDocument: () async => TextDocument(
        file: File('/tmp/boundary.txt'),
        text: 'original',
        hasUtf8Bom: false,
        lineEnding: LineEnding.lf,
        sha256: 'v1',
      ),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await c.initialize();
    await tester.pump();
    expect(c.text.text, 'original');
    // UndoHistory records any focused-controller change but coalesces it
    // through a 500ms throttle, and a stack with a single entry cannot
    // undo — two settled edits are needed to prove the sever.
    c.editorFocus.requestFocus();
    await tester.pump();
    c.text.value = const TextEditingValue(
      text: 'edited one',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump(const Duration(milliseconds: 600));
    c.text.value = const TextEditingValue(
      text: 'edited two',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump(const Duration(milliseconds: 600));
    c.adoptDocument(
      TextDocument(
        file: File('/tmp/boundary.txt'),
        text: 'reloaded',
        hasUtf8Bom: false,
        lineEnding: LineEnding.lf,
        sha256: 'v2',
      ),
      replaceText: true,
    );
    await tester.pump();
    expect(c.text.text, 'reloaded');
    expect(c.editorFocus.hasFocus, isTrue);
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'reloaded');
    // Keyboard Undo takes another path through the field; it must not cross
    // the boundary either.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.text.text, 'reloaded');
    expect(c.isDirty, isFalse);
    // Typing after the swap must land in the fresh controller: it fails
    // loudly if the field still holds the retired instance.
    await tester.enterText(
      find.byKey(const ValueKey('planchette.document')),
      'reloaded more',
    );
    await tester.pump();
    expect(c.text.text, 'reloaded more');
    // Undo keeps working inside the new buffer. Entries are throttled
    // 500ms and the cleared stack re-baselines on the first post-swap
    // edit, so a revert needs two settled edits.
    c.text.value = const TextEditingValue(
      text: 'reloaded more+',
      selection: TextSelection.collapsed(offset: 14),
    );
    await tester.pump(const Duration(milliseconds: 600));
    c.text.value = const TextEditingValue(
      text: 'reloaded more++',
      selection: TextSelection.collapsed(offset: 15),
    );
    await tester.pump(const Duration(milliseconds: 600));
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'reloaded more+');
  });

  TextDocument disk(String text) => TextDocument(
    file: File('/tmp/installed.txt'),
    text: text,
    hasUtf8Bom: false,
    lineEnding: LineEnding.lf,
    sha256: 'x',
  );

  testWidgets('review fix: the document takes typing right after an install', (
    tester,
  ) async {
    // The new field inherited focus without a focus change, so it never
    // opened an input connection: typing was dropped until a click.
    final c = EditorController(displayPath: 'a.txt', initialText: 'v1');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(tester.testTextInput.hasAnyClients, isTrue);

    c.adoptDocument(disk('v2'), replaceText: true);
    await tester.pumpAndSettle();
    expect(c.editorFocus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'v2!',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(c.text.text, 'v2!');
  });

  testWidgets('review fix: an install keeps the caret and the scroll', (
    tester,
  ) async {
    // A revert or reload reset both, losing the reader's place.
    final lines = List.generate(400, (i) => 'line $i').join('\n');
    final c = EditorController(displayPath: 'a.txt', initialText: lines);
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    c.goToLine(300, column: 3);
    await tester.pumpAndSettle();
    final offset = c.scroll.offset;
    final caret = c.text.selection;
    expect(offset, greaterThan(0));

    c.adoptDocument(disk(lines), replaceText: true);
    await tester.pumpAndSettle();
    expect(c.text.selection, caret);
    expect(c.scroll.offset, offset);

    // A shorter file keeps as much of the place as it has.
    c.adoptDocument(disk('short'), replaceText: true);
    await tester.pumpAndSettle();
    expect(c.text.selection, const TextSelection.collapsed(offset: 5));
  });
}
