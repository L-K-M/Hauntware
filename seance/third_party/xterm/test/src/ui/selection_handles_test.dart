import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  final viewKey = GlobalKey<TerminalViewState>();
  final handles = find.byType(CompositedTransformFollower);

  Future<void> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
    TerminalController controller, {
    ScrollController? scroll,
    FocusNode? focus,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(60),
          child: TerminalView(
            terminal,
            key: viewKey,
            controller: controller,
            scrollController: scroll,
            focusNode: focus,
            autofocus: true,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Offset cell(int column, int row) {
    final render = viewKey.currentState!.renderTerminal;
    return render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          Offset(render.cellSize.width / 2, render.lineHeight / 2),
    );
  }

  Finder handleGesture(int index) => find
      .descendant(
        of: handles.at(index),
        matching: find.byType(RawGestureDetector),
      )
      .first;

  Future<void> dragHandle(
    WidgetTester tester,
    int index,
    Offset delta,
  ) async {
    await tester.drag(handleGesture(index), delta);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Android touch selection shows draggable start and end handles',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo charlie\r\ndelta echo foxtrot');
    await tester.pump();

    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));

    expect(terminal.buffer.getText(controller.selection), 'bravo');
    expect(handles, findsNWidgets(2));
    for (final element in handles.evaluate()) {
      final render = element.findRenderObject()! as RenderFollowerLayer;
      expect(render.link.leader, isNotNull,
          reason: 'the handle must be painted');
    }

    final render = viewKey.currentState!.renderTerminal;
    await dragHandle(tester, 0, Offset(-6 * render.cellSize.width, 0));
    expect(terminal.buffer.getText(controller.selection), 'alpha bravo');

    await dragHandle(
      tester,
      1,
      Offset(-render.cellSize.width, render.lineHeight),
    );
    expect(
      terminal.buffer.getText(controller.selection),
      'alpha bravo charlie\ndelta echo',
    );
  });

  testWidgets('touch double-tap shows handles; clearing selection removes them',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo charlie');
    await tester.pump();

    await tester.tapAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(handles, findsNWidgets(2));

    controller.clearSelection();
    await tester.pump();
    expect(handles, findsNothing);
  });

  testWidgets('iOS touch selection uses draggable platform handles',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller,
        platform: TargetPlatform.iOS);
    terminal.write('alpha bravo charlie');
    await tester.pump();

    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(handles, findsNWidgets(2));

    final render = viewKey.currentState!.renderTerminal;
    await dragHandle(tester, 0, Offset(-6 * render.cellSize.width, 0));
    expect(terminal.buffer.getText(controller.selection), 'alpha bravo');
  });

  testWidgets(
      'handles follow scrolling and unlink when endpoints leave the view',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    final scroll = ScrollController();
    addTearDown(controller.dispose);
    addTearDown(scroll.dispose);
    await pumpTerminal(tester, terminal, controller, scroll: scroll);
    for (var row = 0; row < 100; row++) {
      terminal.write('line $row alpha bravo\r\n');
    }
    await tester.pump();
    final render = viewKey.currentState!.renderTerminal;
    scroll.jumpTo(40 * render.lineHeight);
    await tester.pump();

    await tester.longPressAt(cell(10, 45));
    await tester.pump(const Duration(milliseconds: 300));
    expect(handles, findsNWidgets(2));
    final before = tester.getCenter(handleGesture(0));

    scroll.jumpTo(scroll.offset + render.lineHeight);
    await tester.pump();
    expect(tester.getCenter(handleGesture(0)).dy,
        closeTo(before.dy - render.lineHeight, 0.01));

    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    for (final element in handles.evaluate()) {
      final follower = element.findRenderObject()! as RenderFollowerLayer;
      expect(follower.link.leader, isNull,
          reason: 'offscreen handles must not float over other widgets');
    }
  });

  testWidgets('focus loss and unmount remove touch handles', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await pumpTerminal(tester, terminal, controller, focus: focus);
    terminal.write('alpha bravo');
    await tester.pump();

    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(handles, findsNWidgets(2));

    focus.unfocus();
    await tester.pump();
    expect(handles, findsNothing);
    expect(controller.selection, isNotNull);

    await tester.longPressAt(cell(2, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(handles, findsNWidgets(2));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(handles, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the end handle can include the last column', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    final text = 'alpha ' + 'x' * (terminal.viewWidth - 6);
    terminal.write(text);
    await tester.pump();

    await tester.longPressAt(cell(2, 0));
    await tester.pump(const Duration(milliseconds: 300));
    final render = viewKey.currentState!.renderTerminal;
    await dragHandle(
      tester,
      1,
      Offset((terminal.viewWidth - 5) * render.cellSize.width, 0),
    );

    expect(controller.selection!.end.x, terminal.viewWidth);
    expect(terminal.buffer.getText(controller.selection), text);
  });

  testWidgets('a buffer switch during a handle drag removes stale handles',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo charlie');
    await tester.pump();
    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));

    final gesture =
        await tester.startGesture(tester.getCenter(handleGesture(1)));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    terminal.write('\x1b[?1049h');
    await tester.pump();
    expect(handles, findsNothing);

    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('mouse selection does not show touch handles', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo');
    await tester.pump();

    await tester.dragFrom(cell(0, 0), cell(8, 0) - cell(0, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.selection, isNotNull);
    expect(handles, findsNothing);
  });

  testWidgets('a second handle cannot steal an active drag', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo charlie');
    await tester.pump();
    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));

    final width = viewKey.currentState!.renderTerminal.cellSize.width;
    final first = await tester.startGesture(tester.getCenter(handleGesture(0)));
    await first.moveBy(Offset(-3 * width, 0));
    await tester.pump();
    final beforeSecond = controller.selection;

    final second =
        await tester.startGesture(tester.getCenter(handleGesture(1)));
    await second.moveBy(Offset(3 * width, 0));
    await tester.pump();
    final afterSecond = controller.selection;
    await second.up();
    await first.moveBy(Offset(-width, 0));
    await first.up();
    await tester.pump();

    expect(afterSecond, beforeSecond);
    expect(controller.selection!.begin.x, 2);
    expect(controller.selection!.end.x, 11);
  });

  testWidgets('small pen movements accumulate throughout a handle drag',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    await pumpTerminal(tester, terminal, controller);
    terminal.write('alpha bravo charlie');
    await tester.pump();
    await tester.longPressAt(cell(8, 0));
    await tester.pump(const Duration(milliseconds: 300));

    final width = viewKey.currentState!.renderTerminal.cellSize.width;
    final gesture = await tester.startGesture(
      tester.getCenter(handleGesture(1)),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    final before = controller.selection!.end.x;
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(Offset(width / 4, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(controller.selection!.end.x, before + 2);
  });
}
