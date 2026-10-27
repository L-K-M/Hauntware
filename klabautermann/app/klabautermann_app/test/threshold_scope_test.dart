import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartThresholds;
import 'package:klabautermann_app/ui/threshold_scope.dart';

/// OV-11: the bands each metric's bars and alarms read.
void main() {
  testWidgets('without a scope every metric takes the default bands, and a '
      'scope hands out its own and rebuilds on a change', (tester) async {
    final seen = <ThresholdMetric, ChartThresholds>{};
    Widget reader() => Builder(
      builder: (context) {
        for (final metric in ThresholdMetric.values) {
          seen[metric] = ThresholdScope.of(context, metric);
        }
        return const SizedBox();
      },
    );

    await tester.pumpWidget(reader());
    expect(seen.values, everyElement(kDefaultThresholds));

    const tight = ChartThresholds(careful: 50, warning: 60, critical: 70);
    final thresholds = ValueNotifier<MetricThresholds>(const {
      ThresholdMetric.disk: tight,
    });
    addTearDown(thresholds.dispose);
    await tester.pumpWidget(
      ThresholdScope(thresholds: thresholds, child: reader()),
    );
    expect(seen[ThresholdMetric.disk], tight);
    expect(seen[ThresholdMetric.cpu], kDefaultThresholds);

    thresholds.value = const {ThresholdMetric.cpu: tight};
    await tester.pump();
    expect(seen[ThresholdMetric.cpu], tight);
    expect(seen[ThresholdMetric.disk], kDefaultThresholds);
  });
}
