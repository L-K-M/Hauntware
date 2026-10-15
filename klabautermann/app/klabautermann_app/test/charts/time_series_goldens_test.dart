import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

const _mebibyte = 1024.0 * 1024;
const _sceneKey = ValueKey('time-series-scene');

/// 03 §11.1's golden row for the time-series chart, light and dark, with
/// the bundled font: a labelled hatched gap, a gap too narrow for its
/// label, an open gap, missed ticks around an isolated sample, an IEC rate
/// axis and a seconds axis. Baselines come from the Linux runner.
void main() {
  setUpAll(() async {
    await loadChartDateFormats();
    if (goldensCompareHere) await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('time series in the ${brightness.name} theme', (tester) async {
      tester.view.physicalSize = const Size(472, 440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final end = DateTime(2026, 10, 14, 12, 10);

      // Receive and transmit rates every 2 s for ten minutes, disconnected
      // from 12:02 to 12:04, in the background for 20 s at 12:06 and
      // disconnected again since 12:09.
      final network = TimeSeriesRing(capacity: 300, lanes: 2);
      addTearDown(network.dispose);
      for (var second = 0; second < 540; second += 2) {
        final at = end.subtract(Duration(seconds: 600 - second));
        if (second == 120) network.openGap(at, ChartGapReason.disconnected);
        if (second == 360) network.openGap(at, ChartGapReason.background);
        if ((second >= 120 && second < 240) ||
            (second >= 360 && second < 380)) {
          continue;
        }
        network.add(at, [
          (0.9 + 0.6 * math.sin(second / 40)) * _mebibyte,
          (0.3 + 0.2 * math.cos(second / 25)) * _mebibyte,
        ]);
      }
      network.openGap(
        end.subtract(const Duration(minutes: 1)),
        ChartGapReason.disconnected,
      );

      // Four CPU shares every second for a minute, with missed ticks and a
      // single known sample between them.
      final cpu = TimeSeriesRing(capacity: 60, lanes: 4);
      addTearDown(cpu.dispose);
      for (var second = 0; second < 60; second++) {
        final at = end.subtract(Duration(seconds: 59 - second));
        final missed = second >= 30 && second < 36 && second != 33;
        cpu.add(at, [
          missed ? null : 40 + 15 * math.sin(second / 6),
          missed ? null : 15 + 5 * math.cos(second / 4),
          missed ? null : 6 + 4 * math.sin(second / 3),
          missed ? null : 2.0,
        ]);
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
                child: SizedBox(
                  width: 440,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 16,
                    children: [
                      SizedBox(
                        height: 200,
                        child: TimeSeriesChart(
                          data: network,
                          labels: const ['Receive', 'Transmit'],
                          unit: ChartUnit.bytesPerSecond,
                          strings: testChartStrings,
                          source: 'Sampled by this device while connected',
                          end: end,
                        ),
                      ),
                      SizedBox(
                        height: 160,
                        child: TimeSeriesChart(
                          data: cpu,
                          labels: const ['User', 'System', 'I/O wait', 'Steal'],
                          unit: ChartUnit.percent,
                          strings: testChartStrings,
                          source: 'Sampled by this device while connected',
                          end: end,
                          span: const Duration(minutes: 1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await expectLater(
        find.byKey(_sceneKey),
        matchesGoldenFile('goldens/time_series_${brightness.name}.png'),
      );
    }, skip: !goldensCompareHere);
  }
}
