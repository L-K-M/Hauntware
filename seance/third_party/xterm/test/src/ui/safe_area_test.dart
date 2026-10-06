import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// [seance fork] The view keeps its content inside the ambient safe-area
// insets on the left and right, as it already did at the top and bottom.
// Upstream mapped pointer positions through the left inset but drew from the
// view's edge and sized the grid across the whole width, so on a phone in
// landscape the text sat under the notch and every tap, selection and link
// landed one inset to the left of the text under the finger.
void main() {
  const insets = EdgeInsets.only(left: 30, right: 22);
  const highlightColor = Color(0xFF00FF00);

  final viewKey = GlobalKey<TerminalViewState>();
  final boundaryKey = GlobalKey();
  final theme = TerminalThemes.defaultTheme;

  testWidgets('content is drawn where pointer positions map', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(padding: insets),
            child: RepaintBoundary(
              key: boundaryKey,
              child: TerminalView(
                terminal,
                key: viewKey,
                controller: controller,
                theme: theme,
                textStyle: const TerminalStyle(fontSize: 20),
              ),
            ),
          ),
        ),
      ),
    );

    // Text in cell 0, the cursor in cell 10, a highlight on cell 20: far
    // enough apart that drawing one inset off cannot land in another's cell.
    terminal.write('M\x1b[1;11H');
    controller.highlight(
      p1: terminal.buffer.createAnchor(20, 0),
      p2: terminal.buffer.createAnchor(21, 0),
      color: highlightColor,
    );
    await tester.pump();

    final render = viewKey.currentState!.renderTerminal;
    final cell = render.cellSize;

    // The premise: the insets reach the view, and pointer mapping uses them.
    expect(render.getOffset(const CellOffset(0, 0)).dx, insets.left);

    expect(
      terminal.viewWidth,
      (render.size.width - insets.horizontal) ~/ cell.width,
      reason: 'the grid fits between the insets',
    );

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

    /// How many pixels of [rect] differ from the background.
    int inkIn(Rect rect) {
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
    }

    final boundary = boundaryKey.currentContext!.findRenderObject()!;
    Rect mapped(int x) =>
        render.localToGlobal(
          render.getOffset(CellOffset(x, 0)),
          ancestor: boundary,
        ) &
        cell;

    expect(terminal.buffer.cursorX, 10);
    expect(inkIn(mapped(0)), greaterThan(0), reason: 'text');
    expect(inkIn(mapped(10)), greaterThan(0), reason: 'cursor');
    expect(inkIn(mapped(20)), greaterThan(0), reason: 'highlight');

    final origin = render.localToGlobal(Offset.zero, ancestor: boundary);
    expect(
      inkIn(origin & Size(insets.left, cell.height)),
      0,
      reason: 'nothing under the left inset',
    );
  });
}
