import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/content_size_reporter.dart';

void main() {
  testWidgets('reports bounded content size after the frame', (tester) async {
    final sizes = <Size>[];
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SizedBox(
        width: 700,
        height: 500,
        child: ContentSizeReporter(
          onSize: sizes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(sizes, [const Size(700, 500)]);
  });
}
