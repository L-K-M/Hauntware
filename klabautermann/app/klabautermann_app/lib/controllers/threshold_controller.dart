import 'package:flutter/foundation.dart';

import '../ui/charts/charts.dart' show ChartThresholds;
import '../ui/threshold_scope.dart';

/// Whether [levels] may stand as a metric's bands (OV-11): each a whole
/// or fractional percent from 1 to 100, careful below warning below
/// critical, so every band holds some values.
bool validThresholds(ChartThresholds levels) => switch (levels.careful) {
  final careful? => _ordered(careful, levels.warning, levels.critical),
  null => false,
};

bool _ordered(double careful, double warning, double critical) {
  bool percent(double value) => value >= 1 && value <= 100;
  return percent(careful) &&
      percent(warning) &&
      percent(critical) &&
      careful < warning &&
      warning < critical;
}

/// The bands [careful], [warning] and [critical] make, or null when
/// [validThresholds] would refuse them; checked before they are built,
/// since [ChartThresholds] asserts its order.
ChartThresholds? thresholdsOf(
  double careful,
  double warning,
  double critical,
) => _ordered(careful, warning, critical)
    ? ChartThresholds(careful: careful, warning: warning, critical: critical)
    : null;

/// What Settings reads and changes of OV-11's bands, apart from where
/// they live: [ThresholdController] in the app, and a copy kept over the
/// settings link in the desktop settings window. The value holds every
/// metric, defaults included.
abstract interface class ThresholdSettings
    implements ValueListenable<MetricThresholds> {
  /// Sets [metric]'s bands to [levels], which [validThresholds] accepts;
  /// a no-op when they are already in force. A change applied but not
  /// saved throws [ThresholdsNotSavedException], in the app and, over the
  /// link, in the window; any other throw means it did not apply.
  Future<void> setThresholds(ThresholdMetric metric, ChartThresholds levels);
}

/// Bands that applied but were not saved: they last until the app
/// restarts unless a later save carries them. [message] is what the
/// failed save printed.
final class ThresholdsNotSavedException implements Exception {
  const ThresholdsNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The stored form of [thresholds]: metric name to careful, warning and
/// critical percent.
Map<String, List<double>> encodeThresholds(MetricThresholds thresholds) => {
  for (final MapEntry(key: metric, value: levels) in thresholds.entries)
    metric.name: [levels.careful!, levels.warning, levels.critical],
};

/// [stored] read back, every metric present: one stored with levels
/// [validThresholds] refuses, or not at all, takes [kDefaultThresholds].
MetricThresholds decodeThresholds(Map<String, List<double>> stored) => {
  for (final metric in ThresholdMetric.values)
    metric: switch (stored[metric.name]) {
      [final careful, final warning, final critical] =>
        thresholdsOf(careful, warning, critical) ?? kDefaultThresholds,
      _ => kDefaultThresholds,
    },
};

/// The app's OV-11 bands: the composition root restores them from
/// `settings.json` and saves every change there; without a save
/// callback, as in most tests, they are held in memory only. A change
/// applies before it is saved, as the appearance does.
final class ThresholdController extends ChangeNotifier
    implements ThresholdSettings {
  ThresholdController({Map<String, List<double>> stored = const {}, this._save})
    : _value = Map.unmodifiable(decodeThresholds(stored));

  MetricThresholds _value;
  final Future<void> Function(Map<String, List<double>> levels)? _save;

  @override
  MetricThresholds get value => _value;

  @override
  Future<void> setThresholds(
    ThresholdMetric metric,
    ChartThresholds levels,
  ) async {
    if (!validThresholds(levels)) {
      throw ArgumentError.value(levels, 'levels', 'not valid bands');
    }
    if (_value[metric] == levels) return;
    _value = Map.unmodifiable({..._value, metric: levels});
    notifyListeners();
    try {
      await _save?.call(encodeThresholds(_value));
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ThresholdsNotSavedException(
          'The threshold levels were not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}
