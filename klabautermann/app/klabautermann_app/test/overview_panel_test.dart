import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart'
    show ChartSeverity, StackedBar;
import 'package:klabautermann_app/ui/fleet_row_state.dart'
    show kFleetRowThresholds;
import 'package:klabautermann_app/ui/overview_panel.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_app/ui/system_panel.dart' show PanelSection;
import 'package:klabautermann_app/ui/threshold_announcer.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show chartTheme, goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _serverId = 'srv-1';
const _entry = FleetEntry(
  serverId: _serverId,
  label: 'web-1',
  host: 'web-1.example',
  port: 22,
  origin: FleetEntryOrigin.sshConfig,
);
const _kib = 1024;
const _mib = 1024 * _kib;
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
  network: const {
    'eth0': NetRate(
      rxBytesPerSecond: 1.25 * _mib,
      txBytesPerSecond: 200.0 * _kib,
    ),
    'eth1': NetRate(
      rxBytesPerSecond: 0.25 * _mib,
      txBytesPerSecond: 100.0 * _kib,
    ),
  },
  uptime: const Duration(days: 12, hours: 3, minutes: 7),
  bootedAt: DateTime.utc(2026, 10, 3, 11, 23),
  withheld: withheld,
);

/// A mount of [gib] GiB with [use] percent of its space and [inodes]
/// percent of its inodes used.
FsMount _mount(
  String mountPoint, {
  String type = 'ext4',
  int gib = 100,
  int? use,
  int? inodes,
}) => FsMount(
  device: '/dev/sda1',
  type: type,
  mountPoint: mountPoint,
  sizeBytes: gib * _gib,
  usedBytes: use == null ? null : gib * _gib * use ~/ 100,
  availBytes: use == null ? null : gib * _gib * (100 - use) ~/ 100,
  capacityPercent: use,
  inodeUsePercent: inodes,
);

final _fs = FsSnapshot([
  _mount('/', gib: 50, use: 45, inodes: 12),
  _mount('/run', type: 'tmpfs', gib: 1, use: 1, inodes: 1),
  _mount('/var', use: 85, inodes: 30),
]);

const _identity = IdentityResult(
  osPrettyName: 'Ubuntu 24.04.1 LTS',
  kernelName: 'Linux',
  kernelRelease: '6.8.0-45-generic',
);

