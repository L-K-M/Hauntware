import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

final _painter = find.descendant(
  of: find.byType(Sparkline),
  matching: find.byType(CustomPaint),
);

SeriesRing _ring(List<double?> samples, {int? capacity}) {
  final ring = SeriesRing(capacity ?? samples.length);
  addTearDown(ring.dispose);
  samples.forEach(ring.add);
  return ring;
}

Widget _sparkline(SeriesRing ring, {ChartThresholds? thresholds}) => chartFrame(
  SizedBox(
    width: 100,
    height: 40,
    child: Sparkline(
      series: ring,
      label: 'CPU',
      unit: ChartUnit.percent,
      strings: testChartStrings,
      max: 100,
      thresholds: thresholds,
    ),
  ),
);

/// 03 §10.7: the sparkline's painter, its version-counter repaint,
/// semantics (A11Y-02, A11Y-15) and reduced motion (A11Y-11).
void main() {
  testWidgets('paints its threshold bands behind the line', (tester) async {
    await tester.pumpWidget(
      _sparkline(
        _ring([10, 50, 80, 95, 60]),
        thresholds: const ChartThresholds(warning: 70, critical: 90),
      ),
    );
    final palette = ChartPalette.of(tester.element(find.byType(Sparkline)));
    Color wash(Color colour) =>
        colour.withValues(alpha: SparklinePainter.bandAlpha);

    expect(
      _painter,
      paints
        ..rect(color: wash(palette.critical))
        ..rect(color: wash(palette.warning))
        ..path(
          color: palette.series.first,
          strokeWidth: SparklinePainter.strokeWidth,
          style: PaintingStyle.stroke,
        ),
    );
  });

  testWidgets('a known sample between gaps is a dot, never a zero', (
    tester,
  ) async {
    await tester.pumpWidget(_sparkline(_ring([null, 40, null])));
    final palette = ChartPalette.of(tester.element(find.byType(Sparkline)));

    expect(
      _painter,
      paints..circle(
        x: 50,
        radius: SparklinePainter.strokeWidth,
        color: palette.series.first,
      ),
    );
  });

  testWidgets('repaints on a new version inside its own boundary', (
    tester,
  ) async {
    final ring = _ring([10, 20, 30], capacity: 10);
    await tester.pumpWidget(_sparkline(ring));
    SparklinePainter painter() =>
        tester.widget<CustomPaint>(_painter).painter! as SparklinePainter;
    final before = painter();

    ring.add(40);
    await tester.pumpAndSettle();
    final after = painter();
    expect(after.version, ring.version);
    expect(after.shouldRepaint(before), isTrue);

    // A rebuild with nothing new keeps the picture.
    await tester.pumpWidget(_sparkline(ring));
    expect(painter().shouldRepaint(after), isFalse);
    expect(
      find.descendant(
        of: find.byType(Sparkline),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
  });

  // The reduced-motion signals A11Y-11 honours: Android's, through
  // MediaQuery, and iOS's, only through the accessibility features.
  for (final (signal, features) in [
    ('by default', null),
    (
      'when animations are removed',
      FakeAccessibilityFeatures(disableAnimations: true),
    ),
    ('under Reduce Motion', FakeAccessibilityFeatures(reduceMotion: true)),
  ]) {
    final motion = features == null ? 'slides' : 'jumps';
    testWidgets('a new sample $motion in $signal', (tester) async {
      if (features != null) {
        tester.platformDispatcher.accessibilityFeaturesTestValue = features;
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      final ring = _ring([10, 20], capacity: 10);
      await tester.pumpWidget(_sparkline(ring));

      ring.add(30);
      await tester.pump();

      expect(tester.hasRunningAnimations, features == null);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('offers its summary on demand, not as a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ring = _ring([10, 50, 80, 95], capacity: 10);
    await tester.pumpWidget(_sparkline(ring));

    expect(
      tester.getSemantics(find.byType(Sparkline)),
      matchesSemantics(label: 'CPU: now 95%, lowest 10%, highest 95%, rising'),
    );

    ring.add(null);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(Sparkline)),
      matchesSemantics(
        label: 'CPU: now unknown, lowest 10%, highest 95%, rising',
      ),
    );
    semantics.dispose();
  });
}
