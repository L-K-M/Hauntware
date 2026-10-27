import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import 'charts/charts.dart' show ChartThresholds;

/// The metrics OV-11's threshold bands judge: the fleet rows' pressure
/// cells and the Overview's matching cards, with the disk level counting
/// for both a mount's space and its inodes.
enum ThresholdMetric { cpu, memory, disk }

/// The bands every metric starts with (OV-11): careful from 70 %, warning
/// from 80 % and critical from 90 %, the warning and critical levels the
/// fleet rows used before user thresholds.
const ChartThresholds kDefaultThresholds = ChartThresholds(
  careful: 70,
  warning: 80,
  critical: 90,
);

/// Each metric's bands; a metric left out takes [kDefaultThresholds].
typedef MetricThresholds = Map<ThresholdMetric, ChartThresholds>;

/// Hands the user's threshold bands (OV-11) to the fleet rows, the
/// Overview and the threshold announcer. Without one, as in most tests,
/// every metric takes [kDefaultThresholds].
class ThresholdScope
    extends InheritedNotifier<ValueListenable<MetricThresholds>> {
  const ThresholdScope({
    super.key,
    required ValueListenable<MetricThresholds> thresholds,
    required super.child,
  }) : super(notifier: thresholds);

  /// [metric]'s bands for [context], which rebuilds when they change.
  static ChartThresholds of(BuildContext context, ThresholdMetric metric) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThresholdScope>();
    return scope?.notifier?.value[metric] ?? kDefaultThresholds;
  }
}
