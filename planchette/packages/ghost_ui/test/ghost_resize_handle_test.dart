import 'dart:ui' show SemanticsAction;

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
  }) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: Center(
            child: SizedBox(
              height: 100,
              child: GhostResizeHandle(
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
                handleWidth: 10,
                valueText: (w) => '${w.round()} px',
              ),
            ),
          ),
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
