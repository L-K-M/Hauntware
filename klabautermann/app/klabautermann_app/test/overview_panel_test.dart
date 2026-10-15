import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show StackedBar;
import 'package:klabautermann_app/ui/overview_panel.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_app/ui/system_panel.dart' show PanelSection;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show chartTheme, goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _serverId = 'srv-1';
const _mib = 1024 * 1024;
const _gib = 1024 * _mib;

const _wide = Size(900, 1000);
const _phone = Size(390, 1400);

/// When the panel's clock says it is; local, like the engine's stamps.
final _start = DateTime(2026, 10, 15, 14, 30);

const _memory = MemoryUsage(
  totalBytes: 16 * _gib,
  usedBytes: 6 * _gib,
  availableBytes: 10 * _gib,
  buffersBytes: 512 * _mib,
  cachedBytes: 4 * _gib,
  sharedBytes: 1536 * _mib,
  swapTotalBytes: 2 * _gib,
  swapUsedBytes: 256 * _mib,
  zfsArcCountedAsUsed: true,
);

/// A healthy reading: user 12 %, system 5 %, idle 80 %, iowait 3 %.
CoreResult _core({
  Map<String, double>? perCpu = const {
    'cpu1': 40,
    'cpu0': 12,
    'cpu3': 98,
    'cpu2': 3,
  },
  MemoryUsage? memory = _memory,
  Map<MetricField, MetricWithheldReason> withheld = const {},
}) => CoreResult(
  cpu: CpuPercentages(const [12, 0, 5, 80, 3, 0, 0, 0], 17),
  perCpu: perCpu,
  memory: memory,
  load: const LoadAvg(load1: 0.52, load5: 0.4, load15: 0.333),
  loadPerCore: 0.13,
  withheld: withheld,
);

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  /// What the monitoring clock reads.
  DateTime now = _start;
  int _seq = 0;

  Future<void> sample(
    WidgetTester tester,
    SampleResult result, {
    DateTime? at,
  }) async {
    engine.emit(
      Sample(
        serverId: _serverId,
        stream: SampleStream.core,
        seq: ++_seq,
        at: at ?? now,
        result: result,
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool visible = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final shown = ValueNotifier(visible);
  final panel = _Panel(engine, shown);
  final monitoring = MonitoringController(engine, now: () => panel.now);
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
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: ValueListenableBuilder(
                valueListenable: shown,
                builder: (context, visible, _) => OverviewPanel(
                  monitoring: monitoring,
                  serverId: _serverId,
                  visible: visible,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return panel;
}

Iterable<StackedBar> _bars(WidgetTester tester) =>
    tester.widgetList<StackedBar>(find.byType(StackedBar));

/// 03 §10.2's Overview tab, part one: OV-01's CPU, load, memory and swap,
/// OV-03's sparklines and gauges, and OV-04's staleness.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  test('cores keep the host\'s numeric order', () {
    expect(
      orderedCores({'cpu10': 1, 'cpu2': 2, 'cpu0': 3, 'cpu': 4, 'cpu1': 5}),
      [('cpu0', 3), ('cpu1', 5), ('cpu2', 2), ('cpu10', 1), ('cpu', 4)],
    );
    // The names are server data: a number past any integer orders after
    // the others rather than throwing in the CPU card's build.
    const huge = 'cpu99999999999999999999';
    expect(orderedCores({huge: 1, 'cpu10': 2, 'cpu': 3, 'cpu2': 4}), [
      ('cpu2', 4),
      ('cpu10', 2),
      ('cpu', 3),
      (huge, 1),
    ]);
  });

  for (final (name, size) in [
    ('desktop', const Size(1280, 1000)),
    ('phone', _phone),
  ]) {
    testWidgets('the $name Overview samples its streams while it shows', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers, size: size);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      final [overview] = harness.engine.sentOfType<Subscribe>();
      expect((overview as Subscribe).streams, ServerPanel.overview.streams);
      expect(find.text('Waiting for the first reading.'), findsOneWidget);

      harness.engine.emit(
        Sample(
          serverId: 'srv-1',
          stream: SampleStream.core,
          seq: 1,
          at: DateTime.now(),
          result: _core(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Waiting for the first reading.'), findsNothing);
      for (final title in ['CPU', 'Load', 'Memory', 'Swap']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });
  }

  testWidgets('OV-01 words CPU, load, memory and swap in IEC units', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, _core());

    // CPU-01, and CPU-02 as bars in host order.
    for (final text in ['12%', '5%', '80%', 'Busy 17%']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    final cores = [
      for (final bar in _bars(tester))
        if (bar.label.startsWith('cpu')) bar.label,
    ];
    expect(cores, ['cpu0', 'cpu1', 'cpu2', 'cpu3']);
    expect(find.bySemanticsLabel(RegExp(r'^cpu3\s+98%$')), findsOneWidget);

    // CPU-03 in the locale's number format, two decimals.
    for (final text in ['0.52', '0.40', '0.33', '0.13']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }

    // MEM-01 and MEM-02 in binary units, never decimal file sizes.
    for (final text in [
      'Used 6 GiB',
      '512 MiB',
      '4 GiB',
      '10 GiB',
      '1.5 GiB',
      'Used 256 MiB',
      'ZFS ARC counted as used',
      // The installed memory and the swap space, in sight and not only in
      // the bars' summaries.
      '16 GiB',
      '2 GiB',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('Total'), findsNWidgets(2));
    expect(find.textContaining('GB'), findsNothing);
    expect(find.textContaining('MB'), findsNothing);

    // CPU and memory warn as the fleet row's pressure bar does.
    final bars = {for (final bar in _bars(tester)) bar.label: bar};
    expect(bars['CPU']!.thresholds, isNotNull);
    expect(bars['Memory']!.thresholds, isNotNull);
    expect(bars['Swap']!.thresholds, isNull);
    expect(_bars(tester).any((bar) => bar.stale), isFalse);
    expect(find.text('Updated 0 s ago'), findsOneWidget);
  });

  testWidgets('MEM-01\'s bar never draws more than the memory taken', (
    tester,
  ) async {
    // Used is the total less MemAvailable, and the cache counts Cached,
    // which holds shared memory, also in used: 6 GiB in /dev/shm here.
    const memory = MemoryUsage(
      totalBytes: 16 * _gib,
      usedBytes: 10 * _gib,
      availableBytes: 6 * _gib,
      buffersBytes: 256 * _mib,
      cachedBytes: 8 * _gib,
      sharedBytes: 6 * _gib,
    );
    final panel = await _pump(tester);
    await panel.sample(tester, _core(memory: memory));

    final bar = _bars(tester).singleWhere((bar) => bar.label == 'Memory');
    final drawn = bar.segments.fold(
      0.0,
      (sum, segment) => sum + (segment.value ?? 0),
    );
    expect(
      drawn,
      lessThanOrEqualTo(memory.totalBytes! - memory.availableBytes!),
      reason: 'the bar\'s empty part is at least what is available',
    );
  });

  testWidgets('an unknown value reads unknown, never zero (03 §10.4)', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      CoreResult(memory: const MemoryUsage(totalBytes: 16 * _gib)),
    );

    expect(find.text('Unknown'), findsNWidgets(13));
    expect(find.text('0%'), findsNothing);
    expect(find.text('0.00'), findsNothing);
    expect(find.textContaining('0 B'), findsNothing);
    expect(find.text('No swap is set up.'), findsNothing);

    await panel.sample(
      tester,
      _core(memory: const MemoryUsage(swapTotalBytes: 0)),
    );
    expect(find.text('No swap is set up.'), findsOneWidget);
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets('a core name past two digits keeps to one line at '
        '${(textScale * 100).round()} % text', (tester) async {
      final panel = await _pump(tester, size: _phone, textScale: textScale);
      await panel.sample(
        tester,
        _core(
          perCpu: {
            for (var core = 0; core <= 101; core++) 'cpu$core': 7,
            // No kernel prints it: cut rather than overflow the card.
            'cpu99999999999999999999': 7,
          },
        ),
      );

      for (final name in ['cpu9', 'cpu99', 'cpu100', 'cpu101']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(name));
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width),
          reason: '$name wraps',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('SYS-04: figures a container withholds say why', (tester) async {
    const reason = MetricWithheldReason.containerHostFigures;
    const note =
        'Inside this container these figures would be the host\'s, so they '
        'are not shown.';
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      _core(
        perCpu: null,
        memory: null,
        withheld: const {
          MetricField.perCpu: reason,
          MetricField.memory: reason,
        },
      ),
    );

    // The per-core figures, memory and swap: three notes.
    expect(find.text(note), findsNWidgets(3));
    expect(find.text('Busy 17%'), findsOneWidget);

    // CPU and the load averages: one note in each of their cards.
    await panel.sample(
      tester,
      CoreResult(
        perCpu: const {'cpu0': 12},
        memory: _memory,
        withheld: const {
          MetricField.cpu: reason,
          MetricField.load: reason,
          MetricField.loadPerCore: reason,
        },
      ),
    );
    for (final (title, notes) in [
      ('CPU', 1),
      ('Load', 1),
      ('Memory', 0),
      ('Swap', 0),
    ]) {
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is PanelSection && widget.title == title,
          ),
          matching: find.text(note),
        ),
        findsNWidgets(notes),
        reason: title,
      );
    }
  });

  testWidgets('OV-04: values grey once older than the core stream\'s limit, '
      'and the clock runs only while the tab shows', (tester) async {
    final panel = await _pump(tester, visible: false);
    await panel.sample(tester, _core());
    expect(find.text('Updated 0 s ago'), findsOneWidget);

    // Hidden: nothing ages.
    panel.now = _start.add(const Duration(seconds: 19));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Updated 0 s ago'), findsOneWidget);

    panel.visible.value = true;
    await tester.pump();
    expect(find.text('Updated 19 s ago'), findsOneWidget);
    expect(_bars(tester).any((bar) => bar.stale), isFalse);
    Color? loadColor() => tester.widget<Text>(find.text('0.52')).style?.color;
    final muted = Theme.of(
      tester.element(find.text('0.52')),
    ).colorScheme.onSurfaceVariant;
    expect(loadColor(), isNot(muted));

    panel.now = _start.add(const Duration(seconds: 25));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Stale: updated 25 s ago'), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(_bars(tester).every((bar) => bar.stale), isTrue);
    expect(loadColor(), muted);
  });

  testWidgets('a failed reading says why and keeps the last values', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.denied),
    );
    expect(find.text('The server refused this reading.'), findsOneWidget);
    expect(find.text('Waiting for the first reading.'), findsNothing);
    expect(find.byType(StackedBar), findsNothing);

    await panel.sample(tester, _core());
    await panel.sample(
      tester,
      const CollectorUnavailable(
        CollectorUnavailableReason.timeout,
        detail: 'cat: /proc/stat: timed out',
      ),
    );
    expect(
      find.text('This reading took too long, so the server stopped it.'),
      findsOneWidget,
    );
    expect(find.text('cat: /proc/stat: timed out'), findsOneWidget);
    expect(find.text('Busy 17%'), findsOneWidget);
  });

  testWidgets('a phone in the background says sampling is paused', (
    tester,
  ) async {
    final panel = await _pump(tester);
    panel.engine.emit(
      SamplingState(
        serverId: _serverId,
        phase: SamplingPhase.pausedInBackground,
        since: _start.toUtc(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paused: app in background'), findsOneWidget);
    expect(find.text('Waiting for the first reading.'), findsOneWidget);
  });

  for (final (name, size) in [('desktop', _wide), ('phone', _phone)]) {
    testWidgets('lays out without overflow at 200 % text on the $name', (
      tester,
    ) async {
      final panel = await _pump(tester, size: size, textScale: 2);
      await panel.sample(tester, _core());
      expect(tester.takeException(), isNull);
      expect(find.text('ZFS ARC counted as used'), findsOneWidget);
    });
  }

  group('golden', () {
    // 03 §11.1: a healthy server with ZFS on a wide panel, and a stale
    // reading on a phone.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.sample(tester, _core());
        await expectLater(
          find.byType(OverviewPanel),
          matchesGoldenFile('goldens/overview_desktop_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);

      testWidgets('phone, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, size: _phone, brightness: brightness);
        await panel.sample(tester, _core());
        panel.now = _start.add(const Duration(minutes: 3));
        await tester.pump(const Duration(seconds: 1));
        await expectLater(
          find.byType(OverviewPanel),
          matchesGoldenFile('goldens/overview_phone_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
