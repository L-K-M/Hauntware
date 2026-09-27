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

/// Put the caret in the document and settle, so a key event reaches the editor
/// rather than whatever the test harness focused first.
///
/// The focus node is focused directly instead of tapping the field: a tap
/// places the caret where it landed, and the field's own selection
/// reconciliation can then override the offset this was asked for.
Future<void> focusDocument(
  EditorController c,
  WidgetTester tester,
  int offset, {
  int? extent,
}) async {
  c.editorFocus.requestFocus();
  await tester.pump();
  c.text.selection = TextSelection(
    baseOffset: offset,
    extentOffset: extent ?? offset,
  );
  await tester.pump();
}

class TestStrings extends EditorStrings {
  const TestStrings();
  @override
  String get replace => 'Remplacer';
  @override
  String get replaceAll => 'Tout remplacer';
}

void main() {
  testWidgets(
    'shared search, replacement, gutter and statistics work together',
    (tester) async {
      final c = EditorController(
        displayPath: '.env',
        initialText: 'A=cat\nB=CAT\n',
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(c, strings: const TestStrings()));
      await tester.pump();
      expect(find.byKey(const ValueKey('editor-line-gutter')), findsOneWidget);
      expect(find.textContaining('3 lines'), findsOneWidget);
      c.openSearch(replace: true);
      await tester.pump();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller == c.search,
        ),
        'cat',
      );
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller == c.replacement,
        ),
        'dog',
      );
      await tester.tap(find.text('Tout remplacer'));
      await tester.pump();
      expect(c.text.text, 'A=dog\nB=dog\n');
      expect(find.text('Remplacer'), findsOneWidget);
    },
  );
  testWidgets('replacement can be undone and redone in the document', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'test', initialText: 'cat cat');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump(const Duration(milliseconds: 600));
    c.openSearch(replace: true);
    c.search.text = 'cat';
    c.replacement.text = 'dog';
    await tester.pump();
    c.replaceAll();
    await tester.pump(const Duration(milliseconds: 600));
    c.closeSearch();
    await tester.pump();
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'cat cat');
    c.undoController.redo();
    await tester.pump();
    expect(c.text.text, 'dog dog');
  });
  testWidgets('IME composing text retains framework rendering', (tester) async {
    final c = EditorController(displayPath: '.env', initialText: 'KEY=value');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    c.text.value = const TextEditingValue(
      text: 'KEY=文字',
      selection: TextSelection.collapsed(offset: 6),
      composing: TextRange(start: 4, end: 6),
    );
    await tester.pump();
    final context = tester.element(find.byType(PlanchetteEditor));
    final span = c.text.buildTextSpan(context: context, withComposing: true);
    expect(span.toPlainText(), 'KEY=文字');
    expect(
      span.children!.whereType<TextSpan>().any(
        (s) => s.style?.decoration == TextDecoration.underline,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('inactive editor releases focus', (tester) async {
    final c = EditorController(displayPath: 'test', initialText: 'text');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    expect(c.editorFocus.hasFocus, isTrue);
    await tester.pumpWidget(app(c, active: false));
    await tester.pump();
    expect(c.editorFocus.hasFocus, isFalse);
  });
  testWidgets('reparenting a controller between host layouts paints safely', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'test', initialText: 'one\ntwo\n');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('Host chrome'),
              Expanded(child: PlanchetteEditor(controller: c)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(c.scroll.positions.length, 1);
    expect(c.text.text, 'one\ntwo\n');
  });
  testWidgets('locked editor blocks native undo', (tester) async {
    final c = EditorController(displayPath: 'test', initialText: 'before');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(
      find.byKey(const ValueKey('planchette.document')),
      'after',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(app(c, locked: true));
    Actions.maybeInvoke(
      c.editorFocus.context!,
      const UndoTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();
    expect(c.text.text, 'after');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
          .readOnly,
      isTrue,
    );
  });
  testWidgets('Tab reaches the buffer instead of the focus ring', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'def f():\n');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await focusDocument(c, tester, 9);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'def f():\n    ');
    expect(c.editorFocus.hasFocus, isTrue, reason: 'focus must stay put');
  });

  testWidgets('Tab pads to the next stop when the caret follows code', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'x = 1');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await focusDocument(c, tester, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'x    = 1');
  });

  testWidgets('Tab keeps a tab-indented file on tabs', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'if x:\n\ty');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    // The caret is still inside the line's tab indentation.
    await focusDocument(c, tester, 7);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'if x:\n\t\ty');
  });

  testWidgets('Tab stays a tab when a tab-indented caret follows code', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'if x:\n\ty');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    // The caret is after the 'y', at rendered column 5, so the next tab stop
    // is column 8. A literal tab lands there just as spaces would, and a
    // tab-indented file does not pick up spaces because of where the caret was.
    await focusDocument(c, tester, 8);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'if x:\n\ty\t');
  });

  testWidgets('Shift+Tab dedents the caret line', (tester) async {
    final c = EditorController(
      displayPath: 'a.py',
      initialText: '    one\n        two',
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await focusDocument(c, tester, 14);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(c.text.text, '    one\n    two');
  });

  testWidgets('Tab indents every line a block selection touches', (
    tester,
  ) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'one\ntwo');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await focusDocument(c, tester, 0, extent: 7);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, '    one\n    two');
  });

  testWidgets('a locked editor ignores Tab', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'def f():');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c, locked: true));
    await focusDocument(c, tester, 7);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'def f():');
  });

  testWidgets('Find Next reopens a closed find bar', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'a needle a');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'needle';
    await tester.pump();
    expect(c.matches, hasLength(1));
    c.closeSearch();
    await tester.pump();
    expect(c.searchOpen, isFalse);

    c.nextMatch();
    await tester.pump();

    expect(c.searchOpen, isTrue);
    expect(c.matches, hasLength(1));
  });

  testWidgets('Find Previous reopens a closed find bar too', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'a needle a');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'needle';
    await tester.pump();
    c.closeSearch();
    await tester.pump();

    c.previousMatch();
    await tester.pump();

    expect(c.searchOpen, isTrue);
  });

  testWidgets('F3 reopens a closed find bar from the keyboard', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'needle');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'needle';
    await tester.pump();
    c.closeSearch();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();

    expect(c.searchOpen, isTrue);
  });
  testWidgets('an indent is its own undo step', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'def f():\n');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await focusDocument(c, tester, 9);
    // UndoHistory coalesces changes for 500 ms, so an undo inside that window
    // is swallowed by the framework for any edit, typed or not. Past it, the
    // indent must be a step of its own rather than merged into the next
    // character.
    await tester.pump(const Duration(milliseconds: 700));
    expect(c.undoController.value.canUndo, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(c.text.text, 'def f():\n    ');
    expect(c.undoController.value.canUndo, isTrue);
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'def f():\n');
  });

  testWidgets('a locked editor leaves Tab for focus traversal', (tester) async {
    final c = EditorController(displayPath: 'a.py', initialText: 'def f():');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c, locked: true));
    await focusDocument(c, tester, 7);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(c.text.text, 'def f():');
    // The shortcut map is empty, so the key is not consumed and focus traversal
    // still gets it. A keyboard user viewing a locked document must be able to
    // Tab past the editor, not have the key die in a read-only buffer.
    final shortcuts = tester.widget<Shortcuts>(
      find.descendant(
        of: find.byType(PlanchetteEditor),
        matching: find.byType(Shortcuts),
      ),
    );
    expect(
      shortcuts.shortcuts.keys.where(
        (activator) =>
            activator is SingleActivator &&
            activator.trigger == LogicalKeyboardKey.tab,
      ),
      isEmpty,
    );
  });
}
