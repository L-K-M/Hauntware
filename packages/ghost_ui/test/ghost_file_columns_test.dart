import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ghost_ui/src/ghost_file_columns.dart';
import 'package:ghost_ui/src/ghost_file_theme.dart';

const _theme = GhostFileTheme(
  paneBackground: Color(0xFF202020),
  separator: Color(0xFF303030),
  hoverFill: Color(0xFF404040),
  selectionFill: Color(0xFF0060C0),
  onSelection: Color(0xFFFFFFFF),
  inactiveSelectionFill: Color(0xFF383838),
  activePaneIndicator: Color(0xFF50A0F0),
  secondaryText: Color(0xFF909090),
);

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux, extensions: const [_theme]),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  group('GhostFileColumnMetrics', () {
    const scaler = TextScaler.linear(1);

    test('the Size column folds below the breakpoint', () {
      final wide = GhostFileColumnMetrics.forWidth(360, scaler);
      expect(wide.showsSize, isTrue);
      expect(wide.sizeWidth, 60);
      final narrow = GhostFileColumnMetrics.forWidth(359, scaler);
      expect(narrow.showsSize, isFalse);
      expect(narrow.sizeWidth, 0);
    });

    test('the breakpoint and widths scale with text scale', () {
      final metrics = GhostFileColumnMetrics.forWidth(
        719,
        const TextScaler.linear(2),
      );
      expect(metrics.showsSize, isFalse);
      expect(
        GhostFileColumnMetrics.forWidth(
          720,
          const TextScaler.linear(2),
        ).sizeWidth,
        120,
      );
    });

    test('the Modified column keeps its floor and its share cap', () {
      // No measured width → the 116 px floor.
      expect(GhostFileColumnMetrics.forWidth(800, scaler).modifiedWidth, 116);
      // A measured width inside the share window wins.
      expect(
        GhostFileColumnMetrics.forWidth(
          800,
          scaler,
          modifiedWidth: 200,
        ).modifiedWidth,
        200,
      );
      // …but never more than 35% of the pane beyond the floor.
      expect(
        GhostFileColumnMetrics.forWidth(
          400,
          scaler,
          modifiedWidth: 500,
        ).modifiedWidth,
        140, // max(116, 400 * 0.35)
      );
      // A narrow pane keeps at least the floor.
      expect(
        GhostFileColumnMetrics.forWidth(
          300,
          scaler,
          modifiedWidth: 500,
        ).modifiedWidth,
        116,
      );
    });

    test('trailing extent tracks the folded size column', () {
      final wide = GhostFileColumnMetrics.forWidth(800, scaler);
      expect(wide.trailingExtent, 12 + 60 + 12 + 116 + 10);
      final narrow = GhostFileColumnMetrics.forWidth(300, scaler);
      expect(narrow.trailingExtent, 12 + 116 + 10);
    });

    test('outlineInset reserves the disclosure column plus depth', () {
      expect(GhostFileColumnMetrics.outlineInset(outline: false, depth: 3), 0);
      expect(GhostFileColumnMetrics.outlineInset(outline: true, depth: 0), 16);
      expect(
        GhostFileColumnMetrics.outlineInset(outline: true, depth: 2),
        16 + 32,
      );
    });

    test('measured widths pass through inside the share window', () {
      final viaForWidth = GhostFileColumnMetrics.forWidth(
        double.infinity,
        scaler,
        modifiedWidth: 150,
      );
      expect(viaForWidth.modifiedWidth, 150);
      expect(viaForWidth.showsSize, isTrue);
    });

    testWidgets('the scope supplies metrics to descendants', (tester) async {
      final scoped = GhostFileColumnMetrics.forWidth(
        400,
        const TextScaler.linear(1),
      );
      late GhostFileColumnMetrics seen;
      await tester.pumpWidget(
        host(
          GhostFileColumnMetricsScope(
            metrics: scoped,
            child: Builder(
              builder: (context) {
                seen = GhostFileColumnMetrics.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(seen, same(scoped));
      // Outside a scope the full column set applies.
      late GhostFileColumnMetrics unscoped;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              unscoped = GhostFileColumnMetrics.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(unscoped.showsSize, isTrue);
    });
  });

  group('GhostFileColumnHeader', () {
    Widget header({
      GhostFileColumn sortColumn = GhostFileColumn.name,
      GhostFileSortDirection direction = GhostFileSortDirection.ascending,
      bool enabled = true,
      required ValueChanged<GhostFileColumn> onSort,
    }) => host(
      GhostFileColumnHeader(
        listId: 'list',
        sortColumn: sortColumn,
        sortDirection: direction,
        onSort: onSort,
        enabled: enabled,
      ),
    );

    testWidgets('renders Name | Size | Date Modified', (tester) async {
      await tester.pumpWidget(header(onSort: (_) {}));
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Size'), findsOneWidget);
      expect(find.text('Date Modified'), findsOneWidget);
    });

    testWidgets('tapping a cell reports its column', (tester) async {
      final taps = <GhostFileColumn>[];
      await tester.pumpWidget(header(onSort: taps.add));
      await tester.tap(find.byKey(const ValueKey('list.column.size')));
      await tester.tap(find.byKey(const ValueKey('list.column.modified')));
      expect(taps, [GhostFileColumn.size, GhostFileColumn.modified]);
    });

    testWidgets('the sorted column carries the chevron', (tester) async {
      await tester.pumpWidget(
        header(
          sortColumn: GhostFileColumn.size,
          direction: GhostFileSortDirection.descending,
          onSort: (_) {},
        ),
      );
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets('a disabled header ignores clicks', (tester) async {
      final taps = <GhostFileColumn>[];
      await tester.pumpWidget(header(enabled: false, onSort: taps.add));
      await tester.tap(find.byKey(const ValueKey('list.column.name')));
      expect(taps, isEmpty);
    });
  });
}
