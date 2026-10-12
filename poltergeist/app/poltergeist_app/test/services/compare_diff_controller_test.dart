import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/compare_diff_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late _FakeStarter starter;
  late CompareDiffController controller;
  var notifications = 0;

  setUp(() {
    starter = _FakeStarter();
    controller = CompareDiffController(start: starter.start)
      ..addListener(() => notifications++);
    notifications = 0;
  });

  tearDown(() => controller.dispose());

  test('starts once for the same document pair however often it is asked', () {
    final left = _document('a\n');
    final right = _document('b\n');

    controller
      ..compare(left, right)
      ..compare(left, right)
      ..compare(left, right);

    expect(starter.inputs, [('a\n', 'b\n')]);
    expect(notifications, 1);
    expect(controller.phase, CompareDiffPhase.computing);
    expect(controller.left, same(left));
    expect(controller.right, same(right));
  });

  test('waits while either document is missing', () {
    controller
      ..compare(_document('a'), null)
      ..compare(null, _document('b'))
      ..compare(null, null);

    expect(controller.phase, CompareDiffPhase.waiting);
    expect(starter.inputs, isEmpty);
    expect(controller.outcome, isNull);
  });

  test('a new pair cancels the old task and ignores its late result', () async {
    controller.compare(_document('a\n'), _document('b\n'));
    controller.compare(_document('c\n'), _document('c\n'));

    expect(starter.cancels, [true, false]);
    starter.completers.first.complete(compareTexts('a\n', 'b\n'));
    await pumpEventQueue();
    expect(controller.phase, CompareDiffPhase.computing);

    starter.completers.last.complete(compareTexts('c\n', 'c\n'));
    await pumpEventQueue();
    expect(controller.phase, CompareDiffPhase.ready);
    expect(controller.result!.diff.regions, isEmpty);
  });

  test('maps computed, over-cap and failed outcomes to phases', () async {
    final outcomes = <TextComparison, CompareDiffPhase>{
      compareTexts('a', 'b'): CompareDiffPhase.ready,
      const TextComparisonOverLineCap(
        leftLines: 5,
        rightLines: 1,
        maximumLines: 3,
      ): CompareDiffPhase.overLineCap,
      const TextComparisonFailed(): CompareDiffPhase.failed,
    };
    for (final MapEntry(key: outcome, value: phase) in outcomes.entries) {
      controller.compare(_document('x'), _document('y'));
      starter.completers.last.complete(outcome);
      await pumpEventQueue();

      expect(controller.phase, phase);
      expect(controller.outcome, same(outcome));
      expect(
        controller.result,
        phase == CompareDiffPhase.ready ? same(outcome) : isNull,
      );
    }
  });

  test('notifies when computing starts and when the outcome lands', () async {
    controller.compare(_document('a'), _document('b'));
    expect(notifications, 1);

    starter.completers.single.complete(compareTexts('a', 'b'));
    await pumpEventQueue();
    expect(notifications, 2);
  });

  test(
    'dispose cancels the task and a later completion stays silent',
    () async {
      final disposed = CompareDiffController(start: starter.start);
      var heard = 0;
      disposed
        ..addListener(() => heard++)
        ..compare(_document('a'), _document('b'));
      heard = 0;

      disposed.dispose();
      starter.completers.single.complete(compareTexts('a', 'b'));
      await pumpEventQueue();

      expect(starter.cancels, [true]);
      expect(heard, 0);
    },
  );
}

/// A new document each call: identity, not text, keys a comparison.
BuiltInTextDocument _document(String text) => BuiltInTextDocument(
  file: File('unused'),
  text: text,
  hasUtf8Bom: false,
  lineEnding: LineEnding.lf,
  sha256: text,
);

final class _FakeStarter {
  final inputs = <(String, String)>[];
  final completers = <Completer<TextComparison>>[];
  final cancels = <bool>[];

  TextComparisonTask start(String left, String right) {
    inputs.add((left, right));
    final completer = Completer<TextComparison>();
    completers.add(completer);
    final index = cancels.length;
    cancels.add(false);
    return TextComparisonTask(
      completer.future,
      onCancel: () => cancels[index] = true,
    );
  }
}
