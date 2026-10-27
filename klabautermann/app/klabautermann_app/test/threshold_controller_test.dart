import 'dart:io' show FileSystemException;

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/threshold_controller.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartThresholds;
import 'package:klabautermann_app/ui/threshold_scope.dart';

/// OV-11: the user's usage bands and where they are kept.
void main() {
  const tight = ChartThresholds(careful: 50, warning: 60, critical: 70);

  test('bands stand only in order and from 1 to 100 %', () {
    expect(validThresholds(kDefaultThresholds), isTrue);
    expect(validThresholds(tight), isTrue);
    for (final bad in [
      const ChartThresholds(warning: 80, critical: 90),
      const ChartThresholds(careful: 80, warning: 80, critical: 90),
      const ChartThresholds(careful: 70, warning: 90, critical: 90),
      const ChartThresholds(careful: 0, warning: 80, critical: 90),
      const ChartThresholds(careful: 70, warning: 80, critical: 101),
    ]) {
      expect(validThresholds(bad), isFalse, reason: '$bad');
    }
  });

  test('stored bands read back per metric; a missing or invalid one takes '
      'the default', () {
    final read = decodeThresholds({
      'cpu': [50, 60, 70],
      'memory': [90, 80, 70],
    });
    expect(read, {
      ThresholdMetric.cpu: tight,
      ThresholdMetric.memory: kDefaultThresholds,
      ThresholdMetric.disk: kDefaultThresholds,
    });
    expect(decodeThresholds(encodeThresholds(read)), read);
  });

  test('a change notifies and saves every metric; the same bands are a '
      'no-op, and invalid ones never apply', () async {
    final saved = <Map<String, List<double>>>[];
    final thresholds = ThresholdController(
      save: (levels) async => saved.add(levels),
    );
    addTearDown(thresholds.dispose);
    var notified = 0;
    thresholds.addListener(() => notified++);

    await thresholds.setThresholds(ThresholdMetric.disk, tight);
    await thresholds.setThresholds(ThresholdMetric.disk, tight);
    await expectLater(
      thresholds.setThresholds(
        ThresholdMetric.cpu,
        const ChartThresholds(careful: 80, warning: 80, critical: 95),
      ),
      throwsArgumentError,
    );

    expect(thresholds.value[ThresholdMetric.disk], tight);
    expect(thresholds.value[ThresholdMetric.cpu], kDefaultThresholds);
    expect(notified, 1);
    expect(saved, [
      {
        'cpu': [70, 80, 90],
        'memory': [70, 80, 90],
        'disk': [50, 60, 70],
      },
    ]);
  });

  test('bands that cannot be saved still apply and say so', () async {
    final thresholds = ThresholdController(
      save: (_) async => throw const FileSystemException('disk full'),
    );
    addTearDown(thresholds.dispose);

    await expectLater(
      thresholds.setThresholds(ThresholdMetric.memory, tight),
      throwsA(isA<ThresholdsNotSavedException>()),
    );
    expect(thresholds.value[ThresholdMetric.memory], tight);
  });
}
