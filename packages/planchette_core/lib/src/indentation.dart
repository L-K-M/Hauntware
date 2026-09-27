/// Indentation detection and the line edits behind Tab, Shift+Tab, Enter and
/// Backspace in the editor. These are pure text transforms so every host gets
/// identical behavior and they can be tested without Flutter.
library;

enum IndentStyle { tabs, spaces }

/// One level of indentation. [width] is the visual width of a tab stop, and
/// for [IndentStyle.spaces] also the number of spaces inserted per level.
final class Indentation {
  const Indentation.tabs({this.width = defaultIndentWidth})
    : style = IndentStyle.tabs;
  const Indentation.spaces([this.width = defaultIndentWidth])
    : style = IndentStyle.spaces;

  final IndentStyle style;
  final int width;

  /// The text inserted for one level at a tab stop.
  String get unit => style == IndentStyle.tabs ? '\t' : ' ' * width;

  @override
  bool operator ==(Object other) =>
      other is Indentation && other.style == style && other.width == width;

  @override
  int get hashCode => Object.hash(style, width);

  @override
  String toString() => style == IndentStyle.tabs ? 'tabs' : 'spaces($width)';
}

const int defaultIndentWidth = 4;

/// Detection reads at most this much of a document. The start of a file is
/// enough to learn its convention, and the editor re-runs detection on edits
/// until it finds one, so the scan must stay cheap in large files.
const int _detectionLineLimit = 10000;
const int _detectionCharLimit = 256 * 1024;

/// The indentation for a document that has none yet. Makefile recipes must
/// start with a tab and gofmt indents Go with tabs; everything else uses
/// [defaultIndentWidth] spaces.
Indentation defaultIndentationFor(String path) {
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  final basename = path.substring(separator + 1).toLowerCase();
  if (basename == 'makefile' ||
      basename == 'gnumakefile' ||
      basename.endsWith('.mk') ||
      basename.endsWith('.go')) {
    return const Indentation.tabs();
  }
  return const Indentation.spaces();
}

/// Guesses the indentation a document already uses, or null when it has no
/// indented lines to learn from.
///
/// Tabs win when more lines start with a tab than with spaces. Otherwise the
/// width is the most common change in leading spaces between consecutive
/// indented lines, which is robust against deeply nested files where the
/// absolute indentation is mostly 8 or 12. Continuation lines of block
/// comments (` * text`) are ignored because they add a one-space step.
Indentation? detectIndentation(String text) {
  if (text.length > _detectionCharLimit) {
    text = text.substring(0, _detectionCharLimit);
  }
  var tabLines = 0;
  var spaceLines = 0;
  var previousSpaces = 0;
  final steps = List<int>.filled(9, 0);
  var lineStart = 0;
  for (var line = 0; line < _detectionLineLimit; line++) {
    if (lineStart > text.length) break;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    var i = lineStart;
    while (i < lineEnd && text.codeUnitAt(i) == 0x20) {
      i++;
    }
    final spaces = i - lineStart;
    final blank = _isBlank(text, i, lineEnd);
    if (!blank) {
      if (spaces == 0 && i < lineEnd && text.codeUnitAt(i) == 0x09) {
        tabLines++;
      } else if (text.startsWith('*', i) && spaces > 0) {
        // A block comment continuation says nothing about the indent unit.
      } else {
        if (spaces > 0) spaceLines++;
        final step = (spaces - previousSpaces).abs();
        if (step > 0 && step < steps.length) steps[step]++;
        previousSpaces = spaces;
      }
    }
    lineStart = lineEnd + 1;
  }
  if (tabLines == 0 && spaceLines == 0) return null;
  if (tabLines > spaceLines) return const Indentation.tabs();
  var best = 0;
  for (var step = 1; step < steps.length; step++) {
    // Ties prefer the smaller step: a file indented by 2 also has 4-space
    // jumps where two levels close at once.
    if (steps[step] > steps[best]) best = step;
  }
  if (best == 0) return null;
  return Indentation.spaces(best);
}

bool _isBlank(String text, int from, int to) {
  for (var i = from; i < to; i++) {
    final unit = text.codeUnitAt(i);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0d) return false;
  }
  return true;
}

