import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show TextEditingController;

/// Direction used by [moveSelectionLines].
enum LineMoveDirection { up, down }

const String _indentUnit = '\t';

/// Spaces removed by outdent when a line starts with spaces instead of a
/// tab character. Matches the common editor default until Planchette grows
/// a configurable tab width.
const int spacesPerOutdent = 4;

int _lineStartBefore(String text, int offset) {
  var i = offset;
  while (i > 0 && text.codeUnitAt(i - 1) != 0x0a) {
    i--;
  }
  return i;
}

int _lineEndBeforeNewline(String text, int offset) {
  var i = offset;
  while (i < text.length && text.codeUnitAt(i) != 0x0a) {
    i++;
  }
  return i;
}

/// The full lines touched by [selection]: from the line containing the
/// anchor through the line containing the character before the extent.
/// `first` and `lastStart` are line starts; `blockEnd` ends the last line
/// before its newline.
({int first, int lastStart, int blockEnd}) _touchedLines(
  String text,
  TextSelection selection,
) {
  final start = selection.start;
  final end = selection.end;
  final first = _lineStartBefore(text, start);
  final lastStart = end > start
      ? _lineStartBefore(text, end - 1)
      : first;
  return (first: first, lastStart: lastStart, blockEnd: _lineEndBeforeNewline(text, lastStart));
}

/// Line starts from [first] through [last], inclusive.
List<int> _lineStartsBetween(String text, int first, int last) {
  final starts = <int>[first];
  for (var line = first; line < last;) {
    line = _lineEndBeforeNewline(text, line) + 1;
    starts.add(line);
  }
  return starts;
}

void _apply(
  TextEditingController controller,
  String text,
  TextSelection selection,
) {
  controller.value = TextEditingValue(
    text: text,
    selection: selection,
    composing: TextRange.empty,
  );
}

TextSelection _shifted(
  TextSelection selection,
  int Function(int offset) shift,
  int length,
) {
  int moved(int offset) => shift(offset).clamp(0, length).toInt();
  return TextSelection(
    baseOffset: moved(selection.baseOffset),
    extentOffset: moved(selection.extentOffset),
  );
}

/// Tab: insert one tab at the caret, replace an intra-line selection, or
/// indent every line the selection touches. The selection follows the edit.
void indentSelection(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) return;
  final text = value.text;
  final start = selection.start;
  final end = selection.end;
  final first = _lineStartBefore(text, start);
  final last = end > start ? _lineStartBefore(text, end - 1) : first;

  if (last == first) {
    // Collapsed or single-line: typing over the selection.
    _apply(
      controller,
      text.replaceRange(start, end, _indentUnit),
      TextSelection.collapsed(offset: start + _indentUnit.length),
    );
    return;
  }

  // One tab lands at each touched line start. An offset moves right for
  // every insertion at or before it, so a caret at a line start ends up
  // after its new tab.
  final starts = _lineStartsBetween(text, first, last);
  final blockEnd = _lineEndBeforeNewline(text, last);
  final buffer = StringBuffer(text.substring(0, first));
  for (var i = 0; i < starts.length; i++) {
    buffer
      ..write(_indentUnit)
      ..write(text.substring(starts[i], i + 1 < starts.length
          ? starts[i + 1]
          : blockEnd));
  }
  buffer.write(text.substring(blockEnd));
  final newText = buffer.toString();
  _apply(
    controller,
    newText,
    _shifted(
      selection,
      (offset) => offset + starts.where((line) => line <= offset).length,
      newText.length,
    ),
  );
}

/// Shift+Tab: remove one leading tab, or up to [spacesPerOutdent] leading
/// spaces, from every line the selection touches.
void outdentSelection(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) return;
  final text = value.text;
  final touched = _touchedLines(text, selection);
  final starts = _lineStartsBetween(text, touched.first, touched.lastStart);

  // Bytes removed at each line start; an offset moves left for every
  // removal strictly before it, so a caret at a line start stays put.
  final removedAt = <int, int>{};
  final buffer = StringBuffer(text.substring(0, touched.first));
  for (var i = 0; i < starts.length; i++) {
    var removed = 0;
    if (text.startsWith(_indentUnit, starts[i])) {
      removed = _indentUnit.length;
    } else {
      final lineEnd = _lineEndBeforeNewline(text, starts[i]);
      while (removed < spacesPerOutdent &&
          starts[i] + removed < lineEnd &&
          text.codeUnitAt(starts[i] + removed) == 0x20) {
        removed++;
      }
    }
    removedAt[starts[i]] = removed;
    final segmentEnd = i + 1 < starts.length
        ? starts[i + 1]
        : touched.blockEnd;
    buffer.write(text.substring(starts[i] + removed, segmentEnd));
  }
  buffer.write(text.substring(touched.blockEnd));
  final newText = buffer.toString();
  _apply(
    controller,
    newText,
    _shifted(
      selection,
      (offset) =>
          offset -
          removedAt.entries
              .where((entry) => entry.key < offset)
              .fold(0, (total, entry) => total + entry.value),
      newText.length,
    ),
  );
}

