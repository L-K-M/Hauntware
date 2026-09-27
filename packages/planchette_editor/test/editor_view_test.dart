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
  test('soft wrap is off until a host or the reader asks for it', () {
    final c = EditorController(displayPath: 'a.py', initialText: 'x');
    addTearDown(c.dispose);

    expect(c.softWrap, isFalse);
  });

  test('toggling soft wrap notifies once per change', () {
    final c = EditorController(displayPath: 'a.py', initialText: 'x');
    addTearDown(c.dispose);
    var notifications = 0;
    c.addListener(() => notifications++);

    c.setSoftWrap(true);
    c.setSoftWrap(true);
    c.setSoftWrap(false);

    expect(notifications, 2);
    expect(c.softWrap, isFalse);
  });

  testWidgets('without folding every line sits exactly one row apart', (
    tester,
  ) async {
    // 200 short lines in a tall-enough window. With folding off the gutter
    // knows each line's offset from the row height alone, so a reveal lands on
    // an exact, checkable position instead of a re-measured one.
    const lineHeight = 14 * 1.35;
    final text = List.generate(200, (i) => 'line $i').join('\n');
    final c = EditorController(displayPath: 'a.txt', initialText: text);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    c.openSearch();
    c.search.text = 'line 100';
    await tester.pumpAndSettle();

    expect(c.activeMatch, greaterThanOrEqualTo(0));
    // A third of the way down puts the match in the upper third of the window,
    // with the top inset and one third of the real viewport subtracted.
    final viewport = c.scroll.position.viewportDimension;
    expect(c.scroll.offset, closeTo(100 * lineHeight + 14 - viewport / 3, 0.5));
  });

  testWidgets('a folded long line still numbers every line it covers', (
    tester,
  ) async {
    final long = List.filled(300, 'word ').join();
    final c = EditorController(
      displayPath: 'a.txt',
      initialText: '$long\nsecond\nthird',
    );
    addTearDown(c.dispose);
    c.softWrap = true;
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('editor-line-gutter')), findsOneWidget);

    // A reveal has to fall back to a measured position once the rows and the
    // logical lines disagree, and must not throw while doing it.
    c.openSearch();
    c.search.text = 'third';
    await tester.pump();
    c.nextMatch();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(c.scroll.offset, greaterThanOrEqualTo(0));
  });

  testWidgets('a document past the highlight cap says so in the status bar', (
    tester,
  ) async {
    final small = EditorController(displayPath: 'a.py', initialText: 'x = 1');
    addTearDown(small.dispose);
    await tester.pumpWidget(app(small));
    await tester.pump();
    expect(find.textContaining('Large file'), findsNothing);
    expect(small.highlightingEnabled, isTrue);
    // The language is advertised while the file is small enough to highlight.
    expect(find.textContaining('python'), findsOneWidget);

    final large = EditorController(displayPath: 'a.py', initialText: '');
    addTearDown(large.dispose);
    large.text.value = TextEditingValue(
      text: 'x' * (syntaxHighlightingMaxChars + 1),
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pumpWidget(app(large));
    await tester.pumpAndSettle();

    expect(large.highlightingEnabled, isFalse);
    expect(find.textContaining('Large file'), findsOneWidget);
    // The language is not claimed while the file is too big to highlight.
    expect(find.textContaining('python'), findsNothing);
  });
}
