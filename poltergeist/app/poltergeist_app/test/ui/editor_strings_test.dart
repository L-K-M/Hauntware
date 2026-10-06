import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/ui/editor_strings.dart';

/// Marks the strings the shared find and Go to Line bars take from the
/// adapter, so the test sees whether the surface shows Poltergeist's copy
/// rather than the package's English defaults.
class _Marked extends AppLocalizationsEn {
  @override
  String get editorWholeWordsTooltip => '[whole words]';
  @override
  String get editorRegularExpressionTooltip => '[regex]';
  @override
  String get editorFindPatternHint => '[pattern]';
  @override
  String editorPatternInvalid(String detail) => '[invalid]';
  @override
  String get editorCloseGoToLineTooltip => '[close go to line]';
  @override
  String editorGoToLineHint(int lines) => '[1..$lines]';
  @override
  String editorGoToLineInvalid(int lines) => '[not 1..$lines]';
  @override
  String get editorTextToolsTitle => '[tools]';
  @override
  String get editorTextToolsFilterHint => '[filter]';
  @override
  String get editorTextToolNameSortLines => '[sort]';
  @override
  String get editorTextToolDescriptionSortLines => '[orders]';
  @override
  String get editorTextToolApply => '[apply]';
  @override
  String get editorTextToolAppliesTo => '[applies to]';
  @override
  String editorTextToolNoticeSentence(String name, String sentence) =>
      '$name :: $sentence';
  @override
  String editorTextToolChangedSortLines(
    int changed,
    int scope,
    String where,
  ) => '[moved $changed/$scope $where]';
  @override
  String get editorTextToolWhereDocument => '[everywhere]';
  @override
  String get editorLineActions => '[line actions]';
  @override
  String get editorSearchHistory => '[history]';
  @override
  String editorStatusPosition(int line, int column, int lines, int bytes) =>
      '[at $line:$column of $lines/$bytes]';
  @override
  String editorStatusSelection(int characters) => '[$characters picked]';
  @override
  String editorStatusSelectionLines(int characters, int lines) =>
      '[$characters picked on $lines]';
  @override
  String get editorStatusSaving => '[saving]';
  @override
  String get editorStatusUnsaved => '[unsaved]';
  @override
  String get editorStatusLargeFile => '[large]';
  @override
  String editorStatusIndentSpaces(int width) => '[spaces $width]';
  @override
  String editorStatusIndentTabs(int width) => '[tabs $width]';
  @override
  String get editorLanguagePlainText => '[plain]';
  @override
  String get editorLanguageCStyle => '[c-like]';
}

/// Answers every lookup with the name of the ARB key it read, so a
/// string the adapter leaves to the package's English shows up as text
/// with no key name in it.
class _KeyNames implements AppLocalizations {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString();
}

