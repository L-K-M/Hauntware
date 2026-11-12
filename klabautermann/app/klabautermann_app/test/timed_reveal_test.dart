// SAF-07's temporary reveal, shared by every view that shows masked
// values: a reveal masks itself after kRevealDuration, on a second
// toggle, when the app turns inactive and when the view goes.
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/timed_reveal.dart';

void main() {
  late TimedReveals<String> reveals;
  late int changes;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    changes = 0;
    reveals = TimedReveals(onChanged: () => changes++);
  });

  tearDown(() => reveals.dispose());

  testWidgets('a reveal masks itself after kRevealDuration', (tester) async {
    reveals.toggle('a');
    expect(reveals.isRevealed('a'), isTrue);
    expect(changes, 1);

    await tester.pump(kRevealDuration - const Duration(seconds: 1));
    expect(reveals.isRevealed('a'), isTrue);

    await tester.pump(const Duration(seconds: 1));
    expect(reveals.isRevealed('a'), isFalse);
    expect(changes, 2);
  });

  testWidgets('a second toggle masks, and each key keeps its own timer', (
    tester,
  ) async {
    reveals.toggle('a');
    await tester.pump(const Duration(seconds: 10));
    reveals.toggle('b');
    reveals.toggle('a');
    expect(reveals.isRevealed('a'), isFalse);
    expect(reveals.isRevealed('b'), isTrue);
    expect(changes, 3);

    // The cancelled timer of 'a' never fires.
    await tester.pump(kRevealDuration - const Duration(seconds: 1));
    expect(changes, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(reveals.isEmpty, isTrue);
    expect(changes, 4);
  });

  testWidgets('the app turning inactive masks everything', (tester) async {
    reveals
      ..toggle('a')
      ..toggle('b');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(reveals.isEmpty, isTrue);
    expect(changes, 3);

    // Nothing revealed: masking again does not redraw.
    reveals.maskAll();
    expect(changes, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('discard masks quietly, all or the keys picked', (tester) async {
    reveals
      ..toggle('arg')
      ..toggle('env');
    reveals.discard(where: (key) => key == 'env');
    expect(reveals.isRevealed('arg'), isTrue);
    expect(reveals.isRevealed('env'), isFalse);
    reveals.discard();
    expect(reveals.isEmpty, isTrue);
    expect(changes, 2);

    await tester.pump(kRevealDuration);
    expect(changes, 2);
  });

  testWidgets('dispose stops the timers', (tester) async {
    final other = TimedReveals<int>(onChanged: () => changes++);
    other.toggle(1);
    other.dispose();
    await tester.pump(kRevealDuration);
    expect(changes, 1);
  });
}
