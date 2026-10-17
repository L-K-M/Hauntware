import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/chart_strings.dart';
import 'package:klabautermann_app/ui/charts/charts.dart'
    show TimeSeriesChart, chartGapText;
import 'package:klabautermann_app/ui/server_coverage.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show
        chartTheme,
        goldenFontFamily,
        goldensCompareHere,
        loadChartDateFormats,
        loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _serverId = 'srv-1';
const _phone = Size(390, 844);

/// When the card's clock says it is; local, like the engine's stamps.
final _start = DateTime(2026, 10, 16, 12, 10);

UnitsResult _units(Map<String, String> active) => UnitsResult(
  UnitsSnapshot(
    units: [
      for (final MapEntry(key: unit, value: state) in active.entries)
        SystemdUnit(unit: unit, load: 'loaded', active: state, sub: state),
    ],
    format: UnitListFormat.json,
  ),
);

CoreResult _cpu(double busy) => CoreResult(cpu: CpuPercentages(const [], busy));

final class _Card {
  _Card(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;
  DateTime now = _start;
  int _seq = 0;

  void sample(SampleStream stream, SampleResult result, {DateTime? at}) =>
      engine.emit(
        Sample(
          serverId: _serverId,
          stream: stream,
          seq: ++_seq,
          at: at ?? now,
          result: result,
        ),
      );

  void phase(SamplingPhase phase, DateTime since) => engine.emit(
    SamplingState(serverId: _serverId, phase: phase, since: since),
  );

  /// The card's `units` subscription requests, in order.
  List<EngineRequest> get unitsReads => [
    for (final request in engine.sent)
      if (request case Subscribe(
        streams: final streams,
      ) when streams.contains(SampleStream.units))
        request
      else if (request is Unsubscribe)
        request,
  ];
}

Future<_Card> _pumpCard(
  WidgetTester tester, {
  Size size = _phone,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool visible = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final shown = ValueNotifier(visible);
  final card = _Card(engine, shown);
  final monitoring = MonitoringController(engine, now: () => card.now);
  addTearDown(() async {
    shown.dispose();
    monitoring.dispose();
    await engine.close();
  });

  final theme = chartTheme(brightness, fontFamily: goldenFontFamily);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder(
              valueListenable: shown,
              builder: (context, visible, _) => ServerCoverageCard(
                monitoring: monitoring,
                serverId: _serverId,
                visible: visible,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return card;
}

/// 03 §9.5 items 3, 5 and 6: a server's coverage card and inspector
/// section, the session chart's labelled gaps and the phone's return
/// banner.
void main() {
  setUpAll(() async {
    await loadChartDateFormats();
    if (goldensCompareHere) await loadGoldenFonts();
  });

  test('the external-monitor line says what K04\'s rule found, or why it '
      'cannot tell', () {
    final l10n = AppLocalizationsEn();
    Sample units(SampleResult result) => Sample(
      serverId: _serverId,
      stream: SampleStream.units,
      seq: 1,
      at: _start,
      result: result,
    );
    String line(SampleResult? latest, [SampleResult? reading]) =>
        externalMonitorLine(
          l10n,
          latest: latest == null ? null : units(latest),
          reading: reading == null ? null : units(reading),
        ).$2;
    const failed = CollectorUnavailable(CollectorUnavailableReason.denied);

    expect(
      line(null),
      'Looking for an external monitor among this server\'s systemd '
      'services.',
    );
    const unknown =
        'Klabautermann cannot tell whether an external monitor runs: this '
        'server\'s systemd services could not be listed.';
    expect(line(failed), unknown);
    // An empty list means systemctl failed behind its header (K04).
    expect(line(_units({}), _units({})), unknown);

    final running = _units({
      'netdata.service': 'active',
      'telegraf.service': 'inactive',
      'alloy.service': 'active',
    });
    // A failed later list keeps the last one that loaded.
    expect(
      line(failed, running),
      'External monitor running: netdata.service, alloy.service. It may '
      'cover this server while Klabautermann is closed; Klabautermann does '
      'not read it.',
    );
    final stopped = _units({'telegraf.service': 'failed'});
    expect(
      line(stopped, stopped),
      'No external monitor is running. Installed but stopped: '
      'telegraf.service.',
    );
    final none = _units({'ssh.service': 'active'});
    expect(
      line(none, none),
      'No external monitor found among this server\'s systemd services.',
    );
  });

  testWidgets('the card shows the T0 badge and live reading, and reads the '
      'units list once while it shows', (tester) async {
    final card = await _pumpCard(tester);
    expect(find.text('T0'), findsOneWidget);
    expect(find.text('SSH while Klabautermann is open'), findsOneWidget);
    expect(
      find.text('Reads this server only while you have it open.'),
      findsOneWidget,
    );
    // No control offers a tier that does not exist yet.
    expect(find.byType(ButtonStyleButton), findsNothing);

    final [subscribe as Subscribe] = card.unitsReads;
    expect(subscribe.streams, {SampleStream.units});

    card.sample(SampleStream.units, _units({'netdata.service': 'active'}));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('External monitor running: netdata.service.'),
      findsOneWidget,
    );
    final [_, unsubscribe as Unsubscribe] = card.unitsReads;
    expect(unsubscribe.subscriptionId, subscribe.subscriptionId);

    card.phase(SamplingPhase.pausedInBackground, _start.toUtc());
    await tester.pumpAndSettle();
    expect(
      find.text('Paused while Klabautermann is in the background.'),
      findsOneWidget,
    );
  });

  testWidgets('the chart follows the clock only once it has data', (
    tester,
  ) async {
    final card = await _pumpCard(tester);
    DateTime end() =>
        tester.widget<TimeSeriesChart>(find.byType(TimeSeriesChart)).end;

    // Nothing to age, so nothing ticks (the clock's contract, K39a).
    card.now = _start.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(end(), _start);

    card.sample(SampleStream.core, _cpu(20));
    await tester.pump();
    card.now = _start.add(const Duration(seconds: 9));
    await tester.pump(const Duration(seconds: 1));
    expect(end(), card.now);
  });

  testWidgets('a failed units read is not retried this engine run', (
    tester,
  ) async {
    final card = await _pumpCard(tester);
    card.sample(
      SampleStream.units,
      const CollectorUnavailable(CollectorUnavailableReason.denied),
    );
    await tester.pumpAndSettle();
    expect(card.unitsReads, [isA<Subscribe>(), isA<Unsubscribe>()]);
    expect(find.textContaining('cannot tell'), findsOneWidget);
  });

  testWidgets('a hidden card reads nothing', (tester) async {
    final card = await _pumpCard(tester, visible: false);
    expect(card.unitsReads, isEmpty);

    card.visible.value = true;
    await tester.pumpAndSettle();
    expect(card.unitsReads, hasLength(1));
  });

  testWidgets('the session chart labels a gap with why it has no data', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final card = await _pumpCard(tester);
    final second = const Duration(seconds: 1);
    card
      ..phase(SamplingPhase.sampling, _start.subtract(second * 60).toUtc())
      ..sample(SampleStream.core, _cpu(20), at: _start.subtract(second * 50))
      ..sample(SampleStream.core, _cpu(30), at: _start.subtract(second * 48))
      ..phase(
        SamplingPhase.waitingForLink,
        _start.subtract(second * 40).toUtc(),
      );
    await tester.pumpAndSettle();

    // The legend names the reason, the band reads it to screen readers.
    expect(find.text('disconnected'), findsOneWidget);
    expect(
      find.semantics.byLabel(RegExp(r'^No data since .*: disconnected$')),
      findsOne,
    );
    expect(
      find.text('Recorded by this device while connected'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('the desktop inspector shows the selected server\'s coverage', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers);
    expect(
      find.text(
        'Details, alerts, operations and coverage appear here once you '
        'select a server.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    expect(find.text('Recent gaps'), findsOneWidget);
    // Without a reading, no gap is not news that the record is complete.
    expect(find.text('No data yet'), findsOneWidget);
    expect(
      find.text('No pauses, lost links or failed readings.'),
      findsNothing,
    );
    expect(
      find.text('Reads this server only while you have it open.'),
      findsNWidgets(2),
    );
    // The inspector gives each gap in coverage its reason.
    expect(
      find.text(
        'Nothing checks your servers, so nothing can warn you about '
        'them.',
      ),
      findsOneWidget,
    );

    final now = DateTime.now();
    var seq = 0;
    void sample(DateTime at, [SampleResult? result]) => harness.engine.emit(
      Sample(
        serverId: _serverId,
        stream: SampleStream.core,
        seq: ++seq,
        at: at,
        result: result ?? _cpu(10),
      ),
    );
    sample(now.subtract(const Duration(seconds: 6)));
    sample(
      now.subtract(const Duration(seconds: 4)),
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );
    sample(now.subtract(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r': reading failed$')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Updated \d+ s ago$')), findsWidgets);
    expect(
      find.text('No pauses, lost links or failed readings.'),
      findsNothing,
    );
  });

  testWidgets('the inspector lists the newest gaps and counts the rest', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();

    // A collector failing every other reading, a minute apart, so each
    // gap has its own times.
    final start = DateTime.now().subtract(const Duration(minutes: 24));
    for (var i = 0; i < 24; i++) {
      harness.engine.emit(
        Sample(
          serverId: _serverId,
          stream: SampleStream.core,
          seq: i + 1,
          at: start.add(Duration(minutes: i)),
          result: i.isOdd
              ? const CollectorUnavailable(CollectorUnavailableReason.timeout)
              : _cpu(10),
        ),
      );
    }
    await tester.pumpAndSettle();

    final gaps = harness.monitoring
        .historyFor(_serverId, MetricSeries.cpuBusy)
        .gaps;
    expect(gaps, hasLength(12));
    final strings = klabautermannChartStrings(AppLocalizationsEn());
    expect(find.textContaining(RegExp(r': reading failed$')), findsNWidgets(5));
    expect(find.text(chartGapText(gaps.last, strings)), findsOne);
    expect(find.text(chartGapText(gaps[6], strings)), findsNothing);
    expect(find.text('7 earlier gaps not shown.'), findsOne);
  });

  testWidgets('the inspector lists only the gaps with a known cause', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    var seq = 0;
    Future<void> sample() async {
      harness.engine.emit(
        Sample(
          serverId: _serverId,
          stream: SampleStream.core,
          seq: ++seq,
          at: DateTime.now(),
          result: _cpu(10),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder tab(String label) =>
        find.descendant(of: find.byType(TabBar), matching: find.text(label));

    // While hidden, the Overview reads nothing: its line breaks there
    // with no cause to name.
    await sample();
    await tester.tap(tab('Logs'));
    await tester.pumpAndSettle();
    await tester.tap(tab('Overview'));
    await tester.pumpAndSettle();
    await sample();
    final history = harness.monitoring.historyFor(
      _serverId,
      MetricSeries.cpuBusy,
    );
    expect(history.valueAt(0, 1), isNull);
    expect(find.text('No pauses, lost links or failed readings.'), findsOne);
  });

  group('the return banner (03 §9.5 item 6)', () {
    const banner =
        r'^Paused .+ to .+ while in background\. No data for that period\.$';

    /// Sends the app to the background and back; resumed after the test.
    void awayAndBack(WidgetTester tester) {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    /// Opens web-1 on a phone of [size], has the engine say it samples
    /// it unless not [sampled], and sends the app away and back.
    Future<void> openAwayAndBack(
      WidgetTester tester, {
      Size size = _phone,
      bool sampled = true,
    }) async {
      final harness = await pumpApp(tester, size: size, servers: twoServers);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      if (sampled) {
        harness.engine.emit(
          SamplingState(
            serverId: _serverId,
            phase: SamplingPhase.sampling,
            since: DateTime.now().toUtc(),
          ),
        );
        await tester.pumpAndSettle();
      }
      awayAndBack(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('says a phone paused the open server until dismissed', (
      tester,
    ) async {
      await openAwayAndBack(tester);
      expect(find.textContaining(RegExp(banner)), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(banner)), findsNothing);
    });

    // A11Y-09: past its share of the screen the banner scrolls, so the
    // panel under it keeps its room on a small or landscape phone.
    for (final size in [_phone, const Size(360, 640), const Size(568, 320)]) {
      testWidgets('fits at 200 % text on a ${size.width.round()} x '
          '${size.height.round()} phone', (tester) async {
        await openAwayAndBack(tester, size: size);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(find.textContaining(RegExp(banner)), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('stays away while the engine sampled nothing', (tester) async {
      // An open server's subscription alone, as before its link is up.
      await openAwayAndBack(tester, sampled: false);
      expect(find.textContaining(RegExp(banner)), findsNothing);
    });

    testWidgets('tells only the screen open at the return', (tester) async {
      await openAwayAndBack(tester);
      expect(find.textContaining(RegExp(banner)), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('db-1'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(banner)), findsNothing);

      // Leaving the server's screen ended its banner.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(banner)), findsNothing);
    });

    testWidgets('gives the times to the second within one minute', (
      tester,
    ) async {
      final engine = FakeEngineClient();
      var now = _start;
      final monitoring = MonitoringController(
        engine,
        now: () => now,
        linkGrace: Duration.zero,
      );
      addTearDown(() async {
        monitoring.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                // Only the paused server's screen says so.
                for (final serverId in [_serverId, 'srv-2'])
                  BackgroundReturnBanner(
                    monitoring: monitoring,
                    serverId: serverId,
                  ),
              ],
            ),
          ),
        ),
      );
      monitoring.openServer(_serverId);
      engine.emit(
        SamplingState(
          serverId: _serverId,
          phase: SamplingPhase.sampling,
          since: _start.toUtc(),
        ),
      );
      await tester.pump();

      // "12:10:00 PM to 12:10:35 PM", then "12:10 PM to 12:24 PM".
      const seconds = r'^Paused \d+:\d\d:\d\d\D+ to \d+:\d\d:\d\d\D+ while';
      const minutes = r'^Paused \d+:\d\d\D+ to \d+:\d\d\D+ while';
      for (final (away, pattern) in [
        (const Duration(seconds: 35), seconds),
        (const Duration(minutes: 14), minutes),
      ]) {
        monitoring.setAppActivity(AppActivity.background);
        now = now.add(away);
        monitoring.setAppActivity(AppActivity.foreground);
        await tester.pump();
        expect(find.textContaining(RegExp(pattern)), findsOneWidget);
      }
      monitoring.leaveServer(_serverId);
    });

    testWidgets('heads a tablet\'s workspace, as a tablet pauses too', (
      tester,
    ) async {
      await openAwayAndBack(tester, size: const Size(1024, 768));
      expect(find.textContaining(RegExp(banner)), findsOneWidget);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('never shows on a desktop, which never pauses', (tester) async {
      // A narrow desktop window takes the phone's screens.
      await pumpApp(tester, size: _phone, servers: twoServers);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      awayAndBack(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(banner)), findsNothing);
    }, variant: TargetPlatformVariant.desktop());
  });

  for (final (name, size) in [
    ('phone', _phone),
    ('desktop', const Size(1280, 800)),
  ]) {
    testWidgets('lays out without overflow at 200 % text on the $name', (
      tester,
    ) async {
      final card = await _pumpCard(tester, size: size, textScale: 2);
      card
        ..sample(SampleStream.units, _units({'netdata.service': 'active'}))
        ..sample(SampleStream.core, _cpu(25));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the inspector lays out without overflow at 200 % text', (
    tester,
  ) async {
    await pumpApp(tester, servers: twoServers);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('golden', () {
    // 03 §11.1: a running monitor and a session with a background pause.
    for (final brightness in Brightness.values) {
      testWidgets('card, ${brightness.name}', (tester) async {
        final card = await _pumpCard(tester, brightness: brightness);
        card.sample(SampleStream.units, _units({'netdata.service': 'active'}));
        final from = _start.subtract(const Duration(minutes: 9));
        for (var second = 0; second < 540; second += 2) {
          final at = from.add(Duration(seconds: second));
          if (second == 200) {
            card.phase(SamplingPhase.pausedInBackground, at.toUtc());
          }
          if (second == 320) card.phase(SamplingPhase.sampling, at.toUtc());
          if (second >= 200 && second < 320) continue;
          card.sample(SampleStream.core, _cpu(30 + (second % 60) / 2), at: at);
        }
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(ServerCoverageCard),
          matchesGoldenFile('goldens/server_coverage_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
