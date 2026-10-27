import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinaryRate, ghostFormatBinarySize;

/// What a series measures. Byte figures are always IEC binary units
/// (A11Y-06): server tools report in KiB and MiB, so the charts never use
/// the decimal file sizes of `ghostFormatFileSize`.
enum ChartUnit {
  /// A share from 0 to 100.
  percent,
  bytes,
  bytesPerSecond,

  /// A whole number of things, as a container's PIDs.
  count,
}

/// The words charts say, from the host's catalogue (03 D10: the charts
/// take string bags so they can move to a shared package unchanged).
@immutable
final class ChartStrings {
  const ChartStrings({
    required this.seriesSummary,
    required this.seriesEmpty,
    required this.seriesUnknown,
    required this.unknownValue,
    required this.gapAppClosed,
    required this.gapBackground,
    required this.gapDisconnected,
    required this.gapReadingFailed,
    required this.gapSummary,
    required this.gapOngoing,
    required this.time,
    required this.timeWithSeconds,
    required this.trendRising,
    required this.trendFalling,
    required this.trendSteady,
    required this.percent,
    required this.barSummary,
    required this.barPart,
    required this.listSeparator,
    required this.withSeverity,
    required this.severityCareful,
    required this.severityWarning,
    required this.severityCritical,
    required this.stale,
  });

  /// A series' screen-reader summary (A11Y-02): its label, the formatted
  /// current, lowest and highest values, and the trend word.
  final String Function(
    String label,
    String current,
    String min,
    String max,
    String trend,
  )
  seriesSummary;

  /// A series that holds no sample yet.
  final String Function(String label) seriesEmpty;

  /// A series whose samples are all unknown (03 §10.4).
  final String Function(String label) seriesUnknown;

  /// A value the host did not report; never shown as zero (03 §10.4).
  final String unknownValue;

  /// The labels of a time-series chart's bands without data (03 §9.5
  /// item 5): the app was not running, was in the background, had no
  /// link to the server, or the server gave no reading.
  final String gapAppClosed;
  final String gapBackground;
  final String gapDisconnected;
  final String gapReadingFailed;

  /// A band without data as a screen reader hears it: when it began and
  /// ended, and its label.
  final String Function(DateTime start, DateTime end, String reason) gapSummary;

  /// A band without data that has not ended yet.
  final String Function(DateTime start, String reason) gapOngoing;

  /// A time axis label to the minute, and to the second for ticks less
  /// than a minute apart.
  final String Function(DateTime time) time;
  final String Function(DateTime time) timeWithSeconds;

  final String trendRising;
  final String trendFalling;
  final String trendSteady;

  /// A share from 0 to 100 in the UI locale's number format.
  final String Function(double value) percent;

  /// A stacked bar's screen-reader summary: its label, its [barPart]s
  /// joined by [listSeparator], and the formatted total.
  final String Function(String label, String parts, String total) barSummary;

  /// One part of a bar, as its legend and summary name it: the part's
  /// label and its formatted value.
  final String Function(String label, String value) barPart;

  /// Between the parts of a bar's summary.
  final String listSeparator;

  /// A [barPart] past a threshold, with [severityCareful],
  /// [severityWarning] or [severityCritical] (A11Y-01: the colour never
  /// speaks alone).
  final String Function(String part, String severity) withSeverity;

  final String severityCareful;
  final String severityWarning;
  final String severityCritical;

  /// A bar's summary while its values are stale (OV-04).
  final String Function(String summary) stale;
}

/// [value] as axis or value text in [unit].
String formatChartValue(double value, ChartUnit unit, ChartStrings strings) =>
    switch (unit) {
      ChartUnit.percent => strings.percent(value),
      ChartUnit.bytes => ghostFormatBinarySize(value.round()),
      ChartUnit.bytesPerSecond => ghostFormatBinaryRate(value),
      ChartUnit.count => value.round().toString(),
    };

/// The steps of an automatic scale within one IEC unit: 1, 2 and 5 times a
/// power of ten, stopping below 1024 so a label never reads "1000 KiB".
const _scaleSteps = [1, 2, 5, 10, 20, 50, 100, 200, 500];

