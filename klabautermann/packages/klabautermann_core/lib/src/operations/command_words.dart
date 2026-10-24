// CTX-08's one-off command: the words the user types, as the argv an
// exec runs without a shell (03 §7.13).

/// [line]'s words as an exec's argv, split the way a POSIX shell splits
/// a simple command: at unquoted blanks, with single quotes taking their
/// text as is, double quotes letting a backslash escape `"`, `\`, `$`
/// and `` ` ``, and a backslash outside quotes taking the next character.
/// A backslash before a newline joins the lines, inside double quotes
/// too. Nothing is expanded: there is no shell between the words and the
/// command. Null when a quote or a trailing backslash leaves the command
/// incomplete, or there are no words.
List<String>? splitCommandWords(String line) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var i = 0;

  while (i < line.length) {
    final char = line[i];
    switch (char) {
      case ' ' || '\t' || '\n' || '\r':
        if (inWord) words.add(word.toString());
        word.clear();
        inWord = false;
        i++;
      case "'":
        final close = line.indexOf("'", i + 1);
        if (close < 0) return null;
        word.write(line.substring(i + 1, close));
        inWord = true;
        i = close + 1;
      case '"':
        i++;
        var closed = false;
        while (i < line.length) {
          final inner = line[i];
          if (inner == '"') {
            closed = true;
            i++;
            break;
          }
          if (inner == r'\' && i + 1 < line.length && line[i + 1] == '\n') {
            i += 2;
            continue;
          }
          if (inner == r'\' &&
              i + 1 < line.length &&
              const {'"', r'\', r'$', '`'}.contains(line[i + 1])) {
            word.write(line[i + 1]);
            i += 2;
            continue;
          }
          word.write(inner);
          i++;
        }
        if (!closed) return null;
        inWord = true;
      case r'\':
        // A shell would wait for the line a trailing backslash continues.
        if (i + 1 >= line.length) return null;
        if (line[i + 1] != '\n') {
          word.write(line[i + 1]);
          inWord = true;
        }
        i += 2;
      default:
        word.write(char);
        inWord = true;
        i++;
    }
  }
  if (inWord) words.add(word.toString());
  return words.isEmpty ? null : words;
}
