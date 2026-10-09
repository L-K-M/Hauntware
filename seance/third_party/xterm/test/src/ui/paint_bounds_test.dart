import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// [seance fork] Rows are painted wherever the scroll offset puts them, and a
// view that is not a whole number of rows tall leaves one partly outside it:
// the top row when pinned to the bottom, the last one when scrolled up.
// Upstream painted that row over the widgets beside the view (in Séance, the
// tab strip above and the status bar below).
void main() {
  // Outside the theme's palette, so any terminal pixel in a guard shows.
  const guardColor = Color(0xFFFF00FF);
  const guardHeight = 40.0;

  // 20 px text makes 24 px rows; 8.5 rows leaves half of one outside.
  const textStyle = TerminalStyle(fontSize: 20);
  const viewHeight = 24.0 * 8 + 12;

  final viewKey = GlobalKey<TerminalViewState>();
  final boundaryKey = GlobalKey();

  Future<ScrollController> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          // The guards paint first, so the view cannot hide anything under
          // them: in a Column the guard below would paint over the view.
          child: Stack(
            children: [
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: guardHeight,
                child: ColoredBox(color: guardColor),
              ),
              const Positioned(
                top: guardHeight + viewHeight,
                left: 0,
                right: 0,
                height: guardHeight,
                child: ColoredBox(color: guardColor),
              ),
              Positioned(
                top: guardHeight,
                left: 0,
                right: 0,
                height: viewHeight,
                child: TerminalView(
                  terminal,
                  key: viewKey,
                  scrollController: scroll,
                  textStyle: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Scrollback, so the view can sit between rows.
    for (var i = 0; i < 40; i++) {
      terminal.write('MMMMMMMMMMMMMMMMMMMM $i\r\n');
    }
    await tester.pump();

    // The premise: there is scrollback to sit in, and the view really does
    // end partway through a row.
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    final render = viewKey.currentState!.renderTerminal;
    final remainder = render.size.height % render.lineHeight;
    expect(remainder, inExclusiveRange(0, render.lineHeight));
    return scroll;
  }

  /// The pixels outside the view, top guard then bottom guard, that are not
  /// the guard's colour.
  Future<({int above, int below})> strayPixels(WidgetTester tester) async {
    final capture = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData();
      final width = image.width;
      image.dispose();
      return (width, bytes!);
    });
    final (width, ByteData bytes) = capture!;

    int countStray(double top) {
      var stray = 0;
      for (var y = top.toInt(); y < top + guardHeight; y++) {
        for (var x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          final pixel = Color.fromARGB(
            bytes.getUint8(i + 3),
            bytes.getUint8(i),
            bytes.getUint8(i + 1),
            bytes.getUint8(i + 2),
          );
          if (pixel != guardColor) stray++;
        }
      }
      return stray;
    }

    return (
      above: countStray(0),
      below: countStray(guardHeight + viewHeight),
    );
  }

  testWidgets('pinned to the bottom, the top row stays inside', (tester) async {
    await pumpTerminal(tester, Terminal());

    final stray = await strayPixels(tester);
    expect(stray.above, 0, reason: 'the partial top row painted above');
    expect(stray.below, 0);
  });

  testWidgets('scrolled up, the last row stays inside', (tester) async {
    final scroll = await pumpTerminal(tester, Terminal());
    scroll.jumpTo(0);
    await tester.pump();

    final stray = await strayPixels(tester);
    expect(stray.above, 0);
    expect(stray.below, 0, reason: 'the partial last row painted below');
  });
}
