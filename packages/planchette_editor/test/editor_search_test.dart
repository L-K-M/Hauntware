import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

const _undoHistoryDelay = Duration(milliseconds: 600);

enum _EditingAccess { editable, locked }

class _LongStrings extends EditorStrings {
  const _LongStrings();

  @override
  String get replace => 'Diese Übereinstimmung ersetzen';

  @override
  String get replaceAll => 'Alle Übereinstimmungen ersetzen';

  @override
  String matchCount(int current, int total, {bool capped = false}) =>
      'Übereinstimmung $current von insgesamt $total';
}

Widget _app(
  EditorController controller, {
  double textScale = 1,
  EditorStrings strings = const EditorStrings(),
  _EditingAccess access = _EditingAccess.editable,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: PlanchetteEditor(
      controller: controller,
      strings: strings,
      editingLocked: access == _EditingAccess.locked,
    ),
  ),
);

Finder _field(TextEditingController controller) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.controller == controller,
);

void main() {
  for (final width in [320.0, 360.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('search fits width $width at text scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = EditorController(
          displayPath: 'test.txt',
          initialText: 'cat CAT cat',
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _app(controller, textScale: scale, strings: const _LongStrings()),
        );
        controller.openSearch(replace: true);
        controller.search.text = 'cat';
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(tester.getSize(_field(controller.search)).width, width - 24);
        expect(
          tester.getSize(_field(controller.replacement)).width,
          width - 24,
        );
        expect(
          find.text(const _LongStrings().replaceAll).hitTestable(),
          findsOneWidget,
        );
      });
    }
  }

  testWidgets('desktop keeps fields beside search and replacement controls', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    controller.openSearch(replace: true);
    controller.search.text = 'cat';
    await tester.pumpAndSettle();

    final query = tester.getRect(_field(controller.search));
    final replace = tester.getRect(_field(controller.replacement));
    expect(
      query.contains(tester.getCenter(find.byTooltip('Match case'))),
      isFalse,
    );
    expect(
      tester.getCenter(find.byTooltip('Match case')).dy,
      closeTo(query.center.dy, 1),
    );
    expect(
      tester.getCenter(find.text('Replace all')).dy,
      closeTo(replace.center.dy, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard reaches search toggles and replace all with undo', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat CAT cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pump(_undoHistoryDelay);
    controller.openSearch(replace: true);
    controller.search.text = 'cat';
    controller.replacement.text = 'dog';
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.caseSensitive, isTrue);
    expect(
      tester.getSemantics(find.byTooltip('Match case')),
      isSemantics(isSelected: true, isButton: true),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.wholeWord, isTrue);
    expect(
      tester.getSemantics(find.byTooltip('Whole words')),
      isSemantics(isSelected: true, isButton: true),
    );

    // Traverse previous, next, replace toggle, close, replacement, replace, all.
    for (var step = 0; step < 7; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(_undoHistoryDelay);
    expect(controller.text.text, 'dog CAT dog');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.searchOpen, isFalse);
    expect(controller.editorFocus.hasFocus, isTrue);
    controller.undoController.undo();
    await tester.pump();
    expect(controller.text.text, 'cat CAT cat');
  });

  testWidgets('locked search keeps navigation but disables replacement', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat CAT cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, access: _EditingAccess.locked));
    controller.openSearch(replace: true);
    controller.search.text = 'cat';
    controller.replacement.text = 'dog';
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.caseSensitive, isTrue);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Replace'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Replace all'))
          .onPressed,
      isNull,
    );
    expect(controller.text.text, 'cat CAT cat');
  });

  testWidgets('keyboard toggles replacement and preserves query selection', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    controller.search.text = 'cat';
    controller.openSearch();
    await tester.pumpAndSettle();
    final selection = controller.search.selection;

    // Match case, whole words, previous, next, then the replace toggle.
    for (var step = 0; step < 5; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.replaceOpen, isTrue);
    expect(controller.search.selection, selection);
    expect(
      tester.getSemantics(find.byTooltip('Find and replace')),
      isSemantics(isSelected: true, isButton: true),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.replaceOpen, isFalse);
    expect(
      tester.getSemantics(find.byTooltip('Find and replace')),
      isSemantics(isSelected: false, isButton: true),
    );
  });

  testWidgets(
    'resizing preserves search and replacement focus and composition',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = EditorController(
        displayPath: 'test.txt',
        initialText: 'cat cat',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller));
      controller.openSearch(replace: true);
      await tester.pumpAndSettle();

      const composing = TextEditingValue(
        text: 'ca',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      for (final (field, focus) in [
        (controller.search, controller.searchFocus),
        (controller.replacement, controller.replacementFocus),
      ]) {
        focus.requestFocus();
        await tester.pump();
        tester.testTextInput.updateEditingValue(composing);
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);

        for (final width in [320.0, 800.0]) {
          await tester.binding.setSurfaceSize(Size(width, 900));
          await tester.pumpAndSettle();
          expect(focus.hasFocus, isTrue);
          expect(field.value, composing);
          expect(tester.testTextInput.isVisible, isTrue);
        }
      }
    },
  );

  testWidgets('the counter numbers a later page within the document', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'log.txt',
      initialText: List.filled(searchMatchLimit + 3, 'hit').join('\n'),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    controller
      ..openSearch()
      ..search.text = 'hit';
    await tester.pump();
    expect(find.text('1/1000+'), findsOneWidget);

    for (var i = 0; i < searchMatchLimit; i++) {
      controller.nextMatch();
    }
    await tester.pump();
    // The second page holds three matches, but they are the document's
    // 1,001st to 1,003rd, and nothing follows them.
    expect(find.text('1001/1003'), findsOneWidget);
  });

  testWidgets('F3 after closing find leaves typing in the document', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat dog cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    controller
      ..openSearch()
      ..search.text = 'cat';
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.searchOpen, isFalse);
    expect(controller.editorFocus.hasFocus, isTrue);

    // The caret never left the start, so the first match is next.
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pumpAndSettle();
    expect(controller.searchOpen, isTrue);
    expect(controller.editorFocus.hasFocus, isTrue);
    expect(
      controller.text.selection,
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pumpAndSettle();
    expect(
      controller.text.selection,
      const TextSelection(baseOffset: 8, extentOffset: 11),
    );
  });

  testWidgets('review fix: Escape on a find bar button closes the find bar', (
    tester,
  ) async {
    // With both bars open, the find bar's controls are part of it too.
    final controller = EditorController(
      displayPath: 'test.txt',
      initialText: 'cat dog cat',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    controller.openGoToLine();
    await tester.pumpAndSettle();
    controller
      ..openSearch()
      ..search.text = 'cat';
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(controller.searchFocus.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.searchOpen, isFalse);
    expect(controller.goToLineOpen, isTrue);
  });

  testWidgets(
    'review fix: Find Next with nothing focused types into the text',
    (tester) async {
      // The reopened find field autofocused when nothing held focus, such as
      // after a click outside the document, so typing edited the query.
      final controller = EditorController(
        displayPath: 'test.txt',
        initialText: 'cat dog cat',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller));
      controller
        ..openSearch()
        ..search.text = 'cat';
      await tester.pumpAndSettle();
      controller.closeSearch();
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(controller.editorFocus.hasFocus, isFalse);

      controller.nextMatch();
      await tester.pumpAndSettle();
      expect(controller.searchOpen, isTrue);
      expect(controller.searchFocus.hasFocus, isFalse);
      expect(controller.editorFocus.hasFocus, isTrue);
    },
  );
}
