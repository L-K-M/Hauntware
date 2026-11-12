import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/chart_marks.dart'
    show ThresholdBand, thresholdBandAlpha;
import 'package:klabautermann_app/ui/charts/time_series_chart.dart'
    show TimeSeriesCrosshairPainter, TimeSeriesPainter, firstTimeSeriesTick;
import 'package:klabautermann_app/ui/charts/time_series_crosshair.dart'
    show TimeSeriesGapHit, TimeSeriesSampleHit;

import '../support/charts.dart';

const _mebibyte = 1024.0 * 1024;
final _end = DateTime(2026, 10, 14, 12, 10);
DateTime _at(int second) => _end.subtract(Duration(seconds: 600 - second));

final _plot = find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is TimeSeriesPainter,
);

TimeSeriesPainter _painterOf(WidgetTester tester) =>
    tester.widget<CustomPaint>(_plot).painter! as TimeSeriesPainter;

/// Receive and transmit rates every 10 s for ten minutes, disconnected from
/// 12:02 to 12:04, one known receive sample at 12:06 between missed ticks,
/// and disconnected again since 12:09.
TimeSeriesRing _network() {
  final ring = TimeSeriesRing(capacity: 60, lanes: 2);
  addTearDown(ring.dispose);
  for (var second = 0; second < 540; second += 10) {
    if (second > 120 && second < 240) continue;
    ring.add(_at(second), [
      second == 350 || second == 370
          ? null
          : (second < 300 ? 1.0 : 1.5) * _mebibyte,
      0.25 * _mebibyte,
    ]);
    if (second == 120) ring.openGap(_at(120), ChartGapReason.disconnected);
  }
  ring.openGap(_at(540), ChartGapReason.disconnected);
  return ring;
}

Widget _chart(
  TimeSeriesRing ring, {
  DateTime? end,
  double? max,
  double width = 400,
  ChartThresholds? thresholds,
}) => chartFrame(
  SizedBox(
    width: width,
    height: 200,
    child: TimeSeriesChart(
      data: ring,
      labels: const ['Receive', 'Transmit'],
      unit: ChartUnit.bytesPerSecond,
      strings: testChartStrings,
      source: 'Sampled by this device while connected',
      end: end ?? _end,
      max: max,
      thresholds: thresholds,
    ),
  ),
);

final _crosshair = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint && widget.painter is TimeSeriesCrosshairPainter,
);

TimeSeriesCrosshairPainter? _crosshairOf(WidgetTester tester) =>
    _crosshair.evaluate().isEmpty
    ? null
    : tester.widget<CustomPaint>(_crosshair).painter!
          as TimeSeriesCrosshairPainter;

/// Where [second] of the window falls on screen, halfway up the plot.
Offset _onPlot(WidgetTester tester, num second) {
  final painter = _painterOf(tester);
  final plot = painter.plotRectFor(tester.getSize(_plot));
  final micros =
      _at(0).microsecondsSinceEpoch + (second * Duration.microsecondsPerSecond);
  return tester.getTopLeft(_plot) +
      Offset(painter.xOf(plot, micros.round()), plot.center.dy);
}

/// The readout's box on screen.
Rect _readoutRect(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.textContaining('PM'), matching: find.byType(FittedBox))
      .first,
);

/// The contours of every path [painter] strokes in [color], as bounds; a
/// series' marker is filled, so it is left out. A recorded paint keeps
/// its colour as 8-bit channels, so the match is on those.
List<Rect> _contours(TimeSeriesPainter painter, Size size, Color color) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawPath &&
          (call.invocation.positionalArguments[1] as Paint).style ==
              PaintingStyle.stroke &&
          (call.invocation.positionalArguments[1] as Paint).color.toARGB32() ==
              color.toARGB32())
        for (final metric
            in (call.invocation.positionalArguments.first as Path)
                .computeMetrics())
          metric.extractPath(0, metric.length).getBounds(),
  ];
}

/// Each gap band's wash that [painter] draws, in time order.
List<Rect> _bands(TimeSeriesPainter painter, Size size) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRect &&
          (call.invocation.positionalArguments[1] as Paint).color.a < 0.1)
        call.invocation.positionalArguments.first as Rect,
  ];
}

