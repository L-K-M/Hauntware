import 'text_metrics.dart';

/// A rewritten buffer plus the selection that should follow the edit.
///
/// Offsets are UTF-16 code units into [text], matching every other range the
/// core reports, so callers can hand them straight to a `TextEditingValue`.
class TextEdit {
  const TextEdit({required this.text, required this.start, required this.end});

  final String text;
  final int start;
  final int end;

  int get length => end - start;
  bool get isCollapsed => start == end;

  @override
  String toString() => 'TextEdit($start, $end)';
}

/// Columns a tab stop occupies. A stop exists so a caret that already lands on
/// a multiple of the width advances a whole further stop rather than nothing.
const int defaultTabWidth = 4;

const int _space = 0x20;
const int _tab = 0x09;
const int _newline = 0x0a;

/// One line's content as `[start, end)`, excluding its newline.
typedef _Line = ({int start, int end});

/// How one line's leading whitespace changes: [inserted] is written in front of
/// the line and its first [stripped] characters are dropped.
class _LineRewrite {
  const _LineRewrite({required this.inserted, required this.stripped});
  final String inserted;
  final int stripped;

  int get delta => inserted.length - stripped;
}

/// Indent as an editor is expected to, for a selection of [start] to [end]:
///
/// ```text
///   caret at a line start  ->  one whole indent
///   caret after code       ->  padded up to the next tab stop
///   selection on one line  ->  replaced by one whole indent
///   selection over lines   ->  every line it touches is indented
/// ```
///
/// With `insertSpaces` false a literal tab is inserted instead of spaces.
TextEdit insertIndent(
  String text, {
  required int start,
  required int end,
  int tabWidth = defaultTabWidth,
  bool insertSpaces = true,
}) {
  _requireSelection(text, start, end);
  _requireTabWidth(tabWidth);

  final unit = insertSpaces ? ' ' * tabWidth : '\t';
  if (start == end) return _indentAtCaret(text, start, tabWidth, unit);
  if (!_spansNewline(text, start, end)) return _splice(text, start, end, unit);
  return _rewriteTouchedLines(
    text,
    start,
    end,
    (_) => _LineRewrite(inserted: unit, stripped: 0),
  );
}

TextEdit _indentAtCaret(String text, int caret, int tabWidth, String unit) {
  final lineStart = _lineStartBefore(text, caret);
  if (_isBlank(text.substring(lineStart, caret))) {
    // Only whitespace precedes the caret, so a whole indent belongs here.
    return _splice(text, caret, caret, unit);
  }
  // The caret follows code, so pad to the next stop instead of over-indenting.
  final column = _whitespaceColumns(
    text,
    lineStart,
    caret - lineStart,
    tabWidth,
  );
  return _splice(
    text,
    caret,
    caret,
    ' ' * ((column ~/ tabWidth + 1) * tabWidth - column),
  );
}

/// Strip at most one tab stop of leading whitespace from every line the
/// selection touches. A line indented with fewer columns than a stop is fully
/// dedented; a line with no leading whitespace is left untouched.
TextEdit removeIndent(
  String text, {
  required int start,
  required int end,
  int tabWidth = defaultTabWidth,
}) {
  _requireSelection(text, start, end);
  _requireTabWidth(tabWidth);

  return _rewriteTouchedLines(
    text,
    start,
    end,
    (line) => _LineRewrite(inserted: '', stripped: _dedentRun(line, tabWidth)),
  );
}

/// Apply [plan] to every line the selection touches, keeping the selection over
/// the same characters. An endpoint inside a line's removed indentation has no
/// character of its own left, so it collapses to the start of what remains.
TextEdit _rewriteTouchedLines(
  String text,
  int start,
  int end,
  _LineRewrite Function(String line) plan,
) {
  final lines = _linesOf(text);
  final buffer = StringBuffer();
  final rewritten = <_AppliedRewrite>[];
  var copied = 0;
  var shifted = 0;
  for (final line in _touchedLines(lines, start, end)) {
    final rewrite = plan(text.substring(line.start, line.end));
    buffer
      ..write(text.substring(copied, line.start))
      ..write(rewrite.inserted)
      ..write(text.substring(line.start + rewrite.stripped, line.end));
    rewritten.add(_AppliedRewrite(line.start, rewrite, shifted));
    shifted += rewrite.delta;
    copied = line.end;
  }
  buffer.write(text.substring(copied));
  return TextEdit(
    text: buffer.toString(),
    start: _mapOffset(rewritten, start),
    end: _mapOffset(rewritten, end),
  );
}

class _AppliedRewrite {
  const _AppliedRewrite(this.lineStart, this.rewrite, this.shifted);

  /// Content start of the line in the original buffer.
  final int lineStart;
  final _LineRewrite rewrite;

  /// How far every offset from this line's start onwards has already moved.
  final int shifted;
}

