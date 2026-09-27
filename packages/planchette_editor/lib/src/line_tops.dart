import 'package:flutter/rendering.dart';

/// Where each logical line's rows begin, in the editor's content coordinates.
///
/// [tops] has one entry per logical line, so the gutter can index it directly.
/// The first [exactLines] entries come from a real text layout; the rest are
/// extrapolated, and [laidOutCharacters] says how much was measured.
final class LineTops {
  const LineTops({
    required this.tops,
    required this.exactLines,
    required this.laidOutCharacters,
    required this.lineHeight,
  });

  /// The y offset of every logical line, ascending. One entry per line start.
  final List<double> tops;

  /// How many leading entries of [tops] were measured rather than extrapolated.
  final int exactLines;

  /// How many characters of the document the measurement laid out.
  final int laidOutCharacters;

  /// The height of one visual row at the current text scale.
  final double lineHeight;

  /// The y offset of [line], measured where possible and modelled beyond that.
  double topOf(int line) => tops[line];
}

/// Extra rows measured beyond the visible ones, so a small scroll does not
/// immediately invalidate the layout.
const int _lineTopsLookaheadLines = 64;

/// How many visual rows a viewport of [height] shows at [lineHeight].
///
/// Shared with the caller so "the current measurement still covers the
/// viewport" is asked the same way the measurement was sized.
int visibleLineCount(double height, double lineHeight) =>
    lineHeight > 0 ? (height / lineHeight).ceil() : 0;

/// Measure the y offset of every logical line in [text].
///
/// A viewport shows a few dozen rows, but the y of a line depends on the wrap
/// of every line above it, which is why laying out the whole buffer is the
/// obvious way to answer. It is also the reason typing in a large file used to
/// cost hundreds of milliseconds: a paragraph layout plus one caret query per
/// line, redone on every character. This lays out only a prefix — the rows the
/// viewport can show, plus [_lineTopsLookaheadLines] of margin — and answers
/// everything past it from [lineHeight], which is exact for text that does not
/// soft wrap and is the same model the gutter already used above the
/// highlighting cap.
///
/// [minimumLines] is how many lines a previous measurement already covered.
/// Passing it back keeps the prefix from shrinking, so scrolling down a large
/// document lays out progressively bigger prefixes a logarithmic number of
/// times rather than once per scroll step.
LineTops measureLineTops({
  required String text,
  required List<int> lineStarts,
  required TextStyle style,
  required TextScaler scaler,
  required double width,
  required double viewportHeight,
  int minimumLines = 0,
}) {
  // The style's arithmetic sizes the prefix. The row height the paragraph
  // really uses can differ from it — see below — so this is a starting guess.
  final styleHeight = scaler.scale(style.fontSize ?? 14) * (style.height ?? 1);
  // `minimumLines` is folded into the upper bound rather than passed as the
  // lower one: a stale value (most of the document was deleted) can exceed the
  // line count, and clamping to a lower bound above the upper one returns the
  // oversize number and leaves the two bounds inverted.
  final wanted = _clamp(
    visibleLineCount(viewportHeight, styleHeight) + _lineTopsLookaheadLines,
    minimumLines < lineStarts.length ? minimumLines : lineStarts.length,
    lineStarts.length,
  );

  // Cut on a line boundary so the rows measured are rows the editor will draw
  // and so the extrapolated tail begins at a height the measurement knows.
  final characters = wanted >= lineStarts.length
      ? text.length
      : lineStarts[wanted];

  // A plain span measures the same rows as the highlighted one: the spans only
  // differ in colour, and tokenizing the prefix would cost more than the layout.
  final painter = TextPainter(
    text: TextSpan(text: text.substring(0, characters), style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout(maxWidth: width > 1 ? width : 1);

  final tops = <double>[];
  for (final offset in lineStarts) {
    if (offset >= characters) break;
    tops.add(
      painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
    );
  }
  // The row height the paragraph is really using, which is not always
  // `fontSize * height`: the framework's default text height behaviour lets the
  // font's own ascent and descent win. Modelling the tail with the style's
  // arithmetic would drift by the difference on every row.
  final lineHeight = painter.preferredLineHeight;
  // Where the first modelled line begins: the row the prefix ends on. It is
  // *not* the prefix's total height, which also counts the row the caret is
  // already on — starting the tail below that would put every line after the
  // prefix a full row too low. An empty measurement is the one case where even
  // this is wrong, because a laid-out empty string still reports one row and
  // line 0 belongs at the top.
  final tailBase = tops.isEmpty
      ? 0.0
      : painter
            .getOffsetForCaret(TextPosition(offset: characters), Rect.zero)
            .dy;
  painter.dispose();

  final tailStart = tops.length;
  for (var line = tailStart; line < lineStarts.length; line++) {
    tops.add(tailBase + (line - tailStart) * lineHeight);
  }
  return LineTops(
    tops: tops,
    exactLines: tailStart,
    laidOutCharacters: characters,
    lineHeight: lineHeight,
  );
}

int _clamp(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);
