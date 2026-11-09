// 03 §10.7's radial gauge and core heatmap: their summaries, words and
// marks for each state, and what their painters draw.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/bars.dart' show BarFill;
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/core_heatmap.dart'
    show CoreCellPainter;
import 'package:klabautermann_app/ui/charts/gauge.dart' show GaugePainter;

import '../support/charts.dart';

const _gib = 1024.0 * 1024 * 1024;
const _thresholds = ChartThresholds(careful: 70, warning: 80, critical: 90);

final _palette = ChartPalette.fromTheme(chartTheme(Brightness.light));

Widget _memory({
  double? used = 6 * _gib,
  double? total = 16 * _gib,
  ChartThresholds? thresholds = _thresholds,
  bool stale = false,
}) => chartFrame(
  Gauge(
    label: 'Memory',
    part: 'Used',
    value: used,
    total: total,
    unit: ChartUnit.bytes,
    strings: testChartStrings,
    thresholds: thresholds,
    stale: stale,
  ),
);

GaugePainter _gaugePainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(Gauge),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as GaugePainter;

String? _label(WidgetTester tester, Type type) =>
    tester.getSemantics(find.byType(type)).label;

void main() {
  group('Gauge', () {
    testWidgets('names the value, its share and the total', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory());

      expect(_label(tester, Gauge), 'Memory: Used 6 GiB of 16 GiB');
      expect(find.text('38%'), findsOneWidget);
      expect(find.text('Used 6 GiB'), findsOneWidget);
      final painter = _gaugePainter(tester);
      expect(painter.share, closeTo(6 / 16, 1e-9));
      expect(painter.color, _palette.series.first);
      expect(painter.fill, BarFill.solid);
      expect(painter.ticks.map((tick) => tick.at), [0.8, 0.9]);
      semantics.dispose();
    });

    testWidgets('past a level it takes the colour, a stripe, an icon and '
        'words (A11Y-01)', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory(used: 15 * _gib));

      expect(_label(tester, Gauge), 'Memory: Used 15 GiB (critical) of 16 GiB');
      expect(find.text('Used 15 GiB (critical)'), findsOneWidget);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
      final painter = _gaugePainter(tester);
      expect(painter.color, _palette.critical);
      expect(painter.fill, BarFill.severe);

      await tester.pumpWidget(_memory(used: 13 * _gib));
      expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
      expect(_gaugePainter(tester).color, _palette.warning);

      // Careful keeps the series colour and says so by an icon and words.
      await tester.pumpWidget(_memory(used: 12 * _gib));
      expect(find.byIcon(Icons.info_rounded), findsOneWidget);
      expect(_gaugePainter(tester).color, _palette.series.first);
      expect(_gaugePainter(tester).fill, BarFill.solid);
      semantics.dispose();
    });

    testWidgets('an unknown value hatches the arc, never zero (03 §10.4)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory(used: null));
      expect(_label(tester, Gauge), 'Memory: Used unknown of 16 GiB');
      expect(find.text('unknown'), findsOneWidget);
      expect(_gaugePainter(tester).share, isNull);

      await tester.pumpWidget(_memory(used: null, total: null));
      expect(_label(tester, Gauge), 'Memory: unknown');
      semantics.dispose();
    });

    testWidgets('stale values turn grey and carry no severity (OV-04)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory(used: 15 * _gib, stale: true));

      expect(_label(tester, Gauge), 'Memory: Used 15 GiB of 16 GiB, stale');
      expect(_gaugePainter(tester).color, _palette.muted);
      expect(_gaugePainter(tester).fill, BarFill.solid);
      expect(find.byIcon(Icons.error_rounded), findsNothing);
      semantics.dispose();
    });

    testWidgets('fits 200 % text without overflowing', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _memory(used: 15 * _gib),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    test('the painter draws the track, the fill and its stripe', () {
      GaugePainter painter({double? share, BarFill fill = BarFill.solid}) =>
          GaugePainter(
            share: share,
            color: _palette.critical,
            fill: fill,
            trackColor: _palette.track,
            unknownColor: _palette.muted,
            ticks: [(at: 0.9, color: _palette.critical)],
          );

      void Function(Canvas) drawn(GaugePainter painter) =>
          (canvas) => painter.paint(canvas, const Size(72, 72));
      expect(
        drawn(painter(share: 0.5, fill: BarFill.severe)),
        paints
          ..arc(color: _palette.track)
          ..arc(color: _palette.critical)
          ..arc(color: _palette.track, strokeWidth: GaugePainter.severeStripe)
          ..line(color: _palette.critical),
      );
      // Unknown: marks across the track instead of a fill.
      expect(
        drawn(painter()),
        paints
          ..arc(color: _palette.track)
          ..line(color: _palette.muted),
      );
      expect(painter().shouldRepaint(painter()), isFalse);
      expect(painter(share: 0.5).shouldRepaint(painter()), isTrue);
    });
  });

  group('CoreHeatmap', () {
    Widget heatmap(List<(String, double?)> cores, {bool stale = false}) =>
        chartFrame(
          SizedBox(
            width: 200,
            child: CoreHeatmap(
              label: 'Per core',
              cores: cores,
              strings: testChartStrings,
              stale: stale,
            ),
          ),
        );

    List<CoreCellPainter> cells(WidgetTester tester) => [
      for (final paint in tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(CoreHeatmap),
          matching: find.byType(CustomPaint),
        ),
      ))
        paint.painter! as CoreCellPainter,
    ];

    testWidgets('summarises the cores and names each in its tooltip', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        heatmap(const [('cpu0', 10), ('cpu1', 90), ('cpu2', null)]),
      );

      expect(
        _label(tester, CoreHeatmap),
        'Per core: 3 cores, average 50%, busiest cpu1 90%',
      );
      expect(
        [
          for (final tooltip in tester.widgetList<Tooltip>(
            find.byType(Tooltip),
          ))
            tooltip.message,
        ],
        ['cpu0 10%', 'cpu1 90%', 'cpu2 unknown'],
      );
      expect(cells(tester).map((cell) => cell.share), [0.1, 0.9, null]);
      expect(
        cells(tester).every((cell) => cell.color == _palette.series.first),
        isTrue,
      );
      semantics.dispose();
    });

    testWidgets('unknown and stale cores', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(heatmap(const [('cpu0', null), ('cpu1', null)]));
      expect(_label(tester, CoreHeatmap), 'Per core: unknown');

      await tester.pumpWidget(
        heatmap(const [('cpu0', 10), ('cpu1', 90)], stale: true),
      );
      expect(
        _label(tester, CoreHeatmap),
        'Per core: 2 cores, average 50%, busiest cpu1 90%, stale',
      );
      expect(
        cells(tester).every((cell) => cell.color == _palette.muted),
        isTrue,
      );
      semantics.dispose();
    });

    test('a cell fills from the bottom, or hatches when unknown', () {
      CoreCellPainter cell(double? share) => CoreCellPainter(
        share: share,
        color: _palette.series.first,
        trackColor: _palette.track,
        unknownColor: _palette.muted,
      );

      void Function(Canvas) drawn(CoreCellPainter cell) =>
          (canvas) => cell.paint(canvas, const Size(14, 14));
      expect(
        drawn(cell(0.25)),
        paints
          ..rect(color: _palette.track)
          ..rect(
            rect: const Rect.fromLTRB(0, 10.5, 14, 14),
            color: _palette.series.first,
          ),
      );
      expect(
        drawn(cell(null)),
        paints
          ..rect(color: _palette.track)
          ..path(color: _palette.muted),
      );
      expect(cell(0.25).shouldRepaint(cell(0.25)), isFalse);
      expect(cell(0.5).shouldRepaint(cell(0.25)), isTrue);
    });
  });

  test('a load average scales from 1 and reads to two decimals', () {
    expect(chartScaleMax(null, ChartUnit.decimal), 1);
    expect(chartScaleMax(0.3, ChartUnit.decimal), 1);
    expect(chartScaleMax(1.2, ChartUnit.decimal), 2);
    expect(chartScaleMax(7, ChartUnit.decimal), 10);
    expect(formatChartValue(0.5, ChartUnit.decimal, testChartStrings), '0.50');
  });
}
