// The shared state notice: words beside an icon read as one node, with
// the host's or engine's detail under them unless it is empty, and the
// Docker tab's notice adding an action under that.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/docker/containers_panel.dart'
    show DockerNotice;
import 'package:klabautermann_app/ui/state_notice.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget notice) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Column(children: [notice])),
    ),
  );

  testWidgets('reads the text and the detail as one node', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      const StateNotice(
        icon: Icons.error_outline,
        text: 'The read failed.',
        detail: 'permission denied',
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOne);
    expect(
      tester.getSemantics(find.byType(StateNotice)),
      matchesSemantics(label: 'The read failed.\npermission denied'),
    );
    semantics.dispose();
  });

  testWidgets('leaves out a missing or empty detail', (tester) async {
    await pump(
      tester,
      const StateNotice(icon: Icons.info_outline, text: 'Nothing here.'),
    );
    expect(find.byType(Text), findsOne);

    await pump(
      tester,
      const StateNotice(
        icon: Icons.info_outline,
        text: 'Nothing here.',
        detail: '',
      ),
    );
    expect(find.byType(Text), findsOne);
  });

  testWidgets('the Docker notice puts its action under the words', (
    tester,
  ) async {
    var retried = 0;
    await pump(
      tester,
      DockerNotice(
        icon: Icons.error_outline,
        text: 'The daemon did not answer.',
        detail: 'timeout',
        action: TextButton(
          onPressed: () => retried++,
          child: const Text('Retry'),
        ),
      ),
    );

    expect(find.byType(StateNotice), findsOne);
    expect(find.text('timeout'), findsOne);
    expect(
      tester.getTopLeft(find.text('Retry')).dy,
      greaterThan(tester.getBottomLeft(find.text('timeout')).dy),
    );
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });
}
