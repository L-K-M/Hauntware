import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

EditorController editorFor(String text, {String path = 'a.txt'}) =>
    EditorController(displayPath: path, initialText: text);

Finder findField(EditorController c) =>
    find.byWidgetPredicate((w) => w is TextField && w.controller == c.search);

void main() {
  testWidgets('a literal search still works', (tester) async {
    final c = editorFor('cat CAT cat');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'cat';
    await tester.pump();
    expect(c.matches, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pattern toggle searches with a regular expression', (
    tester,
  ) async {
    final c = editorFor('a TODO here\nTODO: fix');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = r'\bTODO\b';
    await tester.pump();
    expect(c.matches, isEmpty, reason: 'literal by default');

    c.toggleRegularExpression();
    await tester.pump();
    expect(c.matches, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a broken pattern says so rather than finding nothing', (
    tester,
  ) async {
    final c = editorFor('anything at all');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.toggleRegularExpression();
    c.search.text = '(unclosed';
    await tester.pump();

    expect(c.matches, isEmpty);
    expect(c.findError, isNotNull);
    expect(find.textContaining('Unterminated'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the error clears when the pattern is fixed', (tester) async {
    final c = editorFor('TODO one');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.toggleRegularExpression();
    c.search.text = '(unclosed';
    await tester.pump();
    expect(c.findError, isNotNull);

    c.search.text = 'TODO';
    await tester.pump();
    expect(c.findError, isNull);
    expect(c.matches, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the toggle is offered with a tooltip and reflects its state', (
    tester,
  ) async {
    final c = editorFor('text');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    await tester.pump();
    expect(find.byTooltip('Regular expression'), findsOneWidget);
    expect(c.useRegularExpression, isFalse);

    await tester.tap(find.byTooltip('Regular expression'));
    await tester.pump();
    expect(c.useRegularExpression, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the find field looks like a field', (tester) async {
    final c = editorFor('text');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    await tester.pump();
    final field = tester.widget<TextField>(findField(c));
    // A borderless, iconless field does not read as something to type into.
    expect(field.decoration?.border, isNot(InputBorder.none));
    expect(field.decoration?.prefixIcon, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the clear button empties the query', (tester) async {
    final c = editorFor('cat');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'cat';
    await tester.pump();
    expect(c.search.text, 'cat');

    await tester.tap(find.byTooltip('Clear the search'));
    await tester.pump();
    expect(c.search.text, isEmpty);
    expect(c.matches, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the status bar reports a selection', (tester) async {
    final c = editorFor('one two three');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    expect(find.textContaining('selected'), findsNothing);

    c.text.selection = const TextSelection(baseOffset: 4, extentOffset: 7);
    await tester.pump();
    expect(find.textContaining('3 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the status bar counts words with a selection', (tester) async {
    final c = editorFor('one two three');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await tester.pump();
    // "one two" is two words and seven characters.
    expect(find.textContaining('2 words'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a document change refreshes an open search', (tester) async {
    final c = editorFor('cat');
    addTearDown(c.dispose);
    await tester.pumpWidget(app(c));
    await tester.pump();
    c.openSearch();
    c.search.text = 'cat';
    await tester.pump();
    expect(c.matches, hasLength(1));

    c.text.text = 'cat and a dog';
    await tester.pump();
    expect(c.matches, hasLength(1));
    expect(find.text('1/1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
