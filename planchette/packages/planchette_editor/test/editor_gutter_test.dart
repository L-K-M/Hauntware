import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

const band = Color(0x40FF0000);

/// The render object that paints the gutter and current-line band.
RenderBox decorations(WidgetTester tester) {
  RenderObject? node = tester.renderObject(
    find.byKey(const ValueKey('editor-line-gutter')),
  );
  while (node != null &&
      !node.runtimeType.toString().contains('DocumentDecorations')) {
    node = node.parent;
  }
  return node! as RenderBox;
}

RenderEditable editable(WidgetTester tester) {
  final pending = [
    tester.renderObject(find.byKey(const ValueKey('planchette.document'))),
  ];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is RenderEditable) return node;
    node.visitChildren(pending.add);
  }
  throw StateError('No RenderEditable in the document field.');
}

/// The line numbers and band rectangles the decorations paint.
({List<(String, double)> numbers, List<Rect> bands}) painted(
  WidgetTester tester,
) {
  final numbers = <(String, double)>[];
  final bands = <Rect>[];
  expect(
    decorations(tester),
    paints..everything((method, arguments) {
      if (method == #drawParagraph) {
        numbers.add(('', (arguments[1] as Offset).dy));
      }
      if (method == #drawRect &&
          (arguments[1] as Paint).color.toARGB32() == band.toARGB32()) {
        bands.add(arguments[0] as Rect);
      }
      return true;
    }),
  );
  return (numbers: numbers, bands: bands);
}

Future<EditorController> mount(WidgetTester tester, String text) async {
  await tester.binding.setSurfaceSize(const Size(400, 300));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final c = EditorController(displayPath: 'notes.txt', initialText: text);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlanchetteEditor(controller: c, currentLineColor: band),
      ),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  // At 400 px wide, the second line wraps onto exactly two rows.
  final wrapped = 'short\n${'word ' * 7}\nthird\n';

  testWidgets('numbers follow soft-wrapped lines', (tester) async {
    await mount(tester, wrapped);
    final height = editable(tester).preferredLineHeight;
    final tops = painted(tester).numbers.map((n) => n.$2).toList();
    expect(tops.length, greaterThanOrEqualTo(4));
    expect(tops[1] - tops[0], moreOrLessEquals(height, epsilon: 1));
    expect(tops[2] - tops[1], moreOrLessEquals(2 * height, epsilon: 1));
    expect(tops[3] - tops[2], moreOrLessEquals(height, epsilon: 1));
  });

  testWidgets('numbers stay exact beyond the old layout cap', (tester) async {
    // Above 200,000 characters the gutter used to assume one row per line.
    await mount(tester, wrapped + 'filler\n' * 30000);
    final height = editable(tester).preferredLineHeight;
    final tops = painted(tester).numbers.map((n) => n.$2).toList();
    expect(tops[2] - tops[1], moreOrLessEquals(2 * height, epsilon: 1));
  });

  testWidgets('the band covers every row of the caret line', (tester) async {
    final c = await mount(tester, wrapped);
    final height = editable(tester).preferredLineHeight;
    c.text.selection = const TextSelection.collapsed(offset: 8);
    await tester.pump();
    final result = painted(tester);
    expect(result.bands, hasLength(1));
    expect(result.bands.single.top, moreOrLessEquals(result.numbers[1].$2));
    expect(result.bands.single.height, moreOrLessEquals(2 * height));

    c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    expect(painted(tester).bands, isEmpty);
  });

  testWidgets('numbers track scrolling', (tester) async {
    final c = await mount(
      tester,
      List.generate(100, (i) => 'line $i').join('\n'),
    );
    final before = painted(tester).numbers;
    c.scroll.jumpTo(10 * editable(tester).preferredLineHeight);
    await tester.pump();
    final after = painted(tester).numbers;
    // Line 11 now sits where line 1 did, and the same rows are filled.
    expect(after.first.$2, moreOrLessEquals(before.first.$2, epsilon: 1));
    expect(after.length, before.length);
    c.scroll.jumpTo(10.5 * editable(tester).preferredLineHeight);
    await tester.pump();
    final between = painted(tester).numbers.first.$2;
    expect(between, lessThan(before.first.$2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the band covers every row of a wrapped final line', (
    tester,
  ) async {
    // No trailing newline: the band has to end where the text ends.
    final c = await mount(tester, 'short\n${'word ' * 7}');
    final height = editable(tester).preferredLineHeight;
    c.text.selection = TextSelection.collapsed(offset: c.text.text.length);
    await tester.pump();
    final result = painted(tester);
    expect(result.bands, hasLength(1));
    expect(result.bands.single.height, moreOrLessEquals(2 * height));
  });

  testWidgets('numbers follow lines that only just wrap', (tester) async {
    // The text field keeps a caret's width free at the end of every row, so a
    // line that fits the bare width can still wrap. A gutter measured apart
    // from the field lost a row at each such line; this one reads the field.
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<EditorController> mountAt(String text) async {
      final c = EditorController(displayPath: 'notes.txt', initialText: text);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlanchetteEditor(controller: c)),
        ),
      );
      await tester.pump();
      return c;
    }

    await mountAt('x');
    final probe = TextPainter(
      text: TextSpan(text: 'y', style: editable(tester).text!.style),
      textDirection: TextDirection.ltr,
    )..layout();
    final advance = probe.width;
    probe.dispose();
    final width = editable(tester).size.width;
    final glyphs = (width / advance).floor();
    // Resize so that the line's glyphs sit just inside the field's width.
    await tester.binding.setSurfaceSize(
      Size(900 + glyphs * advance + 1.5 - width, 700),
    );
    final c = await mountAt(
      List.generate(40, (i) => i.isEven ? 'y' * glyphs : 'line $i').join('\n'),
    );

    final field = editable(tester);
    double rowOf(int line) => field
        .getLocalRectForCaret(TextPosition(offset: c.lineStarts[line]))
        .top;
    expect(rowOf(1) - rowOf(0), greaterThan(field.preferredLineHeight * 1.5));
    // Only paragraphs painted inside the gutter are numbers. The document's
    // own text is painted afterwards on the field's layer, at its origin.
    final gutter = tester.getSize(
      find.byKey(const ValueKey('editor-line-gutter')),
    );
    final tops = <double>[];
    expect(
      decorations(tester),
      paints..everything((method, arguments) {
        if (method == #drawParagraph) {
          final at = arguments[1] as Offset;
          if (at.dx > 0 && at.dx < gutter.width) tops.add(at.dy);
        }
        return true;
      }),
    );
    expect(tops.length, greaterThan(4));
    for (var line = 1; line < tops.length; line++) {
      expect(
        tops[line] - tops[line - 1],
        moreOrLessEquals(rowOf(line) - rowOf(line - 1), epsilon: 0.5),
        reason: 'line ${line + 1}',
      );
    }
  });
}
