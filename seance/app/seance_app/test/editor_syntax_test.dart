import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/editor_syntax.dart';

// The syntax engine and search live in planchette_core and
// planchette_editor, which own their tests. This proves the app's
// compatibility import still resolves to them.
void main() {
  test('the compatibility import resolves to the shared syntax engine', () {
    expect(syntaxLanguageFor('/srv/deploy.py')?.id, 'python');

    const text = '# note\nkey: "value"\n';
    final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
    expect(
      tokens.where((token) => token.type == SyntaxTokenType.comment),
      hasLength(1),
    );
    expect(findSearchMatches(text, 'KEY'), const [
      TextRange(start: 7, end: 10),
    ]);
  });
}
