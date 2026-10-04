part of 'editor_syntax.dart';

final _dotenvAssignment = RegExp(
  r'[ \t]*(?:(export)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*',
);

/// Highlights Node-style dotenv assignments without interpreting their values.
/// Quotes open only immediately after `=` and optional horizontal whitespace:
/// an apostrophe in a bare value such as `NAME=O'Brien` is ordinary content.
List<SyntaxToken> _tokenizeDotenv(String text) {
  final tokens = <SyntaxToken>[];
  var i = text.startsWith('\ufeff') ? 1 : 0;
  while (i < text.length) {
    final assignment = _dotenvAssignment.matchAsPrefix(text, i);
    if (assignment != null) {
      // The matched prefix contains exactly one equals sign. Work backwards
      // from it instead of searching for the captured key: `port` can also
      // occur inside the optional `export` prefix.
      var keyEnd = text.indexOf('=', i);
      while (_dotenvPadding(text.codeUnitAt(keyEnd - 1))) {
        keyEnd--;
      }
      final keyStart = keyEnd - assignment[2]!.length;
      if (assignment[1] != null) {
        var exportStart = i;
        while (_dotenvPadding(text.codeUnitAt(exportStart))) {
          exportStart++;
        }
        tokens.add(
          SyntaxToken(
            exportStart,
            exportStart + 'export'.length,
            SyntaxTokenType.keyword,
          ),
        );
      }
      tokens.add(SyntaxToken(keyStart, keyEnd, SyntaxTokenType.meta));
      i = assignment.end;
      if (i < text.length && (text[i] == '"' || text[i] == "'")) {
        final end = _scanString(text, i, text[i], stopAtNewline: false);
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
      }
    }

    // Unquoted values are text, not shell/INI expressions. A hash starts a
    // comment regardless of whitespace; quoted hashes were consumed above.
    while (i < text.length && !_dotenvLineBreak(text.codeUnitAt(i))) {
      if (text.codeUnitAt(i) == 0x23 /* # */ ) {
        final start = i;
        while (i < text.length && !_dotenvLineBreak(text.codeUnitAt(i))) {
          i++;
        }
        tokens.add(SyntaxToken(start, i, SyntaxTokenType.comment));
        break;
      }
      i++;
    }
    if (i < text.length) i++;
  }
  return tokens;
}

bool _dotenvPadding(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09;

bool _dotenvLineBreak(int codeUnit) => codeUnit == 0x0a || codeUnit == 0x0d;
