import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// [seance fork] The underline and bar cursors are drawn on the cursor's row.
// Upstream dropped the row's offset and drew them at the top of the view,
// wherever the cursor was.
void main() {
  final viewKey = GlobalKey<TerminalViewState>();
  final boundaryKey = GlobalKey();
  final theme = TerminalThemes.defaultTheme;

  // The cursor three rows down, after two letters. Its cell, and the cell
  // in the first row above it, are otherwise blank.
  const cursorCell = CellOffset(2, 3);
  const topCell = CellOffset(2, 0);

  Future<void> pumpTerminal(
    WidgetTester tester,
    TerminalCursorType cursorType,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final terminal = Terminal();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: TerminalView(
            terminal,
            key: viewKey,
            focusNode: focusNode,
            cursorType: cursorType,
            theme: theme,
            textStyle: const TerminalStyle(fontSize: 20),
          ),
        ),
      ),
    );
    terminal.write('\r\n\r\n\r\nab');
    focusNode.requestFocus();
    await tester.pump();

    // The premise. Unfocused, every type is drawn as an outlined box in the
    // cursor cell, which would pass without testing the underline or bar.
    expect(focusNode.hasFocus, isTrue);
    expect(terminal.buffer.cursorX, cursorCell.x);
    expect(terminal.buffer.cursorY, cursorCell.y);
  }

  /// How many pixels of each cell differ from the background.
  Future<List<int>> inkIn(WidgetTester tester, List<CellOffset> cells) async {
    final capture = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData();
      final width = image.width;
      image.dispose();
      return (width, bytes!);
    });
    final (width, bytes) = capture!;

    final render = viewKey.currentState!.renderTerminal;
    final boundary = boundaryKey.currentContext!.findRenderObject()!;
    return [
      for (final cell in cells)
        () {
          final origin = render.localToGlobal(
            render.getOffset(cell),
            ancestor: boundary,
          );
          final rect = origin & render.cellSize;
          var ink = 0;
          for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
            for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
              final i = (y * width + x) * 4;
              final pixel = Color.fromARGB(
                bytes.getUint8(i + 3),
                bytes.getUint8(i),
                bytes.getUint8(i + 1),
                bytes.getUint8(i + 2),
              );
              if (pixel != theme.background) ink++;
            }
          }
          return ink;
        }(),
    ];
  }

  for (final cursorType in [
    TerminalCursorType.underline,
    TerminalCursorType.verticalBar,
  ]) {
    testWidgets('a focused ${cursorType.name} cursor is on its row',
        (tester) async {
      await pumpTerminal(tester, cursorType);

      final [atCursor, atTop] = await inkIn(tester, [cursorCell, topCell]);
      expect(atCursor, greaterThan(0), reason: 'drawn in the cursor cell');
      expect(atTop, 0, reason: 'nothing in the first row above it');
    });
  }
}
