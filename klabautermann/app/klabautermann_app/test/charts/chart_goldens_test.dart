import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

const _mebibyte = 1024.0 * 1024;
const _sceneKey = ValueKey('chart-scene');

/// 03 §11.1's golden row for the charts, light and dark, with the bundled
/// font: threshold bands and a gap, an automatic IEC scale, and min-max
/// downsampling. Baselines come from the Linux runner.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('sparklines in the ${brightness.name} theme', (tester) async {
      tester.view.physicalSize = const Size(472, 80);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final palette = ChartPalette.fromTheme(chartTheme(brightness));
      Widget sparkline(
        int capacity,
        ChartUnit unit,
        Iterable<double?> samples, {
        double? max = 100,
        ChartThresholds? thresholds,
        Color? color,
        bool showScale = true,
      }) {
        final ring = SeriesRing(capacity);
        addTearDown(ring.dispose);
        samples.forEach(ring.add);
        return SizedBox(
          width: 136,
          height: 48,
          child: Sparkline(
            series: ring,
            label: 'Series',
            unit: unit,
            strings: testChartStrings,
            max: max,
            thresholds: thresholds,
            color: color,
            showScale: showScale,
          ),
        );
      }

      await tester.pumpWidget(
        chartFrame(
          brightness: brightness,
          fontFamily: goldenFontFamily,
          RepaintBoundary(
            key: _sceneKey,
            child: ColoredBox(
              color: chartTheme(brightness).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    // A CPU share crossing both thresholds, with four
                    // missed ticks.
                    sparkline(
                      60,
                      ChartUnit.percent,
                      thresholds: const ChartThresholds(
                        warning: 70,
                        critical: 90,
                      ),
                      [
                        for (var i = 0; i < 60; i++)
                          if (i >= 20 && i < 24)
                            null
                          else
                            math.min(
                              100,
                              35 + 20 * math.sin(i / 5) + (i >= 45 ? 45 : 0),
                            ),
                      ],
                    ),
                    // A receive rate peaking at 1.8 MiB/s: a 2 MiB/s scale.
                    sparkline(
                      60,
                      ChartUnit.bytesPerSecond,
                      max: null,
                      color: palette.series[1],
                      [
                        for (var i = 0; i < 60; i++)
                          (i == 50 ? 1.8 : 0.6 + 0.5 * math.sin(i / 7)) *
                              _mebibyte,
                      ],
                    ),
                    // 450 of 600 slots in 136 px: five samples a column and
                    // one spike, without a scale label.
                    sparkline(
                      600,
                      ChartUnit.percent,
                      color: palette.series[2],
                      showScale: false,
                      [
                        for (var i = 0; i < 450; i++)
                          50 + 30 * math.sin(i / 40) + (i == 300 ? 45 : 0),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/charts_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