FailedUnitsResult _failed([List<String> units = const []]) =>
    FailedUnitsResult([
      for (final unit in units)
        SystemdUnit(
          unit: unit,
          load: 'loaded',
          active: 'failed',
          sub: 'failed',
        ),
    ]);

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  /// What the monitoring clock reads.
  DateTime now = _start;
  int _seq = 0;

  /// How often the health card's link opened Settings.
  int settingsOpened = 0;

  Future<void> sample(
    WidgetTester tester,
    SampleResult result, {
    DateTime? at,
    SampleStream stream = SampleStream.core,
  }) async {
    engine.emit(
      Sample(
        serverId: _serverId,
        stream: stream,
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
  ValueNotifier<bool>? announce,
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
                builder: (context, visible, _) {
                  final overview = OverviewPanel(
                    monitoring: monitoring,
                    serverId: _serverId,
                    visible: visible,
                  );
                  if (announce == null) return overview;
                  return AnnouncementScope(
                    announce: announce,
                    openSettings: (_) => panel.settingsOpened++,
                    child: overview,
                  );
                },
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

/// [matching] inside the card headed [title].
Finder _inCard(String title, Finder matching) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is PanelSection && widget.title == title,
  ),
  matching: matching,
);

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
      final [overview, coverage] = harness.engine.sentOfType<Subscribe>();
      expect((overview as Subscribe).streams, ServerPanel.overview.streams);
      // The coverage card's one read of the units list (03 §9.5 item 3).
      expect((coverage as Subscribe).streams, {SampleStream.units});
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

  testWidgets('the phone\'s health card opens Settings on the announcement '
      'switch (D60)', (tester) async {
    await pumpApp(tester, servers: twoServers, size: _phone);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Threshold announcements: on'));
    await tester.pumpAndSettle();
    expect(find.text('Announce threshold changes'), findsOneWidget);
  });

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

    // 3 CPU + 1 per core + 4 load + 4 memory (total is known) + 1 swap,
    // 2 network, and uptime and boot time; the OS and kernel wait for
    // their own reading.
    expect(find.text('Unknown'), findsNWidgets(17));
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

  for (final textScale in [1.0, 2.0]) {
    testWidgets('every core\'s bar has one track length at '
        '${(textScale * 100).round()} % text', (tester) async {
      final panel = await _pump(tester, textScale: textScale);
      await panel.sample(
        tester,
        _core(perCpu: const {'cpu0': 5, 'cpu1': 100, 'cpu2': 50}),
      );

      double track(String core) => tester
          .getSize(
            find.byWidgetPredicate(
              (widget) => widget is StackedBar && widget.label == core,
            ),
          )
          .width;
      // A figure's digits take none of its bar's length, so the bars'
      // lengths compare across cores.
      expect(track('cpu1'), track('cpu0'), reason: '100% beside 5%');
      expect(track('cpu2'), track('cpu0'), reason: '50% beside 5%');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a core\'s figure box takes its room from the bar at '
        '${(textScale * 100).round()} % text', (tester) async {
      final panel = await _pump(tester, textScale: textScale);
      await panel.sample(tester, _core());

      final bar = find.byWidgetPredicate(
        (widget) => widget is StackedBar && widget.label == 'cpu0',
      );
      final row = tester.getSize(
        find.ancestor(of: bar, matching: find.byType(MergeSemantics)).first,
      );
      final name = tester.getSize(
        find
            .ancestor(of: find.text('cpu0'), matching: find.byType(SizedBox))
            .first,
      );
      // The bar, the gap and the widest figure's box share a fixed 106 px,
      // so a row grows only with its name and the boxes cost no column of
      // cores.
      expect(row.width - name.width, 8 + 106 * textScale);
    });
  }

  testWidgets(
    'four cores sit side by side on a 375 px phone',
    skip: !goldensCompareHere,
    (tester) async {
      final panel = await _pump(tester, size: const Size(375, 1400));
      await panel.sample(tester, _core());

      const cores = {'cpu0', 'cpu1', 'cpu2', 'cpu3'};
      final columns = {
        for (final bar in _bars(tester))
          if (cores.contains(bar.label))
            tester.getTopLeft(find.byWidget(bar)).dx,
      };
      // In the goldens' Roboto, at the width of an iPhone SE or 13 mini.
      expect(columns, hasLength(2));
    },
  );

  testWidgets('SYS-04: figures a container withholds say why', (tester) async {
    const reason = MetricWithheldReason.containerHostFigures;
    const note =
        'Inside this container these figures would be the host\'s, so they '
        'are not shown.';
    const perCoreNote =
        'Inside this container the core count would be the host\'s, so the '
        'load per core is not shown.';
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

    // In each card: the shared note, then the load-per-core one.
    void expectNotes(Map<String, (int, int)> notesByCard) {
      for (final MapEntry(key: title, value: (notes, perCore))
          in notesByCard.entries) {
        Finder inCard(String text) => find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is PanelSection && widget.title == title,
          ),
          matching: find.text(text),
        );
        expect(inCard(note), findsNWidgets(notes), reason: title);
        expect(inCard(perCoreNote), findsNWidgets(perCore), reason: title);
      }
    }

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
    expectNotes({
      'CPU': (1, 0),
      'Load': (1, 0),
      'Memory': (0, 0),
      'Swap': (0, 0),
    });

    // A container whose /proc/stat is the host's withholds the total and
    // the per-core figures together: the CPU card says so once. Its own
    // load averages show, divided by no core count.
    await panel.sample(
      tester,
      CoreResult(
        memory: _memory,
        load: const LoadAvg(load1: 0.5, load5: 0.4, load15: 0.3),
        withheld: const {
          MetricField.cpu: reason,
          MetricField.perCpu: reason,
          MetricField.loadPerCore: reason,
        },
      ),
    );
    expect(find.text('0.50'), findsOneWidget);
    expectNotes({
      'CPU': (1, 0),
      'Load': (0, 1),
      'Memory': (0, 0),
      'Swap': (0, 0),
    });
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
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(
        tester,
        size: size,
        textScale: 2,
        announce: announce,
      );
      await panel.sample(tester, _core());
      await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
      await panel.sample(tester, _identity, stream: SampleStream.identity);
      await panel.sample(
        tester,
        _failed(['a-unit-with-a-rather-long-name@instance.service']),
        stream: SampleStream.failedUnits,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('ZFS ARC counted as used'), findsOneWidget);
      expect(find.text('Linux 6.8.0-45-generic'), findsOneWidget);
    });
  }

  test('OV-02 flags listed mounts at the fleet rows\' levels, most severe '
      'and fullest first', () {
    final alarms = diskAlarms(
      FsSnapshot([
        _mount('/', use: 79, inodes: 12),
        _mount('/var', use: 80, inodes: 95),
        _mount('/srv', use: 91),
        // A squashfs image is always full; it is a pseudo filesystem.
        _mount('/snap/core/1', type: 'squashfs', use: 100, inodes: 100),
        _mount('/data'),
      ]),
    );

    expect(
      [
        for (final a in alarms)
          (a.mountPoint, a.measure, a.percent, a.severity),
      ],
      [
        ('/var', DiskMeasure.inodes, 95, ChartSeverity.critical),
        ('/srv', DiskMeasure.space, 91, ChartSeverity.critical),
        ('/var', DiskMeasure.space, 80, ChartSeverity.warning),
      ],
    );
  });

  testWidgets('OV-01 adds mounts, network, uptime, OS and kernel in IEC '
      'units', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(tester, _core());
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    await panel.sample(tester, _identity, stream: SampleStream.identity);

    for (final text in [
      'Disks',
      '/',
      '/var',
      '45%',
      '85%',
      '50 GiB',
      '100 GiB',
      'Network',
      '1.5 MiB/s',
      '300 KiB/s',
      'Host',
      'Ubuntu 24.04.1 LTS',
      'Linux 6.8.0-45-generic',
      '12 days, 3 hours',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // The System tab lists pseudo filesystems behind its filter.
    expect(find.text('/run'), findsNothing);
    expect(find.textContaining('GB'), findsNothing);
    // A mount's bar warns at the fleet rows' levels, as the health card
    // does.
    final varBar = _bars(tester).singleWhere((bar) => bar.label == '/var');
    expect(varBar.thresholds, same(kFleetRowThresholds));
  });

  testWidgets('a df timeout keeps the last mounts with their use unknown', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
      stream: SampleStream.fs,
    );

    expect(
      find.textContaining('Disk usage did not finish in time.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('These mounts are from the reading at'),
      findsOneWidget,
    );
    expect(find.text('/var'), findsOneWidget);
    expect(find.text('85%'), findsNothing);
    expect(_bars(tester).where((bar) => bar.label.startsWith('/')), isEmpty);
    // Which mount hung is not known, so the health card names none.
    expect(
      find.text('Disk use is unknown: the reading did not finish in time.'),
      findsOneWidget,
    );
    expect(find.textContaining('of its space used'), findsNothing);
  });

  testWidgets('Disks lists eight mounts and leaves the rest to the System '
      'tab', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      FsResult(
        FsSnapshot([for (var i = 0; i < 9; i++) _mount('/m$i', use: 10)]),
      ),
      stream: SampleStream.fs,
    );

    expect(_inCard('Disks', find.text('/m7')), findsOneWidget);
    expect(find.text('/m8'), findsNothing);
    expect(
      _inCard('Disks', find.text('1 more mount is on the System tab.')),
      findsOneWidget,
    );
  });

  testWidgets('another df failure shows only why, as the System tab does', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.denied),
      stream: SampleStream.fs,
    );

    expect(
      _inCard('Disks', find.text('The server refused this reading.')),
      findsOneWidget,
    );
    expect(find.text('/var'), findsNothing);
    expect(find.text('85%'), findsNothing);
    expect(_bars(tester).where((bar) => bar.label.startsWith('/')), isEmpty);
    expect(
      find.text('Disk use is unknown: the server refused the reading.'),
      findsOneWidget,
    );
    // Neither card shows anything from the older listing, so neither
    // gives its age.
    expect(find.textContaining('pdated'), findsNothing);
  });

  testWidgets('the health card is as old as the oldest reading it shows', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    panel.now = _start.add(const Duration(minutes: 3));
    await panel.sample(tester, _failed(), stream: SampleStream.failedUnits);
    panel.now = _start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(
      _inCard('Health', find.text('Stale: updated 5 min ago')),
      findsOneWidget,
    );

    // A hung mount: the card names no mount from the last listing, so
    // only the unit list's age counts, while Disks keeps the listing's.
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
      stream: SampleStream.fs,
    );
    expect(_inCard('Health', find.text('Updated 2 min ago')), findsOneWidget);
    expect(
      _inCard('Disks', find.text('Stale: updated 5 min ago')),
      findsOneWidget,
    );
  });

  testWidgets('OV-02: the health card lists failed units and full disks', (
    tester,
  ) async {
    final panel = await _pump(tester);
    expect(
      find.text('Waiting for the first check of failed units.'),
      findsOneWidget,
    );
    expect(find.text('Waiting for the first disk reading.'), findsNWidgets(2));

    await panel.sample(
      tester,
      _failed(['nginx.service']),
      stream: SampleStream.failedUnits,
    );
    await panel.sample(
      tester,
      FsResult(
        FsSnapshot([
          _mount('/', use: 92),
          _mount('/var', use: 40, inodes: 85),
          _mount('/home', use: 50),
        ]),
      ),
      stream: SampleStream.fs,
    );
    for (final text in [
      '1 failed unit',
      'nginx.service: failed',
      '/: 92% of its space used, critical',
      '/var: 85% of its inodes used, warning',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.byIcon(Icons.error_outline), findsWidgets);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);

    await panel.sample(tester, _failed(), stream: SampleStream.failedUnits);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    expect(find.text('No failed units'), findsOneWidget);
    // /var's 85% shows in the Disks card; the health card judges it.
    expect(find.text('/var: 85% of its space used, warning'), findsOneWidget);

    await panel.sample(
      tester,
      FsResult(FsSnapshot([_mount('/', use: 45)])),
      stream: SampleStream.fs,
    );
    expect(
      find.text('No disk has 80% or more of its space or inodes used.'),
      findsOneWidget,
    );

    // A failed check says so above the last list, which it never calls
    // unknown, as part one's cards keep their last values.
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.missing),
      stream: SampleStream.failedUnits,
    );
    expect(
      find.text(
        'The last check of failed units could not run: this server lacks '
        'systemctl.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('unknown'), findsNothing);
    expect(find.text('No failed units'), findsOneWidget);
  });

  testWidgets('slow readings grey with their age once older than the fs '
      'limit', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(tester, _failed(), stream: SampleStream.failedUnits);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    expect(find.text('Updated 0 s ago'), findsNWidgets(2));

    panel.now = _start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    // The health and Disks cards' own lines.
    expect(find.text('Stale: updated 5 min ago'), findsNWidgets(2));
    final mountBars = _bars(tester).where((bar) => bar.label.startsWith('/'));
    expect(mountBars, isNotEmpty);
    expect(mountBars.every((bar) => bar.stale), isTrue);
  });

  testWidgets('a link lost before any core reading is said in words', (
    tester,
  ) async {
    final panel = await _pump(tester);
    void phase(SamplingPhase phase) => panel.engine.emit(
      SamplingState(
        serverId: _serverId,
        phase: phase,
        since: panel.now.toUtc(),
      ),
    );
    phase(SamplingPhase.sampling);
    await panel.sample(tester, _failed(), stream: SampleStream.failedUnits);
    await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
    await panel.sample(
      tester,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );

    panel.now = _start.add(const Duration(minutes: 1));
    phase(SamplingPhase.waitingForLink);
    panel.now = _start.add(const Duration(minutes: 10));
    await tester.pump(const Duration(seconds: 1));
    // Said once, for the greyed slow cards too.
    expect(find.text('Disconnected 9 min ago'), findsOneWidget);
    expect(find.textContaining('Updated'), findsNothing);
    final mountBars = _bars(tester).where((bar) => bar.label.startsWith('/'));
    expect(mountBars, isNotEmpty);
    expect(mountBars.every((bar) => bar.stale), isTrue);
  });

  testWidgets('SYS-04: an uptime and boot time a container withholds say '
      'why', (tester) async {
    final panel = await _pump(tester);
    panel.engine.emit(
      HostProfileChanged(
        _serverId,
        HostProfile(
          virtualization: 'lxc',
          container: 'lxc',
          lxcfsMounts: const [],
        ),
      ),
    );
    await panel.sample(tester, _core());

    expect(find.text('12 days, 3 hours'), findsNothing);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is PanelSection && widget.title == 'Host',
        ),
        matching: find.text(
          'Inside this container these figures would be the host\'s, so '
          'they are not shown.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the Host card waits for its readings and says why one '
      'failed', (tester) async {
    final panel = await _pump(tester);
    Finder host(Finder matching) => _inCard('Host', matching);
    const waiting = 'Waiting for the operating system and kernel.';
    expect(host(find.text(waiting)), findsOneWidget);
    expect(host(find.text('Unknown')), findsNothing);
    expect(host(find.text('Up for')), findsNothing);

    const refused = 'The server refused this reading.';
    await panel.sample(
      tester,
      const CollectorUnavailable(
        CollectorUnavailableReason.denied,
        detail: 'cat: /etc/os-release: Permission denied',
      ),
      stream: SampleStream.identity,
    );
    expect(host(find.text(refused)), findsOneWidget);
    expect(
      host(find.text('cat: /etc/os-release: Permission denied')),
      findsOneWidget,
    );
    expect(host(find.text(waiting)), findsNothing);
    expect(host(find.text('Unknown')), findsNothing);

    // Before a `core` reading the OS and kernel are current, not grey.
    await panel.sample(tester, _identity, stream: SampleStream.identity);
    expect(host(find.text(refused)), findsNothing);
    final muted = Theme.of(
      tester.element(find.byType(OverviewPanel)),
    ).colorScheme.onSurfaceVariant;
    Color? colour(String text) =>
        tester.widget<Text>(host(find.text(text))).style?.color;
    expect(colour('Ubuntu 24.04.1 LTS'), isNot(muted));

    await panel.sample(tester, _core());
    expect(host(find.text('12 days, 3 hours')), findsOneWidget);

    // Read once per session, they grey with the panel's line.
    panel.now = _start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(colour('Ubuntu 24.04.1 LTS'), muted);
    expect(colour('Linux 6.8.0-45-generic'), muted);
  });

  testWidgets('the health card links to the announcement switch (D60)', (
    tester,
  ) async {
    final announce = ValueNotifier(true);
    addTearDown(announce.dispose);
    final panel = await _pump(tester, announce: announce);

    // The label states the switch; the hint says activating it does not
    // flip it here.
    expect(
      tester.getSemantics(find.text('Threshold announcements: on')),
      isSemantics(
        label: 'Threshold announcements: on',
        hint: 'Opens Settings',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.text('Threshold announcements: on'));
    expect(panel.settingsOpened, 1);

    announce.value = false;
    await tester.pump();
    expect(find.text('Threshold announcements: off'), findsOneWidget);
  });

  testWidgets('without the app\'s settings the health card has no link', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('Threshold announcements'), findsNothing);
  });

  group('A11Y-15', () {
    List<String> heard(WidgetTester tester) => [
      for (final announcement in tester.takeAnnouncements())
        announcement.message,
    ];

    CoreResult busy(double percent) => CoreResult(
      cpu: CpuPercentages([percent, 0, 0, 100 - percent], percent),
      memory: _memory,
    );

    testWidgets('a band change is heard once it holds, not while the value '
        'flaps', (tester) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> cpu(int seconds, double percent) => panel.sample(
        tester,
        busy(percent),
        at: _start.add(Duration(seconds: seconds)),
      );

      // Where a value starts is no news.
      await cpu(0, 85);
      await cpu(2, 85);
      expect(heard(tester), isEmpty);

      await cpu(4, 50);
      await cpu(10, 50);
      expect(heard(tester), isEmpty, reason: 'held 6 s of 10');
      await cpu(14, 50);
      expect(heard(tester), ['CPU 50%: back to normal']);

      // Around the warning level: one change, then the flaps hold it.
      await cpu(16, 82);
      await cpu(26, 82);
      expect(heard(tester), ['CPU 82%: warning level']);
      await cpu(28, 78);
      await cpu(30, 81);
      await cpu(34, 79);
      await cpu(36, 80);
      expect(heard(tester), isEmpty);

      // Straight past both levels: the higher one, once.
      await cpu(38, 96);
      await cpu(48, 96);
      expect(heard(tester), ['CPU 96%: critical level']);
    });

    test('a band is heard only with a value inside it', () {
      // Each change as (seconds, value, band), readings 2 s apart.
      List<(int, double, ChartSeverity)> changes(List<double> values) {
        final watch = BandWatch(BandMetric.cpu);
        return [
          for (final (i, value) in values.indexed)
            if (watch.observe(value, _start.add(Duration(seconds: 2 * i)))
                case final band?)
              (2 * i, value, band),
        ];
      }

      // One reading in the warning band on the way down or up must not
      // be heard as a warning at 40 % or 95 % before the real change.
      expect(changes([95, 95, 87, 40, 40, 40, 40, 40, 40, 40, 40]), [
        (16, 40.0, ChartSeverity.normal),
      ]);
      expect(changes([50, 85, 95, 95, 95, 95, 95, 95, 95]), [
        (14, 95.0, ChartSeverity.critical),
      ]);
    });

    testWidgets('a spoken figure always lies in the band it names', (
      tester,
    ) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      var seconds = 0;
      // Each value held past the band hold.
      Future<List<String>> hold(double percent) async {
        for (final _ in [0, 1]) {
          await panel.sample(
            tester,
            busy(percent),
            at: _start.add(Duration(seconds: seconds)),
          );
          seconds += 12;
        }
        return heard(tester);
      }

      await hold(85);
      // 79.6 % reads "80%", which is no longer back to normal.
      expect(await hold(79.6), isEmpty);
      expect(await hold(95), ['CPU 95%: critical level']);
      expect(await hold(89.6), isEmpty);
      expect(await hold(89.4), ['CPU 89%: warning level']);
      expect(await hold(79.4), ['CPU 79%: back to normal']);
    });

    testWidgets('each listed mount is heard by its own band, a reading\'s '
        'changes in one announcement', (tester) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> fs(int seconds, List<FsMount> mounts) => panel.sample(
        tester,
        FsResult(FsSnapshot(mounts)),
        at: _start.add(Duration(seconds: seconds)),
        stream: SampleStream.fs,
      );

      await fs(0, [_mount('/', use: 70), _mount('/var', use: 10, inodes: 10)]);
      await fs(30, [_mount('/', use: 95), _mount('/var', use: 10, inodes: 85)]);
      expect(heard(tester), isEmpty);
      await fs(60, [_mount('/', use: 95), _mount('/var', use: 10, inodes: 85)]);
      // One utterance: a second announcement sent at once would cut the
      // first off on iOS and replace it on Windows.
      expect(heard(tester), [
        'Disk / 95%: critical level, Inodes on /var 85%: warning level',
      ]);
    });

    testWidgets('a mount that comes back starts from where it then stands', (
      tester,
    ) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> fs(int seconds, List<FsMount> mounts) => panel.sample(
        tester,
        FsResult(FsSnapshot(mounts)),
        at: _start.add(Duration(seconds: seconds)),
        stream: SampleStream.fs,
      );

      await fs(0, [_mount('/'), _mount('/data', use: 95)]);
      await fs(30, [_mount('/')]);
      await fs(60, [_mount('/'), _mount('/data', use: 50)]);
      await fs(90, [_mount('/'), _mount('/data', use: 50)]);
      expect(heard(tester), isEmpty);
    });

    testWidgets('nothing is heard while the switch is off or the Overview '
        'is hidden', (tester) async {
      final announce = ValueNotifier(false);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> cpu(int seconds, double percent) => panel.sample(
        tester,
        busy(percent),
        at: _start.add(Duration(seconds: seconds)),
      );

      await cpu(0, 50);
      await cpu(2, 95);
      await cpu(14, 95);
      expect(heard(tester), isEmpty);

      announce.value = true;
      panel.visible.value = false;
      await tester.pump();
      await cpu(16, 50);
      await cpu(28, 50);
      expect(heard(tester), isEmpty);

      // Shown again: where the value stands now is the start.
      panel.visible.value = true;
      await tester.pump();
      await cpu(30, 50);
      expect(heard(tester), isEmpty);
      await cpu(32, 95);
      await cpu(44, 95);
      expect(heard(tester), ['CPU 95%: critical level']);

      // Hidden while critical and back at 50 %: no band to fall from.
      panel.visible.value = false;
      await tester.pump();
      await cpu(46, 50);
      panel.visible.value = true;
      await tester.pump();
      await cpu(48, 50);
      await cpu(60, 50);
      expect(heard(tester), isEmpty);
    });

    testWidgets('nothing is heard while a pushed route covers the Overview', (
      tester,
    ) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> cpu(int seconds, double percent) => panel.sample(
        tester,
        busy(percent),
        at: _start.add(Duration(seconds: seconds)),
      );
      await cpu(0, 50);

      // Settings on a phone is such a route, opened from the health card.
      final navigator = Navigator.of(
        tester.element(find.byType(OverviewPanel)),
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      await cpu(2, 95);
      await cpu(14, 95);
      expect(heard(tester), isEmpty);

      // Back on stage: where the value stands now is the start.
      navigator.pop();
      await tester.pumpAndSettle();
      await cpu(16, 95);
      await cpu(28, 95);
      expect(heard(tester), isEmpty);
      await cpu(30, 50);
      await cpu(42, 50);
      expect(heard(tester), ['CPU 50%: back to normal']);
    });

    testWidgets('a server that left the fleet and came back is still heard '
        '(SYN-08)', (tester) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);
      Future<void> cpu(int seconds, double percent) => panel.sample(
        tester,
        busy(percent),
        at: _start.add(Duration(seconds: seconds)),
      );
      await cpu(0, 50);
      await cpu(2, 50);

      // The controller drops the server's boxes and makes new ones, and
      // the screen around the panel rebuilds, as the phone's server
      // screen does on every fleet change.
      panel.engine
        ..emit(CatalogReplaced(const []))
        ..emit(CatalogReplaced(const [_entry]));
      await tester.pump();
      tester.element(find.byType(OverviewPanel)).markNeedsBuild();
      await tester.pump();

      await cpu(10, 50);
      await cpu(12, 95);
      await cpu(24, 95);
      expect(find.textContaining('95%'), findsWidgets);
      expect(heard(tester), ['CPU 95%: critical level']);
    });

    testWidgets('without announcements, band changes go to a live region', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(tester, announce: announce);

      await panel.sample(tester, busy(50));
      await panel.sample(
        tester,
        busy(85),
        at: _start.add(const Duration(seconds: 2)),
      );
      await panel.sample(
        tester,
        busy(85),
        at: _start.add(const Duration(seconds: 12)),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      expect(
        tester.getSemantics(find.bySemanticsLabel('CPU 85%: warning level')),
        isSemantics(label: 'CPU 85%: warning level', isLiveRegion: true),
      );
    });
  });

  group('golden', () {
    // 03 §11.1: a server with ZFS, a failed unit and a full mount on a
    // wide panel, and the same readings gone stale on a phone; every card
    // in view.
    Future<_Panel> pumpAll(
      WidgetTester tester,
      Size size,
      Brightness brightness,
    ) async {
      final announce = ValueNotifier(true);
      addTearDown(announce.dispose);
      final panel = await _pump(
        tester,
        size: size,
        brightness: brightness,
        announce: announce,
      );
      await panel.sample(tester, _core());
      await panel.sample(tester, FsResult(_fs), stream: SampleStream.fs);
      await panel.sample(tester, _identity, stream: SampleStream.identity);
      await panel.sample(
        tester,
        _failed(['backup.service']),
        stream: SampleStream.failedUnits,
      );
      return panel;
    }

    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        await pumpAll(tester, const Size(900, 1500), brightness);
        await expectLater(
          find.byType(OverviewPanel),
          matchesGoldenFile('goldens/overview_desktop_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);

      testWidgets('phone, ${brightness.name}', (tester) async {
        final panel = await pumpAll(tester, const Size(390, 2600), brightness);
        panel.now = _start.add(const Duration(minutes: 5));
        await tester.pump(const Duration(seconds: 1));
        await expectLater(
          find.byType(OverviewPanel),
          matchesGoldenFile('goldens/overview_phone_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
