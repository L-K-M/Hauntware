import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart'
    show DragStartBehavior, kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    GhostPaneEdge edge = GhostPaneEdge.leading,
    TextDirection direction = TextDirection.ltr,
    double width = 200,
    VoidCallback? onReset,
    DragStartBehavior dragStartBehavior = DragStartBehavior.start,
    bool compete = false,
  }) async {
    final calls = <String>[];
    Widget handle = GhostResizeHandle(
      label: 'Resize list',
      width: width,
      minimumWidth: 100,
      maximumWidth: 300,
      edge: edge,
      widthAfterStep: (delta) => width + delta,
      onStep: (delta) => calls.add('step $delta'),
      onStart: () => calls.add('start'),
      onDelta: (delta) => calls.add('delta $delta'),
      onEnd: () => calls.add('end'),
      onReset: onReset == null ? null : () => calls.add('reset'),
      dragStartBehavior: dragStartBehavior,
      handleWidth: 10,
      valueText: (w) => '${w.round()} px',
    );
    if (compete) {
      // A tap recognizer keeps the arena open past the touch slop, which is
      // where the two drag-start behaviours diverge.
      handle = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: handle,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: Center(child: SizedBox(height: 100, child: handle)),
        ),
      ),
    );
    return calls;
  }

  testWidgets('drags report start, deltas and end, mirrored in RTL', (
    tester,
  ) async {
    final calls = await pump(tester);
    await tester.drag(find.byType(GhostResizeHandle), const Offset(30, 0));
    expect(calls.first, 'start');
    expect(calls.last, 'end');
    expect(calls.where((c) => c.startsWith('delta ')), isNotEmpty);
    expect(
      calls.where((c) => c.startsWith('delta -')),
      isEmpty,
      reason: 'a rightward drag grows in LTR',
    );

    final rtl = await pump(tester, direction: TextDirection.rtl);
    await tester.drag(find.byType(GhostResizeHandle), const Offset(30, 0));
    expect(rtl.where((c) => c.startsWith('delta -')), isNotEmpty);
  });

  testWidgets('a double tap calls onReset', (tester) async {
    final calls = await pump(tester, onReset: () {});
    await tester.tap(find.byType(GhostResizeHandle));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byType(GhostResizeHandle));
    // Lets the recognizer's double-tap and minimum-interval timers expire.
    await tester.pump(kDoubleTapTimeout);
    expect(calls, ['reset']);
  });

  testWidgets('a tap focuses the handle without committing a drag', (
    tester,
  ) async {
    final calls = await pump(tester, onReset: () {});
    await tester.tap(find.byType(GhostResizeHandle));
    await tester.pump(kDoubleTapTimeout);
    await tester.pump();
    expect(calls, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(calls, ['step 16.0']);
  });

  testWidgets('a tapped handle resizes on the first arrow', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.byType(GhostResizeHandle));
    await tester.pump();
    calls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(calls, ['step 16.0']);
  });

  testWidgets('cancelling a started drag commits it once', (tester) async {
    final calls = await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GhostResizeHandle)),
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(calls.first, 'start');
    expect(calls.last, 'end');
    expect(calls.where((call) => call == 'end'), hasLength(1));
  });

  testWidgets('DragStartBehavior.down reports the whole drag', (tester) async {
    final down = await pump(
      tester,
      compete: true,
      dragStartBehavior: DragStartBehavior.down,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(GhostResizeHandle)),
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pump();
    expect(down, ['start', 'delta 20.0', 'end']);

    // With the default start behaviour the pre-threshold move is dropped
    // and the drag begins where the recognizer wins the arena.
    final start = await pump(tester, compete: true);
    final other = await tester.startGesture(
      tester.getCenter(find.byType(GhostResizeHandle)),
    );
    await other.moveBy(const Offset(20, 0));
    await other.up();
    await tester.pump();
    expect(start, ['start', 'end']);
  });

  testWidgets('arrow keys step by 16 once focused, and modified arrows '
      'are left alone', (tester) async {
    final calls = await pump(tester);
    final focus = Focus.of(
      tester.element(
        find.descendant(
          of: find.byType(GhostResizeHandle),
          matching: find.byType(MouseRegion),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(calls, ['step 16.0', 'step -16.0']);
  });

  testWidgets('assistive technology reads the width and grows the owned '
      'pane, within its bounds', (tester) async {
    final handle = tester.ensureSemantics();
    final trailing = await pump(tester, edge: GhostPaneEdge.trailing);
    final node = tester.getSemantics(find.byType(GhostResizeHandle));
    expect(node.label, 'Resize list');
    expect(node.value, '200 px');
    expect(node.increasedValue, '216 px');

    tester.semantics.increase(find.semantics.byLabel('Resize list'));
    expect(trailing.last, 'step -16.0', reason: 'a trailing pane grows left');

    await pump(tester, width: 300);
    expect(
      tester
          .getSemantics(find.byType(GhostResizeHandle))
          .getSemanticsData()
          .hasAction(SemanticsAction.increase),
      isFalse,
    );
    handle.dispose();
  });
}
