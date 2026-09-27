import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

final hundredLines = List.generate(100, (i) => 'line ${i + 1}').join('\n');

Future<EditorController> mount(
  WidgetTester tester, {
  String text = '',
  String path = 'notes.txt',
  TextDocument? document,
}) async {
  await tester.binding.setSurfaceSize(const Size(600, 400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c = document == null
      ? EditorController(displayPath: path, initialText: text)
      : EditorController(displayPath: path, loadDocument: () async => document);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PlanchetteEditor(controller: c)),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

bool get apple => defaultTargetPlatform == TargetPlatform.macOS;

void main() {
  testWidgets('the platform shortcut opens Go to Line and jumps into view', (
    tester,
  ) async {
    final c = await mount(tester, text: hundredLines);
    await chord(
      tester,
      apple ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft,
      apple ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.keyG,
    );
    expect(c.goToLineOpen, isTrue);
    expect(c.goToLineFocus.hasFocus, isTrue);
    expect(c.goToLineInput.text, '1');

    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller == c.goToLineInput,
      ),
      '80',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.goToLineOpen, isFalse);
    expect(c.caretLineColumn, (80, 1));
    expect(c.editorFocus.hasFocus, isTrue);
    expect(c.scroll.offset, greaterThan(0));
    final editable = c.editorFocus.context!
        .findAncestorStateOfType<EditableTextState>()!
        .renderEditable;
    final caret = editable.getLocalRectForCaret(c.text.selection.extent);
    expect(caret.top, greaterThanOrEqualTo(0));
    expect(caret.bottom, lessThanOrEqualTo(editable.size.height));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Control chords stay text bindings on macOS', (tester) async {
    final c = await mount(tester, text: 'abc');
    await chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyF,
    );
    await chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyG,
    );
    expect(c.searchOpen, isFalse);
    expect(c.goToLineOpen, isFalse);
    await chord(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyF);
    expect(c.searchOpen, isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('line:column, clamping, invalid input and Escape', (
    tester,
  ) async {
    final c = await mount(tester, text: 'ab\ncdef\ng');
    c.openGoToLine();
    c.goToLineInput.text = '2:3';
    expect(c.submitGoToLine(), isTrue);
    expect(c.caretLineColumn, (2, 3));

    c.goToLine(2, column: 99);
    expect(c.caretLineColumn, (2, 5));
    c.goToLine(99);
    expect(c.caretLineColumn, (3, 1));
    c.goToLine(0);
    expect(c.caretLineColumn, (1, 1));

    c.openGoToLine();
    c.goToLineInput.text = 'twelve';
    expect(c.submitGoToLine(), isFalse);
    expect(c.goToLineOpen, isTrue);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.goToLineOpen, isFalse);
    expect(c.editorFocus.hasFocus, isTrue);
  });

  testWidgets('clicking the position opens Go to Line', (tester) async {
    final c = await mount(tester, text: 'one\ntwo');
    await tester.tap(find.textContaining('Ln 1, Col 1'));
    await tester.pump();
    expect(c.goToLineOpen, isTrue);
  });

  testWidgets('status shows the saved size, language and selection', (
    tester,
  ) async {
    final c = await mount(
      tester,
      path: 'win.txt',
      document: TextDocument(
        file: File('win.txt'),
        text: 'ab\ncd\n',
        hasUtf8Bom: true,
        lineEnding: LineEnding.crlf,
        sha256: 'x',
      ),
    );
    // Six LF characters on screen; on disk a BOM and two CRs are added.
    expect(c.byteCount, 6);
    expect(find.textContaining('11 bytes'), findsOneWidget);
    expect(find.textContaining('Plain Text'), findsOneWidget);

    c.text.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    await tester.pump();
    expect(find.textContaining('3 selected on 2 lines'), findsOneWidget);

    final python = await mount(tester, text: 'x = 1', path: 'a.py');
    expect(python.text.language?.id, 'python');
    expect(find.textContaining('Python'), findsOneWidget);
  });
}
