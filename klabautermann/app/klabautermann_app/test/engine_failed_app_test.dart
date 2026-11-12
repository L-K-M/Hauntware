import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/already_running_app.dart';

const _title = 'Klabautermann could not start';

/// A launch whose engine isolate does not start (03 §10.1): the window is
/// already shown by then, so it must say why rather than stay blank.
void main() {
  test('main shows the failure and goes no further when the engine does '
      'not start', () {
    final main = File('lib/main.dart').readAsStringSync();
    final spawn = main.indexOf('IsolateEngineClient.spawn(');
    final restore = main.indexOf('restoreMainWindow(');
    expect(spawn, greaterThan(restore));

    final handler = main.indexOf('} on Object catch (error) {', spawn);
    expect(handler, greaterThan(spawn));
    expect(main.lastIndexOf('try {', spawn), greaterThan(restore));
    final handled = main.substring(handler, main.indexOf('return;', handler));
    expect(handled, contains('runApp('));
    expect(handled, contains('EngineFailedApp('));
    // Nothing after the handler builds over the engine before its return.
    expect(handled, isNot(contains('Controller(')));
  });

  testWidgets('the failure screen names the problem and the detail, and '
      'quits', (tester) async {
    var quits = 0;
    await tester.pumpWidget(
      EngineFailedApp(
        detail: 'Bad state: engine refused Hello',
        onQuit: () => quits++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_title), findsOneWidget);
    expect(
      tester.getSemantics(find.text(_title)).flagsCollection.isHeader,
      isTrue,
    );
    expect(find.textContaining('background engine did not start'), findsOne);
    expect(
      find.text('Details: Bad state: engine refused Hello'),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(quits, 1);
    await tester.tap(find.text('Quit'));
    expect(quits, 2);
  });
}
