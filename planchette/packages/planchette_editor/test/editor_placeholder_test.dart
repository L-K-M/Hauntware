import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  /// The field keeps its hint in the tree and fades it out, so visibility is
  /// the opacity around the hint text.
  double hintOpacity(WidgetTester tester, String hint) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.text(hint),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('the placeholder shows only while the document is empty', (
    tester,
  ) async {
    final editor = EditorController(displayPath: 'Untitled', initialText: '');
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: editor,
            placeholder: 'Start typing.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(hintOpacity(tester, 'Start typing.'), 1);

    editor.text.text = 'x';
    await tester.pumpAndSettle();
    expect(hintOpacity(tester, 'Start typing.'), 0);

    editor.text.text = '';
    await tester.pumpAndSettle();
    expect(hintOpacity(tester, 'Start typing.'), 1);
  });

  testWidgets('no placeholder is shown unless the host asks for one', (
    tester,
  ) async {
    final editor = EditorController(displayPath: 'Untitled', initialText: '');
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlanchetteEditor(controller: editor)),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(field.decoration!.hintText, isNull);
  });
}
