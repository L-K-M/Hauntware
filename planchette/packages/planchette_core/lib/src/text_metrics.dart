/// The length of [text] encoded as UTF-8, counted without encoding it. An
/// unpaired surrogate counts 3 bytes, as `utf8.encode` writes it as U+FFFD.
int utf8EncodedLength(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (_isLeadSurrogate(unit) &&
        i + 1 < text.length &&
        _isTrailSurrogate(text.codeUnitAt(i + 1))) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

bool _isLeadSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isTrailSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// Offsets at which logical lines begin: 0 plus the position after each
/// `\n`. A trailing newline therefore still counts its empty final line.
List<int> lineStartOffsets(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) starts.add(i + 1);
  }
  return starts;
}

/// The 1-based display column the character at [offset] ends on, counting
/// [lineStart] as column 1. A tab advances to the next multiple of
/// [tabWidth] columns — the same convention the ruler readout implies and
/// the indentation rendering assumes. East Asian wide code points and
/// emoji count two columns (wcwidth rules); combining marks and invisible
/// joiners count zero. Surrogate pairs count once, so the result does not
/// match raw UTF-16 offset arithmetic.
int displayColumnFor(
  String text,
  int lineStart,
  int offset, {
  int tabWidth = 4,
}) {
  var column = 1;
  var i = lineStart;
  while (i < offset && i < text.length) {
    var unit = text.codeUnitAt(i);
    if (unit == 0x09) {
      column += tabWidth - (column - 1) % tabWidth;
      i++;
      continue;
    }
    if (_isLeadSurrogate(unit) &&
        i + 1 < offset &&
        i + 1 < text.length &&
        _isTrailSurrogate(text.codeUnitAt(i + 1))) {
      unit =
          0x10000 + ((unit - 0xd800) << 10) + (text.codeUnitAt(i + 1) - 0xdc00);
      i += 2;
    } else {
      i++;
    }
    if (_isZeroWidth(unit)) continue;
    column += _isWide(unit) ? 2 : 1;
  }
  return column;
}

/// The offset the caret reaches when Go to Line aims at 1-based display
/// [column] — the inverse of [displayColumnFor] for caret positions, so a
/// column the status bar reported lands the caret where it was read. A column
/// that is a character's exact end lands after it; one inside a wide or tab
/// span lands before it, and past the line's end clamps to [lineEnd].
int offsetForDisplayColumn(
  String text,
  int lineStart,
  int lineEnd,
  int column, {
  int tabWidth = 4,
}) {
  if (column <= 1) return lineStart;
  var col = 1;
  var i = lineStart;
  while (i < lineEnd && i < text.length) {
    final charStart = i;
    var unit = text.codeUnitAt(i);
    var width = 1;
    if (unit == 0x09) {
      width = tabWidth - (col - 1) % tabWidth;
      i++;
    } else {
      if (_isLeadSurrogate(unit) &&
          i + 1 < text.length &&
          _isTrailSurrogate(text.codeUnitAt(i + 1))) {
        unit =
            0x10000 +
            ((unit - 0xd800) << 10) +
            (text.codeUnitAt(i + 1) - 0xdc00);
        i += 2;
      } else {
        i++;
      }
      width = _isZeroWidth(unit) ? 0 : (_isWide(unit) ? 2 : 1);
    }
    col += width;
    if (col == column) return i;
    if (col > column) return charStart;
  }
  return i;
}

bool _isZeroWidth(int cp) =>
    (cp >= 0x0300 && cp <= 0x036f) || // combining diacritical marks
    (cp >= 0x1ab0 && cp <= 0x1aff) ||
    (cp >= 0x1dc0 && cp <= 0x1dff) ||
    (cp >= 0x20d0 && cp <= 0x20ff) || // combining marks for symbols
    (cp >= 0xfe20 && cp <= 0xfe2f) || // combining half marks
    cp == 0x200b || // zero width space
    cp == 0x200c || // zero width non-joiner
    cp == 0x200d || // zero width joiner
    cp == 0xfeff; // BOM / zero width no-break space

bool _isWide(int cp) =>
    (cp >= 0x1100 && cp <= 0x115f) || // Hangul Jamo
    cp == 0x2329 ||
    cp == 0x232a || // angle brackets
    (cp >= 0x2e80 && cp <= 0xa4cf) || // CJK … Yi
    (cp >= 0xac00 && cp <= 0xd7a3) || // Hangul syllables
    (cp >= 0xf900 && cp <= 0xfaff) || // CJK compatibility ideographs
    (cp >= 0xfe10 && cp <= 0xfe6f) || // vertical + small forms
    (cp >= 0xff00 && cp <= 0xff60) || // fullwidth forms
    (cp >= 0xffe0 && cp <= 0xffe6) || // fullwidth signs
    (cp >= 0x1f300 && cp <= 0x1faff) || // emoji
    (cp >= 0x20000 && cp <= 0x3fffd); // astral CJK
