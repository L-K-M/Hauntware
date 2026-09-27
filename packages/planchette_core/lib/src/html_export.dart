import 'editor_syntax.dart';

/// CSS colors for [highlightedHtml], such as `#1f7a54` or `rgb(31 122 84)`.
/// They are written into a style block, so [highlightedHtml] rejects a value
/// with any character that could end a declaration or the block.
final class HtmlPalette {
  const HtmlPalette({
    required this.background,
    required this.foreground,
    required this.tokens,
  });

  final String background;
  final String foreground;

  /// A color per token type; a type without one keeps the text color.
  final Map<SyntaxTokenType, String> tokens;
}

/// A standalone HTML page showing [text] with [tokens] highlighted, for
/// sharing or printing outside the editor. Colors come from [palette] and go
/// into one style block keyed by token class, so the markup stays small and
/// the page prints as it looks. Whitespace and tabs are kept as typed.
String highlightedHtml({
  required String text,
  required List<SyntaxToken> tokens,
  required HtmlPalette palette,
  String title = '',
}) {
  for (final color in [
    palette.background,
    palette.foreground,
    ...palette.tokens.values,
  ]) {
    if (!_plainCssColor.hasMatch(color)) {
      throw ArgumentError.value(color, 'palette', 'Not a plain CSS color');
    }
  }
  final out = StringBuffer()
    ..writeln('<!doctype html>')
    ..writeln('<html>')
    ..writeln('<head>')
    ..writeln('<meta charset="utf-8">')
    ..writeln('<title>${_escape(title)}</title>')
    ..writeln('<style>')
    ..writeln(
      'body{margin:0;background:${palette.background};'
      'color:${palette.foreground}}',
    )
    ..writeln(
      'pre{margin:0;padding:16px;font:14px/1.35 ui-monospace,Menlo,'
      'Consolas,"DejaVu Sans Mono",monospace;tab-size:4;white-space:pre}',
    );
  for (final type in SyntaxTokenType.values) {
    final color = palette.tokens[type];
    if (color != null) out.writeln('.${_classOf(type)}{color:$color}');
  }
  out
    ..writeln('</style>')
    ..writeln('</head>')
    ..writeln('<body>')
    ..write('<pre><code>');

  var position = 0;
  for (final token in tokens) {
    // Tokens are ordered and non-overlapping; clamp defensively so a stale
    // token list can never throw on a shorter text.
    final start = token.start.clamp(position, text.length);
    final end = token.end.clamp(start, text.length);
    out.write(_escape(text.substring(position, start)));
    if (end > start) {
      out
        ..write('<span class="${_classOf(token.type)}">')
        ..write(_escape(text.substring(start, end)))
        ..write('</span>');
    }
    position = end;
  }
  out
    ..write(_escape(text.substring(position)))
    ..writeln('</code></pre>')
    ..writeln('</body>')
    ..writeln('</html>');
  return out.toString();
}

/// Hex, named and functional colors; no `;`, braces, quotes or angle
/// brackets, so a value cannot leave its declaration or the style block.
final _plainCssColor = RegExp(r'^[#A-Za-z0-9(),.%/ -]+$');

// A switch, not a map, so a new token type fails to compile until it has a
// class.
String _classOf(SyntaxTokenType type) => switch (type) {
  SyntaxTokenType.comment => 'c',
  SyntaxTokenType.string => 's',
  SyntaxTokenType.number => 'n',
  SyntaxTokenType.keyword => 'k',
  SyntaxTokenType.meta => 'm',
};

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
