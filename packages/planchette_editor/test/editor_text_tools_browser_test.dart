import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Past the undo-merge window a tool run waits out — the default quiet
/// period plus margin, so the tests follow the constant, not a copy of it.
final _undoWait =
    EditorController.defaultUndoQuiet + const Duration(milliseconds: 100);

Widget _app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

/// Pumps an editor with the catalog browser open, after settling the
/// undo-quiet window so immediate rows apply without a further wait.
Future<EditorController> _pumpBrowser(
  WidgetTester tester,
  String text, {
  Size? size,
  double textScale = 1.0,
}) async {
  final editor = EditorController(displayPath: 'notes.txt', initialText: text);
  addTearDown(editor.dispose);
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() async => tester.binding.setSurfaceSize(null));
  }
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: _app(editor),
    ),
  );
  await tester.pump();
  editor.text.selection = const TextSelection.collapsed(offset: 0);
  await tester.pump(_undoWait);
  editor.openTextTools();
  await tester.pump();
  return editor;
}

Finder _filterField() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && widget.decoration?.hintText == 'Filter tools',
);

/// The browser's scrolling list, for bringing lazy rows into view.
Finder _browserList() => find.descendant(
  of: find.byType(TextToolsBrowser),
  matching: find.byType(ListView),
);

/// Scrolls until [target] is visible, for rows the lazy list has not
/// built yet. Steps less than the shortest viewport — a taller step can
/// jump a row past the visible window between evaluations, so the loop
/// never sees it onstage.
Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(
    target,
    _browserList(),
    const Offset(0, -100),
    maxIteration: 300,
  );
  await tester.pump();
}

