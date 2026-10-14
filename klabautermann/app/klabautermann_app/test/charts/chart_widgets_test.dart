import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/sparkline.dart'
    show SparklinePainter;

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

Widget _sparkline(
  SeriesRing ring, {
  ChartThresholds? thresholds,
  bool showScale = false,
}) => chartFrame(
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
      showScale: showScale,
    ),
  ),
);

SparklinePainter _painterOf(WidgetTester tester) =>
    tester.widget<CustomPaint>(_painter).painter! as SparklinePainter;

/// 03 §10.7: the sparkline's painter, its version-counter repaint,
/// semantics (A11Y-02, A11Y-15) and reduced motion (A11Y-11).
void main() {
  testWidgets('paints its threshold bands and rules behind the line', (
    tester,
  ) async {
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
        ..rect(color: palette.critical)
        ..rect(color: wash(palette.warning))
        ..rect(color: palette.warning)
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
    final before = _painterOf(tester);

    ring.add(40);
    await tester.pumpAndSettle();
    final after = _painterOf(tester);
    expect(after.version, ring.version);
    expect(after.shouldRepaint(before), isTrue);

    // A rebuild with nothing new keeps the picture.
    await tester.pumpWidget(_sparkline(ring));
    expect(_painterOf(tester).shouldRepaint(after), isFalse);
    expect(
      find.descendant(
        of: find.byType(Sparkline),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
  });

  testWidgets('follows the ring a rebuild hands it', (tester) async {
    final first = _ring([10, 20], capacity: 10);
    final second = _ring([30, 40, 50], capacity: 10);
    await tester.pumpWidget(_sparkline(first));
    await tester.pumpWidget(_sparkline(second));

    second.add(60);
    await tester.pumpAndSettle();
    expect(_painterOf(tester).version, second.version);

    first.add(30);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('a full ring slides its oldest sample out without a gap', () {
    final ring = _ring(List.filled(11, 50), capacity: 10);
    double lineLeft(double slide) {
      final canvas = TestRecordingCanvas();
      SparklinePainter(
        series: ring,
        version: ring.version,
        slide: AlwaysStoppedAnimation(slide),
        scaleMax: 100,
        lineColor: const Color(0xFF000000),
        warningBand: null,
        criticalBand: null,
      ).paint(canvas, const Size(100, 40));
      final draw = canvas.invocations.singleWhere(
        (call) => call.invocation.memberName == #drawPath,
      );
      return (draw.invocation.positionalArguments.first as Path)
          .getBounds()
          .left;
    }

    // The plot's left edge, inset by half the stroke.
    const plotLeft = SparklinePainter.strokeWidth / 2;
    for (final slide in [0.0, 0.5, 0.99]) {
      expect(lineLeft(slide), lessThanOrEqualTo(plotLeft), reason: '$slide');
    }
    expect(lineLeft(1), plotLeft);
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

  testWidgets('a new sample follows a Reduce Motion switch since the build', (
    tester,
  ) async {
    final ring = _ring([10, 20], capacity: 10);
    await tester.pumpWidget(_sparkline(ring));

    // iOS's switch reaches no MediaQuery, so nothing rebuilds the
    // sparkline before its next sample.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    ring.add(30);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    ring.add(40);
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('offers its summary on demand, not as a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ring = _ring([10, 50, 80, 95], capacity: 10);
    // The scale label stays out of the summary.
    await tester.pumpWidget(_sparkline(ring, showScale: true));

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
