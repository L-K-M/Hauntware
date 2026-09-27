/// Indentation helpers for a line-oriented editor.
///
/// These are deliberately pure text functions with no editor, no Flutter and no
/// notion of a buffer: the same answers serve an interactive Tab press, an
/// automatic indent after Enter, and a host that wants to align a pasted block.
///
/// Offsets are UTF-16 units and are clamped into the text, so a caller may pass
/// a selection extent or a caret at the very end without checking first.
library;

/// The run of spaces and tabs that opens the line containing [offset].
///
/// A line that starts with anything else has no leading whitespace to offer.
String leadingWhitespace(String text, int offset) {
  final start = _lineStart(text, offset);
  var end = start;
  while (end < text.length && _isBlank(text.codeUnitAt(end))) {
    end++;
  }
  return text.substring(start, end);
}

/// The indentation a line inserted at [offset] should carry.
///
/// That is the current line's own indentation, plus one [unit] when the line
/// ends in something that opens a block. Only a trailing opener counts, so
/// closing a block does not deepen the next line.
///
/// [afterColon] asks the same question of a trailing colon. It belongs to
/// line-oriented formats — YAML, INI, dotenv — where a key opens a block, and
/// not to languages where a colon is punctuation. The caller knows which from
/// the document's language.
String indentForNewLine(
  String text,
  int offset, {
  required String unit,
  bool afterColon = false,
}) {
  final indent = leadingWhitespace(text, offset);
  // Walk back from the caret over the current line only, so the line break that
  // precedes it can never be mistaken for the line's last character.
  var last = offset.clamp(0, text.length) - 1;
  while (last >= _lineStart(text, offset) && _isBlank(text.codeUnitAt(last))) {
    last--;
  }
  if (last < 0) return indent;
  return _opensBlock(text.codeUnitAt(last), afterColon: afterColon)
      ? '$indent$unit'
      : indent;
}

/// The half-open range of leading whitespace on the caret's line, which a Tab
/// replaces with one indent level.
///
/// An empty range when the caret sits at the very start of an unindented line,
/// which is where the insertion belongs.
({int start, int end}) indentRange(String text, int offset) {
  final start = _lineStart(text, offset);
  var end = start;
  while (end < text.length && _isBlank(text.codeUnitAt(end))) {
    end++;
  }
  return (start: start, end: end);
}

/// Offset just after the line break at or before [offset], or 0.
int _lineStart(String text, int offset) {
  final target = offset.clamp(0, text.length);
  for (var i = target - 1; i >= 0; i--) {
    if (text.codeUnitAt(i) == 0x0a) return i + 1;
  }
  return 0;
}

bool _isBlank(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09;

/// Whether a character at the end of a line opens an indented block.
bool _opensBlock(int codeUnit, {required bool afterColon}) => switch (codeUnit) {
  0x7b /* { */ => true,
  0x5b /* [ */ => true,
  0x28 /* ( */ => true,
  0x3a /* : */ => afterColon,
  _ => false,
};