/// TiB, the largest unit `ghostFormatBinarySize` names: its steps run on.
const _tebibyte = 1024.0 * 1024 * 1024 * 1024;

/// The top of an automatic scale for a series whose highest known value is
/// [dataMax]: 100 for a percentage, so hosts compare by eye, and otherwise
/// the next round IEC figure (500 KiB, 1 MiB, 2 MiB), so the scale label
/// reads as a round number. An empty or all-zero series gets 1 KiB. Debug
/// builds assert that [dataMax] is finite; release builds give a
/// non-finite one 1 KiB too.
double chartScaleMax(double? dataMax, ChartUnit unit) {
  assert(dataMax == null || dataMax.isFinite, 'samples are finite');
  return uncheckedChartScaleMax(dataMax, unit);
}

/// [chartScaleMax] without its debug check, as a release build runs it, so
/// tests can show that a non-finite [dataMax] gets 1 KiB there too rather
/// than an endless search.
@visibleForTesting
double uncheckedChartScaleMax(double? dataMax, ChartUnit unit) {
  if (unit == ChartUnit.percent) return 100;
  if (unit == ChartUnit.count) return _countScaleMax(dataMax);
  // NaN would never meet a step and +Infinity would reach an infinite
  // decade, so neither may enter the search below.
  if (dataMax == null || !dataMax.isFinite || dataMax <= 0) return 1024;
  for (var unitSize = 1.0; unitSize < _tebibyte; unitSize *= 1024) {
    for (final step in _scaleSteps) {
      if (step * unitSize >= dataMax) return step * unitSize;
    }
  }
  for (var decade = _tebibyte; ; decade *= 10) {
    for (final step in const [1, 2, 5]) {
      if (step * decade >= dataMax) return step * decade;
    }
  }
}

/// A count's scale: the next 1, 2 or 5 times a power of ten at or above
/// [dataMax], and 10 for an empty, all-zero or non-finite series.
double _countScaleMax(double? dataMax) {
  if (dataMax == null || !dataMax.isFinite || dataMax <= 0) return 10;
  for (var decade = 1.0; ; decade *= 10) {
    for (final step in const [1, 2, 5]) {
      if (step * decade >= dataMax) return step * decade;
    }
  }
}

/// The screen-reader summary of a series labelled [label] (A11Y-02): its
/// current, lowest and highest values and its trend on a scale spanning
/// [span], that it has no data yet, or that it is unknown. Charts expose it
/// on demand and never as a live region (A11Y-15).
String chartSeriesSummary({
  required String label,
  required List<double?> samples,
  required ChartUnit unit,
  required double span,
  required ChartStrings strings,
}) {
  if (samples.isEmpty) return strings.seriesEmpty(label);
  final known = [for (final value in samples) ?value];
  if (known.isEmpty) return strings.seriesUnknown(label);

  String format(double value) => formatChartValue(value, unit, strings);
  final current = samples.last;
  return strings.seriesSummary(
    label,
    current == null ? strings.unknownValue : format(current),
    format(known.reduce(math.min)),
    format(known.reduce(math.max)),
    _trendWord(known, span, strings),
  );
}

/// A change smaller than this share of the scale reads as steady, so noise
/// on a quiet host does not announce a trend.
const _steadyShare = 0.05;

/// The trend compares the means of the oldest and newest quarters of the
/// known samples, so one noisy sample weighs less than in a first-to-last
/// comparison. Fewer than four known samples read as steady.
const _trendWindowDivisor = 4;

String _trendWord(List<double> known, double span, ChartStrings strings) {
  final window = known.length ~/ _trendWindowDivisor;
  if (window == 0 || span <= 0) return strings.trendSteady;

  double mean(Iterable<double> values) =>
      values.reduce((a, b) => a + b) / window;
  final change =
      mean(known.skip(known.length - window)) - mean(known.take(window));
  if (change.abs() < span * _steadyShare) return strings.trendSteady;
  return change > 0 ? strings.trendRising : strings.trendFalling;
}
