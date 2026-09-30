import 'dart:math' as math;

/// The result of a line command: the whole new buffer and the selection to
/// put on it. Base and extent are kept apart so a selection dragged upwards
/// stays anchored where it started.
final class LineEdit {
  const LineEdit(this.text, this.selectionBase, this.selectionExtent);

  final String text;
  final int selectionBase;
  final int selectionExtent;

  @override
  bool operator ==(Object other) =>
      other is LineEdit &&
      other.text == text &&
      other.selectionBase == selectionBase &&
      other.selectionExtent == selectionExtent;

  @override
  int get hashCode => Object.hash(text, selectionBase, selectionExtent);

  @override
  String toString() =>
      'LineEdit($selectionBase, $selectionExtent, '
      '${text.replaceAll('\n', r'\n')})';
}

enum LineDirection { up, down }

// Line commands act on every line the selection touches. A selection that
// ends at the very start of a line does not touch that line: dragging from
// one line's start to the next line's start selects one whole line, and the
// command should act on that line alone.
//
// Loading normalizes line endings, but pasted text keeps its own, so a `\r`
// before a `\n` is part of the break, not of the line: every command treats
// `\r\n` as one separator and keeps each line's own separator with it.

/// Copies the touched lines below themselves and moves the selection onto
/// the copy, so repeating the command keeps stacking copies downwards.
LineEdit duplicateLines(String text, int base, int extent) {
  final lines = touchedLineRange(text, base, extent);
  final block = text.substring(lines.start, lines.end);
  // The copy takes the break that ends the block, or on the last line the
  // one before it, or for a whole-buffer block one of its own, so a CRLF
  // buffer stays CRLF.
  final after = lineSeparatorAt(text, lines.end);
  final inside = block.indexOf('\n');
  final separator = after.isNotEmpty
      ? after
      : lines.start > 0
      ? lineSeparatorBefore(text, lines.start)
      : inside > 0 && block.codeUnitAt(inside - 1) == _return
      ? '\r\n'
      : '\n';
  final shift = block.length + separator.length;
  return LineEdit(
    text.replaceRange(lines.end, lines.end, '$separator$block'),
    base + shift,
    extent + shift,
  );
}

/// Swaps the touched lines with the line above or below them, carrying the
/// selection along. Returns null at the top or bottom of the buffer.
LineEdit? moveLines(
  String text,
  int base,
  int extent,
  LineDirection direction,
) {
  final lines = touchedLineRange(text, base, extent);
  final block = text.substring(lines.start, lines.end);
  final String result;
  final int shift;
  switch (direction) {
    case LineDirection.up:
      if (lines.start == 0) return null;
      final separator = lineSeparatorBefore(text, lines.start);
      final neighbourEnd = lines.start - separator.length;
      final above = lineStart(text, neighbourEnd);
      final neighbour = text.substring(above, neighbourEnd);
      result = text.replaceRange(
        above,
        lines.end,
        '$block$separator$neighbour',
      );
      shift = -(neighbour.length + separator.length);
    case LineDirection.down:
      if (lines.end == text.length) return null;
      final separator = lineSeparatorAt(text, lines.end);
      final belowStart = lines.end + separator.length;
      final below = lineContentEnd(text, belowStart);
      final neighbour = text.substring(belowStart, below);
      result = text.replaceRange(
        lines.start,
        below,
        '$neighbour$separator$block',
      );
      shift = neighbour.length + separator.length;
  }
  // A selection that ended at the start of the following line loses that
  // newline when the block becomes the last line.
  int moved(int offset) => math.min(offset + shift, result.length);
  return LineEdit(result, moved(base), moved(extent));
}

