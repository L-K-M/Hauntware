import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart';

/// One indent level, and whether a Tab writes a tab or spaces.
final class EditorIndent {
  const EditorIndent({this.usesTabs = false, this.size = 2});

  /// A literal tab per level. Files that already use tabs stay consistent
  /// rather than being converted.
  final bool usesTabs;

  /// Spaces per level when [usesTabs] is false. Two is the common choice for
  /// Python and YAML, four for the C family and shell.
  final int size;

  /// What one level of indentation is made of.
  String get unit => usesTabs ? '\t' : ' ' * size.clamp(0, 16);
}

/// The pair a closer completes, and the closer itself, keyed by opener.
const Map<String, String> _bracketPairs = {
  '(': ')',
  '[': ']',
  '{': '}',
  '"': '"',
  "'": "'",
  '`': '`',
};

/// The characters that should move over a pair already under the caret rather
/// than insert a second one.
const Set<String> _closers = {')', ']', '}', '"', "'", '`'};

/// Language families where a trailing colon opens an indented block. Everywhere
/// else a colon is punctuation, and indenting after one is wrong.
///
/// The list is deliberately short, because the two failure modes are not
/// symmetric: a missed indent is obvious while typing and costs nothing, while
/// a spurious one silently reformats prose. XML and Markdown are out because a
/// line rarely *ends* in a colon there, and in Markdown it happens in ordinary
/// prose — a bare "TODO:" line would gain an indent nobody asked for. CSS is in
/// because a line-ending colon there really does continue an indented block, as
/// in a `grid-template-areas:` value.
const Set<String> _colonOpensBlock = {'yaml', 'ini', 'dotenv', 'css'};

/// Whether a trailing colon should indent the next line for [language].
bool colonOpensBlock(SyntaxLanguage? language) =>
    language != null && _colonOpensBlock.contains(language.id);

/// Whether [language] is one where brackets are syntax worth pairing. Prose is
/// not: pairing in a Markdown paragraph is noise rather than help.
bool pairsBrackets(SyntaxLanguage? language) =>
    language != null && language.id != 'markdown';

/// Whether typing [character] at [offset] should open a pair.
///
/// The character already under the caret disqualifies it: typing the closer of
/// a pair the user just made should move over that pair, which is
/// [movesOverCloser]'s job, not a second insertion.
bool opensPair(
  SyntaxLanguage? language,
  String character,
  String text,
  int offset,
) {
  if (!pairsBrackets(language)) return false;
  if (!_bracketPairs.containsKey(character)) return false;
  return offset >= text.length || text[offset] != character;
}

/// Whether [character] should move over the pair it closes.
///
/// Only the matching closer qualifies. Typing `)` between `(` and something else
/// is a real bracket, not a request to skip.
bool movesOverCloser(
  SyntaxLanguage? language,
  String character,
  String text,
  int offset,
) {
  // The same gate as `opensPair`. In prose a brace is a character, and stepping
  // over one would delete what the user just typed.
  if (!pairsBrackets(language)) return false;
  if (!_closers.contains(character) || offset >= text.length) return false;
  if (text[offset] != character) return false;
  return _isOpenerFor(language, character, text, offset);
}

bool _isOpenerFor(
  SyntaxLanguage? language,
  String closer,
  String text,
  int offset,
) {
  for (final pair in _bracketPairs.entries) {
    if (pair.value != closer) continue;
    // Either an opener sits directly before the pair, or the pair is a quote,
    // whose closing half is its own.
    if (offset == 0 || text[offset - 1] == pair.key) return true;
  }
  return false;
}

/// The closer that completes [opener], or null.
String? closerFor(String opener) => _bracketPairs[opener];

/// Indent every line [value]'s selection touches by one level.
TextEditingValue indentSelection(
  TextEditingValue value, {
  required String unit,
}) => _shiftIndent(value, unit: unit, forwards: true);

/// Remove one level of indentation from every line [value]'s selection touches.
TextEditingValue dedentSelection(
  TextEditingValue value, {
  required String unit,
}) => _shiftIndent(value, unit: unit, forwards: false);

/// Shift the leading whitespace of the selected lines.
///
/// The selection is reported over the same lines afterwards rather than over the
/// same offsets: the offsets inside a line have all moved by the same amount,
/// and a caller that needs a column can recover it from the new text.
TextEditingValue _shiftIndent(
  TextEditingValue value, {
  required String unit,
  required bool forwards,
}) {
  if (unit.isEmpty || !value.selection.isValid) return value;
  final text = value.text;
  final selection = value.selection;
  final start = selection.start.clamp(0, text.length);
  final end = selection.end.clamp(0, text.length);
  final collapsed = selection.isCollapsed;
  final firstLine = _lineStartAt(text, start);
  // A selection that ends exactly on a line start does not reach into that
  // line, so a trailing empty line is never indented by accident.
  final lastLine = _lineStartAt(text, end > start ? end - 1 : start);

  final buffer = StringBuffer();
  // How much each shifted line's indentation became, and how much that is worth
  // in characters, so the selection can follow the change.
  final indents = <int>[];
  final shifts = <int>[];
  var copied = 0;
  var line = firstLine;
  while (true) {
    final range = indentRange(text, line);
    final existing = text.substring(range.start, range.end);
    // A dedent removes one level, and at most one. If the file's indent does
    // not match the setting — tabs against spaces, or a width from another
    // project — removing nothing would leave the user with no way to outdent
    // their own file, so one character goes.
    final after = forwards
        ? existing.length + unit.length
        : existing.startsWith(unit)
        ? existing.length - unit.length
        : existing.startsWith('\t')
        ? existing.length - 1
        : existing.length;
    buffer
      ..write(text.substring(copied, range.start))
      ..write(
        after > existing.length
            ? '$unit$existing'
            : existing.substring(0, after < 0 ? 0 : after),
      );
    indents.add(after);
    shifts.add(after - existing.length);
    copied = range.end;
    if (line >= lastLine) break;
    line = _nextLineStart(text, line);
  }
  buffer.write(text.substring(copied));

  final shifted = buffer.toString();
  // The last shifted line moved by everything shifted *before* it; its own shift
  // only moves offsets inside it, and the selection should not reach past its
  // end. `lastLine` is an offset in the old text, so it has to be carried into
  // the new one before it can be used to find that end.
  final beforeLast = shifts
      .sublist(0, shifts.length - 1)
      .fold(0, (a, b) => a + b);
  final newLastLine = lastLine + beforeLast;
  return value.copyWith(
    text: shifted,
    selection: TextSelection(
      // A caret stays on the line it was on, at the end of that line's new
      // indentation. A selection covers the same lines, from the first one's
      // start to the last one's end, which is what indenting a block is for.
      baseOffset: collapsed ? firstLine + indents.first : firstLine,
      extentOffset: collapsed
          ? firstLine + indents.first
          : _lineEndAt(shifted, newLastLine),
    ),
    composing: TextRange.empty,
  );
}

int _lineStartAt(String text, int offset) {
  for (var i = offset.clamp(0, text.length) - 1; i >= 0; i--) {
    if (text.codeUnitAt(i) == 0x0a) return i + 1;
  }
  return 0;
}

int _nextLineStart(String text, int lineStart) {
  for (var i = lineStart; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) return i + 1;
  }
  return text.length;
}

/// The offset of the end of the line that starts at [lineStart] in [text].
int _lineEndAt(String text, int lineStart) {
  final next = _nextLineStart(text, lineStart);
  if (next >= text.length) return text.length;
  // The break itself is not part of the line's content.
  return next - 1;
}
