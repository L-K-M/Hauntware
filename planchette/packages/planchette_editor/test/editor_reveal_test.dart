import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// Reveal tests: a search match scrolls into view on the row the document's
/// own layout puts it, however the lines above it wrap. Ported from #28.
Widget app(EditorController c) => MaterialApp(
  home: Scaffold(body: PlanchetteEditor(controller: c)),
);

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

void main() {
  testWidgets('a reveal lands on the measured row of its match', (
    tester,
  ) async {
    // 200 short lines, none of which folds. Flutter's TextField cannot turn
    // soft wrap off, so the gutter measures the rows; the point of the test is
    // that the reveal reads those measurements rather than re-deriving them.
    const lineHeight = 14 * 1.35;
    final text = List.generate(200, (i) => 'line $i').join('\n');
    final c = EditorController(displayPath: 'a.txt', initialText: text);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    c.openSearch();
    c.search.text = 'line 100';
    await tester.pumpAndSettle();

    expect(c.activeMatch, greaterThanOrEqualTo(0));
    // A third of the way down puts the match in the upper third of the window,
    // with the top inset and one third of the real viewport subtracted. The row
    // height comes from the font's own line metrics rather than
    // fontSize x height, so the rows drift a little over a hundred lines and
    // one row of slack is allowed; a gutter that mis-places lines by folding
    // or by estimating drifts far further than that.
    final viewport = c.scroll.position.viewportDimension;
    expect(
      c.scroll.offset,
      closeTo(100 * lineHeight + 14 - viewport / 3, lineHeight),
    );
  });

  testWidgets('a folded long line still numbers every line it covers', (
    tester,
  ) async {
    final long = List.filled(300, 'word ').join();
    final c = EditorController(
      displayPath: 'a.txt',
      initialText: '$long\nsecond\nthird',
    );
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('editor-line-gutter')), findsOneWidget);

    // A reveal has to fall back to a measured position once the rows and the
    // logical lines disagree, and must not throw while doing it.
    c.openSearch();
    c.search.text = 'third';
    await tester.pump();
    // Prove the search matched first, or "the reveal did nothing" and "the
    // reveal scrolled to the wrong row" look the same.
    expect(c.matches, hasLength(1));
    c.nextMatch();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The first line folds into dozens of rows at this width, so 'third' on
    // logical line 3 has a row far below the viewport. A reveal that used the
    // line's top rather than the match's row, or clamped to line 0, would
    // leave the offset at 0.
    expect(c.scroll.offset, greaterThan(0));
  });

  testWidgets('a reveal finds the last line of a folded large file', (
    tester,
  ) async {
    // Past the highlighting cap with a first line long enough to fold, and a
    // match on the last line of a file with no trailing newline. This is the
    // shape that used to underflow the fallback's line index, and it pins the
    // reachable path so a refactor cannot quietly break it.
    final long = List.filled(9000, 'word ').join();
    final text =
        '$long\n'
        '${'filler ' * 6000}\n'
        'the needle is here';
    expect(text.endsWith('\n'), isFalse);

    final c = EditorController(displayPath: 'a.txt', initialText: text);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    c.openSearch();
    c.search.text = 'needle';
    await tester.pump();
    expect(c.matches, hasLength(1));
    await tester.pumpAndSettle();

    // The last line is far down the document, so a correct reveal leaves the
    // viewport well past the top. An underflowed line index would clamp to 0.
    expect(tester.takeException(), isNull);
    expect(c.scroll.offset, greaterThan(100));
  });

  testWidgets('a reveal past the highlighting cap lands on its row', (
    tester,
  ) async {
    // Above the cap the old gutter assumed one row per logical line, so a
    // match below many wrapped lines was scrolled to far above its row.
    final filler = List.generate(
      4000,
      (i) => i.isEven ? 'word ' * 20 : 'line $i',
    ).join('\n');
    final text = '$filler\nthe needle line';
    expect(text.length, greaterThan(syntaxHighlightingMaxChars));
    final c = EditorController(displayPath: 'a.txt', initialText: text);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.reset());
    await tester.pumpWidget(app(c));
    await tester.pump();

    c.openSearch();
    c.search.text = 'needle';
    await tester.pumpAndSettle();

    final field = editable(tester);
    final row = field.getLocalRectForCaret(
      TextPosition(offset: c.matches[c.activeMatch].start),
    );
    expect(row.top, greaterThanOrEqualTo(0));
    expect(row.bottom, lessThanOrEqualTo(field.size.height));
  });
}