/// The lines of [text] as content ranges.
List<_Line> _linesOf(String text) {
  final starts = lineStartOffsets(text);
  return [
    for (var i = 0; i < starts.length; i++)
      (
        start: starts[i],
        end: i + 1 < starts.length ? starts[i + 1] - 1 : text.length,
      ),
  ];
}

/// The lines a selection of [start] to [end] touches. The line holding the
/// last selected character is the last one, so a selection ending exactly on a
/// line start leaves the line it ends on alone — that is what selecting whole
/// lines means.
List<_Line> _touchedLines(List<_Line> lines, int start, int end) {
  final first = _lineIndexOf(lines, start);
  final last = _lineIndexOf(lines, end == start ? start : end - 1);
  return [for (var i = first; i <= last; i++) lines[i]];
}

int _lineIndexOf(List<_Line> lines, int offset) {
  var lo = 0;
  var hi = lines.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (lines[mid].start <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Where [offset] lands in the rewritten buffer. The touched lines are
/// contiguous, so the last rewrite starting at or before [offset] is the only
/// one that can move it; anything past them picks up the total shift.
int _mapOffset(List<_AppliedRewrite> applied, int offset) {
  var lo = 0;
  var hi = applied.length - 1;
  var index = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (applied[mid].lineStart <= offset) {
      index = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (index < 0) return offset;

  final rewrite = applied[index];
  if (offset > rewrite.lineStart + rewrite.rewrite.stripped) {
    return offset + rewrite.shifted + rewrite.rewrite.delta;
  }
  // At or inside the removed indentation the endpoint no longer names a
  // character, so it sits at the start of what remains of the line.
  return rewrite.lineStart + rewrite.shifted;
}

/// Characters of leading whitespace worth at most one [tabWidth] of columns.
int _dedentRun(String line, int tabWidth) {
  var columns = 0;
  var count = 0;
  while (count < line.length && columns < tabWidth) {
    final unit = line.codeUnitAt(count);
    if (unit != _space && unit != _tab) break;
    final next = unit == _tab
        ? (columns ~/ tabWidth + 1) * tabWidth
        : columns + 1;
    if (next > tabWidth) break;
    columns = next;
    count++;
  }
  return count;
}

bool _isBlank(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit != _space && unit != _tab) return false;
  }
  return true;
}

/// Columns reached by the [width] whitespace characters starting at [offset].
int _whitespaceColumns(String text, int offset, int width, int tabWidth) {
  var column = 0;
  for (var i = 0; i < width; i++) {
    column = text.codeUnitAt(offset + i) == _tab
        ? (column ~/ tabWidth + 1) * tabWidth
        : column + 1;
  }
  return column;
}

int _lineStartBefore(String text, int offset) {
  for (var i = offset - 1; i >= 0; i--) {
    if (text.codeUnitAt(i) == _newline) return i + 1;
  }
  return 0;
}

bool _spansNewline(String text, int start, int end) {
  final at = text.indexOf('\n', start);
  return at >= 0 && at < end;
}

TextEdit _splice(String text, int start, int end, String replacement) {
  final caret = start + replacement.length;
  return TextEdit(
    text: text.replaceRange(start, end, replacement),
    start: caret,
    end: caret,
  );
}

void _requireSelection(String text, int start, int end) {
  if (start < 0 || end < start || end > text.length) {
    throw ArgumentError.value(
      'start: $start, end: $end',
      'selection',
      'must satisfy 0 <= start <= end <= ${text.length}',
    );
  }
}

void _requireTabWidth(int tabWidth) {
  if (tabWidth < 1) {
    throw ArgumentError.value(tabWidth, 'tabWidth', 'must be at least 1');
  }
}

/// How many leading characters [text] indents its deepest line, or 0 when no
/// line is indented. Sampling stops once one indented line is found, so this
/// stays cheap on a large document.
({int width, bool usesTabs}) measureIndentation(
  String text, {
  int maximumLines = 400,
}) {
  final starts = lineStartOffsets(text);
  final examined = starts.length < maximumLines ? starts.length : maximumLines;
  var deepest = 0;
  var usesTabs = false;
  for (var i = 0; i < examined; i++) {
    final start = starts[i];
    var width = 0;
    var tabbed = false;
    var blank = true;
    for (var offset = start; offset < text.length; offset++) {
      final unit = text.codeUnitAt(offset);
      if (unit == _tab) {
        tabbed = true;
        width++;
      } else if (unit == _space) {
        width++;
      } else {
        blank = unit == _newline;
        break;
      }
    }
    // A line of nothing but whitespace says nothing about how the file
    // indents, so it must not win the deepest-line comparison.
    if (blank || width == 0) continue;
    if (width > deepest) {
      deepest = width;
      usesTabs = tabbed;
    }
  }
  return (width: deepest, usesTabs: usesTabs);
}
