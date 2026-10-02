import 'package:characters/characters.dart';

import 'indentation.dart';

/// Text-cell columns, not pixel advances: wide CJK and emoji use two cells;
/// combining sequences stay together. Status/navigation offsets remain UTF-16.
int textColumnAfter(
  String text, {
  int initialColumn = 0,
  int tabWidth = defaultIndentWidth,
}) {
  if (initialColumn < 0) {
    throw ArgumentError.value(initialColumn, 'initialColumn');
  }
  if (tabWidth < 1) throw ArgumentError.value(tabWidth, 'tabWidth');

  var column = initialColumn;
  for (final cluster in text.characters) {
    if (cluster == '\t') {
      column += tabWidth - column % tabWidth;
      continue;
    }
    if (cluster == '\n' || cluster == '\r' || cluster == '\r\n') {
      column = 0;
      continue;
    }
    if (_marksOnly.hasMatch(cluster) || _invisibleOnly.hasMatch(cluster)) {
      continue;
    }

    // VS16 requests emoji presentation; plain text symbols keep one cell.
    final emoji =
        _emojiPresentation.hasMatch(cluster) ||
        (cluster.contains('\ufe0f') && _pictographic.hasMatch(cluster));
    column += emoji || cluster.runes.any(_wideRune) ? 2 : 1;
  }
  return column;
}

final _marksOnly = RegExp(r'^\p{Mark}+$', unicode: true);
final _emojiPresentation = RegExp(r'\p{Emoji_Presentation}', unicode: true);
final _pictographic = RegExp(r'\p{Extended_Pictographic}', unicode: true);
final _invisibleOnly = RegExp(
  r'^[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200b\u200c\u200d\u2060\ufeff]+$',
);

// Conventional terminal-width ranges from Unicode EastAsianWidth. Ambiguous
// characters stay narrow; this policy deliberately does not infer font metrics.
bool _wideRune(int rune) =>
    (rune >= 0x1100 && rune <= 0x115f) ||
    rune == 0x2329 ||
    rune == 0x232a ||
    (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) ||
    (rune >= 0xac00 && rune <= 0xd7a3) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0xfe10 && rune <= 0xfe19) ||
    (rune >= 0xfe30 && rune <= 0xfe6f) ||
    (rune >= 0xff01 && rune <= 0xff60) ||
    (rune >= 0xffe0 && rune <= 0xffe6) ||
    (rune >= 0x1b000 && rune <= 0x1b2ff) ||
    (rune >= 0x1f200 && rune <= 0x1f251) ||
    (rune >= 0x20000 && rune <= 0x3fffd);
