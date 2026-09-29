import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
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
}
