import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

const palette = HtmlPalette(
  background: '#fffaf0',
  foreground: '#222',
  tokens: {SyntaxTokenType.keyword: '#8a3fa8', SyntaxTokenType.string: 'green'},
);

String body(String html) => html.substring(
  html.indexOf('<pre><code>') + '<pre><code>'.length,
  html.indexOf('</code></pre>'),
);

void main() {
  test('wraps tokens in classed spans and keeps the rest as text', () {
    final html = highlightedHtml(
      text: 'if x "y"',
      tokens: const [
        SyntaxToken(0, 2, SyntaxTokenType.keyword),
        SyntaxToken(5, 8, SyntaxTokenType.string),
      ],
      palette: palette,
    );

    expect(
      body(html),
      '<span class="k">if</span> x <span class="s">&quot;y&quot;</span>',
    );
    expect(html, contains('.k{color:#8a3fa8}'));
    expect(html, contains('.s{color:green}'));
    expect(html, isNot(contains('.c{')));
    expect(html, contains('background:#fffaf0'));
  });

  test('escapes markup in the text and the title', () {
    final html = highlightedHtml(
      text: '<a href="x">&</a>\n\tindented',
      tokens: const [],
      palette: palette,
      title: 'a<b>.html',
    );

    expect(
      body(html),
      '&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;\n\tindented',
    );
    expect(html, contains('<title>a&lt;b&gt;.html</title>'));
  });

  test('highlights a real tokenizer run end to end', () {
    const source = 'void main() {\n  // hi\n  print("x");\n}\n';
    final html = highlightedHtml(
      text: source,
      tokens: tokenizeSyntax(source, syntaxLanguageFor('main.dart')!),
      palette: palette,
    );

    expect(body(html), contains('<span class="c">// hi</span>'));
    expect(body(html), contains('<span class="s">&quot;x&quot;</span>'));
    // Nothing is lost: stripping the markup gives the text back.
    final plain = body(html)
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
    expect(plain, source);
  });

  test('clamps tokens that run past a shorter text', () {
    final html = highlightedHtml(
      text: 'ab',
      tokens: const [SyntaxToken(1, 9, SyntaxTokenType.keyword)],
      palette: palette,
    );

    expect(body(html), 'a<span class="k">b</span>');
  });
}
