import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_reads.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartGapReason;
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

/// A Logs panel stream's side of [LogStreamListener], in arrival order.
final class _PanelStream implements LogStreamListener {
  final events = <Object>[];

  @override
  void onLogBatch(LogBatch batch) => events.add(batch.records.length);

  @override
  void onLogStatus(LogStreamStatus status) => events.add(status);

  @override
  void onLogRejected(LogRejection rejection) => events.add(rejection);
}

/// SVC-04's unit logs: a bounded window of one unit.
LogStreamSpec _unitLogs(String unit) => LogStreamSpec(
  serverId: 'srv-1',
  source: JournalLogSource(unit: unit),
  window: 50,
  follow: false,
);

/// The Logs panel's live journal.
final _panelLog = LogStreamSpec(
  serverId: 'srv-1',
  source: const JournalLogSource(),
  window: 500,
  follow: true,
);

const _openRejected = RequestRejected('OpenLogStream', 'not implemented yet');

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

  group('refresh (PLT-02)', () {
    SamplingState phase(SamplingPhase phase) => SamplingState(
      serverId: 'srv-1',
      phase: phase,
      since: DateTime.utc(2026, 10, 16, 12),
    );

    test(
      'asks the engine to read one held subscription at once, and ends '
      'at once while the engine samples nothing, as with links off',
      () async {
        monitoring.subscribe('srv-1', 'processes', {SampleStream.procs});
        var done = false;
        unawaited(
          monitoring.refresh('srv-1', 'processes').then((_) => done = true),
        );
        // Nothing held under these ids, so nothing to read.
        await monitoring.refresh('srv-1', 'system');
        await monitoring.refresh('srv-2', 'processes');
        await settle();

        expect(done, isTrue);
        final [refresh] = engine
            .sentOfType<RefreshSubscription>()
            .cast<RefreshSubscription>();
        expect(
          (refresh.serverId, refresh.subscriptionId),
          ('srv-1', 'processes'),
        );
      },
    );

    test('while the server samples, waits for a newer reading of each '
        'stream, a failed one included', () async {
      monitoring.subscribe('srv-1', 'system', {
        SampleStream.fs,
        SampleStream.core,
      });
      engine
        ..emit(phase(SamplingPhase.sampling))
        ..emit(_sample('srv-1', SampleStream.fs, 1))
        ..emit(_sample('srv-1', SampleStream.core, 2));
      await settle();

      var done = false;
      unawaited(monitoring.refresh('srv-1', 'system').then((_) => done = true));
      engine.emit(_sample('srv-1', SampleStream.core, 3));
      await settle();
      expect(done, isFalse);

      engine.emit(_sample('srv-1', SampleStream.fs, 4));
      await settle();
      expect(done, isTrue);
    });

    test('ends once the server stops sampling, leaves the fleet or the '
        'controller goes', () async {
      final other = MonitoringController(engine);
      for (final controller in [monitoring, other]) {
        controller.subscribe('srv-1', 'jobs', {SampleStream.timers});
      }
      engine.emit(phase(SamplingPhase.sampling));
      await settle();

      final ended = <String>[];
      unawaited(
        monitoring.refresh('srv-1', 'jobs').then((_) => ended.add('link')),
      );
      engine.emit(phase(SamplingPhase.waitingForLink));
      await settle();
      expect(ended, ['link']);

      engine.emit(phase(SamplingPhase.sampling));
      await settle();
      unawaited(
        monitoring.refresh('srv-1', 'jobs').then((_) => ended.add('fleet')),
      );
      unawaited(other.refresh('srv-1', 'jobs').then((_) => ended.add('gone')));
      other.dispose();
      engine.emit(CatalogReplaced([_entry('srv-2')]));
      await settle();
      expect(ended, ['link', 'gone', 'fleet']);
    });

    testWidgets('gives up after kRefreshWait without the readings', (
      tester,
    ) async {
      final waiting = MonitoringController(engine);
      addTearDown(waiting.dispose);
      waiting.subscribe('srv-1', 'services', {SampleStream.units});
      engine.emit(phase(SamplingPhase.sampling));
      await tester.pump();

      var done = false;
      unawaited(waiting.refresh('srv-1', 'services').then((_) => done = true));
      await tester.pump(kRefreshWait - const Duration(seconds: 1));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(done, isTrue);
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

    CoreResult cpuAt(double busy) =>
        CoreResult(cpu: CpuPercentages(const [], busy));

    test('a stream no subscription named for a while resumes after a '
        'gap', () async {
      monitoring.subscribe('srv-1', 'overview-0', {core});
      emit(core, 1, cpuAt(10));
      emit(core, 2, cpuAt(20));
      await settle();
      monitoring.unsubscribe('srv-1', 'overview-0');
      await settle();

      // The engine reports no Gap for a stream it was not asked for.
      monitoring.subscribe('srv-1', 'overview-0', {core});
      emit(core, 3, cpuAt(90));
      await settle();
      expect(ring(core, MetricSeries.cpuBusy), [10, 20, null, 90]);
      expect(ring(core, MetricSeries.load1), [null, null, null, null]);
    });

    test('a stream handed between surfaces in one turn has no gap', () async {
      monitoring.subscribe('srv-1', 'overview-0', {core});
      emit(core, 1, cpuAt(10));
      await settle();

      // A tab switch: the old panel lets go before the new one subscribes.
      monitoring
        ..unsubscribe('srv-1', 'overview-0')
        ..subscribe('srv-1', 'system-1', {core, SampleStream.fs});
      await settle();
      emit(core, 2, cpuAt(20));
      await settle();
      expect(ring(core, MetricSeries.cpuBusy), [10, 20]);
    });
  });

  group('freshness (03 §9.5 item 4)', () {
    test('each stream\'s latest sample gives its own age', () async {
      const second = Duration(seconds: 1);
      final at = DateTime.utc(2026, 10, 14, 12, 0, 4);
      engine
        ..emit(_sample('srv-1', SampleStream.core, 1, at: at))
        // A slow stream's newer reading does not make core look fresh.
        ..emit(_sample('srv-1', SampleStream.fs, 2, at: at.add(second * 25)));
      await settle();
      DateTime? latest(String serverId, SampleStream stream) =>
          monitoring.sampleFor(serverId, stream).value?.at;

      final now = at.add(second * 26);
      expect(sampleAge(latest('srv-1', SampleStream.core), now), second * 26);
      expect(sampleAge(latest('srv-1', SampleStream.fs), now), second);
      expect(sampleAge(at, at.subtract(second)), Duration.zero);
      expect(sampleAge(latest('srv-2', SampleStream.core), now), isNull);
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

    test('the latest sampling state lands in its server\'s box with the '
        'phase it left, and leaves with the server (SYN-08)', () async {
      final since = DateTime.utc(2026, 10, 14, 12);
      SamplingState state(String serverId, SamplingPhase phase) =>
          SamplingState(serverId: serverId, phase: phase, since: since);
      final paused = state('srv-1', SamplingPhase.pausedInBackground);
      engine
        ..emit(state('srv-1', SamplingPhase.sampling))
        ..emit(paused);
      await settle();
      final box = monitoring.samplingFor('srv-1');
      expect(box.value!.state, same(paused));
      expect(box.value!.previous, SamplingPhase.sampling);
      expect(monitoring.samplingFor('srv-2').value, isNull);

      engine
        ..emit(CatalogReplaced([_entry('srv-2')]))
        // Still in flight when the server left: it must not come back.
        ..emit(state('srv-1', SamplingPhase.sampling));
      await settle();
      expect(_disposed(box as ChangeNotifier), isTrue);
      expect(monitoring.samplingFor('srv-1').value, isNull);
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

  test('the latest host profile lands in its server\'s box and leaves '
      'with the server (SYN-08)', () async {
    final kvm = HostProfile(virtualization: 'kvm', container: 'none');
    final lxc = HostProfile(virtualization: 'lxc', container: 'lxc');
    engine
      ..emit(HostProfileChanged('srv-1', kvm))
      ..emit(HostProfileChanged('srv-1', lxc));
    await settle();
    final box = monitoring.profileFor('srv-1');
    expect(box.value, same(lxc));
    expect(monitoring.profileFor('srv-2').value, isNull);

    engine
      ..emit(CatalogReplaced([_entry('srv-2')]))
      // Still in flight when the server left: it must not come back.
      ..emit(HostProfileChanged('srv-1', kvm));
    await settle();
    expect(_disposed(box as ChangeNotifier), isTrue);
    expect(monitoring.profileFor('srv-1').value, isNull);
  });

  test('each stream\'s latest reading outlives a collector that fails '
      'after it, and leaves with the server (SYN-08)', () async {
    const fs = SampleStream.fs;
    final listed = _sample('srv-1', fs, 1, result: FsResult(FsSnapshot([])));
    engine
      ..emit(listed)
      ..emit(_sample('srv-1', fs, 2));
    await settle();
    final box = monitoring.lastReadingFor('srv-1', fs);
    expect(box.value, same(listed));
    expect(monitoring.sampleFor('srv-1', fs).value?.seq, 2);

    engine.emit(CatalogReplaced([_entry('srv-2')]));
    await settle();
    expect(_disposed(box as ChangeNotifier), isTrue);
    expect(monitoring.lastReadingFor('srv-1', fs).value, isNull);
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

    testWidgets('a view back after the grace connects again', (tester) async {
      final links = MonitoringController(engine);
      addTearDown(links.dispose);

      links
        ..openServer('srv-1')
        ..leaveServer('srv-1');
      await tester.pump(kLinkLeaveGrace);
      expect(engine.sentOfType<Disconnect>(), hasLength(1));

      links.openServer('srv-1');
      expect(engine.sentOfType<Connect>(), hasLength(2));
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

    testWidgets('a view that leaves after the engine stopped, or after '
        'dispose, waits out no grace', (tester) async {
      final stopping = FakeEngineClient();
      final stopped = MonitoringController(stopping)..openServer('srv-1');
      addTearDown(stopped.dispose);
      await stopping.close();
      stopped.leaveServer('srv-1');

      MonitoringController(engine)
        ..openServer('srv-1')
        ..dispose()
        ..leaveServer('srv-1');
      // The test binding fails a timer still pending here: it would hold
      // the dead controller for the grace, to send nothing.
    });
  });

  group('a server that leaves the fleet (03 §5.1)', () {
    testWidgets('drops its pending Disconnect, so a view back after a '
        're-import within the grace connects again', (tester) async {
      final links = MonitoringController(engine);
      addTearDown(links.dispose);
      links
        ..openServer('srv-1')
        ..leaveServer('srv-1');

      engine.emit(CatalogReplaced([_entry('srv-2')]));
      await tester.pump(kLinkLeaveGrace);
      expect(engine.sentOfType<Disconnect>(), isEmpty);

      engine.emit(CatalogReplaced([_entry('srv-1'), _entry('srv-2')]));
      await tester.pump();
      links.openServer('srv-1');
      expect(engine.sentOfType<Connect>(), hasLength(2));
    });

    test('is sent nothing while gone; views still mounted connect and '
        'subscribe again when it comes back', () async {
      monitoring
        ..openServer('srv-1')
        ..subscribe('srv-1', 'overview', {SampleStream.core});
      engine.emit(CatalogReplaced([_entry('srv-2')]));
      await settle();
      final before = engine.sent.length;

      monitoring
        ..openServer('srv-1')
        ..leaveServer('srv-1')
        ..subscribe('srv-1', 'panel', {SampleStream.procs})
        ..unsubscribe('srv-1', 'overview');
      expect(engine.sent, hasLength(before));

      engine.emit(CatalogReplaced([_entry('srv-1'), _entry('srv-2')]));
      await settle();
      final replayed = engine.sent.skip(before).toList();
      expect(replayed, hasLength(2));
      expect((replayed.first as Connect).serverId, 'srv-1');
      final subscribe = replayed.last as Subscribe;
      expect(
        (subscribe.serverId, subscribe.subscriptionId),
        ('srv-1', 'panel'),
      );
      expect(subscribe.streams, {SampleStream.procs});

      // A fleet that keeps it changes nothing.
      engine.emit(CatalogReplaced([_entry('srv-1')]));
      await settle();
      expect(engine.sent, hasLength(before + 2));
    });

    testWidgets('a view that leaves while it is gone waits out no grace', (
      tester,
    ) async {
      final links = MonitoringController(engine);
      addTearDown(links.dispose);
      links.openServer('srv-1');
      engine.emit(CatalogReplaced(const []));
      await tester.pump();
      links.leaveServer('srv-1');

      engine.emit(CatalogReplaced([_entry('srv-1')]));
      await tester.pump();
      expect(engine.sentOfType<Connect>(), hasLength(1), reason: 'no view');
      links.openServer('srv-1');
      expect(engine.sentOfType<Connect>(), hasLength(2));
      expect(engine.sentOfType<Disconnect>(), isEmpty);
      // The test binding fails a grace timer still pending here.
    });

    test('a view that opens while it is gone connects only once it comes '
        'back', () async {
      monitoring.openServer('srv-1');
      engine.emit(CatalogReplaced(const []));
      await settle();
      monitoring
        ..leaveServer('srv-1')
        ..openServer('srv-1');
      expect(engine.sentOfType<Connect>(), hasLength(1));

      engine.emit(CatalogReplaced([_entry('srv-1')]));
      await settle();
      expect(engine.sentOfType<Connect>(), hasLength(2));
    });

    test('the first fleet replays nothing: the views and surfaces open '
        'before it were sent already', () async {
      monitoring
        ..openServer('srv-1')
        ..subscribe('srv-1', 'overview', {SampleStream.core});
      final sent = engine.sent.length;

      engine.emit(CatalogReplaced([_entry('srv-1')]));
      await settle();
      expect(engine.sent, hasLength(sent));
    });
  });

  // A RequestRejected names no stream, so every OpenLogStream the app
  // sends, a unit-log read's or a Logs panel stream's, waits in one line
  // for its answer (03 §10.1).
  group('log streams (03 §10.1)', () {
    List<String> openIds() => [
      for (final open in engine.sentOfType<OpenLogStream>())
        (open as OpenLogStream).streamId,
    ];

    test('reads and panel streams take ids from one counter and get '
        'their own events', () async {
      final read = monitoring.openLogRead(_unitLogs('nginx.service'));
      final panel = _PanelStream();
      monitoring.logs.open(_panelLog, panel);
      final second = monitoring.openLogRead(_unitLogs('ssh.service'));
      final secondPanel = _PanelStream();
      monitoring.logs.open(_panelLog, secondPanel);

      final ids = openIds();
      expect(ids, ['log-0', 'log-1', 'log-2', 'log-3']);

      // Each event goes to the later stream of its kind, so none reaches
      // a stream merely for being the oldest open or the oldest of its
      // kind.
      engine
        ..emit(LogStreamState(ids[3], const LogStreamRunning()))
        ..emit(
          LogBatch(
            streamId: ids[2],
            records: const [JournalRecord(message: 'started')],
          ),
        );
      await settle();
      expect(read.records, isEmpty);
      expect(read.state, isA<LogReadRequested>());
      expect(second.records, hasLength(1));
      expect(panel.events, isEmpty);
      expect(secondPanel.events, [const LogStreamRunning()]);
    });

    test('one rejection refuses only the oldest open, a read before a '
        'panel stream', () async {
      final read = monitoring.openLogRead(_unitLogs('nginx.service'));
      final panel = _PanelStream();
      monitoring.logs.open(_panelLog, panel);

      engine.emit(_openRejected);
      await settle();
      expect(read.state, isA<LogReadRefused>());
      expect(panel.events, isEmpty);

      engine.emit(_openRejected);
      await settle();
      expect(panel.events, [LogRejection.refused]);
    });

    test('one rejection refuses only the oldest open, a panel stream '
        'before a read', () async {
      final panel = _PanelStream();
      monitoring.logs.open(_panelLog, panel);
      final read = monitoring.openLogRead(_unitLogs('nginx.service'));

      engine.emit(_openRejected);
      await settle();
      expect(panel.events, [LogRejection.refused]);
      expect(read.state, isA<LogReadRequested>());

      engine.emit(_openRejected);
      await settle();
      expect(read.state, isA<LogReadRefused>());
    });

    test('a later open\'s answer also answers a read sent before it', () async {
      final read = monitoring.openLogRead(_unitLogs('nginx.service'));
      final panel = _PanelStream();
      monitoring.logs.open(_panelLog, panel);

      // Answered in order, the read was accepted before the panel stream's
      // answer, so the later rejection is nobody's.
      engine
        ..emit(LogStreamState(openIds()[1], const LogStreamRunning()))
        ..emit(_openRejected);
      await settle();
      expect(read.state, isA<LogReadRequested>());
      expect(panel.events, [const LogStreamRunning()]);
    });

    test('a disposed controller lets go of its streams', () async {
      // A controller of its own, since tearDown disposes the shared one.
      final ownEngine = FakeEngineClient();
      final own = MonitoringController(ownEngine);
      final read = own.openLogRead(_unitLogs('nginx.service'));
      final panel = _PanelStream();
      own.logs.open(_panelLog, panel);

      own.dispose();
      await ownEngine.close();
      await pumpEventQueue();
      expect(read.state, isA<LogReadRequested>());
      expect(panel.events, isEmpty);
    });
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
  group('coverage gaps (03 §9.5 items 5 and 6)', () {
    const core = SampleStream.core;
    final t0 = DateTime.utc(2026, 10, 16, 12);
    DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
    var seq = 0;
    void sample(int seconds, [SampleResult? result]) => engine.emit(
      _sample(
        'srv-1',
        core,
        ++seq,
        at: at(seconds),
        result: result ?? CoreResult(cpu: CpuPercentages(const [], 10)),
      ),
    );
    void phase(SamplingPhase phase, int seconds) => engine.emit(
      SamplingState(serverId: 'srv-1', phase: phase, since: at(seconds)),
    );
    void gap(GapCause cause, int from, int until) => engine.emit(
      Gap(
        serverId: 'srv-1',
        streams: const {core, SampleStream.fs},
        from: at(from),
        until: at(until),
        cause: cause,
      ),
    );

    setUp(() => seq = 0);

    test('a Gap breaks the session ring before the reading that resumes '
        'it', () async {
      monitoring.subscribe('srv-1', 'overview-0', {core});
      sample(0);
      sample(2);
      gap(GapCause.disconnected, 2, 30);
      sample(30);
      await settle();
      expect(
        monitoring.seriesFor('srv-1', core, MetricSeries.cpuBusy).samples,
        [10, 10, null, 10],
      );
    });

    test(
      'the session history labels each gap with why it has no data',
      () async {
        monitoring.subscribe('srv-1', 'overview-0', {core});
        sample(0);
        // The background opens its gap when the phase says so, before
        // readings resume; the Gap then confirms it.
        phase(SamplingPhase.pausedInBackground, 5);
        // Back with the link down: in the foreground from the return, the
        // gap is the link's.
        phase(SamplingPhase.waitingForLink, 60);
        phase(SamplingPhase.sampling, 61);
        gap(GapCause.background, 0, 62);
        sample(62);
        // A link lost while sampling.
        phase(SamplingPhase.waitingForLink, 70);
        phase(SamplingPhase.sampling, 80);
        sample(82);
        // A lost reading, then a collector that failed.
        gap(GapCause.readingLost, 82, 90);
        sample(90);
        sample(92, const CollectorUnavailable(_timeout));
        sample(94);
        // A lost link outranks a failed reading as the cause from then on.
        sample(96, const CollectorUnavailable(_timeout));
        phase(SamplingPhase.waitingForLink, 98);
        gap(GapCause.readingLost, 94, 110);
        sample(110);
        await settle();

        final history = monitoring.historyFor('srv-1', MetricSeries.cpuBusy);
        expect(
          [
            for (final g in history.gaps)
              (g.start.toUtc(), g.end?.toUtc(), g.reason),
          ],
          [
            (at(5), at(60), ChartGapReason.background),
            (at(60), at(62), ChartGapReason.disconnected),
            (at(70), at(82), ChartGapReason.disconnected),
            (at(82), at(90), ChartGapReason.readingFailed),
            (at(92), at(94), ChartGapReason.readingFailed),
            (at(96), at(98), ChartGapReason.readingFailed),
            (at(98), at(110), ChartGapReason.disconnected),
          ],
        );
        expect(history.length, 6);
      },
    );

    test('a controller disposed as a ring stream goes unnamed leaves its '
        'rings alone', () async {
      final own = MonitoringController(engine)
        ..subscribe('srv-1', 'overview-0', {core});
      sample(0);
      await settle();
      own
        ..unsubscribe('srv-1', 'overview-0')
        ..dispose();
      // Whether no subscription names `core` is settled after the turn,
      // when the disposed rings must not be written.
      await settle();
    });

    test('a pause before any reading opens no gap', () async {
      // Shown already, as the coverage card asks for it as it builds.
      final history = monitoring.historyFor('srv-1', MetricSeries.cpuBusy);
      monitoring.subscribe('srv-1', 'overview-0', {core});
      phase(SamplingPhase.pausedInBackground, 5);
      gap(GapCause.readingLost, 5, 9);
      sample(9);
      await settle();
      expect(history.gaps, isEmpty);
      expect(history.length, 1);
    });

    test(
      'a stream nobody names ends its open gap and breaks the line',
      () async {
        monitoring.subscribe('srv-1', 'overview-0', {core});
        sample(0);
        phase(SamplingPhase.pausedInBackground, 5);
        await settle();
        monitoring.unsubscribe('srv-1', 'overview-0');
        await settle();

        final history = monitoring.historyFor('srv-1', MetricSeries.cpuBusy);
        expect(history.gaps.single.end, isNotNull);
        expect(history.valueAt(0, history.length - 1), isNull);
      },
    );

    test('a phone keeps its last background pause for the open servers '
        'the engine was sampling', () async {
      var now = t0;
      final timed = MonitoringController(
        engine,
        now: () => now,
        linkGrace: Duration.zero,
      );
      addTearDown(timed.dispose);
      void awayAndBack() => timed
        ..setAppActivity(AppActivity.background)
        ..setAppActivity(AppActivity.foreground);

      // Subscribed, but the engine never said it sampled (links off):
      // a pause stops nothing.
      timed
        ..openServer('srv-1')
        ..subscribe('srv-1', 'overview-0', {core});
      awayAndBack();
      expect(timed.backgroundPause.value, isNull);

      phase(SamplingPhase.sampling, 0);
      await settle();
      timed.setAppActivity(AppActivity.background);
      now = at(780);
      timed.setAppActivity(AppActivity.foreground);
      final pause = timed.backgroundPause.value!;
      expect((pause.start, pause.end), (t0, at(780)));
      expect(pause.serverIds, {'srv-1'});

      // The next pause replaces it; a dismissal clears it.
      timed.setAppActivity(AppActivity.background);
      expect(timed.backgroundPause.value, isNull);
      timed
        ..setAppActivity(AppActivity.foreground)
        ..dismissBackgroundPause();
      expect(timed.backgroundPause.value, isNull);

      // It belongs to the screen open at the return: leaving clears it,
      // and a server shown only later has no return to tell.
      awayAndBack();
      timed.leaveServer('srv-1');
      expect(timed.backgroundPause.value, isNull);
      awayAndBack();
      expect(timed.backgroundPause.value, isNull);
    });

    test('a server the engine pauses while the app is away counts', () async {
      final timed = MonitoringController(engine, linkGrace: Duration.zero);
      addTearDown(timed.dispose);
      timed
        ..openServer('srv-1')
        ..subscribe('srv-1', 'overview-0', {core});
      phase(SamplingPhase.waitingForLink, 0);
      await settle();

      // Waiting for its link, it had nothing to pause.
      timed
        ..setAppActivity(AppActivity.background)
        ..setAppActivity(AppActivity.foreground);
      expect(timed.backgroundPause.value, isNull);

      timed.setAppActivity(AppActivity.background);
      phase(SamplingPhase.pausedInBackground, 5);
      await settle();
      timed.setAppActivity(AppActivity.foreground);
      expect(timed.backgroundPause.value?.serverIds, {'srv-1'});
    });
  });
}
