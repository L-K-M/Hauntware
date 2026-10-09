import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
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

  Future<RenderTerminal> pumpTerminal(
    WidgetTester tester,
    Terminal terminal, {
    TerminalController? controller,
  }) async {
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
    final render = viewKey.currentState!.renderTerminal;

    // The premise: the insets reach the view, and pointer mapping uses them.
    expect(render.getOffset(const CellOffset(0, 0)).dx, insets.left);
    return render;
  }

  /// Captures the view and returns how many pixels of a rect, in the view's
  /// coordinates, differ from the background.
  Future<int Function(Rect)> capture(WidgetTester tester) async {
    final captured = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData();
      final width = image.width;
      image.dispose();
      return (width, bytes!);
    });
    final (width, bytes) = captured!;
    final render = viewKey.currentState!.renderTerminal;
    final boundary = boundaryKey.currentContext!.findRenderObject()!;

    return (Rect local) {
      final rect = local.shift(
        render.localToGlobal(Offset.zero, ancestor: boundary),
      );
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
    };
  }

  testWidgets('content is drawn where pointer positions map', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final render = await pumpTerminal(tester, terminal, controller: controller);

    // Text in cell 0, the cursor in cell 10, a highlight on cell 20: far
    // enough apart that drawing one inset off cannot land in another's cell.
    terminal.write('M\x1b[1;11H');
    controller.highlight(
      p1: terminal.buffer.createAnchor(20, 0),
      p2: terminal.buffer.createAnchor(21, 0),
      color: highlightColor,
    );
    await tester.pump();

    final cell = render.cellSize;
    expect(
      terminal.viewWidth,
      (render.size.width - insets.horizontal) ~/ cell.width,
      reason: 'the grid fits between the insets',
    );

    final inkIn = await capture(tester);
    Rect mapped(int x) => render.getOffset(CellOffset(x, 0)) & cell;

    expect(terminal.buffer.cursorX, 10);
    expect(inkIn(mapped(0)), greaterThan(0), reason: 'text');
    expect(inkIn(mapped(10)), greaterThan(0), reason: 'cursor');
    expect(inkIn(mapped(20)), greaterThan(0), reason: 'highlight');
    expect(
      inkIn(Offset.zero & Size(insets.left, cell.height)),
      0,
      reason: 'nothing under the left inset',
    );
  });

  testWidgets('composing text wraps within the grid', (tester) async {
    final terminal = Terminal();
    final render = await pumpTerminal(tester, terminal);

    // Composing at column 5, clear of the grid's edge, and two rows' worth
    // long, so it wraps onto lines that start at that edge.
    terminal.write('\x1b[1;6H');
    render.composingText = 'M' * (terminal.viewWidth * 2);
    await tester.pump();

    final inkIn = await capture(tester);
    final lines = render.cellSize.height * 3;
    expect(terminal.buffer.cursorX, 5);
    expect(
      inkIn(Rect.fromLTWH(0, 0, insets.left, lines)),
      0,
      reason: 'wrapped lines start at the grid, not under the left inset',
    );
    expect(
      inkIn(
        Rect.fromLTWH(
          render.size.width - insets.right,
          0,
          insets.right,
          lines,
        ),
      ),
      0,
      reason: 'nothing under the right inset',
    );
  });
}
