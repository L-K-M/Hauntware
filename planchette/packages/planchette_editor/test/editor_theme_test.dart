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
  searchScopeBackground: Color(0xFF00000A),
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
    // The dark theme registers no extension, so once the theme animation
    // settles the editor falls back to its built-in dark palette.
    await tester.pumpAndSettle();
    expect(c.text.theme, same(EditorSyntaxTheme.dark));
  });

  test('themes with the same colors are equal', () {
    final copy = EditorSyntaxTheme.dark.copyWith();
    expect(identical(copy, EditorSyntaxTheme.dark), isFalse);
    expect(copy, EditorSyntaxTheme.dark);
    expect(copy.hashCode, EditorSyntaxTheme.dark.hashCode);
    expect(
      EditorSyntaxTheme.dark.copyWith(keyword: const Color(0xFF000000)),
      isNot(EditorSyntaxTheme.dark),
    );
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

  // From #81: hosts on the built-in palettes get readable match highlights
  // without an app theme of their own. The 4.5:1 floor is WCAG AA for the
  // 14 px body text the editor draws.
  for (final brightness in Brightness.values) {
    test('the built-in ${brightness.name} palette keeps matches readable', () {
      double contrast(Color a, Color b) {
        final (x, y) = (a.computeLuminance(), b.computeLuminance());
        return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
      }

      final syntax = EditorSyntaxTheme.of(brightness);
      final surface = ThemeData(brightness: brightness).colorScheme.surface;
      final match = Color.alphaBlend(syntax.matchBackground, surface);
      expect(
        contrast(syntax.activeMatchForeground, syntax.activeMatchBackground),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(Color.alphaBlend(syntax.matchForeground, match), match),
        greaterThanOrEqualTo(4.5),
      );
    });
  }
}
