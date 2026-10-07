part of 'text_validation.dart';

/// Flags a key assigned twice, which every dotenv reader accepts without a
/// word, most keeping the last value, so one of the lines is a mistake; and
/// a quoted value that never closes, which the highlighting already shows
/// running to the end of the file. Reads the dotenv tokenizer's output, so
/// keys and quotes are exactly the ones the highlighting colours.
void _validateDotenv(String text, _ProblemSink sink) {
  final firstLines = <String, int>{};
  for (final token in tokenizeSyntax(text, SyntaxLanguages.dotenv)) {
    if (sink.isFull) return;
    if (token.type == SyntaxTokenType.meta) {
      final key = text.substring(token.start, token.end);
      final first = firstLines[key];
      if (first == null) {
        firstLines[key] = sink.lineOf(token.start);
        continue;
      }
      sink.add(
        TextProblemKind.duplicateKey,
        TextProblemSeverity.warning,
        token.start,
        token.end,
        subject: key,
        relatedLine: first,
      );
      continue;
    }
    if (token.type != SyntaxTokenType.string) continue;
    if (_dotenvQuoteCloses(text, token.start, token.end)) continue;
    // Only the opening line: the rest of the file is the value now.
    var lineEnd = token.start;
    while (lineEnd < text.length && !_isLineBreak(text.codeUnitAt(lineEnd))) {
      lineEnd++;
    }
    sink.add(
      TextProblemKind.unterminatedQuote,
      TextProblemSeverity.error,
      token.start,
      lineEnd,
    );
  }
}

/// Whether the quoted value at [start] closes before [end], the end of its
/// token. The tokenizer ends an unclosed value at the end of the text, as it
/// does one whose closing quote is the last character; read it again the
/// way the tokenizer does, a backslash escaping the next character.
bool _dotenvQuoteCloses(String text, int start, int end) {
  if (end < text.length) return true;
  final quote = text.codeUnitAt(start);
  var i = start + 1;
  while (i < end) {
    final c = text.codeUnitAt(i);
    if (c == 0x5c /* backslash */ ) {
      i += 2;
      continue;
    }
    if (c == quote) return true;
    i++;
  }
  return false;
}

bool _isLineBreak(int c) => c == 0x0a || c == 0x0d;
