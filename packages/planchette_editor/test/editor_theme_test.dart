import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

const custom = EditorSyntaxTheme(
  comment: Color(0xFF000001),
  string: Color(0xFF000002),
  number: Color(0xFF000003),
  keyword: Color(0xFF000004),
  meta: Color(0xFF000005),
  matchBackground: Color(0xFF000006),
  matchForeground: Color(0xFF000007),
  activeMatchBackground: Color(0xFF000008),
  activeMatchForeground: Color(0xFF000009),
);

void main() {
  testWidgets('a host theme extension styles the editor', (tester) async {
    final c = EditorController(
      displayPath: 'a.py',
      initialText: 'def f(): pass',
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [custom]),
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.text.theme, same(custom));

    final explicit = custom.copyWith(keyword: const Color(0xFF0000AA));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [custom]),
        home: Scaffold(
          body: PlanchetteEditor(controller: c, syntaxTheme: explicit),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.text.theme, same(explicit), reason: 'the widget parameter wins');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    // MaterialApp animates theme changes; the extension lerps with it.
    await tester.pumpAndSettle();
    expect(c.text.theme, same(EditorSyntaxTheme.dark));
  });

  test('themes interpolate for animated theme changes', () {
    final halfway = EditorSyntaxTheme.light.lerp(EditorSyntaxTheme.dark, 0.5);
    expect(
      halfway.keyword,
      Color.lerp(
        EditorSyntaxTheme.light.keyword,
        EditorSyntaxTheme.dark.keyword,
        0.5,
      ),
    );
    expect(
      EditorSyntaxTheme.light.lerp(null, 0.5),
      same(EditorSyntaxTheme.light),
    );
  });
}
