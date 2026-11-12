// The shared titled group: a heading of its own over its children,
// stretched to the width.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/panel_kit.dart';

void main() {
  testWidgets('heads its children with a heading node', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TitledGroup(
            title: 'Processes',
            children: [Text('first'), Text('second')],
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('Processes')),
      matchesSemantics(label: 'Processes', isHeader: true),
    );
    expect(
      tester.getTopLeft(find.text('first')).dy,
      greaterThan(tester.getBottomLeft(find.text('Processes')).dy),
    );
    expect(
      tester.getSize(find.text('second')).width,
      tester.getSize(find.byType(Scaffold)).width,
    );
    semantics.dispose();
  });
}
