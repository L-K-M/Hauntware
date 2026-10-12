import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  group('startTextComparison', () {
    test('the worker returns what compareTexts computes', () async {
      const left = 'alpha\nbeta\ngamma\n';
      const right = 'alpha\ndelta\ngamma\nepsilon\n';

      final outcome = await startTextComparison(left, right).result;

      expect(outcome, isA<TextComparisonComputed>());
      outcome as TextComparisonComputed;
      final expected = compareTexts(left, right) as TextComparisonComputed;
      expect(outcome.diff.regions, expected.diff.regions);
      expect(outcome.diff.minimal, isTrue);
      expect(outcome.left.lineCount, 4);
      expect(outcome.right.columnsOf(3), 7);
    });

    test('an over-cap input comes back over the line cap', () async {
      final over = List.filled(compareMaximumLines + 1, 'x').join('\n');

      final outcome = await startTextComparison(over, 'a').result;

      expect(outcome, isA<TextComparisonOverLineCap>());
      expect((outcome as TextComparisonOverLineCap).leftLines, 20001);
    });

    test('cancel leaves the result pending and is idempotent', () async {
      final left = [for (var i = 0; i < 20000; i++) 'l${i % 13}'].join('\n');
      final right = [for (var i = 0; i < 20000; i++) 'l${i % 17}'].join('\n');
      final task = startTextComparison(left, right);

      task
        ..cancel()
        ..cancel();
      final settled = await Future.any([
        task.result.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 500), () => false),
      ]);

      expect(settled, isFalse);
    });

    test('a completed task resolves immediately and ignores cancel', () async {
      final task = TextComparisonTask.completed(const TextComparisonFailed())
        ..cancel();

      expect(await task.result, isA<TextComparisonFailed>());
    });

    test('cancel runs its callback once', () {
      var cancels = 0;
      final task = TextComparisonTask(
        Completer<TextComparison>().future,
        onCancel: () => cancels++,
      );

      task
        ..cancel()
        ..cancel();

      expect(cancels, 1);
    });
  }, timeout: const Timeout(Duration(seconds: 30)));
}