void main() {
  testWidgets('the shared find and Go to Line bars use the ARB copy', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: '/srv/notes.txt',
      initialText: 'one\ntwo\n',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            strings: PoltergeistEditorStrings(_Marked()),
            showStatus: false,
          ),
        ),
      ),
    );
    await tester.pump();

    controller.openSearch();
    await tester.pump();
    expect(find.byTooltip('[whole words]'), findsOneWidget);
    expect(find.byTooltip('[regex]'), findsOneWidget);

    await tester.tap(find.byTooltip('[regex]'));
    await tester.pump();
    expect(find.text('[pattern]'), findsOneWidget);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '[pattern]',
      ),
      '(',
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.textContaining('[invalid]'), findsOneWidget);

    controller.closeSearch();
    controller.openGoToLine();
    await tester.pump();
    expect(find.byTooltip('[close go to line]'), findsOneWidget);
    final goToLineField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '[1..3]',
    );
    await tester.enterText(goToLineField, '');
    await tester.pump();
    expect(goToLineField, findsOneWidget);

    await tester.enterText(goToLineField, 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('[not 1..3]'), findsOneWidget);
  });

  testWidgets('the browser, tool bar and notice use the ARB copy', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: '/srv/notes.txt',
      initialText: 'b\na\n',
      undoQuiet: Duration.zero,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            strings: PoltergeistEditorStrings(_Marked()),
            showStatus: false,
          ),
        ),
      ),
    );
    await tester.pump();

    controller.openTextTools();
    await tester.pumpAndSettle();
    expect(find.text('[tools]'), findsOneWidget);
    expect(find.widgetWithText(TextField, '[filter]'), findsOneWidget);
    expect(find.text('[sort]…'), findsOneWidget);
    expect(find.text('[orders]'), findsOneWidget);

    controller.chooseTextTool('sortLines');
    await tester.pumpAndSettle();
    expect(find.text('[applies to]'), findsOneWidget);
    expect(find.text('[apply]'), findsOneWidget);

    await tester.tap(find.text('[apply]'));
    await tester.pumpAndSettle();
    expect(
      find.text('[sort] :: [moved 2/2 [everywhere]]'),
      findsOneWidget,
    );
  });

  testWidgets('the find bar extras come from the ARB copy', (tester) async {
    final controller = EditorController(
      displayPath: '/srv/notes.txt',
      initialText: 'b\na\n',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            strings: PoltergeistEditorStrings(_Marked()),
            showStatus: false,
          ),
        ),
      ),
    );
    await tester.pump();
    controller.openSearch();
    await tester.pumpAndSettle();
    expect(find.byTooltip('[line actions]'), findsOneWidget);
  });

  testWidgets('the shared status row uses the ARB copy', (tester) async {
    final controller = EditorController(
      displayPath: '/srv/notes.txt',
      initialText: 'one\ntwo\n',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            strings: PoltergeistEditorStrings(_Marked()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('[at 1:1 of 3/8]'), findsOneWidget);
    expect(find.textContaining('[spaces 4]'), findsOneWidget);
    expect(find.textContaining('[plain]'), findsOneWidget);

    // "one\nt" spans two lines; the edit after it dirties the buffer.
    controller.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 5,
    );
    await tester.pump();
    expect(find.textContaining('[5 picked on 2]'), findsOneWidget);
    controller.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 2,
    );
    await tester.pump();
    expect(find.textContaining('[2 picked]'), findsOneWidget);
    controller.text.value = const TextEditingValue(
      text: 'uno\ntwo\n',
      selection: TextSelection.collapsed(offset: 0),
    );
    await tester.pump();
    expect(find.textContaining('[unsaved]'), findsOneWidget);
  });

  test('every status row string routes through the ARB copy', () {
    final strings = PoltergeistEditorStrings(_Marked());
    expect(strings.documentPosition(1, 2, 3, 8), '[at 1:2 of 3/8]');
    expect(strings.selectionSummary(5, 2), '[5 picked on 2]');
    expect(strings.selectionSummary(2, 1), '[2 picked]');
    expect(strings.unsaved, '[unsaved]');
    expect(strings.saving, '[saving]');
    expect(strings.largeFile, '[large]');
    expect(strings.indentation(const Indentation.tabs(width: 8)), '[tabs 8]');
    expect(strings.languageName(null), '[plain]');
    expect(strings.languageName(syntaxLanguageFor('/srv/main.c')), '[c-like]');
    // Proper-noun language names stay the package's own.
    expect(strings.languageName(syntaxLanguageFor('/srv/app.py')), 'Python');
  });

  test('every editing command label comes from the ARB catalog', () {
    final strings = PoltergeistEditorStrings(_KeyNames());
    expect(strings.editorCommandsGroup, contains('editorCommandsGroup'));
    for (final command in EditorCommand.values) {
      expect(
        strings.editorCommandLabel(command),
        startsWith('Symbol("editor'),
        reason: '$command has no ARB label',
      );
    }
  });

  test('the ARB catalog covers every shared text tool, option and choice', () {
    final strings = PoltergeistEditorStrings(AppLocalizationsEn());

    // A fallback leak means the shared package's own English would render.
    // The case tools whose display name legitimately is the id itself are
    // exempt from the not-the-id heuristic. Find-bar tools render their
    // options as find-row controls, never as labeled options-bar rows, so
    // their option ids are not label keys either.
    const selfNamed = {'lowercase', 'camelCase', 'snakeCase', 'kebabCase'};
    final choiceIds = <String>{};
    for (final tool in textToolCatalog) {
      if (!selfNamed.contains(tool.id)) {
        expect(strings.textToolName(tool.id), isNot(tool.id),
          reason: '${tool.id} has no ARB name');
      }
      expect(strings.textToolDescription(tool.id), isNotEmpty,
        reason: '${tool.id} has no ARB description');
      expect(strings.textToolKeywords(tool.id), isNotEmpty,
        reason: '${tool.id} has no ARB keywords');
      for (final option in tool.options) {
        if (!tool.usesFindBar) {
          expect(strings.textToolOptionName(tool.id, option.id),
            isNot(option.id),
            reason: '${tool.id}/${option.id} has no ARB label');
        }
        if (option is ChoiceOption) choiceIds.addAll(option.choices);
      }
    }
    for (final choiceId in choiceIds) {
      expect(strings.textToolChoiceName(choiceId), isNot(choiceId),
        reason: '$choiceId has no ARB label');
    }
    for (final group in TextToolGroup.values) {
      expect(strings.textToolGroupName(group), isNotEmpty,
        reason: '$group has no ARB label');
    }
  });
}