/// A replacement buffer with the selection to install alongside it.
/// [selectionBase] and [selectionExtent] keep the original direction.
final class IndentEdit {
  const IndentEdit(this.text, this.selectionBase, this.selectionExtent);

  final String text;
  final int selectionBase;
  final int selectionExtent;

  @override
  bool operator ==(Object other) =>
      other is IndentEdit &&
      other.text == text &&
      other.selectionBase == selectionBase &&
      other.selectionExtent == selectionExtent;

  @override
  int get hashCode => Object.hash(text, selectionBase, selectionExtent);

  @override
  String toString() =>
      'IndentEdit($selectionBase, $selectionExtent, '
      '${text.replaceAll('\t', r'\t').replaceAll('\n', r'\n')})';
}

/// Tab. A caret or a partial selection within one line is replaced by
/// whitespace up to the next tab stop, like typing. A selection that spans
/// lines, or covers one whole line, indents each touched line instead.
IndentEdit indentSelection(
  String text,
  int base,
  int extent,
  Indentation indentation,
) {
  final start = base < extent ? base : extent;
  final end = base < extent ? extent : base;
  final firstLine = _lineStart(text, start);
  final lastLineEnd = _lineEnd(text, end);
  final coversLine = start == firstLine && end == lastLineEnd && end > start;
  if (!text.substring(start, end).contains('\n') && !coversLine) {
    final String insert;
    if (indentation.style == IndentStyle.tabs) {
      insert = '\t';
    } else {
      final column = _visualColumn(text, firstLine, start, indentation.width);
      insert = ' ' * (indentation.width - column % indentation.width);
    }
    final caret = start + insert.length;
    return IndentEdit(text.replaceRange(start, end, insert), caret, caret);
  }
  final starts = _touchedLineStarts(text, start, end);
  final unit = indentation.unit;
  final buffer = StringBuffer();
  var copied = 0;
  for (final lineStart in starts) {
    buffer
      ..write(text.substring(copied, lineStart))
      ..write(_isBlank(text, lineStart, _lineEnd(text, lineStart)) ? '' : unit);
    copied = lineStart;
  }
  buffer.write(text.substring(copied));
  int map(int offset, {required bool isStart}) {
    var shifted = offset;
    for (final lineStart in starts) {
      final inserted = _isBlank(text, lineStart, _lineEnd(text, lineStart))
          ? 0
          : unit.length;
      // A selection that begins at a line start grows to include the new
      // indentation, so re-pressing Tab keeps operating on whole lines.
      if (lineStart < offset || (lineStart == offset && !isStart)) {
        shifted += inserted;
      }
    }
    return shifted;
  }

  final newStart = map(start, isStart: true);
  final newEnd = map(end, isStart: false);
  return base <= extent
      ? IndentEdit(buffer.toString(), newStart, newEnd)
      : IndentEdit(buffer.toString(), newEnd, newStart);
}

/// Shift+Tab. Removes one level from every touched line: a leading tab, or
/// spaces back to the previous tab stop. Returns null when nothing changes.
IndentEdit? outdentSelection(
  String text,
  int base,
  int extent,
  Indentation indentation,
) {
  final start = base < extent ? base : extent;
  final end = base < extent ? extent : base;
  final removals = <(int, int)>[];
  for (final lineStart in _touchedLineStarts(text, start, end)) {
    final count = _outdentWidth(text, lineStart, indentation.width);
    if (count > 0) removals.add((lineStart, count));
  }
  if (removals.isEmpty) return null;
  final buffer = StringBuffer();
  var copied = 0;
  for (final (lineStart, count) in removals) {
    buffer.write(text.substring(copied, lineStart));
    copied = lineStart + count;
  }
  buffer.write(text.substring(copied));
  int map(int offset) {
    var shifted = offset;
    for (final (lineStart, count) in removals) {
      if (offset <= lineStart) break;
      shifted -= offset >= lineStart + count ? count : offset - lineStart;
    }
    return shifted;
  }

  return IndentEdit(buffer.toString(), map(base), map(extent));
}

int _outdentWidth(String text, int lineStart, int width) {
  if (lineStart < text.length && text.codeUnitAt(lineStart) == 0x09) return 1;
  var spaces = 0;
  while (lineStart + spaces < text.length &&
      text.codeUnitAt(lineStart + spaces) == 0x20) {
    spaces++;
  }
  if (spaces == 0) return 0;
  final remainder = spaces % width;
  return remainder == 0 ? width : remainder;
}

