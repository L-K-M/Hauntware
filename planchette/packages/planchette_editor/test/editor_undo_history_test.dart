import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

final document = find.byKey(const ValueKey('planchette.document'));

/// Types [chars] at the caret one keystroke at a time, the way the platform
/// reports them, [gap] apart.
Future<void> type(
  WidgetTester tester,
  EditorController c,
  String chars, {
  Duration gap = const Duration(milliseconds: 50),
}) async {
  for (final char in chars.split('')) {
    final at = c.text.selection.extentOffset;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: c.text.text.replaceRange(at, at, char),
        selection: TextSelection.collapsed(offset: at + 1),
      ),
    );
    // Frame by frame, so animations the keystroke starts can finish.
    for (var left = gap; left > Duration.zero; left -= _frame) {
      await tester.pump(left < _frame ? left : _frame);
    }
  }
}

const _frame = Duration(milliseconds: 100);

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  final modifier = defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

/// How many steps Flutter's own field history can take back: it is
/// stepped until the text stops changing. This changes the buffer.
Future<int> fieldHistoryDepth(WidgetTester tester, EditorController c) async {
  final field = tester.state<UndoHistoryState<TextEditingValue>>(
    find.byType(UndoHistory<TextEditingValue>),
  );
  var depth = 0;
  while (true) {
    final before = c.text.text;
    field.undo();
    await tester.pump();
    if (c.text.text == before) return depth;
    depth++;
  }
}

void main() {
  testWidgets(
    'shortcuts undo and redo a word at a time',
    (tester) async {
      final c = EditorController(displayPath: 'a.txt', initialText: '');
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c));
      await tester.showKeyboard(document);

      await type(tester, c, 'hello world');
      expect(c.text.text, 'hello world');

      await chord(tester, LogicalKeyboardKey.keyZ);
      expect(c.text.text, 'hello ');
      await chord(tester, LogicalKeyboardKey.keyZ);
      expect(c.text.text, '');
      expect(c.undoController.value.canUndo, isFalse);

      await chord(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(c.text.text, 'hello ');
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await chord(tester, LogicalKeyboardKey.keyY);
      } else {
        await chord(tester, LogicalKeyboardKey.keyZ, shift: true);
      }
      expect(c.text.text, 'hello world');
      expect(c.text.selection, const TextSelection.collapsed(offset: 11));
      expect(c.undoController.value.canRedo, isFalse);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('typing after an undo clears redo', (tester) async {
    final c = EditorController(displayPath: 'a.txt', initialText: '');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(document);
    await type(tester, c, 'abc');
    c.undo();
    await tester.pump();
    expect(c.undoController.value.canRedo, isTrue);
    await type(tester, c, 'x');
    expect(c.undoController.value.canRedo, isFalse);
    c.redo();
    expect(c.text.text, 'x');
  });

  testWidgets('a composition is recorded only once it commits', (tester) async {
    final c = EditorController(displayPath: 'a.txt', initialText: '');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(document);
    await type(tester, c, 'ab ');
    await tester.pump(const Duration(seconds: 1));

    for (final (text, end) in [('ab k', 4), ('ab か', 4), ('ab かん', 5)]) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: end),
          composing: TextRange(start: 3, end: end),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
    }
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ab 漢',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();

    // No half-composed state comes back: one undo takes the whole commit.
    c.undo();
    await tester.pump();
    expect(c.text.text, 'ab ');
    c.redo();
    await tester.pump();
    expect(c.text.text, 'ab 漢');
  });

  testWidgets('undo during a composition takes back the composition', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'a.txt', initialText: 'ab');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(document);
    c.text.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'abか',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      ),
    );
    await tester.pump();
    expect(c.undoController.value.canUndo, isTrue);
    c.undo();
    await tester.pump();
    expect(c.text.text, 'ab');
    expect(c.text.value.composing.isValid, isFalse);
  });

  testWidgets('a text tool run is one step between typing', (tester) async {
    final c = EditorController(
      displayPath: 'a.txt',
      initialText: '',
      undoQuiet: Duration.zero,
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(document);
    await type(tester, c, 'abc');
    c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await c.runTextTool('uppercase');
    await tester.pump();
    expect(c.text.text, 'ABC');
    c.undo();
    expect(c.text.text, 'abc');
    c.undo();
    expect(c.text.text, '');
  });

  testWidgets('Flutter\'s field history stays bounded', (tester) async {
    final budget = PlanchetteEditor.fieldSnapshotBudgetBytes;
    addTearDown(() => PlanchetteEditor.fieldSnapshotBudgetBytes = budget);
    // A 400-character document is 800 bytes a snapshot: four fit.
    PlanchetteEditor.fieldSnapshotBudgetBytes = 3200;
    final lines = List.generate(40, (i) => 'line ${i + 100}').join('\n');
    final c = EditorController(displayPath: 'a.txt', initialText: lines);
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.showKeyboard(document);
    c.text.selection = TextSelection.collapsed(offset: lines.length);
    await tester.pump();

    // Forty keystrokes, each in a throttle window of its own, would leave
    // forty snapshots in the field; the view remounts it in the pauses.
    final fields = <State>{};
    double? offset;
    for (var i = 0; i < 40; i++) {
      await type(tester, c, 'x', gap: const Duration(milliseconds: 600));
      fields.add(tester.state(find.byType(UndoHistory<TextEditingValue>)));
      // The first keystroke scrolls the caret's last line into view; a
      // remount keeps that place rather than starting at the top.
      offset ??= c.scroll.offset;
      expect(c.scroll.offset, offset);
    }
    expect(offset, greaterThan(0));
    expect(fields.length, greaterThan(5));
    expect(c.text.text, '$lines${'x' * 40}');
    expect(c.editorFocus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    // The editor's own undo still reaches back across every remount.
    for (var i = 0; i < 40; i++) {
      c.undo();
    }
    await tester.pump();
    expect(c.text.text, lines);
    for (var i = 0; i < 40; i++) {
      c.redo();
    }
    await tester.pump();
    expect(c.text.text, '$lines${'x' * 40}');

    // Typing still reaches the remounted field.
    await type(tester, c, '!');
    expect(c.text.text, '$lines${'x' * 40}!');

    expect(await fieldHistoryDepth(tester, c), lessThanOrEqualTo(5));
  });
}
