import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/time_series_chart.dart'
    show TimeSeriesPainter, firstTimeSeriesTick;

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

Widget _chart(TimeSeriesRing ring, {DateTime? end, double? max}) => chartFrame(
  SizedBox(
    width: 400,
    height: 200,
    child: TimeSeriesChart(
      data: ring,
      labels: const ['Receive', 'Transmit'],
      unit: ChartUnit.bytesPerSecond,
      strings: testChartStrings,
      source: 'Sampled by this device while connected',
      end: end ?? _end,
      max: max,
    ),
  ),
);

/// The contours of every path [painter] strokes in [color], as bounds. A
/// recorded paint keeps its colour as 8-bit channels, so the match is on
/// those.
List<Rect> _contours(TimeSeriesPainter painter, Size size, Color color) {
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, size);
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawPath &&
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
    // The open gap reaches the right edge.
    expect(
      bands.last.right,
      closeTo(size.width - TimeSeriesPainter.strokeWidth / 2, 0.01),
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

        for (final surface in [
          theme.colorScheme.surface,
          theme.colorScheme.surfaceContainerLow,
          theme.colorScheme.surfaceContainer,
          theme.colorScheme.surfaceContainerHigh,
          chrome.paneBackground,
          chrome.inspectorBackground,
          chrome.sidebarBackground,
        ]) {
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
                      end: _end,
                    ),
                  ),
                ),
              ),
            ),
          );
          final band = _bands(_painterOf(tester), tester.getSize(_plot)).single;
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
                expect(peak, greaterThanOrEqualTo(3), reason: '$surface');
                strokes++;
              }
              start = -1;
              peak = 0;
            }
          }
          expect(strokes, greaterThan(100), reason: '$surface');
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
}