/// Removes the touched lines and their line break. The caret keeps its
/// column on the line that takes their place, as far as that line reaches.
/// Returns null for an empty buffer.
LineEdit? deleteLines(String text, int base, int extent) {
  if (text.isEmpty) return null;
  final lines = touchedLineRange(text, base, extent);
  final column = extent - lineStart(text, extent);
  final int from;
  final int to;
  if (lines.end < text.length) {
    (from, to) = (
      lines.start,
      lines.end + lineSeparatorAt(text, lines.end).length,
    );
  } else if (lines.start > 0) {
    // The last line has no break of its own; take the one before it.
    (from, to) = (
      lines.start - lineSeparatorBefore(text, lines.start).length,
      lines.end,
    );
  } else {
    (from, to) = (0, text.length);
  }
  final result = text.replaceRange(from, to, '');
  final start = lineStart(result, from);
  var caret = math.min(start + column, lineContentEnd(result, start));
  // The column came from another line and may fall inside a character
  // there; never leave the caret between the halves of a surrogate pair.
  if (caret > start &&
      caret < result.length &&
      _isLowSurrogate(result.codeUnitAt(caret))) {
    caret--;
  }
  return LineEdit(result, caret, caret);
}

/// Joins the touched lines into one, or the caret's line with the next.
/// Each joined line loses its leading indentation and is separated by one
/// space, unless the text before it already ends in whitespace or the line
/// is blank. A caret lands where the first break was; a selection keeps
/// covering the same text. Returns null on the last line.
LineEdit? joinLines(String text, int base, int extent) {
  final lines = touchedLineRange(text, base, extent);
  var end = lines.end;
  final firstBreak = text.indexOf('\n', lines.start);
  if (firstBreak < 0 || firstBreak >= end) {
    if (end == text.length) return null;
    end = lineContentEnd(text, end + lineSeparatorAt(text, end).length);
  }

  final joined = StringBuffer();
  final replacements = <({int start, int end, int length})>[];
  var read = lines.start;
  // The last code unit written, to decide whether a separator is needed.
  int? last;
  for (
    var newline = text.indexOf('\n', read);
    newline >= 0 && newline < end;
    newline = text.indexOf('\n', read)
  ) {
    // The break starts at its carriage return, if it has one.
    final i = newline > read && text.codeUnitAt(newline - 1) == _return
        ? newline - 1
        : newline;
    joined.write(text.substring(read, i));
    if (i > read) last = text.codeUnitAt(i - 1);
    var next = newline + 1;
    while (next < end && _isIndent(text.codeUnitAt(next))) {
      next++;
    }
    final blank =
        next == end ||
        text.codeUnitAt(next) == _newline ||
        (text.codeUnitAt(next) == _return &&
            next + 1 < text.length &&
            text.codeUnitAt(next + 1) == _newline);
    final space = !blank && last != null && !_isIndent(last);
    if (space) {
      joined.write(' ');
      last = _space;
    }
    replacements.add((start: i, end: next, length: space ? 1 : 0));
    read = next;
  }
  joined.write(text.substring(read, end));

  final result = text.replaceRange(lines.start, end, joined.toString());
  if (base == extent) {
    final caret = replacements.first.start;
    return LineEdit(result, caret, caret);
  }
  int mapped(int offset) {
    var delta = 0;
    for (final r in replacements) {
      if (offset <= r.start) break;
      if (offset < r.end) return r.start + delta + r.length;
      delta += r.length - (r.end - r.start);
    }
    return offset + delta;
  }

  return LineEdit(result, mapped(base), mapped(extent));
}

