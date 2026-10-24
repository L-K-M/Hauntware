import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  final url = Uri.parse('https://example.com');
  // Outlast the fork's 400 ms multi-click window between independent gestures.
  const gestureTimeout = Duration(milliseconds: 600);

  Future<Offset> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
    TerminalController controller,
    List<Uri> opened, {
    String? text,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: TerminalView(
              terminal,
              controller: controller,
              onLinkTap: opened.add,
            ),
          ),
        ),
      ),
    );
    terminal.write(text ?? url.toString());
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    return render.localToGlobal(
      render.getOffset(const CellOffset(5, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2),
    );
  }

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform uses its link modifier, not plain clicks', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);

      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(gestureTimeout);
      expect(opened, isEmpty);

      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump(gestureTimeout);
      expect(opened, [url]);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('touch opens links; double-click, shift-click and drag select', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);

    await tester.tapAt(point);
    await tester.pump(gestureTimeout);
    expect(opened, [url]);
    opened.clear();

    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(gestureTimeout);
    expect(controller.selection, isNotNull);
    expect(opened, isEmpty);
    controller.clearSelection();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(point + const Offset(60, 0),
        kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(gestureTimeout);
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), isNotEmpty);
    controller.clearSelection();

    await tester.dragFrom(
      point,
      const Offset(60, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(gestureTimeout);
    expect(opened, isEmpty);
    expect(controller.selection, isNotNull);
  });

  const mouseReportingModes = {
    'click-only': ('\x1b[?9h', 1),
    'press/release': ('\x1b[?1000h', 2),
  };
  const sgrMouse = '\x1b[?1006h';
  for (final mode in mouseReportingModes.entries) {
    testWidgets('${mode.key} mouse reporting retains click ownership',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);
      terminal.write('${mode.value.$1}$sgrMouse');
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(gestureTimeout);
      expect(opened, isEmpty);
      expect(output, hasLength(mode.value.$2));
      expect(output.every((event) => event.startsWith('\x1b[<')), isTrue);
    });
  }

  // Cmd has no bit in the mouse protocol, so a remote would only see a plain
  // click: on Apple platforms a Cmd-click on a link opens it instead.
  for (final mode in mouseReportingModes.entries) {
    testWidgets('Cmd-click opens links under ${mode.key} mouse reporting',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(
        tester,
        terminal,
        controller,
        opened,
        text: '${url.toString().padRight(30)}plain text',
      );
      terminal.write('${mode.value.$1}$sgrMouse');
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(gestureTimeout);
      expect(opened, [url]);
      expect(output, isEmpty);

      // Off a link, the remote keeps the Cmd-click.
      final cellWidth = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal
          .cellSize
          .width;
      await tester.tapAt(
        point + Offset(cellWidth * 30, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump(gestureTimeout);
      expect(opened, [url]);
      expect(output, hasLength(mode.value.$2));

      // A plain click on the link stays the remote's.
      output.clear();
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(gestureTimeout);
      expect(opened, [url]);
      expect(output, hasLength(mode.value.$2));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  // The press decides: a claimed press reaches the remote neither down nor
  // up, so the release must open the link whatever the modifiers do in
  // between — otherwise the click is lost entirely.
  testWidgets('a claimed press opens its link when Cmd rises before mouse-up',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    terminal.write('\x1b[?1000h$sgrMouse');
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    final press = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    // Past the tap's deadline, so the press is claimed while Cmd is held.
    await tester.pump(kPressTimeout * 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await press.up();
    await tester.pump(gestureTimeout);

    expect(opened, [url]);
    expect(output, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a claimed press opens its link when Shift falls before mouse-up',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    terminal.write('\x1b[?1000h$sgrMouse');
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    final press = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kPressTimeout * 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(gestureTimeout);

    expect(opened, [url]);
    expect(output, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  // The claim is taken at raw pointer-down, so the decision sees the
  // modifiers the press started with even when the tap's own down resolves
  // at mouse-up (a quick click) — and it stands on every platform whose
  // modifier opens links, not just Cmd on Apple. Without a remote to own
  // the press there is nobody else to finish the click, so one of these
  // presses whose modifier drifts before mouse-up must still open its link:
  // anything else loses the click entirely.
  for (final entry in {
    TargetPlatform.macOS: LogicalKeyboardKey.metaLeft,
    TargetPlatform.linux: LogicalKeyboardKey.controlLeft,
    TargetPlatform.windows: LogicalKeyboardKey.controlLeft,
  }.entries) {
    for (final heldMs in [0, 200]) {
      final held = heldMs == 0 ? 'quick' : 'held';

      testWidgets(
          '${entry.key}: a $held press opens its link when its modifier '
          'rises before mouse-up', (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        addTearDown(controller.dispose);
        final opened = <Uri>[];
        final point = await pumpTerminal(tester, terminal, controller, opened);

        await tester.sendKeyDownEvent(entry.value);
        final press = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        if (heldMs > 0) {
          await tester.pump(Duration(milliseconds: heldMs));
        }
        await tester.sendKeyUpEvent(entry.value);
        await press.up();
        await tester.pump(gestureTimeout);

        expect(opened, [url]);
      }, variant: TargetPlatformVariant({entry.key}));

      testWidgets(
          '${entry.key}: a $held press opens its link when Shift falls '
          'before mouse-up', (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        addTearDown(controller.dispose);
        final opened = <Uri>[];
        final point = await pumpTerminal(tester, terminal, controller, opened);

        await tester.sendKeyDownEvent(entry.value);
        final press = await tester.startGesture(
          point,
          kind: PointerDeviceKind.mouse,
        );
        if (heldMs > 0) {
          await tester.pump(Duration(milliseconds: heldMs));
        }
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await press.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(entry.value);
        await tester.pump(gestureTimeout);

        expect(opened, [url]);
      }, variant: TargetPlatformVariant({entry.key}));
    }
  }

  // The link is captured where the press went down: a release shifted
  // within tap slop into another link's cell must not pick that other link.
  testWidgets('a press opens the link under mouse-down, not under mouse-up', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    await pumpTerminal(
      tester,
      terminal,
      controller,
      opened,
      // Two links in adjacent cells, so a slop-sized move crosses over.
      text: '\x1b]8;;https://one.test\x1b\\A\x1b]8;;\x1b\\'
          '\x1b]8;;https://two.test\x1b\\B\x1b]8;;\x1b\\',
    );
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    Offset cellCenter(int x) => render.localToGlobal(
          render.getOffset(CellOffset(x, 0)) +
              Offset(render.cellSize.width / 2, render.cellSize.height / 2),
        );
    final step = render.cellSize.width;
    expect(step, lessThan(kTouchSlop));

    // Touch: its tap slop spans a cell, and a touch tap counts as a link
    // click wherever the remote does not own the tap.
    final press = await tester.startGesture(
      cellCenter(0),
      kind: PointerDeviceKind.touch,
    );
    await press.moveBy(Offset(step, 0));
    await press.up();
    await tester.pump(gestureTimeout);

    expect(opened, [Uri.parse('https://one.test')]);
  });

  // A claim whose press is cancelled (here: dragged past tap slop) opens
  // nothing and must not survive into a later press. Every press re-decides
  // the claim at pointer-down, so the plain click that follows cannot fire
  // the abandoned one.
  testWidgets('a cancelled claim leaves nothing for the next press', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    final press = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kPressTimeout * 2);
    await press.moveBy(const Offset(60, 0));
    await press.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(gestureTimeout);
    expect(opened, isEmpty);

    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(gestureTimeout);
    expect(opened, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Cmd pressed after a reported press leaves the link closed',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    // Click-only reporting consumes the press but passes its release on.
    terminal.write('\x1b[?9h$sgrMouse');
    final output = <String>[];
    terminal.onOutput = output.add;

    final press = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kPressTimeout * 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await press.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(gestureTimeout);

    expect(output, hasLength(1));
    expect(opened, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('holding Cmd shows links the remote would otherwise own',
      (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    terminal.write('\x1b[?1000h');
    await tester.pump();
    bool showsLink() => tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .any((region) => region.cursor == SystemMouseCursors.click);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    await mouse.moveTo(point);
    await tester.pump();
    expect(showsLink(), isFalse);

    // The pointer stays put: the hint follows Cmd alone.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(showsLink(), isTrue);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(showsLink(), isFalse);
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a claimed press dragged away reports nothing', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    terminal.write('\x1b[?1000h$sgrMouse');
    final output = <String>[];
    terminal.onOutput = output.add;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    final press = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    // Past the tap's deadline, so its press is claimed before the drag.
    await tester.pump(kPressTimeout * 2);
    await press.moveBy(const Offset(60, 0));
    await press.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(gestureTimeout);

    expect(output, isEmpty);
    expect(opened, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final update in {
    'mouse reporting': '\x1b[?1000h',
    'rewritten output': '\r\x1b[2Kplain text',
  }.entries) {
    testWidgets('hover clears after ${update.key}', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(point);
      await tester.pump();

      terminal.write(update.value);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widgetList<MouseRegion>(find.byType(MouseRegion))
            .any((region) => region.cursor == SystemMouseCursors.click),
        isFalse,
      );
      // Moving again must not advertise an inactive or erased link either.
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(
        tester
            .widgetList<MouseRegion>(find.byType(MouseRegion))
            .any((region) => region.cursor == SystemMouseCursors.click),
        isFalse,
      );
      await mouse.removePointer();
    });
  }

  testWidgets('OSC 8 link text opens its target, not its text', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final target = Uri.parse('https://example.com/auth?token=abc');
    final point = await pumpTerminal(
      tester,
      terminal,
      controller,
      opened,
      // A URL in the link text, so this pins the precedence and not just the
      // absence of anything else to open.
      text: '\x1b]8;;$target\x1b\\https://decoy.test/looks-fine\x1b]8;;\x1b\\',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(gestureTimeout);
    expect(opened, [target]);
  });

  testWidgets('hover signals links without opening them', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(point);
    await tester.pump();
    expect(
      tester
          .widgetList<MouseRegion>(find.byType(MouseRegion))
          .any((region) => region.cursor == SystemMouseCursors.click),
      isTrue,
    );
    expect(opened, isEmpty);
    await mouse.removePointer();
  });
}
