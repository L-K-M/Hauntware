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
    expect(tops.lineHeight, _lineHeight(scaler: scaled));
    expect(
      tops.tops,
      referenceTops(text, lineStartOffsets(text), scaler: scaled),
    );
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
