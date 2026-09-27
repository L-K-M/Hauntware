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
  testWidgets('caret-line band follows the caret and survives scrolling', (
    tester,
  ) async {
    final c = EditorController(
      displayPath: 'test',
      initialText: List.generate(40, (i) => 'line $i').join('\n'),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    String band() =>
        (tester.widget<CustomPaint>(find.byKey(const ValueKey('editor-caret-band'))).painter)
            .toString();
    expect(band(), contains('caretLine: 1'));
    c.text.selection = const TextSelection.collapsed(offset: 15);
    await tester.pump();
    expect(band(), contains('caretLine: 3'));
    expect(c.scroll.hasClients, isTrue);
    c.scroll.jumpTo(120);
    await tester.pump();
    expect(band(), contains('caretLine: 3'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('caret-line band covers a wrapped final line', (tester) async {
    final c = EditorController(
      displayPath: 'test',
      initialText: 'one\n${'word ' * 40}',
    );
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(240, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.text.selection = TextSelection.collapsed(
      offset: c.text.text.length,
    );
    await tester.pump();
    // The painter is library-private; read its fields dynamically rather
    // than parsing a toString() contract.
    final painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('editor-caret-band')))
        .painter!;
    final lineTops = (painter as dynamic).lineTops as List<double>;
    final lineHeight = (painter as dynamic).lineHeight as double;
    final documentHeight = (painter as dynamic).documentHeight as double;
    // The only line wraps, so the laid-out height must exceed one row.
    expect(lineTops.length, 2);
    expect(documentHeight, greaterThan(lineHeight * 3));
  });

  testWidgets('caret-line band can be disabled by hosts', (tester) async {
    final c = EditorController(displayPath: 'test', initialText: 'x');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: c,
            highlightCaretLine: false,
            showLineNumbers: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('editor-caret-band')), findsNothing);
  });

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
}