/// 03 §10.7 and §9.5 item 5: gaps are hatched, labelled and never
/// interpolated; the legend names the source; semantics (A11Y-02, A11Y-15)
/// and the version-counter repaint.
void main() {
  setUpAll(loadChartDateFormats);

  testWidgets('never draws a line across a gap or an unknown sample', (
    tester,
  ) async {
    await tester.pumpWidget(_chart(_network()));
    final painter = _painterOf(tester);
    final size = tester.getSize(_plot);
    final palette = ChartPalette.of(tester.element(_plot));

    final bands = _bands(painter, size);
    expect(bands, hasLength(2));
    // The open gap reaches the plot's right edge, which leaves room for a
    // marker on a sample there.
    expect(bands.last.right, closeTo(painter.plotRectFor(size).right, 0.01));
    expect(
      painter.plotRectFor(size).right,
      size.width - TimeSeriesPainter.markerReach,
    );

    final receive = _contours(painter, size, palette.series[0]);
    final transmit = _contours(painter, size, palette.series[1]);
    // Receive breaks at the first gap and around the lone sample; transmit
    // only at the gap.
    expect(receive, hasLength(3));
    expect(transmit, hasLength(2));
    for (final contour in [...receive, ...transmit]) {
      for (final band in bands) {
        final apart =
            contour.right <= band.left + 0.01 ||
            contour.left >= band.right - 0.01;
        expect(apart, isTrue, reason: '$contour crosses $band');
      }
    }
    // The lone sample at 12:06 is a dot between the receive lines.
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, size);
    final dot = canvas.invocations.singleWhere(
      (call) => call.invocation.memberName == #drawCircle,
    );
    final centre = dot.invocation.positionalArguments.first as Offset;
    expect(receive[1].right, lessThan(centre.dx));
    expect(centre.dx, lessThan(receive[2].left));
  });

  testWidgets('widens a gap shorter than a pixel around its centre', (
    tester,
  ) async {
    final ring = TimeSeriesRing(capacity: 10, lanes: 2);
    addTearDown(ring.dispose);
    ring.add(_at(290), [1, 1]);
    ring.openGap(_at(300), ChartGapReason.disconnected);
    ring.add(_at(300).add(const Duration(milliseconds: 500)), [1, 1]);
    // A minute-long gap maps times to pixels.
    ring.openGap(_at(400), ChartGapReason.disconnected);
    ring.add(_at(460), [1, 1]);
    await tester.pumpWidget(_chart(ring));

    final [short, long] = _bands(_painterOf(tester), tester.getSize(_plot));
    expect(short.width, closeTo(TimeSeriesPainter.minGapWidth, 0.01));
    final perSecond = long.width / 60;
    expect(short.center.dx, closeTo(long.left - 99.75 * perSecond, 0.01));
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'every hatch stroke clears 3:1 as drawn at 1x (${brightness.name})',
      (tester) async {
        final theme = chartTheme(brightness);
        final chrome = theme.extension<GhostChrome>()!;
        final ink = ChartPalette.fromTheme(theme).scaleText;
        final ring = TimeSeriesRing(capacity: 2, lanes: 1);
        addTearDown(ring.dispose);
        ring.openGap(_at(100), ChartGapReason.disconnected);
        const scene = ValueKey('hatch');
        Future<Rect> pump(Color surface, DateTime end) async {
          await tester.pumpWidget(
            chartFrame(
              brightness: brightness,
              RepaintBoundary(
                key: scene,
                child: ColoredBox(
                  color: surface,
                  child: SizedBox(
                    width: 400,
                    height: 200,
                    child: TimeSeriesChart(
                      data: ring,
                      labels: const ['User'],
                      unit: ChartUnit.percent,
                      strings: testChartStrings,
                      source: '',
                      end: end,
                    ),
                  ),
                ),
              ),
            ),
          );
          return _bands(_painterOf(tester), tester.getSize(_plot)).single;
        }

        // Antialiasing depends on where the band falls between pixels, so
        // each surface is checked with the band moved by quarter pixels.
        final open = _end.difference(_at(100)).inMicroseconds;
        final first = await pump(Colors.white, _end);
        final pixelTime = open / first.width;
        for (final (surface, quarter) in [
          for (final surface in [
            theme.colorScheme.surface,
            theme.colorScheme.surfaceContainerLow,
            theme.colorScheme.surfaceContainer,
            theme.colorScheme.surfaceContainerHigh,
            chrome.paneBackground,
            chrome.inspectorBackground,
            chrome.sidebarBackground,
          ])
            for (var quarter = 0; quarter < 4; quarter++) (surface, quarter),
        ]) {
          final shift = Duration(
            microseconds: (pixelTime * quarter / 4).round(),
          );
          final band = await pump(surface, _end.add(shift));
          expect(band.left, closeTo(first.left - quarter / 4, 0.001));
          final where = '$surface, band moved $quarter/4 px';
          // A desktop at 100 % scaling rasterizes at one pixel per point,
          // where a thin diagonal stroke never reaches its full colour.
          final pixels = (await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(scene),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData();
            final width = image.width;
            image.dispose();
            return (bytes: bytes!, width: width);
          }))!;
          Color pixel(int x, int y) {
            final at = (y * pixels.width + x) * 4;
            final byte = pixels.bytes.getUint8;
            return Color.fromARGB(255, byte(at), byte(at + 1), byte(at + 2));
          }

          final wash = Color.alphaBlend(
            ink.withValues(alpha: TimeSeriesPainter.gapWashAlpha),
            surface,
          );
          var strokes = 0;
          // Rows clear of the label, the grid and the band's edges; each
          // run of hatch pixels is one stroke crossing the row.
          for (
            var y = (band.top + band.height * 0.55).ceil();
            y < band.top + band.height * 0.9;
            y++
          ) {
            final left = band.left.ceil() + 1, right = band.right.floor() - 2;
            var peak = 0.0;
            var start = -1;
            for (var x = left; x <= right; x++) {
              final ratio = contrastRatio(pixel(x, y), wash);
              if (ratio > 1.2) {
                if (start < 0) start = x;
                peak = math.max(peak, ratio);
                continue;
              }
              if (start > left) {
                expect(peak, greaterThanOrEqualTo(3), reason: where);
                strokes++;
              }
              start = -1;
              peak = 0;
            }
          }
          expect(strokes, greaterThan(100), reason: where);
        }
      },
    );
  }

  testWidgets('the legend names the series, gap reasons and source', (
    tester,
  ) async {
    final ring = _network();
    // A 20 s background gap, too narrow for its label in the band.
    ring.add(_at(545), [_mebibyte, _mebibyte]);
    ring.openGap(_at(545), ChartGapReason.background);
    ring.add(_at(565), [_mebibyte, _mebibyte]);
    await tester.pumpWidget(_chart(ring));

    for (final text in [
      'Receive',
      'Transmit',
      'disconnected',
      'in background',
      'Sampled by this device while connected',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });

  testWidgets('starts the legend at the start edge in either direction', (
    tester,
  ) async {
    // Wide enough that the source fits on one line, so the legend is
    // narrower than the chart.
    for (final direction in TextDirection.values) {
      await tester.pumpWidget(
        chartFrame(
          Directionality(
            textDirection: direction,
            child: SizedBox(
              width: 600,
              height: 200,
              child: TimeSeriesChart(
                data: _network(),
                labels: const ['Receive', 'Transmit'],
                unit: ChartUnit.bytesPerSecond,
                strings: testChartStrings,
                source: 'Sampled by this device while connected',
                end: _end,
              ),
            ),
          ),
        ),
      );

      final chart = tester.getRect(find.byType(TimeSeriesChart));
      final firstEntry = find
          .ancestor(of: find.text('Receive'), matching: find.byType(Row))
          .first;
      for (final part in [
        firstEntry,
        find.text('Sampled by this device while connected'),
      ]) {
        final rect = tester.getRect(part);
        expect(
          direction == TextDirection.rtl ? rect.right : rect.left,
          direction == TextDirection.rtl ? chart.right : chart.left,
          reason: '$part in $direction',
        );
      }
    }
  });

  testWidgets('wraps a legend label wider than the chart within its entry', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      chartFrame(
        SizedBox(
          width: 120,
          height: 200,
          child: TimeSeriesChart(
            data: _network(),
            labels: const ['Receive', 'Transmit'],
            unit: ChartUnit.bytesPerSecond,
            strings: testChartStrings,
            source: 'Sampled by this device while connected',
            end: _end,
          ),
        ),
      ),
    );

    // At doubled text each label, with its swatch, is wider than the chart.
    expect(tester.takeException(), isNull);
    final chart = tester.getRect(find.byType(TimeSeriesChart));
    for (final label in ['Receive', 'Transmit', 'disconnected']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(chart.left), reason: label);
      expect(rect.right, lessThanOrEqualTo(chart.right), reason: label);
    }
  });

  testWidgets('offers series summaries and gap spans, not live regions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_chart(_network()));

    for (final label in [
      // The right edge lies in the open gap, so no value is current.
      'Receive: now unknown, lowest 1 MiB/s, highest 1.5 MiB/s, rising',
      'Transmit: now unknown, lowest 256 KiB/s, highest 256 KiB/s, steady',
      // CLDR puts a narrow no-break space before the day period.
      'No data from 12:02:00\u202fPM to 12:04:00\u202fPM: disconnected',
      'No data since 12:09:00\u202fPM: disconnected',
      'Sampled by this device while connected',
    ]) {
      // The painter's nodes belong to no widget of their own.
      final node = find.semantics.byLabel(label);
      expect(node, findsOne, reason: label);
      // No flags: in particular, not a live region.
      expect(node.evaluate().single, matchesSemantics(label: label));
    }
    // The legend's entries repeat the summaries, so they stay silent.
    expect(find.semantics.byLabel('Receive'), findsNothing);

    // Twenty minutes into the gap the window holds no sample, though the
    // ring does.
    await tester.pumpWidget(
      _chart(_network(), end: _end.add(const Duration(minutes: 20))),
    );
    expect(find.semantics.byLabel('Receive: unknown'), findsOne);
    semantics.dispose();
  });

  testWidgets('keeps a plot and the summaries under doubled text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final ring = TimeSeriesRing(capacity: 10, lanes: 4);
    addTearDown(ring.dispose);
    for (final (index, reason) in ChartGapReason.values.indexed) {
      ring.add(_at(index * 120), [50, 2, 3, 4]);
      ring.openGap(_at(index * 120 + 60), reason);
    }
    await tester.pumpWidget(
      chartFrame(
        SizedBox(
          width: 400,
          height: 90,
          child: TimeSeriesChart(
            data: ring,
            labels: const ['User', 'System', 'I/O wait', 'Steal'],
            unit: ChartUnit.percent,
            strings: testChartStrings,
            source: 'Sampled by this device while connected',
            end: _end,
          ),
        ),
      ),
    );

    // The legend and source scroll within half the height rather than
    // overflowing the chart and squeezing the plot to nothing.
    expect(tester.takeException(), isNull);
    expect(tester.getSize(_plot).height, greaterThanOrEqualTo(41));
    // The axis labels leave no room for the plot itself, but the summaries
    // still carry the data.
    const label = 'User: now unknown, lowest 50%, highest 50%, steady';
    expect(
      find.semantics.byLabel(label).evaluate().single,
      matchesSemantics(label: label),
    );
    semantics.dispose();
  });

  testWidgets('asks for its fallback height when measured intrinsically', (
    tester,
  ) async {
    await tester.pumpWidget(
      chartFrame(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TimeSeriesChart(
                  data: _network(),
                  labels: const ['Receive', 'Transmit'],
                  unit: ChartUnit.bytesPerSecond,
                  strings: testChartStrings,
                  source: 'Sampled by this device while connected',
                  end: _end,
                ),
              ),
              const SizedBox(width: 8, height: 120),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TimeSeriesChart)).height, 200);
    expect(tester.getSize(_plot).height, greaterThan(100));
  });

  testWidgets(
    "keeps the legend off the page's primary scroll controller",
    (tester) async {
      // The app's theme takes the host platform, and Material's scroll
      // behaviour reads the platform from the theme.
      final theme = chartTheme(Brightness.light);
      await tester.pumpWidget(
        chartFrame(
          Theme(
            data: theme.copyWith(platform: defaultTargetPlatform),
            child: SizedBox(
              width: 400,
              height: 200,
              child: TimeSeriesChart(
                data: _network(),
                labels: const ['Receive', 'Transmit'],
                unit: ChartUnit.bytesPerSecond,
                strings: testChartStrings,
                source: '',
                end: _end,
              ),
            ),
          ),
        ),
      );

      // On a phone a status-bar tap would scroll the legend, and two charts
      // on one page would attach two positions to one controller.
      final primary = PrimaryScrollController.maybeOf(tester.element(_plot));
      expect(primary, isNotNull);
      expect(primary!.hasClients, isFalse);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  test('puts time ticks on round local times in any zone', () {
    int utc(int hour, int minute) =>
        DateTime.utc(2026, 10, 14, hour, minute).microsecondsSinceEpoch;
    int first(int from, Duration offset) => firstTimeSeriesTick(
      from: from,
      step: Duration.microsecondsPerHour,
      offset: offset.inMicroseconds,
    );
    const india = Duration(hours: 5, minutes: 30);
    const nepal = Duration(hours: 5, minutes: 45);

    // 11:50 in India ticks first at noon there, not at 07:00 UTC.
    expect(first(utc(6, 20), india), utc(6, 30));
    // 10:45 in Nepal ticks first at 11:00 there; a tick start keeps it.
    expect(first(utc(5, 0), nepal), utc(5, 15));
    expect(first(utc(5, 15), nepal), utc(5, 15));
    expect(first(utc(5, 0), Duration.zero), utc(5, 0));
  });

  testWidgets('places time ticks in the zone it is given, not UTC', (
    tester,
  ) async {
    final ring = TimeSeriesRing(capacity: 2, lanes: 1);
    addTearDown(ring.dispose);
    // Noon in Nepal, where no UTC grid of half an hour or more has a tick.
    final to = DateTime.utc(2026, 10, 14, 6, 15).microsecondsSinceEpoch;
    const size = Size(400, 200);
    List<double> ticksIn(Duration zone) {
      final canvas = TestRecordingCanvas();
      TimeSeriesPainter(
        data: ring,
        version: ring.version,
        from: to - 4 * Duration.microsecondsPerHour,
        to: to,
        scaleMax: 100,
        unit: ChartUnit.percent,
        strings: testChartStrings,
        colors: const [Colors.blue],
        gaps: const [],
        summaries: const [],
        textStyle: const TextStyle(fontSize: 11, color: Colors.black),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
        background: Colors.white,
        zoneOffsetOf: (_) => zone,
      ).paint(canvas, size);
      // The tick marks are the only 1 px wide rectangles.
      return [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawRect)
            if (call.invocation.positionalArguments.first case Rect(
              width: 1,
              :final center,
            ))
              center.dx,
      ];
    }

    // Runs under any TZ, CI's UTC included: the zone comes from the test.
    final edge = size.width - TimeSeriesPainter.markerReach;
    expect(
      ticksIn(const Duration(hours: 5, minutes: 45)).last,
      closeTo(edge, 0.01),
    );
    expect(ticksIn(Duration.zero).last, lessThan(edge - 1));
  });

  testWidgets('scales to the data in view in IEC units', (tester) async {
    final ring = TimeSeriesRing(capacity: 10, lanes: 2);
    addTearDown(ring.dispose);
    ring.add(_at(100), [3 * _mebibyte, 0]);
    ring.add(_at(400), [1.5 * _mebibyte, 0]);
    await tester.pumpWidget(_chart(ring));
    expect(_painterOf(tester).scaleMax, 5 * _mebibyte);

    // Five minutes on, the 3 MiB/s sample has left the window.
    await tester.pumpWidget(
      _chart(ring, end: _end.add(const Duration(minutes: 5))),
    );
    expect(_painterOf(tester).scaleMax, 2 * _mebibyte);
    await tester.pumpWidget(_chart(ring, max: 10 * _mebibyte));
    expect(_painterOf(tester).scaleMax, 10 * _mebibyte);
  });

  testWidgets('repaints on a new sample or a later end, never animating', (
    tester,
  ) async {
    final ring = _network();
    await tester.pumpWidget(_chart(ring));
    final before = _painterOf(tester);

    ring.add(_at(600), [_mebibyte, _mebibyte]);
    await tester.pump();
    final after = _painterOf(tester);
    expect(after.version, ring.version);
    expect(after.shouldRepaint(before), isTrue);
    // Reduced motion (A11Y-11) has nothing to stop.
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(_chart(ring));
    expect(_painterOf(tester).shouldRepaint(after), isFalse);
    await tester.pumpWidget(
      _chart(ring, end: _end.add(const Duration(seconds: 2))),
    );
    expect(_painterOf(tester).shouldRepaint(after), isTrue);
  });

  group('crosshair', () {
    testWidgets('follows a hovering mouse to the nearest sample', (
      tester,
    ) async {
      await tester.pumpWidget(_chart(_network()));
      final base = _painterOf(tester);
      expect(_crosshairOf(tester), isNull);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(_onPlot(tester, 302));
      await tester.pump();

      final hit = _crosshairOf(tester)!.hit as TimeSeriesSampleHit;
      expect(hit.at, _at(300).microsecondsSinceEpoch);
      expect(find.text('12:05:00\u202fPM'), findsOneWidget);
      expect(find.text('Receive 1.5 MiB/s'), findsOneWidget);
      expect(find.text('Transmit 256 KiB/s'), findsOneWidget);
      // Moving the crosshair neither rebuilds the chart nor repaints its
      // lines.
      expect(identical(_painterOf(tester), base), isTrue);

      // An unknown value reads as no reading.
      await mouse.moveTo(_onPlot(tester, 351));
      await tester.pump();
      expect(find.text('Receive no reading'), findsOneWidget);

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(_crosshairOf(tester), isNull);
      expect(find.textContaining('Receive '), findsNothing);
    });

    testWidgets('says no reading and why inside a gap', (tester) async {
      await tester.pumpWidget(_chart(_network()));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(_onPlot(tester, 180));
      await tester.pump();

      expect(_crosshairOf(tester)!.hit, isA<TimeSeriesGapHit>());
      expect(find.text('No reading: disconnected'), findsOneWidget);
      expect(find.textContaining('Receive '), findsNothing);
    });

    testWidgets('follows a dragging finger and goes when it lifts', (
      tester,
    ) async {
      await tester.pumpWidget(_chart(_network()));
      final finger = await tester.startGesture(_onPlot(tester, 40));
      await finger.moveBy(const Offset(20, 0));
      await finger.moveTo(_onPlot(tester, 100));
      await tester.pump();
      expect(_crosshairOf(tester)!.hit.at, _at(100).microsecondsSinceEpoch);
      expect(find.text('12:01:40\u202fPM'), findsOneWidget);

      await finger.up();
      await tester.pump();
      expect(_crosshairOf(tester), isNull);
    });

    testWidgets('moves with the arrow keys while focused', (tester) async {
      await tester.pumpWidget(_chart(_network()));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_crosshairOf(tester), isNull);

      // The first key starts at the newest stop: the open gap's middle.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_crosshairOf(tester)!.hit, isA<TimeSeriesGapHit>());
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        _crosshairOf(tester)!.hit,
        TimeSeriesSampleHit(42, _at(530).microsecondsSinceEpoch),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(_crosshairOf(tester)!.hit.at, _at(0).microsecondsSinceEpoch);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_crosshairOf(tester)!.hit.at, _at(10).microsecondsSinceEpoch);
      expect(find.text('Receive 1 MiB/s'), findsOneWidget);

      // Focus leaving takes the crosshair with it.
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await tester.pump();
      expect(_crosshairOf(tester), isNull);
    });

    testWidgets('offers the readout as an adjustable value', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_chart(_network()));
      final readout = find.semantics.byLabel('Values at a time');
      expect(
        readout.evaluate().single,
        matchesSemantics(
          label: 'Values at a time',
          isFocusable: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
          hasFocusAction: true,
        ),
      );

      tester.semantics.decrease(readout);
      await tester.pump();
      tester.semantics.decrease(readout);
      await tester.pump();
      expect(
        readout.evaluate().single.value,
        '12:08:50\u202fPM, Receive 1.5 MiB/s, Transmit 256 KiB/s',
      );
      // The series summaries stay as they were.
      expect(
        find.semantics.byLabel(
          'Transmit: now unknown, lowest 256 KiB/s, highest 256 KiB/s, steady',
        ),
        findsOne,
      );
      semantics.dispose();
    });

    testWidgets('puts the readout beside the rule, not over it', (
      tester,
    ) async {
      await tester.pumpWidget(_chart(_network()));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      for (final second in [10, 300, 530]) {
        final point = _onPlot(tester, second);
        await mouse.moveTo(point);
        await tester.pump();
        final rule = _onPlot(tester, second).dx;
        final box = _readoutRect(tester);
        expect(
          box.right <= rule || box.left >= rule,
          isTrue,
          reason: '$box covers the rule at $rule',
        );
        expect(
          tester.getRect(find.byType(TimeSeriesChart)).contains(box.center),
          isTrue,
        );
      }
      // Near the right edge it goes before the rule.
      expect(_readoutRect(tester).right, lessThan(_onPlot(tester, 530).dx));
    });

    for (final scale in [2.0, 3.0]) {
      for (final width in [400.0, 120.0]) {
        testWidgets('fits the chart at ${scale}x text, ${width.round()} wide', (
          tester,
        ) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(_chart(_network(), width: width));
          // At triple text the value labels can take a narrow chart's whole
          // width; with no plot there is nothing to point at.
          final plot = _painterOf(tester).plotRectFor(tester.getSize(_plot));
          if (plot.width <= 0) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(_crosshairOf(tester)?.hit, isNotNull);
            return;
          }
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          for (final second in [10, 180, 300, 530]) {
            await mouse.moveTo(_onPlot(tester, second));
            await tester.pump();
            expect(tester.takeException(), isNull);
            final chart = tester.getRect(find.byType(TimeSeriesChart));
            final box = _readoutRect(tester);
            expect(box.left, greaterThanOrEqualTo(chart.left - 0.01));
            expect(box.right, lessThanOrEqualTo(chart.right + 0.01));
            expect(box.top, greaterThanOrEqualTo(chart.top - 0.01));
            expect(box.bottom, lessThanOrEqualTo(chart.bottom + 0.01));
          }
        });
      }
    }

    test('repaints when the chart or the hit changes', () {
      final ring = TimeSeriesRing(capacity: 2, lanes: 1);
      addTearDown(ring.dispose);
      TimeSeriesPainter chart() => TimeSeriesPainter(
        data: ring,
        version: ring.version,
        from: 0,
        to: 10,
        scaleMax: 100,
        unit: ChartUnit.percent,
        strings: testChartStrings,
        colors: const [Colors.blue],
        gaps: const [],
        summaries: const [],
        textStyle: const TextStyle(fontSize: 11, color: Colors.black),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
        background: Colors.white,
      );
      final base = chart();
      final painter = TimeSeriesCrosshairPainter(
        chart: base,
        hit: const TimeSeriesSampleHit(0, 4),
        ink: Colors.black,
      );
      bool repaints(TimeSeriesCrosshairPainter next) =>
          next.shouldRepaint(painter);
      expect(
        repaints(
          TimeSeriesCrosshairPainter(
            chart: base,
            hit: const TimeSeriesSampleHit(0, 4),
            ink: Colors.black,
          ),
        ),
        isFalse,
      );
      expect(
        repaints(
          TimeSeriesCrosshairPainter(
            chart: base,
            hit: const TimeSeriesSampleHit(1, 5),
            ink: Colors.black,
          ),
        ),
        isTrue,
      );
      expect(
        repaints(
          TimeSeriesCrosshairPainter(
            chart: chart(),
            hit: const TimeSeriesSampleHit(0, 4),
            ink: Colors.black,
          ),
        ),
        isTrue,
      );
      expect(
        repaints(
          TimeSeriesCrosshairPainter(
            chart: base,
            hit: const TimeSeriesSampleHit(0, 4),
            ink: Colors.red,
          ),
        ),
        isTrue,
      );
    });
  });

  group('thresholds', () {
    const levels = ChartThresholds(warning: 80, critical: 90);

    testWidgets('draws the bands and names each level', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        chartFrame(
          SizedBox(
            width: 400,
            height: 200,
            child: TimeSeriesChart(
              data: _network(),
              labels: const ['Receive', 'Transmit'],
              unit: ChartUnit.percent,
              strings: testChartStrings,
              source: '',
              end: _end,
              thresholds: levels,
            ),
          ),
        ),
      );
      final painter = _painterOf(tester);
      final palette = ChartPalette.of(tester.element(_plot));
      expect(painter.warningBand, (from: 80.0, color: palette.warning));
      expect(painter.criticalBand, (from: 90.0, color: palette.critical));

      final size = tester.getSize(_plot);
      final plot = painter.plotRectFor(size);
      final canvas = TestRecordingCanvas();
      painter.paint(canvas, size);
      Rect? rule(Color color) => [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawRect &&
              (call.invocation.positionalArguments[1] as Paint).color
                      .toARGB32() ==
                  color.toARGB32())
            call.invocation.positionalArguments.first as Rect,
      ].singleOrNull;
      expect(
        rule(palette.warning)!.bottom,
        closeTo(painter.yOf(plot, 80), 0.01),
      );
      expect(
        rule(palette.critical)!.bottom,
        closeTo(painter.yOf(plot, 90), 0.01),
      );
      expect(
        rule(palette.critical.withValues(alpha: thresholdBandAlpha))!.top,
        plot.top,
      );

      expect(find.text('warning 80%'), findsOneWidget);
      expect(find.text('critical 90%'), findsOneWidget);
      expect(find.semantics.byLabel('warning 80%, critical 90%'), findsOne);
      semantics.dispose();
    });

    testWidgets('leaves out a level above the scale', (tester) async {
      await tester.pumpWidget(
        _chart(
          _network(),
          max: 2 * _mebibyte,
          thresholds: ChartThresholds(
            warning: _mebibyte,
            critical: 4 * _mebibyte,
          ),
        ),
      );
      expect(find.text('warning 1 MiB/s'), findsOneWidget);
      expect(find.textContaining('critical'), findsNothing);
    });

    test('repaints on a band change', () {
      final ring = TimeSeriesRing(capacity: 2, lanes: 1);
      addTearDown(ring.dispose);
      TimeSeriesPainter painter({ThresholdBand? warning, String? words}) =>
          TimeSeriesPainter(
            data: ring,
            version: ring.version,
            from: 0,
            to: 10,
            scaleMax: 100,
            unit: ChartUnit.percent,
            strings: testChartStrings,
            colors: const [Colors.blue],
            gaps: const [],
            summaries: const [],
            textStyle: const TextStyle(fontSize: 11, color: Colors.black),
            textScaler: TextScaler.noScaling,
            textDirection: TextDirection.ltr,
            background: Colors.white,
            warningBand: warning,
            thresholdSummary: words,
          );
      final none = painter();
      expect(painter().shouldRepaint(none), isFalse);
      expect(
        painter(warning: (from: 80, color: Colors.amber)).shouldRepaint(none),
        isTrue,
      );
      expect(
        painter(words: 'warning 80%').shouldRebuildSemantics(none),
        isTrue,
      );
    });
  });

  testWidgets("marks each series' latest point with its own shape", (
    tester,
  ) async {
    await tester.pumpWidget(_chart(_network()));
    final painter = _painterOf(tester);
    final size = tester.getSize(_plot);
    final plot = painter.plotRectFor(size);
    final palette = ChartPalette.of(tester.element(_plot));
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, size);
    // Each marker is one filled path in its series' colour.
    List<Rect> marks(Color color) => [
      for (final call in canvas.invocations)
        if (call.invocation.memberName == #drawPath &&
            (call.invocation.positionalArguments[1] as Paint).style ==
                PaintingStyle.fill &&
            (call.invocation.positionalArguments[1] as Paint).color
                    .toARGB32() ==
                color.toARGB32())
          (call.invocation.positionalArguments.first as Path).getBounds(),
    ];
    final receive = marks(palette.series[0]).single;
    final transmit = marks(palette.series[1]).single;
    // Both at 12:08:50, the last sample before the open gap.
    final x = painter.xOf(plot, _at(530).microsecondsSinceEpoch);
    expect(receive.center.dx, closeTo(x, 0.01));
    expect(
      transmit.center.dy,
      closeTo(painter.yOf(plot, 0.25 * _mebibyte), 0.5),
    );
    // A circle and a square: their bounds differ in size.
    expect(receive.size, isNot(transmit.size));

    // A window with no known sample draws no marker.
    await tester.pumpWidget(
      _chart(_network(), end: _end.add(const Duration(minutes: 20))),
    );
    final empty = TestRecordingCanvas();
    _painterOf(tester).paint(empty, size);
    expect(
      empty.invocations.where(
        (call) =>
            call.invocation.memberName == #drawPath &&
            (call.invocation.positionalArguments[1] as Paint).style ==
                PaintingStyle.fill,
      ),
      isEmpty,
    );
  });
}
