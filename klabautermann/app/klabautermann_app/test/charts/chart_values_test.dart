import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

final _iecFigure = RegExp(r'^\d+(\.\d)? (B|KiB|MiB|GiB|TiB)$');
final _roundIecFigure = RegExp(
  r'^(1|2|5|10|20|50|100|200|500) (B|KiB|MiB|GiB|TiB)$',
);
final _decimalUnit = RegExp(r'\b(kB|KB|MB|GB|TB)\b');

/// A11Y-06 and A11Y-02: IEC-only axis and value text, and the series
/// summary's statistics and words.
void main() {
  group('IEC units only', () {
    // Powers of two and their neighbours up to 256 TiB (the largest unit
    // the formatter names is TiB), plus rounding boundaries.
    final magnitudes = <double>[
      0,
      for (var power = 0; power <= 48; power++)
        for (final factor in [1.0, 1.5]) ...[
          math.pow(2, power).toDouble() * factor - 1,
          math.pow(2, power).toDouble() * factor,
        ],
      1023.99 * 1024,
      999e6,
    ];

    test('byte and rate values read in binary units', () {
      for (final value in magnitudes) {
        final size = formatChartValue(value, ChartUnit.bytes, testChartStrings);
        final rate = formatChartValue(
          value,
          ChartUnit.bytesPerSecond,
          testChartStrings,
        );

        expect(size, matches(_iecFigure), reason: '$value B');
        expect(rate, '$size/s', reason: '$value B/s');
        expect(rate, isNot(contains(_decimalUnit)));
      }
    });

    test('an automatic scale tops out at a round binary figure', () {
      for (final value in magnitudes.where((value) => value > 0)) {
        for (final unit in [ChartUnit.bytes, ChartUnit.bytesPerSecond]) {
          final top = chartScaleMax(value, unit);
          final label = formatChartValue(
            top,
            ChartUnit.bytes,
            testChartStrings,
          );

          expect(top, greaterThanOrEqualTo(value), reason: '$value');
          expect(label, matches(_roundIecFigure), reason: '$value: $label');
        }
      }
      expect(chartScaleMax(600 * 1024, ChartUnit.bytes), 1024 * 1024);
      expect(chartScaleMax(300, ChartUnit.bytesPerSecond), 500);
      // An empty or idle series still has a scale; percentages span 100.
      expect(chartScaleMax(null, ChartUnit.bytes), 1024);
      expect(chartScaleMax(0, ChartUnit.bytesPerSecond), 1024);
      expect(chartScaleMax(3, ChartUnit.percent), 100);
    });

    test('the charts never call a decimal size formatter', () {
      final offenders = [
        for (final file in Directory('lib/ui/charts').listSync())
          if (file is File &&
              RegExp(
                r'ghostFormat(FileSize|ByteRate)\s*\(',
              ).hasMatch(file.readAsStringSync()))
            file.path,
      ];

      expect(offenders, isEmpty);
    });
  });

  test('percentages use the catalogue number format', () {
    expect(formatChartValue(42.4, ChartUnit.percent, testChartStrings), '42%');
    expect(formatChartValue(100, ChartUnit.percent, testChartStrings), '100%');
  });

  group('the series summary', () {
    String summary(
      List<double?> samples, {
      ChartUnit unit = ChartUnit.percent,
      double span = 100,
    }) => chartSeriesSummary(
      label: 'CPU',
      samples: samples,
      unit: unit,
      span: span,
      strings: testChartStrings,
    );

    test('says the current, lowest and highest values and the trend', () {
      expect(
        summary([10, 12, 30, 42]),
        'CPU: now 42%, lowest 10%, highest 42%, rising',
      );
      expect(
        summary([4096, null, 2048, null], unit: ChartUnit.bytesPerSecond),
        'CPU: now unknown, lowest 2 KiB/s, highest 4 KiB/s, steady',
      );
      expect(summary([]), 'CPU: no data yet');
      // A metric the host never reports is unknown, not still to come.
      expect(summary([null, null]), 'CPU: unknown');
    });

    test('compares the outer quarters against the scale for the trend', () {
      expect(summary([10, 12, 11, 30, 32, 31, 60, 62]), endsWith('rising'));
      expect(summary([60, 62, 40, 30, 20, 10, 5, 4]), endsWith('falling'));
      // A one-sample spike and noise under 5 % of the scale are steady, as
      // are too few samples and a scale of nothing.
      expect(summary([20, 22, 21, 95, 20, 23, 21, 22]), endsWith('steady'));
      expect(summary([10, 50]), endsWith('steady'));
      expect(summary([10, 20, 30, 40], span: 0), endsWith('steady'));
    });
  });
}
