import 'package:flutter/foundation.dart' show ChangeNotifier, FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

Sample _sample(
  String serverId,
  SampleStream stream,
  int seq, {
  SampleResult? result,
  DateTime? at,
}) => Sample(
  serverId: serverId,
  stream: stream,
  seq: seq,
  at: at ?? DateTime.utc(2026, 10, 14, 12, 0, seq),
  // Valid for every stream, which `Sample` asserts.
  result: result ?? const CollectorUnavailable(_timeout),
);

const _timeout = CollectorUnavailableReason.timeout;

OverviewResult _overview({double? cpu, int? used, int? swap, double? load}) =>
    OverviewResult(
      cpu: cpu == null ? null : CpuPercentages(const [], cpu),
      memory: MemoryUsage(usedBytes: used, swapUsedBytes: swap),
      load: load == null
          ? null
          : LoadAvg(load1: load, load5: load, load15: load),
    );

FleetEntry _entry(String serverId) => FleetEntry(
  serverId: serverId,
  label: serverId,
  host: '$serverId.example',
  port: kSshDefaultPort,
  origin: FleetEntryOrigin.sshConfig,
);

/// Whether [notifier] was disposed: only then does adding a listener fail.
bool _disposed(ChangeNotifier notifier) {
  try {
    notifier.addListener(() {});
    return false;
  } on FlutterError {
    return true;
  }
}

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  /// Lets the fake engine's broadcast events reach the controller.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('subscriptions (D45)', () {
    test('each surface subscribes with its own id and streams', () {
      monitoring
        ..subscribe('srv-1', 'row', {SampleStream.overview})
        ..subscribe('srv-1', 'overview', {SampleStream.core, SampleStream.fs});

      final [row, overview] = engine.sentOfType<Subscribe>().cast<Subscribe>();
      expect(row.serverId, 'srv-1');
      expect(row.subscriptionId, 'row');
      expect(row.streams, {SampleStream.overview});
      expect(overview.subscriptionId, 'overview');
      expect(overview.streams, {SampleStream.core, SampleStream.fs});
      expect(monitoring.isSubscribed('srv-1', 'row'), isTrue);
      expect(monitoring.isSubscribed('srv-1', 'overview'), isTrue);
      expect(monitoring.isSubscribed('srv-2', 'row'), isFalse);
    });

    test('unsubscribing one surface leaves the others subscribed', () {
      monitoring
        ..subscribe('srv-1', 'row', {SampleStream.overview})
        ..subscribe('srv-1', 'overview', {SampleStream.core})
        ..unsubscribe('srv-1', 'overview')
        // Already gone, or never subscribed: nothing to send.
        ..unsubscribe('srv-1', 'overview')
        ..unsubscribe('srv-2', 'row');

      final [unsubscribe] = engine
          .sentOfType<Unsubscribe>()
          .cast<Unsubscribe>();
      expect(unsubscribe.serverId, 'srv-1');
      expect(unsubscribe.subscriptionId, 'overview');
      expect(monitoring.isSubscribed('srv-1', 'overview'), isFalse);
      expect(monitoring.isSubscribed('srv-1', 'row'), isTrue);
    });

    // An on-demand stream is read once per Subscribe that names it, so a
    // surface refreshes it by resending: the repeat must reach the engine.
    test('subscribing an id again forwards the replacing Subscribe', () {
      monitoring
        ..subscribe('srv-1', 'row', {SampleStream.overview})
        ..subscribe('srv-1', 'row', {SampleStream.core, SampleStream.fs});

      final [first, second] = engine.sentOfType<Subscribe>().cast<Subscribe>();
      expect(first.streams, {SampleStream.overview});
      expect(second.subscriptionId, 'row');
      expect(second.streams, {SampleStream.core, SampleStream.fs});
      expect(monitoring.isSubscribed('srv-1', 'row'), isTrue);
    });
  });

  group('samples (03 §10.1)', () {
    test('land in the box of their server and stream only', () async {
      var notified = 0;
      monitoring.addListener(() => notified++);
      final rowBox = monitoring.sampleFor('srv-1', SampleStream.overview);
      var rowUpdates = 0;
      rowBox.addListener(() => rowUpdates++);

      final row = _sample('srv-1', SampleStream.overview, 1);
      final core = _sample('srv-1', SampleStream.core, 2);
      final other = _sample('srv-2', SampleStream.overview, 1);
      engine
        ..emit(row)
        ..emit(core)
        ..emit(other)
        ..emit(const LinkState('srv-1', LinkReady()));
      await settle();

      expect(rowBox.value, same(row));
      expect(rowUpdates, 1);
      expect(
        monitoring.sampleFor('srv-1', SampleStream.core).value,
        same(core),
      );
      expect(
        monitoring.sampleFor('srv-2', SampleStream.overview).value,
        same(other),
      );
      expect(monitoring.sampleFor('srv-2', SampleStream.core).value, isNull);
      // §10.1: a tick never rebuilds what listens to the whole controller.
      expect(notified, 0);
    });

    test(
      'a sample not above its server\'s last seq is dropped (D44)',
      () async {
        final first = _sample('srv-1', SampleStream.overview, 5);
        engine
          ..emit(first)
          // One counter per server: a lower or equal seq on another stream
          // of the same server is stale too.
          ..emit(_sample('srv-1', SampleStream.core, 4))
          ..emit(_sample('srv-1', SampleStream.overview, 5))
          // Another server counts on its own.
          ..emit(_sample('srv-2', SampleStream.overview, 1));
        await settle();

        expect(
          monitoring.sampleFor('srv-1', SampleStream.overview).value,
          same(first),
        );
        expect(monitoring.sampleFor('srv-1', SampleStream.core).value, isNull);
        expect(
          monitoring.sampleFor('srv-2', SampleStream.overview).value?.seq,
          1,
        );

        final next = _sample('srv-1', SampleStream.core, 6);
        engine.emit(next);
        await settle();
        expect(
          monitoring.sampleFor('srv-1', SampleStream.core).value,
          same(next),
        );
      },
    );
  });

  group('session rings (OV-03)', () {
    const overview = SampleStream.overview, core = SampleStream.core;
    void emit(SampleStream stream, int seq, SampleResult result) =>
        engine.emit(_sample('srv-1', stream, seq, result: result));
    List<double?> ring(SampleStream stream, MetricSeries series) =>
        monitoring.seriesFor('srv-1', stream, series).samples.toList();

    test('each kept sample adds one reading to every series of its '
        'stream', () async {
      emit(overview, 1, _overview(cpu: 12.5, used: 1024, swap: 0, load: 0.5));
      emit(core, 2, CoreResult(cpu: CpuPercentages(const [], 50)));
      // Not above the floor: dropped, so no ring hears it.
      emit(overview, 2, _overview(cpu: 99));
      await settle();

      expect(ring(overview, MetricSeries.cpuBusy), [12.5]);
      expect(ring(overview, MetricSeries.memoryUsed), [1024]);
      expect(ring(overview, MetricSeries.swapUsed), [0]);
      expect(ring(overview, MetricSeries.load1), [0.5]);
      // What the reading lacks is a gap, never zero (03 §10.4).
      expect(ring(core, MetricSeries.cpuBusy), [50]);
      expect(ring(core, MetricSeries.memoryUsed), [null]);
      expect(ring(core, MetricSeries.load1), [null]);
    });

    test('an unavailable collector is a gap in every series', () async {
      emit(overview, 1, const CollectorUnavailable(_timeout));
      await settle();

      for (final series in MetricSeries.values) {
        expect(ring(overview, series), [null], reason: '$series');
      }
    });

    test('a ring keeps the newest $kSessionRingCapacity readings', () async {
      const total = kSessionRingCapacity + 5;
      for (var seq = 1; seq <= total; seq++) {
        emit(overview, seq, _overview(cpu: seq.toDouble()));
      }
      await settle();

      final cpu = monitoring.seriesFor('srv-1', overview, MetricSeries.cpuBusy);
      expect(cpu.length, kSessionRingCapacity);
      expect(cpu.samples.first, 6);
      expect(cpu.samples.last, total);
    });
  });

  group('freshness (03 §9.5 item 4)', () {
    test('the newest kept sample\'s time gives its age', () async {
      const second = Duration(seconds: 1);
      final at = DateTime.utc(2026, 10, 14, 12, 0, 4);
      engine
        ..emit(_sample('srv-1', SampleStream.overview, 1, at: at))
        // A later seq read earlier, such as a slow stream's reading, does
        // not make the server look older.
        ..emit(
          _sample('srv-1', SampleStream.fs, 2, at: at.subtract(second * 3)),
        );
      await settle();

      final newest = monitoring.newestSampleAt('srv-1').value;
      expect(newest, at);
      expect(sampleAge(newest, at.add(second * 6)), second * 6);
      expect(sampleAge(newest, at.subtract(second)), Duration.zero);
      expect(sampleAge(monitoring.newestSampleAt('srv-2').value, at), isNull);
    });

    testWidgets('the clock ticks while something listens, and only then', (
      tester,
    ) async {
      final now = DateTime.utc(2026, 10, 14);
      final timed = MonitoringController(engine, now: () => now);
      expect(timed.clock.value, now);
      var heard = 0;
      void listener() => heard++;

      timed.clock.addListener(listener);
      await tester.pump(kFreshnessTick * 4);
      expect(heard, 4);

      timed.clock.removeListener(listener);
      await tester.pump(kFreshnessTick * 5);
      expect(heard, 4);
      // The test binding also fails a periodic timer left running here.
      timed.dispose();
    });
  });

  test('a server that leaves the fleet loses its readings and seq floor '
      '(SYN-08)', () async {
    const overview = SampleStream.overview;
    cpu(String serverId) =>
        monitoring.seriesFor(serverId, overview, MetricSeries.cpuBusy);
    engine
      ..emit(_sample('srv-1', overview, 5))
      ..emit(_sample('srv-2', overview, 1));
    await settle();
    final dropped = [
      monitoring.sampleFor('srv-1', overview) as ChangeNotifier,
      monitoring.newestSampleAt('srv-1') as ChangeNotifier,
      cpu('srv-1'),
    ];
    final kept = cpu('srv-2');

    engine
      ..emit(CatalogReplaced([_entry('srv-2')]))
      // Still in flight when the server left: it must not come back.
      ..emit(_sample('srv-1', overview, 6));
    await settle();

    expect(dropped.where(_disposed), hasLength(dropped.length));
    expect(monitoring.sampleFor('srv-1', overview).value, isNull);
    expect(cpu('srv-1').length, 0);
    expect(cpu('srv-2'), same(kept));

    // Back in the fleet, its readings start over: a low seq is kept.
    engine
      ..emit(CatalogReplaced([_entry('srv-1'), _entry('srv-2')]))
      ..emit(_sample('srv-1', overview, 1));
    await settle();
    expect(monitoring.sampleFor('srv-1', overview).value?.seq, 1);
  });

  group('links (03 §5.12)', () {
    testWidgets('the first view connects; the last leave disconnects after '
        'the grace', (tester) async {
      final links = MonitoringController(engine);
      addTearDown(links.dispose);

      links
        ..openServer('srv-1')
        ..openServer('srv-1')
        ..leaveServer('srv-1');
      expect(
        engine.sentOfType<Connect>().cast<Connect>().single.serverId,
        'srv-1',
      );

      links.leaveServer('srv-1');
      await tester.pump(kLinkLeaveGrace - const Duration(seconds: 1));
      expect(engine.sentOfType<Disconnect>(), isEmpty);

      await tester.pump(const Duration(seconds: 1));
      expect(
        engine.sentOfType<Disconnect>().cast<Disconnect>().single.serverId,
        'srv-1',
      );
    });

    testWidgets('a view back within the grace keeps the link', (tester) async {
      final links = MonitoringController(engine);
      addTearDown(links.dispose);

      links
        ..openServer('srv-1')
        ..leaveServer('srv-1');
      await tester.pump(const Duration(seconds: 10));
      links.openServer('srv-1');
      await tester.pump(kLinkLeaveGrace);
      expect(engine.sentOfType<Connect>(), hasLength(1));
      expect(engine.sentOfType<Disconnect>(), isEmpty);

      links.leaveServer('srv-1');
      await tester.pump(kLinkLeaveGrace);
      expect(engine.sentOfType<Disconnect>(), hasLength(1));
    });

    test('a zero grace disconnects as the last view leaves', () {
      final links = MonitoringController(engine, linkGrace: Duration.zero);
      addTearDown(links.dispose);

      links
        ..openServer('srv-1')
        ..leaveServer('srv-1');
      expect(engine.sentOfType<Disconnect>(), hasLength(1));
    });

    test(
      'a stopped engine is sent nothing, and no grace outlives it',
      () async {
        final stopping = FakeEngineClient();
        final links = MonitoringController(
          stopping,
          linkGrace: const Duration(milliseconds: 1),
        );
        addTearDown(links.dispose);
        links
          ..openServer('srv-1')
          ..leaveServer('srv-1');

        // Shut down but not yet heard as done: sending throws, which the
        // controller takes as the engine stopping.
        final closed = stopping.close();
        links.openServer('srv-2');
        await closed;
        await Future<void>.delayed(const Duration(milliseconds: 5));

        links
          ..subscribe('srv-2', 'row', {SampleStream.overview})
          ..unsubscribe('srv-2', 'row')
          ..leaveServer('srv-2')
          ..setAppActivity(AppActivity.background);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(stopping.sent, [isA<Connect>()]);
      },
    );
  });

  test('the app activity reaches the engine only when it changes', () {
    monitoring
      // The engine starts with the app in the foreground.
      ..setAppActivity(AppActivity.foreground)
      ..setAppActivity(AppActivity.background)
      ..setAppActivity(AppActivity.background)
      ..setAppActivity(AppActivity.foreground);

    expect(
      [
        for (final request in engine.sentOfType<SetAppActivity>())
          (request as SetAppActivity).activity,
      ],
      [AppActivity.background, AppActivity.foreground],
    );
  });

  test('each surface gets a subscription id of its own (D45)', () {
    final first = monitoring.newSubscriptionId('overview');
    final second = monitoring.newSubscriptionId('overview');

    expect(first, startsWith('overview'));
    expect(second, isNot(first));
  });
}
