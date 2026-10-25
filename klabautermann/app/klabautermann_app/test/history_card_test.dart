// The Overview's History card (HIS-01, 03 §7.20): on-device rollups read
// from the engine per tier, charted with each gap a labelled band (Y4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/history_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/history_card.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/history.dart';

const _server = 'srv-1';

void main() {
  group('historyRing', () {
    test('ticks sit mid-bucket with the mean and peak, and each gap takes '
        'the cause the engine recorded or else the app being closed', () {
      final ring = historyRing(
        historySample(),
        HistoryTier.minute,
        AlertMetric.cpuBusy,
        now: historyNow,
      );

      expect(ring.length, 33 * 60);
      expect(
        ring.microsAt(0),
        historyAt(0).add(const Duration(seconds: 30)).microsecondsSinceEpoch,
      );
      expect((ring.valueAt(0, 0), ring.valueAt(1, 0)), (30, 40));

      DateTime hour(int h) => historyAt(h * 60);
      DateTime tick(int h) => hour(h).add(const Duration(seconds: 30));
      expect(
        [
          for (final gap in ring.gaps)
            (gap.start.toUtc(), gap.end?.toUtc(), gap.reason),
        ],
        [
          (hour(10), tick(14), ChartGapReason.disconnected),
          (hour(22), tick(26), ChartGapReason.background),
          (hour(34), tick(38), ChartGapReason.appClosed),
          (hour(44), tick(45), ChartGapReason.readingFailed),
          // The run ended two hours before the read, so its gap stays open
          // to the chart's edge.
          (hour(46), null, ChartGapReason.appClosed),
        ],
      );
    });

    test('a metric the buckets lack charts as unknown, and a run that '
        'reaches the read leaves no gap open', () {
      final range = HistoryRange(
        buckets: [historyBucket(0, 20), historyBucket(1, 25)],
        gaps: const [],
      );
      final ring = historyRing(
        range,
        HistoryTier.minute,
        AlertMetric.memoryUsed,
        now: historyAt(2).add(const Duration(seconds: 50)),
      );

      expect(ring.length, 2);
      expect(ring.valueAt(0, 1), isNull);
      expect(ring.gaps, isEmpty);
    });
  });

  group('HistoryCard', () {
    late FakeEngineClient engine;
    late HistoryReads reads;

    setUp(() {
      engine = FakeEngineClient();
      reads = HistoryReads(engine);
    });

    tearDown(() async {
      reads.dispose();
      await engine.close();
    });

    Future<void> pumpCard(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: HistoryCard(
              reads: reads,
              serverId: _server,
              now: () => historyNow,
            ),
          ),
        ),
      ),
    );

    Future<void> answer(WidgetTester tester, HistoryRange range) async {
      final request = engine.sentOfType<ReadHistory>().last as ReadHistory;
      engine.emit(
        HistoryRead(
          requestId: request.requestId,
          serverId: request.serverId,
          tier: request.tier,
          range: range,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('it reads the last 48 hours when it shows, and says so '
        'when nothing is recorded yet', (tester) async {
      await pumpCard(tester);
      final first = engine.sentOfType<ReadHistory>().single as ReadHistory;
      expect((first.serverId, first.tier), (_server, HistoryTier.minute));
      expect(find.byType(TimeSeriesChart), findsNothing);

      await answer(tester, const HistoryRange(buckets: [], gaps: []));
      expect(find.textContaining('No history yet.'), findsOneWidget);
    });

    testWidgets('picking 30 days or refreshing reads again, picking a '
        'metric does not, and the chart shows what was read', (tester) async {
      await pumpCard(tester);
      await answer(tester, historySample());
      expect(find.byType(TimeSeriesChart), findsOneWidget);

      // Another metric charts the same read again.
      await tester.tap(find.text('Memory used'));
      await tester.pumpAndSettle();
      expect(engine.sentOfType<ReadHistory>(), hasLength(1));
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Memory used'))
            .selected,
        isTrue,
      );

      await tester.tap(find.text('Last 30 days'));
      await tester.pumpAndSettle();
      final ten = engine.sentOfType<ReadHistory>().last as ReadHistory;
      expect(ten.tier, HistoryTier.tenMinutes);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(engine.sentOfType<ReadHistory>(), hasLength(3));
    });

    testWidgets('a slow answer for an earlier read never replaces a later '
        'one', (tester) async {
      await pumpCard(tester);
      final stale = engine.sentOfType<ReadHistory>().single as ReadHistory;
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();

      await answer(tester, historySample());
      engine.emit(
        HistoryRead(
          requestId: stale.requestId,
          serverId: _server,
          tier: HistoryTier.minute,
          range: const HistoryRange(buckets: [], gaps: []),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TimeSeriesChart), findsOneWidget);
      expect(find.textContaining('No history yet.'), findsNothing);
    });

    testWidgets('a stopped engine answers with nothing recorded', (
      tester,
    ) async {
      await pumpCard(tester);
      await engine.close();
      await tester.pumpAndSettle();
      expect(find.textContaining('No history yet.'), findsOneWidget);
      expect(
        await reads.read(_server, HistoryTier.tenMinutes),
        isA<HistoryRange>().having((r) => r.buckets, 'buckets', isEmpty),
      );
    });
  });
}
