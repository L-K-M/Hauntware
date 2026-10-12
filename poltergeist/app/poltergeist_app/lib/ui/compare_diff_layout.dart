import 'dart:math' as math;
import 'dart:typed_data';

import 'package:planchette_editor/planchette_editor.dart' show displayColumnFor;
import 'package:poltergeist_core/poltergeist_core.dart';

// Pure wrap arithmetic for the compare view's diff rows (06 §6), public
// only for its tests. Rows wrap at display-column boundaries so a row's
// height is known before it is built: the list needs every row's extent
// up front to jump straight to a change among 40 000 rows.

/// The most display columns a row shows of one line; the rest is counted,
/// not drawn, so one minified line cannot build a 4 MiB row.
const int compareMaximumDisplayColumns = 10000;

/// The narrowest wrap, so a squeezed column still shows readable chunks.
const int _minimumColumnsPerRow = 8;

/// The compare view's tab stops, matching [ComparedText.columnsOf].
const int _tabWidth = 4;

/// Columns a text area of [textWidth] holds at [charWidth] per column.
int compareColumnsPerRow({
  required double textWidth,
  required double charWidth,
}) => math.max(_minimumColumnsPerRow, (textWidth / charWidth).floor());

/// Columns one wrapped chunk may fill. A non-Latin line keeps an eighth
/// spare, because a fallback glyph may advance wider than the columns it
/// counts for.
int compareWrapWidth(int perRow, {required bool nonLatin}) =>
    nonLatin ? math.max(1, perRow - (perRow + 7) ~/ 8) : perRow;

/// The visual lines a line of [columns] takes, never fewer than
/// [wrapCompareLine] draws. Latin lines are exact. A non-Latin chunk may
/// end one column short before a wide character, so its count is an upper
/// bound and a row can keep a blank last line. A line cut at
/// [compareMaximumDisplayColumns] adds one line saying how much is hidden.
int compareVisualLines(int columns, int perRow, {required bool nonLatin}) {
  final shown = math.min(columns, compareMaximumDisplayColumns);
  final width = compareWrapWidth(perRow, nonLatin: nonLatin);
  final perLine = nonLatin ? math.max(1, width - 1) : width;
  final lines = math.max(1, (shown + perLine - 1) ~/ perLine);
  return columns > compareMaximumDisplayColumns ? lines + 1 : lines;
}

/// One line of a compared text broken into chunks for display.
final class CompareWrappedLine {
  const CompareWrappedLine(this.text, this.lineCount, this.hiddenCharacters);

  /// The chunks joined with `\n`, tabs expanded to spaces.
  final String text;
  final int lineCount;

  /// Characters past [compareMaximumDisplayColumns], not drawn.
  final int hiddenCharacters;
}

/// Breaks the line `text[start, end)` into chunks of at most
/// [compareWrapWidth] columns. Tabs expand to the next multiple of four
/// from the line's start, a wide character never splits across chunks,
/// and a zero-width mark stays with the character before it.
CompareWrappedLine wrapCompareLine(
  String text,
  int start,
  int end,
  int perRow, {
  required bool nonLatin,
}) {
  final width = compareWrapWidth(perRow, nonLatin: nonLatin);
  final out = StringBuffer();
  var lines = 1;
  var chunk = 0;
  var column = 0;

  void place(String glyph, int columns) {
    if (columns > 0 && chunk > 0 && chunk + columns > width) {
      out.write('\n');
      lines++;
      chunk = 0;
    }
    out.write(glyph);
    chunk += columns;
    column += columns;
  }

  var i = start;
  while (i < end) {
    var next = i + 1;
    final unit = text.codeUnitAt(i);
    if (_isLeadSurrogate(unit) &&
        next < end &&
        _isTrailSurrogate(text.codeUnitAt(next))) {
      next++;
    }

    if (unit == 0x09) {
      final spaces = _tabWidth - column % _tabWidth;
      if (column + spaces > compareMaximumDisplayColumns) break;
      for (var k = 0; k < spaces; k++) {
        place(' ', 1);
      }
    } else {
      final columns = displayColumnFor(text, i, next) - 1;
      if (column + columns > compareMaximumDisplayColumns) break;
      place(text.substring(i, next), columns);
    }
    i = next;
  }

  final hidden = i < end ? text.substring(i, end).runes.length : 0;
  return CompareWrappedLine(out.toString(), lines, hidden);
}

bool _isLeadSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isTrailSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// The visual lines [text]'s line [line] takes, or 0 for no line.
int _lineVisualLines(ComparedText text, int line, int perRow) => line < 0
    ? 0
    : compareVisualLines(
        text.columnsOf(line),
        perRow,
        nonLatin: text.isNonLatin(line),
      );

/// Each row's first visual line, as prefix sums: row r spans
/// `offsets[r]` to `offsets[r + 1]`, and the last entry is the total. A
/// side-by-side row is as tall as its taller half; a gap takes no lines.
Int32List compareRowOffsets(
  LineDiffRows rows,
  ComparedText left,
  ComparedText right,
  int perRow,
) {
  final offsets = Int32List(rows.length + 1);
  for (var row = 0; row < rows.length; row++) {
    final lines = math.max(
      1,
      math.max(
        _lineVisualLines(left, rows.leftLineAt(row), perRow),
        _lineVisualLines(right, rows.rightLineAt(row), perRow),
      ),
    );
    offsets[row + 1] = offsets[row] + lines;
  }
  return offsets;
}

/// The row holding [visualLine], clamped to the rows that exist.
int compareRowAtVisualLine(Int32List offsets, int visualLine) {
  final last = offsets.length - 2;
  if (last < 0) return 0;
  var lo = 0;
  var hi = last;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (offsets[mid] <= visualLine) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}
