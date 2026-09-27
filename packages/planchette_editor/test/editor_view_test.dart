import 'dart:io';

import 'package:flutter/material.dart';
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
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'reloaded');
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
}
