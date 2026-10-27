import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/charts/bars.dart'
    show BarFill, BarPainter, BarRun;
import 'package:klabautermann_app/ui/charts/charts.dart';

import '../support/charts.dart';

const _gib = 1024.0 * 1024 * 1024;
const _thresholds = ChartThresholds(careful: 70, warning: 80, critical: 90);

final _palette = ChartPalette.fromTheme(chartTheme(Brightness.light));

Widget _memory({
  double? used = 6 * _gib,
  double? buffers = 0.5 * _gib,
  double? cache = 3 * _gib,
  double? total = 16 * _gib,
  ChartThresholds? thresholds,
  bool stale = false,
}) => chartFrame(
  SizedBox(
    width: 200,
    child: StackedBar(
      label: 'Memory',
      segments: [
        BarSegment(label: 'Used', value: used),
        BarSegment(label: 'Buffers', value: buffers),
        BarSegment(label: 'Cache', value: cache),
      ],
      total: total,
      unit: ChartUnit.bytes,
      strings: testChartStrings,
      thresholds: thresholds,
      stale: stale,
    ),
  ),
);

Widget _pressure(List<PressureCell> cells, {bool stale = false}) => chartFrame(
  PressureBar(cells: cells, strings: testChartStrings, stale: stale),
);

List<PressureCell> _cells(
  double? cpu,
  double? memory,
  double? disk, {
  ChartThresholds? thresholds,
}) => [
  PressureCell(label: 'CPU', percent: cpu, thresholds: thresholds),
  PressureCell(label: 'Memory', percent: memory, thresholds: thresholds),
  PressureCell(label: 'Disk', percent: disk, thresholds: thresholds),
];

Finder _paintersIn(Type bar) => find.descendant(
  of: find.byType(bar),
  matching: find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is BarPainter,
  ),
);

/// The bar's own painter; a stacked bar's legend swatches follow it.
Finder _paintIn(Type bar) => _paintersIn(bar).first;

BarPainter _painter(WidgetTester tester, Finder paint) =>
    tester.widget<CustomPaint>(paint).painter! as BarPainter;

List<BarRun> _runsIn(WidgetTester tester, Type bar) =>
    _painter(tester, _paintIn(bar)).runs;

/// The colour and fill of each legend swatch of a stacked bar.
List<(Color, BarFill)> _swatchesIn(WidgetTester tester) => tester
    .widgetList<CustomPaint>(_paintersIn(StackedBar))
    .skip(1)
    .map((paint) => (paint.painter! as BarPainter).runs.single)
    .map((run) => (run.color, run.fill))
    .toList();

BarRun _fill(double start, double end, Color color, {int cell = 0}) =>
    (cell: cell, start: start, end: end, color: color, fill: BarFill.solid);

BarRun _hatched(double start, {int cell = 0}) => (
  cell: cell,
  start: start,
  end: 1,
  color: _palette.muted,
  fill: BarFill.unknown,
);

String _label(WidgetTester tester, Type bar) =>
    tester.getSemantics(find.byType(bar)).label;