/// Enter. The new line repeats the leading whitespace before the caret. After
/// an opening bracket (or a colon, where [indentAfterColon]) it gains one
/// level, and a bracket pair such as `{|}` splits onto three lines. A line
/// holding only indentation is emptied, so repeated Enters leave no trailing
/// whitespace behind.
IndentEdit insertNewline(
  String text,
  int base,
  int extent,
  Indentation indentation, {
  bool indentAfterColon = false,
}) {
  final start = base < extent ? base : extent;
  final end = base < extent ? extent : base;
  final lineStart = _lineStart(text, start);
  var indentEnd = lineStart;
  while (indentEnd < start && _isIndentUnit(text.codeUnitAt(indentEnd))) {
    indentEnd++;
  }
  final leading = text.substring(lineStart, indentEnd);
  final restEnd = _lineEnd(text, end);
  if (indentEnd == start && start > lineStart && _isBlank(text, end, restEnd)) {
    // Only indentation before the caret and nothing after it: move the
    // indentation to the new line instead of leaving it behind.
    final replaced = text.replaceRange(lineStart, restEnd, '\n$leading');
    final caret = lineStart + 1 + leading.length;
    return IndentEdit(replaced, caret, caret);
  }
  var before = start;
  while (before > indentEnd && _isIndentUnit(text.codeUnitAt(before - 1))) {
    before--;
  }
  final opener = before > indentEnd ? text[before - 1] : '';
  final opens =
      _closers.containsKey(opener) || (indentAfterColon && opener == ':');
  final inner = opens ? '$leading${indentation.unit}' : leading;
  var after = end;
  while (after < restEnd && _isIndentUnit(text.codeUnitAt(after))) {
    after++;
  }
  final closes =
      _closers.containsKey(opener) &&
      after < restEnd &&
      text[after] == _closers[opener];
  final insert = closes ? '\n$inner\n$leading' : '\n$inner';
  // Whitespace between the caret and a closing bracket would otherwise end up
  // in front of the bracket on its own line.
  final replaceEnd = closes ? after : end;
  final replaced = text.replaceRange(start, replaceEnd, insert);
  final caret = start + 1 + inner.length;
  return IndentEdit(replaced, caret, caret);
}

const _closers = {'{': '}', '[': ']', '(': ')'};

/// Backspace inside space indentation deletes back to the previous tab stop.
/// Returns null when ordinary Backspace applies.
IndentEdit? deleteIndentBackward(
  String text,
  int caret,
  Indentation indentation,
) {
  if (indentation.style != IndentStyle.spaces || caret <= 0) return null;
  final lineStart = _lineStart(text, caret);
  final column = caret - lineStart;
  if (column == 0) return null;
  for (var i = lineStart; i < caret; i++) {
    if (text.codeUnitAt(i) != 0x20) return null;
  }
  final remainder = column % indentation.width;
  final count = remainder == 0 ? indentation.width : remainder;
  if (count <= 1) return null;
  final from = caret - count;
  return IndentEdit(text.replaceRange(from, caret, ''), from, from);
}

bool _isIndentUnit(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09;

int _lineStart(String text, int offset) =>
    offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

int _lineEnd(String text, int offset) {
  final newline = text.indexOf('\n', offset);
  return newline < 0 ? text.length : newline;
}

/// The starts of lines a selection touches. A multi-line selection that ends
/// at column 0 does not touch its final line: it was selected up to, not into.
List<int> _touchedLineStarts(String text, int start, int end) {
  final starts = <int>[_lineStart(text, start)];
  var newline = text.indexOf('\n', starts.first);
  while (newline >= 0 && newline + 1 < end) {
    starts.add(newline + 1);
    newline = text.indexOf('\n', newline + 1);
  }
  return starts;
}

int _visualColumn(String text, int lineStart, int offset, int tabWidth) {
  var column = 0;
  for (var i = lineStart; i < offset; i++) {
    column = text.codeUnitAt(i) == 0x09
        ? column + tabWidth - column % tabWidth
        : column + 1;
  }
  return column;
}
