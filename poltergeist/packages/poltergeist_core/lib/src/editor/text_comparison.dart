import 'dart:typed_data';

import 'package:planchette_core/planchette_core.dart' as shared;

import 'line_diff.dart';

/// The most lines either side may have for the diff to be computed (06 §6).
/// Each side is also held to `builtInEditorMaximumBytes` by its loader.
const int compareMaximumLines = 20000;

/// The lines a text has as a line counter reports them: one per `\n`, plus
/// an unterminated last line. A 20 000-line file passes the cap whether or
/// not it ends with a newline.
int countComparedLines(String text) {
  var lines = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) lines++;
  }
  if (text.isNotEmpty && text.codeUnitAt(text.length - 1) != 0x0a) lines++;
  return lines;
}

/// Where each line of one compared text starts and how wide it is, measured
/// off the UI isolate so a renderer can size rows without rescanning.
///
/// Lines split at `\n` exactly as the editor numbers them: a trailing
/// newline leaves an empty last line, so a final-newline difference shows
/// as one changed line.
final class ComparedText {
  ComparedText._(this._starts, this._columns, this._nonLatin, this._length);

  factory ComparedText.measure(String text) {
    final starts = shared.lineStartOffsets(text);
    final columns = Int32List(starts.length);
    final nonLatin = Uint8List(starts.length);
    for (var line = 0; line < starts.length; line++) {
      final start = starts[line];
      final end = line + 1 < starts.length ? starts[line + 1] - 1 : text.length;
      columns[line] = shared.displayColumnFor(text, start, end) - 1;
      for (var i = start; i < end; i++) {
        if (text.codeUnitAt(i) >= _firstNonLatinCodeUnit) {
          nonLatin[line] = 1;
          break;
        }
      }
    }
    return ComparedText._(
      Int32List.fromList(starts),
      columns,
      nonLatin,
      text.length,
    );
  }

  final Int32List _starts;
  final Int32List _columns;
  final Uint8List _nonLatin;
  final int _length;

  int get lineCount => _starts.length;

  int lineStart(int line) => _starts[line];

  /// The offset of [line]'s `\n`, or the text's end for the last line.
  int lineEnd(int line) =>
      line + 1 < _starts.length ? _starts[line + 1] - 1 : _length;

  /// The display columns [line] spans, with tabs at 4 and wide characters
  /// at 2 (planchette_core's `displayColumnFor`).
  int columnsOf(int line) => _columns[line];

  /// Whether [line] has a code unit past the Latin and IPA blocks, where a
  /// monospace font may fall back to glyphs whose advance differs from the
  /// counted columns.
  bool isNonLatin(int line) => _nonLatin[line] == 1;
}

/// U+0300, the first combining mark, ends the Latin and IPA blocks.
const _firstNonLatinCodeUnit = 0x0300;

/// What comparing two texts produced.
sealed class TextComparison {
  const TextComparison();
}

final class TextComparisonComputed extends TextComparison {
  const TextComparisonComputed({
    required this.diff,
    required this.left,
    required this.right,
  });

  final LineDiff diff;
  final ComparedText left;
  final ComparedText right;
}

/// A side has more than [maximumLines] lines, so nothing was computed.
final class TextComparisonOverLineCap extends TextComparison {
  const TextComparisonOverLineCap({
    required this.leftLines,
    required this.rightLines,
    required this.maximumLines,
  });

  final int leftLines;
  final int rightLines;
  final int maximumLines;
}

/// The worker died or could not start; never a claim that nothing changed.
final class TextComparisonFailed extends TextComparison {
  const TextComparisonFailed();
}

/// Compares two LF-normalized texts line by line, after checking the line
/// cap on each side.
TextComparison compareTexts(
  String left,
  String right, {
  int maximumLines = compareMaximumLines,
  int costLimit = lineDiffCostLimit,
}) {
  final leftLines = countComparedLines(left);
  final rightLines = countComparedLines(right);
  if (leftLines > maximumLines || rightLines > maximumLines) {
    return TextComparisonOverLineCap(
      leftLines: leftLines,
      rightLines: rightLines,
      maximumLines: maximumLines,
    );
  }

  return TextComparisonComputed(
    diff: diffLines(left.split('\n'), right.split('\n'), costLimit: costLimit),
    left: ComparedText.measure(left),
    right: ComparedText.measure(right),
  );
}