/// 03 §10.7: the stacked and pressure bars' fills, unknown and stale
/// states, threshold colour with its icon and words (A11Y-01), and their
/// summaries (A11Y-02, A11Y-15).
void main() {
  group('StackedBar', () {
    testWidgets('stacks its segments in the series colours', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory());

      expect(_runsIn(tester, StackedBar), [
        _fill(0, 0.375, _palette.series[0]),
        _fill(0.375, 0.40625, _palette.series[1]),
        _fill(0.40625, 0.59375, _palette.series[2]),
      ]);
      // One summary, not a live region; the legend stays out of it.
      expect(
        tester.getSemantics(find.byType(StackedBar)),
        matchesSemantics(
          label: 'Memory: Used 6 GiB, Buffers 512 MiB, Cache 3 GiB of 16 GiB',
        ),
      );
      expect(find.text('Buffers 512 MiB'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('cuts segments that overrun the total at its end', (
      tester,
    ) async {
      await tester.pumpWidget(_memory(cache: 12 * _gib));

      expect(
        _runsIn(tester, StackedBar).last,
        _fill(0.40625, 1, _palette.series[2]),
      );
    });

    for (final (used, severity, colour, icon) in [
      (10.0, null, _palette.series[0], null),
      (12.0, 'careful', _palette.series[0], Icons.info_rounded),
      (13.0, 'warning', _palette.warning, Icons.warning_rounded),
      (15.0, 'critical', _palette.critical, Icons.error_rounded),
    ]) {
      testWidgets('used at $used of 16 GiB reads ${severity ?? 'normal'}', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          _memory(
            used: used * _gib,
            cache: 0.5 * _gib,
            thresholds: _thresholds,
          ),
        );

        final firstRun = _runsIn(tester, StackedBar).first;
        expect(firstRun.color, colour);
        expect(
          firstRun.fill,
          severity == null || severity == 'careful'
              ? BarFill.solid
              : BarFill.severe,
        );
        final part = severity == null
            ? 'Used ${used.round()} GiB'
            : 'Used ${used.round()} GiB ($severity)';
        expect(find.text(part), findsOneWidget);
        expect(_label(tester, StackedBar), startsWith('Memory: $part, '));
        if (icon == null) {
          expect(find.byType(Icon), findsNothing);
        } else {
          expect(
            tester.widget<Icon>(find.byIcon(icon)).color,
            severity == 'careful' ? _palette.scaleText : colour,
          );
        }
        // The icon's slot is there either way, so the bar keeps its length.
        expect(tester.getSize(_paintIn(StackedBar)).width, 200 - 4 - 14);
        semantics.dispose();
      });
    }

    testWidgets('stripes a severe segment and its swatch', (tester) async {
      await tester.pumpWidget(
        _memory(used: 13 * _gib, cache: 0.5 * _gib, thresholds: _thresholds),
      );
      // Used is 13 of 16 GiB on a 200 - 4 - 14 = 182 px bar.
      const used = 182 * 13 / 16;
      const stripe = BarPainter.severeStripe;

      expect(
        _paintIn(StackedBar),
        paints
          ..rect(color: _palette.track)
          ..rect(
            rect: const Rect.fromLTRB(0, 0, used, 8),
            color: _palette.warning,
          )
          ..rect(
            rect: const Rect.fromLTRB(0, 4 - stripe / 2, used, 4 + stripe / 2),
            color: _palette.track,
          )
          ..rect(color: _palette.series[1]),
      );
      // The legend draws each swatch like its segment.
      expect(_swatchesIn(tester), [
        (_palette.warning, BarFill.severe),
        (_palette.series[1], BarFill.solid),
        (_palette.series[2], BarFill.solid),
      ]);
    });

    testWidgets('hatches what it cannot attribute, never a zero', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_memory(buffers: null));

      // Unknown buffers could be anywhere past the known segments.
      expect(_runsIn(tester, StackedBar), [
        _fill(0, 0.375, _palette.series[0]),
        _fill(0.375, 0.5625, _palette.series[2]),
        _hatched(0.5625),
      ]);
      // Its swatch is hatched like the bar, not in a colour the bar lacks.
      expect(_swatchesIn(tester), [
        (_palette.series[0], BarFill.solid),
        (_palette.muted, BarFill.unknown),
        (_palette.series[2], BarFill.solid),
      ]);
      expect(
        _label(tester, StackedBar),
        'Memory: Used 6 GiB, Buffers unknown, Cache 3 GiB of 16 GiB',
      );

      // A negative or infinite value is no reading either.
      for (final buffers in [-1.0, double.infinity]) {
        await tester.pumpWidget(_memory(buffers: buffers));
        expect(_runsIn(tester, StackedBar).last, _hatched(0.5625));
      }

      await tester.pumpWidget(_memory(total: null));
      expect(_runsIn(tester, StackedBar), [_hatched(0)]);
      expect(_label(tester, StackedBar), endsWith('of unknown'));

      await tester.pumpWidget(
        _memory(used: null, buffers: null, cache: null, total: null),
      );
      expect(_label(tester, StackedBar), 'Memory: unknown');
      semantics.dispose();
    });

    testWidgets('turns grey and claims no severity when stale', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _memory(used: 15 * _gib, thresholds: _thresholds, stale: true),
      );

      expect(
        _runsIn(tester, StackedBar).map((run) => run.color),
        everyElement(_palette.muted),
      );
      expect(find.byType(Icon), findsNothing);
      expect(
        _label(tester, StackedBar),
        'Memory: Used 15 GiB, Buffers 512 MiB, Cache 3 GiB of 16 GiB, stale',
      );
      semantics.dispose();
    });

    testWidgets('claims no severity against a zero total', (tester) async {
      await tester.pumpWidget(_memory(total: 0, thresholds: _thresholds));

      expect(_runsIn(tester, StackedBar), isEmpty);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('parts its runs by the track and hatches unknown', (
      tester,
    ) async {
      await tester.pumpWidget(
        chartFrame(
          SizedBox(
            width: 200,
            child: StackedBar(
              label: 'Disk',
              segments: const [
                BarSegment(label: 'Used', value: 50),
                BarSegment(label: 'Reserved', value: 25),
                BarSegment(label: 'Other', value: null),
              ],
              total: 100,
              unit: ChartUnit.bytes,
              strings: testChartStrings,
              showLegend: false,
            ),
          ),
        ),
      );
      const gap = BarPainter.runGap;

      expect(
        _paintIn(StackedBar),
        paints
          ..rect(rect: const Rect.fromLTWH(0, 0, 200, 8), color: _palette.track)
          ..rect(
            rect: const Rect.fromLTRB(0, 0, 100, 8),
            color: _palette.series[0],
          )
          ..rect(
            rect: const Rect.fromLTRB(100 + gap, 0, 150, 8),
            color: _palette.series[1],
          )
          ..path(
            color: _palette.muted,
            style: PaintingStyle.stroke,
            strokeWidth: BarPainter.hatchWidth,
          ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });

  group('PressureBar', () {
    testWidgets('fills each cell in its fixed colour', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_pressure(_cells(50, 75, 25)));

      expect(_runsIn(tester, PressureBar), [
        _fill(0, 0.5, _palette.series[0]),
        _fill(0, 0.75, _palette.series[1], cell: 1),
        _fill(0, 0.25, _palette.series[2], cell: 2),
      ]);
      expect(
        tester.getSemantics(find.byType(PressureBar)),
        // The tooltip stays out of the tree, so the summary is read once.
        matchesSemantics(label: 'CPU 50%, Memory 75%, Disk 25%', tooltip: ''),
      );
      semantics.dispose();
    });

    testWidgets('fills a cell to its share, a small one too', (tester) async {
      await tester.pumpWidget(_pressure(_cells(3, 0, 50)));
      // Cells are (46 - 2 * 2) / 3 = 14 px wide, and nothing follows a
      // fill, so no gap shortens it.
      const cell = 14.0;

      expect(
        _paintIn(PressureBar),
        paints
          ..rect(color: _palette.track)
          ..rect(
            rect: const Rect.fromLTRB(0, 0, 3 / 100 * cell, 6),
            color: _palette.series[0],
          )
          ..rect(color: _palette.track)
          ..rect(color: _palette.track)
          ..rect(
            rect: const Rect.fromLTRB(2 * (cell + 2), 0, 39, 6),
            color: _palette.series[2],
          ),
      );
    });

    testWidgets('shows severity by colour, stripe, icon and words', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _pressure(_cells(50, 92, 85, thresholds: _thresholds)),
      );

      expect(_runsIn(tester, PressureBar).map((run) => (run.color, run.fill)), [
        (_palette.series[0], BarFill.solid),
        (_palette.critical, BarFill.severe),
        (_palette.warning, BarFill.severe),
      ]);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
      const summary = 'CPU 50%, Memory 92% (critical), Disk 85% (warning)';
      expect(_label(tester, PressureBar), summary);
      // A host that folds the bar into its own node says the same words.
      expect(
        pressureSummary(
          _cells(50, 92, 85, thresholds: _thresholds),
          testChartStrings,
        ),
        summary,
      );
      // The tooltip shows the same words on hover, and leaves a touch
      // long-press to the row around the bar.
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, summary);
      expect(tooltip.triggerMode, TooltipTriggerMode.manual);
      semantics.dispose();
    });

    testWidgets('hatches an unknown share and greys stale values', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_pressure(_cells(null, 92, 0)));

      // An idle disk is an empty cell; an unknown CPU share is not.
      expect(_runsIn(tester, PressureBar), [
        _hatched(0),
        _fill(0, 0.92, _palette.series[1], cell: 1),
      ]);
      expect(_label(tester, PressureBar), 'CPU unknown, Memory 92%, Disk 0%');

      await tester.pumpWidget(
        _pressure(_cells(null, 92, 85, thresholds: _thresholds), stale: true),
      );
      expect(_runsIn(tester, PressureBar), [
        _hatched(0),
        _fill(0, 0.92, _palette.muted, cell: 1),
        _fill(0, 0.85, _palette.muted, cell: 2),
      ]);
      expect(find.byType(Icon), findsNothing);
      expect(
        _label(tester, PressureBar),
        'CPU unknown, Memory 92%, Disk 85%, stale',
      );
      semantics.dispose();
    });

    testWidgets('keeps its size whatever it shows', (tester) async {
      Future<Size> sizeOf(
        List<PressureCell> cells, {
        bool stale = false,
      }) async {
        await tester.pumpWidget(_pressure(cells, stale: stale));
        return tester.getSize(find.byType(PressureBar));
      }

      final normal = await sizeOf(_cells(10, 20, 30, thresholds: _thresholds));
      expect(normal, const Size(46 + 4 + 14, 14));
      for (final size in [
        await sizeOf(_cells(95, 85, 30, thresholds: _thresholds)),
        await sizeOf(_cells(null, null, null, thresholds: _thresholds)),
        await sizeOf(_cells(95, 20, 30, thresholds: _thresholds), stale: true),
      ]) {
        expect(size, normal);
      }
    });
  });

  test('a value at a threshold has its severity', () {
    expect(_thresholds.severityOf(69.9), ChartSeverity.normal);
    expect(_thresholds.severityOf(70), ChartSeverity.careful);
    expect(_thresholds.severityOf(79.9), ChartSeverity.careful);
    expect(_thresholds.severityOf(80), ChartSeverity.warning);
    expect(_thresholds.severityOf(89.9), ChartSeverity.warning);
    expect(_thresholds.severityOf(90), ChartSeverity.critical);
  });

  test('the painter keeps a sliver of a run narrower than the gap', () {
    final painter = BarPainter(
      cellCount: 1,
      runs: [
        _fill(0, 0.5, _palette.series[0]),
        _fill(0.5, 0.504, _palette.series[1]),
      ],
      trackColor: _palette.track,
    );

    // The second run is 0.8 px wide: it gives up half of it to the gap
    // rather than vanishing, as small buffers on a wide memory bar did.
    expect(
      (Canvas canvas) => painter.paint(canvas, const Size(200, 8)),
      paints
        ..rect(color: _palette.track)
        ..rect(
          rect: const Rect.fromLTRB(0, 0, 100, 8),
          color: _palette.series[0],
        )
        ..rect(
          rect: const Rect.fromLTRB(100.4, 0, 100.8, 8),
          color: _palette.series[1],
        ),
    );
  });

  test('the painter repaints when what it draws changes', () {
    BarPainter painter({
      int cellCount = 1,
      double end = 0.5,
      Color? trackColor,
    }) => BarPainter(
      cellCount: cellCount,
      runs: [_fill(0, end, _palette.series[0])],
      trackColor: trackColor ?? _palette.track,
    );
    final old = painter();

    // Equal runs in a new list, as every rebuild makes them.
    expect(painter().shouldRepaint(old), isFalse);
    expect(painter(end: 0.6).shouldRepaint(old), isTrue);
    expect(painter(cellCount: 2).shouldRepaint(old), isTrue);
    expect(painter(trackColor: _palette.muted).shouldRepaint(old), isTrue);
  });
}