/// Comments or uncomments the touched lines with a language's line-comment
/// [markers], such as `['//']` or `['#', ';']`.
///
/// When every non-blank touched line already starts, after its indentation,
/// with one of the markers, that marker and one following space are removed
/// from each line. Otherwise the first marker and a space go in front of each
/// non-blank line's text, at its indentation. Blank lines in a selection stay
/// as they are, but a caret on a blank line comments it. A caret keeps its
/// place in the text; a selection grows to cover the touched lines whole,
/// keeping its direction. Returns null when [markers] is empty or nothing
/// would change.
LineEdit? toggleLineComments(
  String text,
  int base,
  int extent,
  List<String> markers,
) {
  if (markers.isEmpty) return null;
  final lines = touchedLineRange(text, base, extent);
  final collapsed = base == extent;
  // Longest first, so a marker that begins with another one is removed whole.
  final byLength = [...markers]..sort((a, b) => b.length - a.length);
  String? markerAt(int offset) {
    for (final marker in byLength) {
      if (text.startsWith(marker, offset)) return marker;
    }
    return null;
  }

  // The text start (after indentation) and content end of each touched line.
  final touched = <({int text, int end})>[];
  for (var start = lines.start; ;) {
    final end = lineContentEnd(text, start);
    var at = start;
    while (at < end && _isIndent(text.codeUnitAt(at))) {
      at++;
    }
    touched.add((text: at, end: end));
    if (end >= lines.end) break;
    start = end + lineSeparatorAt(text, end).length;
  }
  final written = [
    for (final line in touched)
      if (line.text < line.end) line,
  ];
  if (written.isEmpty && !collapsed) return null;
  final uncomment =
      written.isNotEmpty &&
      written.every((line) => markerAt(line.text) != null);

  final edits = <({int at, int remove, String insert})>[];
  for (final line in touched) {
    if (uncomment) {
      final marker = markerAt(line.text);
      if (marker == null) continue;
      var remove = marker.length;
      if (line.text + remove < line.end &&
          text.codeUnitAt(line.text + remove) == _space) {
        remove++;
      }
      edits.add((at: line.text, remove: remove, insert: ''));
    } else if (line.text < line.end || collapsed) {
      edits.add((at: line.text, remove: 0, insert: '${markers.first} '));
    }
  }
  if (edits.isEmpty) return null;

  final result = StringBuffer();
  var copied = 0;
  var delta = 0;
  for (final edit in edits) {
    result
      ..write(text.substring(copied, edit.at))
      ..write(edit.insert);
    copied = edit.at + edit.remove;
    delta += edit.insert.length - edit.remove;
  }
  result.write(text.substring(copied));

  if (collapsed) {
    var shift = 0;
    for (final edit in edits) {
      if (base < edit.at) break;
      if (base < edit.at + edit.remove) {
        // A caret inside a removed marker lands where the marker began.
        final caret = edit.at + shift;
        return LineEdit(result.toString(), caret, caret);
      }
      shift += edit.insert.length - edit.remove;
    }
    return LineEdit(result.toString(), base + shift, base + shift);
  }
  final start = lines.start;
  final end = lines.end + delta;
  return base < extent
      ? LineEdit(result.toString(), start, end)
      : LineEdit(result.toString(), end, start);
}

const _newline = 0x0a;
const _return = 0x0d;
const _space = 0x20;
const _tab = 0x09;

bool _isIndent(int unit) => unit == _space || unit == _tab;

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// The touched lines as one range: from the first line's start to the last
/// line's end, excluding its line break. A selection that ends at column 0
/// does not touch that last line.
({int start, int end}) touchedLineRange(String text, int base, int extent) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final from = math.min(base, extent);
  var to = math.max(base, extent);
  if (to > from && text.codeUnitAt(to - 1) == _newline) to--;
  return (start: lineStart(text, from), end: lineContentEnd(text, to));
}

/// The start of the line holding [offset].
int lineStart(String text, int offset) =>
    offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

/// The end of the line holding [offset], before its break: its `\n`, or the
/// `\r` in front of that `\n`.
int lineContentEnd(String text, int offset) {
  final newline = text.indexOf('\n', offset);
  if (newline < 0) return text.length;
  // A `\r` right before a `\n` always belongs to that break, even when
  // [offset] is the `\n` itself.
  return newline > 0 && text.codeUnitAt(newline - 1) == _return
      ? newline - 1
      : newline;
}

/// The line break starting at [end], a line's content end: `\r\n`, `\n`,
/// or nothing on the last line.
String lineSeparatorAt(String text, int end) {
  if (end >= text.length) return '';
  return text.codeUnitAt(end) == _return ? '\r\n' : '\n';
}

/// The line break that ends just before [start], a line's start.
String lineSeparatorBefore(String text, int start) =>
    start >= 2 && text.codeUnitAt(start - 2) == _return ? '\r\n' : '\n';