/// Enter: replace the selection with a newline plus the first selected
/// line's leading whitespace. Callers must not invoke this during IME
/// composition.
void insertNewlineWithIndent(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) return;
  final text = value.text;
  // The first selected line survives the replace; the last one does not,
  // and the extent's position depends on how the selection was built.
  final caret = selection.start.clamp(0, text.length).toInt();
  final lineStart = _lineStartBefore(text, caret);
  var indentEnd = lineStart;
  while (indentEnd < text.length) {
    final unit = text.codeUnitAt(indentEnd);
    if (unit == 0x20 || unit == 0x09) {
      indentEnd++;
    } else {
      break;
    }
  }
  final indent = text.substring(lineStart, indentEnd);
  _apply(
    controller,
    text.replaceRange(selection.start, selection.end, '\n$indent'),
    TextSelection.collapsed(offset: selection.start + 1 + indent.length),
  );
}

/// Content end and separator length of the line terminating at [lineEnd]
/// (the index of its '\n', or the end of the text). A '\r' immediately
/// before the line feed belongs to the separator, so CRLF neighbors swap
/// without stranding carriage returns.
(int, int) _contentEndAndSeparatorLength(String text, int lineEnd) {
  if (lineEnd >= text.length) return (lineEnd, 0);
  return lineEnd > 0 && text.codeUnitAt(lineEnd - 1) == 0x0d
      ? (lineEnd - 1, 2)
      : (lineEnd, 1);
}

/// Alt+ArrowUp/ArrowDown: swap the touched lines with the neighbor above or
/// below, keeping the selection on the moved text. Line contents swap while
/// separators stay in place, so CRLF and LF endings survive unchanged. A
/// no-op at the edges.
void moveSelectionLines(
  TextEditingController controller, {
  required LineMoveDirection direction,
}) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) return;
  final text = value.text;
  if (text.isEmpty) return;
  final touched = _touchedLines(text, selection);
  final (blockContentEnd, blockSeparatorLength) = _contentEndAndSeparatorLength(
    text,
    touched.blockEnd,
  );
  final block = text.substring(touched.first, blockContentEnd);
  final blockEndWithSeparator = blockContentEnd + blockSeparatorLength;

  late final String newText;
  late final int blockStart;
  if (direction == LineMoveDirection.up) {
    if (touched.first == 0) return;
    final previousStart = _lineStartBefore(text, touched.first - 1);
    final (previousContentEnd, previousSeparatorLength) =
        _contentEndAndSeparatorLength(text, touched.first - 1);
    final previous = text.substring(previousStart, previousContentEnd);
    newText =
        '${text.substring(0, previousStart)}'
        '$block'
        '${text.substring(previousContentEnd, touched.first)}'
        '$previous'
        '${text.substring(blockContentEnd, blockEndWithSeparator)}'
        '${text.substring(blockEndWithSeparator)}';
    blockStart = previousStart;
  } else {
    if (touched.blockEnd >= text.length) return;
    final nextStart = touched.blockEnd + 1;
    final nextEnd = _lineEndBeforeNewline(text, nextStart);
    final (nextContentEnd, nextSeparatorLength) = _contentEndAndSeparatorLength(
      text,
      nextEnd,
    );
    final next = text.substring(nextStart, nextContentEnd);
    final suffixStart = nextContentEnd + nextSeparatorLength;
    newText =
        '${text.substring(0, touched.first)}'
        '$next'
        '${text.substring(blockContentEnd, blockEndWithSeparator)}'
        '$block'
        '${text.substring(nextContentEnd, suffixStart)}'
        '${text.substring(suffixStart)}';
    blockStart =
        touched.first + (nextContentEnd - nextStart) + blockSeparatorLength;
  }
  _apply(
    controller,
    newText,
    _shifted(
      selection,
      (offset) =>
          blockStart +
          (offset - touched.first).clamp(0, block.length).toInt(),
      newText.length,
    ),
  );
}

/// Shift+Alt+ArrowDown/ArrowUp: insert a copy of the touched lines below
/// them and select the copy.
void duplicateSelectionLines(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  if (!selection.isValid) return;
  final text = value.text;
  if (text.isEmpty) return;
  final touched = _touchedLines(text, selection);
  final block = text.substring(touched.first, touched.blockEnd);
  final blockIsLastLine = touched.blockEnd >= text.length;
  // Inside the text the copy follows the block's line break and carries one
  // of its own; appended at the end it needs the break before it instead.
  final insertAt = blockIsLastLine
      ? touched.blockEnd
      : touched.blockEnd + 1;
  final insertion = blockIsLastLine ? '\n$block' : '$block\n';
  final copyStart = blockIsLastLine ? insertAt + 1 : insertAt;
  _apply(
    controller,
    text.replaceRange(insertAt, insertAt, insertion),
    TextSelection(
      baseOffset: copyStart,
      extentOffset: copyStart + block.length,
    ),
  );
}
