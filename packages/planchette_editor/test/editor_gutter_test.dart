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
}
