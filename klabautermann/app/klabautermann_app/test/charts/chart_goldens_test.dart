import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

const _mebibyte = 1024.0 * 1024;
const _gibibyte = 1024 * _mebibyte;
const _sceneKey = ValueKey('chart-scene');

/// 03 §11.1's golden row for the charts, light and dark, with the bundled
/// font: threshold bands and a gap, an automatic IEC scale, and min-max
/// downsampling; stacked and pressure bars in their threshold, unknown and
/// stale states. Baselines come from the Linux runner.
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

    testWidgets('bars in the ${brightness.name} theme', (tester) async {
      tester.view.physicalSize = const Size(480, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const thresholds = ChartThresholds(warning: 80, critical: 90);
      Widget memory({double? buffers = 0.5, bool stale = false}) => StackedBar(
        label: 'Memory',
        segments: [
          const BarSegment(label: 'Used', value: 6 * _gibibyte),
          BarSegment(
            label: 'Buffers',
            value: buffers == null ? null : buffers * _gibibyte,
          ),
          const BarSegment(label: 'Cache', value: 3 * _gibibyte),
        ],
        total: 16 * _gibibyte,
        unit: ChartUnit.bytes,
        strings: testChartStrings,
        thresholds: thresholds,
        stale: stale,
      );
      Widget pressure(
        double? cpu,
        double? memory,
        double? disk, {
        bool stale = false,
      }) => PressureBar(
        cells: [
          PressureCell(label: 'CPU', percent: cpu, thresholds: thresholds),
          PressureCell(
            label: 'Memory',
            percent: memory,
            thresholds: thresholds,
          ),
          PressureCell(label: 'Disk', percent: disk, thresholds: thresholds),
        ],
        strings: testChartStrings,
        stale: stale,
      );

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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 24,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          memory(),
                          // A disk past its critical threshold.
                          StackedBar(
                            label: 'Disk',
                            segments: const [
                              BarSegment(label: 'Used', value: 186 * _gibibyte),
                            ],
                            total: 200 * _gibibyte,
                            unit: ChartUnit.bytes,
                            strings: testChartStrings,
                            thresholds: thresholds,
                          ),
                          // Unknown buffers hatch the unattributed rest.
                          memory(buffers: null),
                          memory(stale: true),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 12,
                      children: [
                        pressure(42, 63, 31),
                        pressure(42, 85, 31),
                        pressure(42, 92, 85),
                        pressure(null, 63, 31),
                        pressure(42, 92, 85, stale: true),
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
        matchesGoldenFile('goldens/bars_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