void main() {
  group('textToolsOpen', () {
    EditorController controller() {
      final c = EditorController(
        displayPath: 'a.txt',
        initialText: 'b\na',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      return c;
    }

    test('opens and closes', () {
      final c = controller();

      expect(c.textToolsOpen, isFalse);
      c.openTextTools();
      expect(c.textToolsOpen, isTrue);
      c.closeTextTools();
      expect(c.textToolsOpen, isFalse);
    });

    test('opening closes find, go to line and the options bar', () {
      final c = controller();
      c.openSearch();
      c.openTextTools();

      expect(c.textToolsOpen, isTrue);
      expect(c.searchOpen, isFalse);
    });

    test('opening find, go to line or the bar closes the browser', () {
      final c = controller();
      c.openTextTools();
      c.openSearch();
      expect(c.textToolsOpen, isFalse);

      c.openTextTools();
      c.openGoToLine();
      expect(c.textToolsOpen, isFalse);

      c.openTextTools();
      c.openTextTool('sortLines');
      expect(c.textToolsOpen, isFalse);
      expect(c.toolBarTool?.id, 'sortLines');
    });

    test('does not open while loading', () {
      final c = EditorController(
        displayPath: 'a.txt',
        loadDocument: () => Completer<TextDocument>().future,
      );
      addTearDown(c.dispose);

      c.openTextTools();

      expect(c.textToolsOpen, isFalse);
    });

    test('chooseTextTool throws for a tool outside the catalog', () {
      final c = controller();

      expect(() => c.chooseTextTool('notATool'), throwsArgumentError);
    });

    test('chooseTextTool sends an options tool to the bar', () {
      final c = controller();

      c.openTextTools();
      c.chooseTextTool('sortLines');

      expect(c.textToolsOpen, isFalse);
      expect(c.toolBarTool?.id, 'sortLines');
    });

    test('chooseTextTool sends a pattern tool to its find row', () {
      final c = controller();

      c.openTextTools();
      c.chooseTextTool('keepLinesMatching');

      expect(c.textToolsOpen, isFalse);
      expect(c.searchOpen, isTrue);
      expect(c.lineActionsOpen, isTrue);
    });

    test('chooseTextTool runs an immediate tool and reports it', () async {
      final c = controller();

      c.openTextTools();
      c.chooseTextTool('reverseLines');
      // The immediate run is applied asynchronously.
      await Future<void>.delayed(Duration.zero);

      expect(c.textToolsOpen, isFalse);
      expect(c.text.text, 'a\nb');
      expect(c.toolReport?.tool.id, 'reverseLines');
    });

    test('repeatTextTool is null before the first run', () async {
      final c = controller();

      expect(await c.repeatTextTool(), isNull);
    });

    test('runRecentTextTool replays a recorded bar run', () async {
      final c = controller();
      await c.runTextTool('reverseLines');
      final record = c.toolHistory.last!;

      c.text.selection = const TextSelection.collapsed(offset: 0);
      await c.runRecentTextTool(record);

      expect(c.text.text, 'b\na');
    });

    test('runRecentTextTool reopens a recorded pattern run', () async {
      final c = controller();
      const record = TextToolRunRecord('keepLinesMatching', {
        'pattern': 'b',
        'regularExpression': false,
        'caseSensitive': false,
        'wholeWord': false,
      });

      await c.runRecentTextTool(record);

      expect(c.searchOpen, isTrue);
      expect(c.lineActionsOpen, isTrue);
      expect(c.search.text, 'b');
    });

    test('runRecentTextTool ignores a record for a removed tool', () async {
      final c = controller();
      const record = TextToolRunRecord('gone', {});

      expect(await c.runRecentTextTool(record), isNull);
      expect(c.searchOpen, isFalse);
      expect(c.textToolsOpen, isFalse);
    });
  });

  group('TextToolsBrowser', () {
    testWidgets('lists Repeat and Recent before the seven groups', (
      tester,
    ) async {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: 'b\na',
        undoQuiet: Duration.zero,
      );
      addTearDown(editor.dispose);
      await tester.pumpWidget(_app(editor));
      await tester.pump();
      await editor.runTextTool('reverseLines');
      await tester.pump();
      editor.openTextTools();
      await tester.pump();

      expect(find.text('Repeat Reverse Lines'), findsOneWidget);
      expect(find.text('Reverse Lines'), findsOneWidget);
      // Repeat heads the list; the first group follows Recent.
      expect(
        tester.getTopLeft(find.text('Repeat Reverse Lines')).dy,
        lessThan(tester.getTopLeft(find.text('Repeat and Recent')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Repeat and Recent')).dy,
        lessThan(tester.getTopLeft(find.text('Lines')).dy),
      );
      // One downward pass: the lazy list evicts rows far from the
      // viewport, so each row is asserted while it is in view.
      expect(find.text('Lines'), findsOneWidget);
      await _reveal(
        tester,
        find.text('Deletes repeated lines, keeping the first of each.'),
      );
      expect(
        find.text('Deletes repeated lines, keeping the first of each.'),
        findsOneWidget,
      );
      for (final group in [
        'Case',
        'Whitespace',
        'Clean Up',
        'Wrap',
        'Encode',
        'Insert',
      ]) {
        await _reveal(tester, find.text(group));
        expect(find.text(group), findsOneWidget);
      }
    });

    testWidgets('the filter matches names, descriptions and keywords', (
      tester,
    ) async {
      await _pumpBrowser(tester, 'b\na');

      await tester.enterText(_filterField(), 'dedupe');
      await tester.pump();

      expect(find.text('Remove Duplicate Lines…'), findsOneWidget);
      expect(find.text('Sort Lines…'), findsNothing);
    });

    testWidgets('an empty filter match says so', (tester) async {
      await _pumpBrowser(tester, 'b\na');

      await tester.enterText(_filterField(), 'zzz-no-such-tool');
      await tester.pump();

      expect(find.text('No tools match.'), findsOneWidget);
    });

    testWidgets('choosing an immediate tool runs it and closes', (
      tester,
    ) async {
      final editor = await _pumpBrowser(tester, 'b\na');

      await tester.tap(find.text('Reverse Lines'));
      await tester.pump(_undoWait);

      expect(editor.text.text, 'a\nb');
      expect(editor.textToolsOpen, isFalse);
      expect(editor.toolReport?.tool.id, 'reverseLines');
      expect(find.text('Reverse Lines'), findsNothing);
    });

    testWidgets('choosing an options tool opens its bar', (tester) async {
      final editor = await _pumpBrowser(tester, 'b\na');

      await tester.tap(find.text('Sort Lines…'));
      await tester.pump();
      // Lets the bar's dry-run timer fire before the test ends.
      await tester.pump(const Duration(milliseconds: 200));

      expect(editor.textToolsOpen, isFalse);
      expect(editor.toolBarTool?.id, 'sortLines');
      expect(find.text('Sort Lines…'), findsNothing);
    });

    testWidgets('choosing a pattern tool opens its find row', (tester) async {
      final editor = await _pumpBrowser(tester, 'b\na\nc');

      await _reveal(tester, find.text('Keep Lines Matching…'));
      await tester.tap(find.text('Keep Lines Matching…'));
      await tester.pump();
      // Lets the row's debounced count settle before the test ends.
      await tester.pump(const Duration(milliseconds: 500));

      expect(editor.textToolsOpen, isFalse);
      expect(editor.searchOpen, isTrue);
      expect(editor.lineActionsOpen, isTrue);
    });

    testWidgets('the Repeat row reruns the last tool', (tester) async {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: 'b\na',
        undoQuiet: Duration.zero,
      );
      addTearDown(editor.dispose);
      await tester.pumpWidget(_app(editor));
      await tester.pump();
      await editor.runTextTool('reverseLines');
      await tester.pump();
      editor.openTextTools();
      await tester.pump();

      await tester.tap(find.text('Repeat Reverse Lines'));
      await tester.pump();

      expect(editor.text.text, 'b\na');
      expect(editor.textToolsOpen, isFalse);
    });

    testWidgets('Escape closes the browser and refocuses the document', (
      tester,
    ) async {
      final editor = await _pumpBrowser(tester, 'b\na');

      // Opening focuses the filter, so Escape leaves from there.
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'text tools filter',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(editor.textToolsOpen, isFalse);
      expect(editor.editorFocus.hasFocus, isTrue);
    });

    testWidgets('a locked document browses with disabled rows', (tester) async {
      final editor = await _pumpBrowser(tester, 'b\na');
      editor.setEditingLocked(true);
      await tester.pump();

      // The list stays open for reading; no row runs.
      expect(editor.textToolsOpen, isTrue);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Reverse Lines'))
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Reverse Lines'), warnIfMissed: false);
      await tester.pump(_undoWait);

      expect(editor.text.text, 'b\na');
      expect(editor.toolReport, isNull);
    });

    testWidgets('a 320 px phone width scrolls without overflow', (
      tester,
    ) async {
      await _pumpBrowser(tester, 'b\na', size: const Size(320, 568));

      // Builds every row on the way down, asserting while in view.
      await _reveal(tester, find.text('Insert'));
      expect(find.text('Insert'), findsOneWidget);
      await _reveal(tester, find.text('UUID'));
      expect(find.text('UUID'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a doubled text scale lays out without overflow', (
      tester,
    ) async {
      await _pumpBrowser(
        tester,
        'b\na',
        size: const Size(320, 568),
        textScale: 2.0,
      );

      await _reveal(tester, find.text('Insert'));
      await tester.enterText(_filterField(), 'dedupe');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Remove Duplicate Lines…'), findsOneWidget);
    });

    testWidgets('the title and groups announce as headings', (tester) async {
      await _pumpBrowser(tester, 'b\na');

      expect(find.bySemanticsLabel('Text Tools'), findsOneWidget);
      expect(find.bySemanticsLabel('Lines'), findsOneWidget);
      // A row merges its name and description into one announcement.
      await _reveal(
        tester,
        find.text('Deletes repeated lines, keeping the first of each.'),
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Deletes repeated lines, keeping the first of each.'),
        ),
        findsOneWidget,
      );
    });
  });
}
