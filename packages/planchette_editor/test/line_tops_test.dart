import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_core/planchette_core.dart';
// Deliberately imported from src/: LineTops is an implementation detail of the
// gutter, so it stays out of the package's public surface while still being
// directly testable.
import 'package:planchette_editor/src/line_tops.dart';

const _style = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.35);
const _scaler = TextScaler.noScaling;

double _lineHeight({TextScaler scaler = _scaler}) =>
    scaler.scale(_style.fontSize!) * _style.height!;

/// The answer a whole-document layout would give, which the measured answer has
/// to agree with wherever it claims to be exact.
List<double> referenceTops(
  String text,
  List<int> lineStarts, {
  double width = 900,
  TextStyle style = _style,
  TextScaler scaler = _scaler,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout(maxWidth: width);
  final tops = [
    for (final offset in lineStarts)
      painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
  ];
  painter.dispose();
  return tops;
}

String lines(int count, {int length = 40}) =>
    List.generate(count, (i) => 'x' * length).join('\n');

void main() {
  test('a document smaller than the viewport is measured exactly', () {
    final text = 'one\ntwo\nthree\nfour\nfive';
    final tops = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 800,
    );
    expect(tops.laidOutCharacters, text.length);
    expect(tops.exactLines, 5);
    expect(tops.tops, referenceTops(text, lineStartOffsets(text)));
  });

  test('an empty document still has one line at the top', () {
    final tops = measureLineTops(
      text: '',
      lineStarts: const [0],
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 800,
    );
    expect(tops.tops, [0]);
    // Nothing was laid out, so nothing is claimed as exact — the single line
    // is the modelled one.
    expect(tops.exactLines, 0);
    expect(tops.laidOutCharacters, 0);
  });

  test(
    'only as much of a large document as the viewport shows is laid out',
    () {
      // 40,000 lines is roughly 800 times a 400px viewport's worth of rows.
      final text = lines(40000);
      final starts = lineStartOffsets(text);
      final tops = measureLineTops(
        text: text,
        lineStarts: starts,
        style: _style,
        scaler: _scaler,
        width: 900,
        viewportHeight: 400,
      );
      // One entry per line, so the gutter can index it, but only a prefix was
      // actually laid out. This is the assertion that catches a regression to
      // measuring the whole document.
      expect(tops.tops, hasLength(starts.length));
      expect(tops.laidOutCharacters, lessThan(text.length ~/ 10));
      expect(tops.exactLines, lessThan(200));
    },
  );

  test('the measured prefix agrees with a whole-document layout', () {
    final text = lines(4000);
    final starts = lineStartOffsets(text);
    final tops = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 400,
    );
    final reference = referenceTops(text, starts);
    expect(
      tops.tops.sublist(0, tops.exactLines),
      reference.sublist(0, tops.exactLines),
    );
  });

  test('a wrapped document still measures its prefix exactly', () {
    // 400 characters per line at 900px is about 107 columns, so each of these
    // wraps onto four rows and the uniform model would be visibly wrong.
    final text = lines(500, length: 400);
    final starts = lineStartOffsets(text);
    final tops = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 400,
    );
    final reference = referenceTops(text, starts);
    expect(
      tops.tops.sublist(0, tops.exactLines),
      reference.sublist(0, tops.exactLines),
    );
    // The rows are not the uniform height, so the tail has to start where the
    // measured prefix actually ended rather than at a line count times it.
    expect(
      tops.tops[tops.exactLines - 1],
      greaterThan((tops.exactLines - 1) * _lineHeight()),
    );
  });

  test('the modelled tail keeps the same offset as the measured lines', () {
    // The measured prefix and the modelled tail have to meet exactly. Two ways
    // to get this wrong, both of which were: starting the tail one row too low,
    // because the prefix's total height also counts the row the caret is on;
    // and modelling the rows with `fontSize * height` when the paragraph is
    // really using the font's own ascent and descent, which drifts on every
    // row. The property that catches both is that every line, measured or
    // modelled, sits at the same offset from a whole multiple of the row height.
    final text = lines(4000);
    final starts = lineStartOffsets(text);
    final tops = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 400,
    );
    double offsetOf(int line) => tops.topOf(line) - line * tops.lineHeight;

    final measured = offsetOf(0);
    for (final line in [
      1,
      tops.exactLines - 1,
      tops.exactLines,
      tops.exactLines + 1,
      starts.length - 1,
    ]) {
      // Half a pixel: anything tighter measures Skia's own sub-pixel rounding
      // at the paragraph's first baseline rather than anything decided here.
      expect(offsetOf(line), closeTo(measured, 0.5), reason: 'line $line');
    }
  });

  test('a document measured end to end lines up completely', () {
    final text = 'a\nb\nc\n';
    final tops = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 800,
    );
    expect(tops.tops, referenceTops(text, lineStartOffsets(text)));
    expect(tops.topOf(3), closeTo(3 * tops.lineHeight, 0.01));
  });

  test('offsets stay ascending across the measured and modelled boundary', () {
    final text = lines(40000, length: 400);
    final starts = lineStartOffsets(text);
    final tops = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 400,
    );
    for (var i = 1; i < tops.tops.length; i += 97) {
      expect(tops.tops[i], greaterThan(tops.tops[i - 1]));
    }
    expect(
      tops.tops[tops.exactLines],
      greaterThan(tops.tops[tops.exactLines - 1]),
    );
  });

  test('minimumLines keeps a prefix that has already been paid for', () {
    final text = lines(40000);
    final starts = lineStartOffsets(text);
    final first = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 400,
    );
    // A later frame with a shorter viewport must not throw away the layout.
    final second = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 100,
      minimumLines: first.exactLines,
    );
    expect(second.exactLines, greaterThanOrEqualTo(first.exactLines));
  });

  test('a text scale change remeasures with the scaled row height', () {
    final text = 'one\ntwo\nthree';
    final scaled = const TextScaler.linear(2);
    final tops = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: scaled,
      width: 900,
      viewportHeight: 800,
    );
    // The row height is the one the paragraph is really using, which the text
    // scale does scale and which is not `fontSize * height`.
    final unscaled = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: _scaler,
      width: 900,
      viewportHeight: 800,
    );
    expect(tops.lineHeight, closeTo(unscaled.lineHeight * 2, 0.5));
    expect(
      tops.tops,
      referenceTops(text, lineStartOffsets(text), scaler: scaled),
    );
  });

  test('a document shorter than the viewport measures every line once', () {
    // The editor stops remeasuring when the whole document is covered, on the
    // grounds that the tops then no longer depend on the viewport. That is the
    // property this states, for the two viewport heights a resize moves
    // between.
    final text = List.filled(5, 'line').join('\n');
    final starts = lineStartOffsets(text);
    final short = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 400,
      viewportHeight: 300,
    );
    final tall = measureLineTops(
      text: text,
      lineStarts: starts,
      style: _style,
      scaler: _scaler,
      width: 400,
      viewportHeight: 2000,
    );
    expect(short.exactLines, 5);
    expect(tall.exactLines, 5);
    expect(tall.tops, short.tops);
  });

  test('a stale minimumLines beyond the document still measures it once', () {
    // Deleting most of a long document leaves the editor holding a line count
    // larger than the document has. `minimumLines` then exceeds the line count,
    // and the clamp's bounds are inverted, so this pins what that produces.
    final text = List.filled(5, 'line').join('\n');
    final tops = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: _scaler,
      width: 400,
      viewportHeight: 300,
      minimumLines: 900,
    );
    expect(tops.exactLines, 5);
    expect(tops.tops, hasLength(5));
  });

  test('a zero or negative width does not throw', () {
    final text = 'one\ntwo\nthree';
    final tops = measureLineTops(
      text: text,
      lineStarts: lineStartOffsets(text),
      style: _style,
      scaler: _scaler,
      width: 0,
      viewportHeight: 800,
    );
    expect(tops.tops, hasLength(3));
  });
}
