/// Spike S5 part 1 (04 §13 S5, 03 §11.4): the engine's side of the
/// performance budgets, measured by replaying committed fixtures through
/// the code the engine runs.
///
/// A spawned isolate plays the engine (D18). It replays the fast
/// sampler of several hosts, each from one platform fixture of
/// `klabautermann_host/test/fixtures` with its counters advancing, plus
/// one `journalctl -f -o json` follow cycling through the fixtures'
/// `journal.txt` rows. Each reply goes through the HWS/1 frame reader,
/// the sample pipeline (parsers, rates, the protocol's [Sample] values)
/// and a `SendPort` to this isolate, which stands in for the UI; the
/// follow's lines go through the journal parser into [LogBatch]es. Ticks
/// run on a real clock. The engine's times are wall time of synchronous
/// code, so CPU time on an idle core; the process CPU from
/// `/proc/self/stat` also counts this isolate and the VM's own threads.
/// `klabautermann/docs/evidence/s5/README.md` describes each figure.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/replay/fixture_replay.dart';
import 'package:klabautermann_core/src/replay/host_fixtures.dart';
import 'package:klabautermann_core/src/sampling/sample_pipeline.dart';
import 'package:klabautermann_core/src/sampling/sampler_session.dart'
    show SamplerReplied;
import 'package:klabautermann_host/klabautermann_host.dart';

import 'heap_probe.dart';
import 'local_sampler.dart' show clockTicksPerSecond, readProcessCpu;

/// The loads the harness knows by name.
enum BudgetScenario {
  /// 03 §6.4's Phone column with ten fleet rows and one server open:
  /// `overview` on every host every 10 s and `core` on the open one
  /// every 3 s.
  phone,

  /// 04 §13 S5's load: ten hosts at 2 s, each reading `core` at the
  /// Desktop column's cadence.
  tenHostsCoreAt2s,
}

/// Whether a run reads the heap.
enum HeapReadings {
  off,

  /// The isolate group's live heap after a forced full collection, read
  /// through the VM service when the engine reads the resident set: at
  /// the window's start and about every tenth. Each reading pauses the
  /// engine isolate for the collection. Only `dart run` (JIT) has the
  /// service.
  afterFullCollection,
}

/// What one run replays: [hosts] fleet rows, the first [openHosts] of
/// them opened (see [ReplaySchedule]), and a follow of
/// [logLinesPerSecond] lines (none at 0); measured for [measure] after
/// [warmup].
final class BudgetPlan {
  const BudgetPlan({
    required this.name,
    required this.hosts,
    required this.overviewEvery,
    required this.openHosts,
    required this.coreEvery,
    required this.logLinesPerSecond,
    required this.warmup,
    required this.measure,
    this.heap = HeapReadings.off,
  });

  factory BudgetPlan.of(
    BudgetScenario scenario, {
    required Duration warmup,
    required Duration measure,
    int logLinesPerSecond = 1000,
    HeapReadings heap = HeapReadings.off,
  }) {
    final (openHosts, coreEvery) = switch (scenario) {
      BudgetScenario.phone => (1, const Duration(seconds: 3)),
      BudgetScenario.tenHostsCoreAt2s => (10, const Duration(seconds: 2)),
    };
    return BudgetPlan(
      name: scenario.name,
      hosts: 10,
      overviewEvery: const Duration(seconds: 10),
      openHosts: openHosts,
      coreEvery: coreEvery,
      logLinesPerSecond: logLinesPerSecond,
      warmup: warmup,
      measure: measure,
      heap: heap,
    );
  }

  final String name;
  final int hosts, openHosts, logLinesPerSecond;
  final Duration overviewEvery, coreEvery, warmup, measure;
  final HeapReadings heap;
}

const _optionNames = {
  'scenario',
  'seconds',
  'warmup',
  'log-rate',
  'fixtures',
  'out',
};

/// `tool/engine_budget.dart`'s [args]: each option's value by name, and
/// whether `--heap` asks for heap readings. Throws [FormatException]
/// naming the argument that does not fit.
({Map<String, String> options, HeapReadings heap}) parseBudgetArgs(
  List<String> args,
) {
  final options = <String, String>{};
  var heap = HeapReadings.off;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--heap') {
      heap = HeapReadings.afterFullCollection;
      continue;
    }
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (!_optionNames.contains(name) || i + 1 == args.length) {
      throw FormatException('unexpected argument ${args[i]}');
    }
    // An option where the value belongs means the value was left out, as
    // in `--out --heap`, which would otherwise write to a file `--heap`.
    final value = args[++i];
    if (value.startsWith('--')) {
      throw FormatException('--$name needs a value, not $value');
    }
    options[name] = value;
  }
  return (options: options, heap: heap);
}

/// `klabautermann_host`'s fixtures, from this package or from
/// `klabautermann/`; null when neither has them.
String? findHostFixtures() {
  for (final path in const [
    '../klabautermann_host/test/fixtures',
    'packages/klabautermann_host/test/fixtures',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  return null;
}

/// Runs [plan] over the fixtures under [fixturesRoot] and returns the
/// evidence JSON.
Future<Map<String, Object?>> runEngineBudget(
  BudgetPlan plan, {
  required String fixturesRoot,
}) async {
  final fixtures = loadHostFixtures(fixturesRoot);
  final journalRows = loadJournalRows(fixturesRoot);
  final clockTicks = Platform.isLinux ? await clockTicksPerSecond() : null;
  final loadStart = _loadavg();
  final heap = switch (plan.heap) {
    HeapReadings.off => null,
    HeapReadings.afterFullCollection => await HeapProbe.open(),
  };
  final port = ReceivePort('klabautermann engine budget');
  final report = Completer<Map<String, Object?>>();
  var messages = 0, samples = 0, logRecords = 0, logDropped = 0;
  // Which hosts got through, and whether their counters gave rates.
  final samplesByServer = <String, int>{};
  final profiled = <String>{};
  var samplesWithCpu = 0, samplesWithDiskRates = 0;
  // One reading at a time.
  final heapBytes = <int>[];
  var heapReads = Future<void>.value();
  port.listen((message) {
    switch (message) {
      case _ReplayReport(:final json):
        report.complete(json);
      case [final Object? error, final Object? stack]:
        if (!report.isCompleted) {
          report.completeError(StateError('the replay failed: $error\n$stack'));
        }
      case _ReadHeap():
        heapReads = heapReads.then(
          (_) async => heapBytes.add(await heap!.liveHeapBytes()),
        );
      case LogBatch(:final records, :final dropped):
        messages++;
        logRecords += records.length;
        logDropped += dropped;
      case Sample(:final serverId, :final result):
        messages++;
        samples++;
        samplesByServer.update(serverId, (n) => n + 1, ifAbsent: () => 1);
        if (result case OverviewResult(cpu: _?) || CoreResult(cpu: _?)) {
          samplesWithCpu++;
        }
        if (result case CoreResult(disks: _?)) samplesWithDiskRates++;
      case HostProfileChanged(:final serverId):
        messages++;
        profiled.add(serverId);
      case EngineEvent():
        messages++;
    }
  });

  Isolate? engine;
  try {
    engine = await Isolate.spawn(
      _replayEngine,
      (
        ui: port.sendPort,
        plan: plan,
        fixtures: fixtures,
        journalRows: journalRows,
        clockTicks: clockTicks,
      ),
      onError: port.sendPort,
      debugName: 'klabautermann engine budget',
    );
    final measured = await report.future.timeout(
      plan.warmup + plan.measure + const Duration(minutes: 1),
    );
    await heapReads;
    return {
      'schemaVersion': 1,
      'tool': 'klabautermann_core/tool/engine_budget.dart',
      'measuredAt': DateTime.now().toUtc().toIso8601String(),
      'runtime': {
        'dart': Platform.version,
        'mode': const bool.fromEnvironment('dart.vm.product') ? 'aot' : 'jit',
      },
      'machine': {
        'os': Platform.operatingSystemVersion,
        'cpus': Platform.numberOfProcessors,
        'cpuModel': _cpuModel(),
        // Other work on the machine shows here (proc_loadavg(5)).
        'loadavg': {'start': loadStart, 'end': _loadavg()},
      },
      'plan': {
        'name': plan.name,
        'hosts': [
          for (var i = 0; i < plan.hosts; i++)
            fixtures[i % fixtures.length].platform,
        ],
        'overviewEveryMs': plan.overviewEvery.inMilliseconds,
        'openHosts': plan.openHosts,
        'coreEveryMs': plan.coreEvery.inMilliseconds,
        'logLinesPerSecond': plan.logLinesPerSecond,
        'journalRows': journalRows.length,
        'journalRowBytesMean': _round(
          journalRows.fold(0, (sum, row) => sum + utf8.encode(row).length) /
              journalRows.length,
        ),
        'warmupSeconds': plan.warmup.inMicroseconds / 1e6,
        'measureSeconds': plan.measure.inMicroseconds / 1e6,
        'heap': plan.heap.name,
      },
      ...measured,
      'heapAfterFullCollectionBytes': heap == null ? null : heapBytes,
      // What crossed the isolate hop in the whole run, warm-up included.
      'ui': {
        'messages': messages,
        'samples': samples,
        'samplesByServer': samplesByServer,
        'samplesWithCpu': samplesWithCpu,
        'samplesWithDiskRates': samplesWithDiskRates,
        'serversProfiled': profiled.length,
        'logRecords': logRecords,
        'logDropped': logDropped,
      },
    };
  } finally {
    // A replay that timed out would otherwise keep ticking; one that
    // reported has already exited.
    engine?.kill(priority: Isolate.immediate);
    port.close();
    // A reading still running when the replay failed would fail on the
    // closed probe, and that unawaited error would mask the replay's own.
    await heapReads.catchError((Object _) {});
    await heap?.close();
  }
}

String? _loadavg() =>
    Platform.isLinux ? File('/proc/loadavg').readAsStringSync().trim() : null;

String? _cpuModel() {
  if (!Platform.isLinux) return null;

  for (final line in File('/proc/cpuinfo').readAsLinesSync()) {
    if (line.startsWith('model name')) {
      return line.substring(line.indexOf(':') + 1).trim();
    }
  }
  return null;
}

typedef _ReplaySetup = ({
  SendPort ui,
  BudgetPlan plan,
  List<HostFixture> fixtures,
  List<String> journalRows,
  int? clockTicks,
});

/// The engine's request for a heap reading.
final class _ReadHeap {
  const _ReadHeap();
}

/// The engine isolate's last message: its measurements.
final class _ReplayReport {
  const _ReplayReport(this.json);

  final Map<String, Object?> json;
}

void _replayEngine(_ReplaySetup setup) => _Replay(setup).start();

/// One replayed host: its fast sampler's reader, its pipeline and every
/// reply the run can ask of it, by slot.
final class _Host {
  _Host({
    required this.fixture,
    required this.serverId,
    required this.collector,
    required this.streams,
    required this.replies,
    required this.pipeline,
  });

  final HostFixture fixture;
  final String serverId;
  final Collector collector;
  final Set<SampleStream> streams;
  final List<Uint8List> replies;
  final ServerSamplePipeline pipeline;
  final assembler = HwsTickAssembler(nonce: replayNonce);
}

/// The measurements of the window after the warm-up.
final class _Window {
  _Window(
    this.start, {
    required this.skippedBefore,
    required this.droppedBefore,
  });

  final Duration start;
  final int skippedBefore, droppedBefore;
  final int? cpuTicksBefore = Platform.isLinux
      ? readProcessCpu(pid).self
      : null;

  /// The resident set size at the start and about every tenth of the
  /// window, and the most seen in the once-a-second readings.
  final rss = [ProcessInfo.currentRss];
  late int rssMax = rss.first;

  final tickUs = <int>[], frameUs = <int>[], pipelineUs = <int>[];
  final sendUs = <int>[], batchUs = <int>[], recordsPerBatch = <int>[];
  final replyBytes = <Collector, List<int>>{};
  var events = 0, feedUs = 0, linesFed = 0, bytesFed = 0;
}

final class _Replay {
  _Replay(this._setup)
    : _schedule = ReplaySchedule(
        hosts: _setup.plan.hosts,
        overviewEvery: _setup.plan.overviewEvery,
        openHosts: _setup.plan.openHosts,
        coreEvery: _setup.plan.coreEvery,
      ),
      _follow = FollowReplay(
        streamId: 'follow-1',
        maxPending: math.max(1, _setup.plan.logLinesPerSecond),
      );

  final _ReplaySetup _setup;
  final ReplaySchedule _schedule;
  final FollowReplay _follow;
  final _sequence = SampleSequence();
  final _clock = Stopwatch();
  final _startedAt = DateTime.now().toUtc();
  late final List<_Host> _hosts;

  /// One second of the follow's lines.
  late final JournalFeed _journal;

  _Window? _window;
  var _linesFed = 0;
  var _lastRss = Duration.zero;

  BudgetPlan get _plan => _setup.plan;

  void start() {
    _journal = JournalFeed(_setup.journalRows, _plan.logLinesPerSecond);
    final end = _plan.warmup + _plan.measure;
    _hosts = [
      for (var i = 0; i < _plan.hosts; i++)
        _host(i, _setup.fixtures[i % _setup.fixtures.length], end),
    ];

    // The link is up and the probe answered before the first tick, as
    // after a connect (03 §6.1); none of it is measured.
    for (final host in _hosts) {
      host.assembler.push(readyFrame());
      host.pipeline
          .updateConditions(
            streams: host.streams,
            linkReady: true,
            activity: AppActivity.foreground,
            at: _startedAt,
          )
          .forEach(_send);
      // The probe runs on the slow sampler, a session of its own.
      final probe = HwsTickAssembler(nonce: replayNonce)..push(readyFrame());
      final tick = probe.push(replyFrame(1, null, host.fixture.probe)).single;
      host.pipeline.addProbe(SamplerReplied(tick as HwsTick)).forEach(_send);
    }

    _clock.start();
    Timer.periodic(const Duration(milliseconds: 10), _step);
  }

  _Host _host(int i, HostFixture fixture, Duration end) {
    final collector = _schedule.collectorOf(i);
    final payload = collector == Collector.core
        ? fixture.core
        : fixture.overview;
    final uptime = fixtureUptime(fixture.core) ?? 1000;
    final serverId = 'host-$i-${fixture.platform}';
    // Framed before the clock starts, so the host's side costs nothing
    // in the run.
    Uint8List reply(int slot) {
      final seconds = _schedule.slotTime(i, slot).inMicroseconds / 1e6;
      return replyFrame(slot + 1, uptime + seconds, [
        (
          name: collector.wireName,
          status: SectionStatus.ok,
          payload: advanceCounters(payload, seconds),
        ),
      ]);
    }

    return _Host(
      fixture: fixture,
      serverId: serverId,
      collector: collector,
      streams: _schedule.streamsOf(i),
      replies: [
        for (var slot = 0; slot < _schedule.slotsWithin(i, end); slot++)
          reply(slot),
      ],
      pipeline: ServerSamplePipeline(serverId: serverId, sequence: _sequence),
    );
  }

  void _send(EngineEvent event) => _setup.ui.send(event);

  void _step(Timer timer) {
    final now = _clock.elapsed;
    if (now >= _plan.warmup + _plan.measure) {
      timer.cancel();
      // The lines due by now still reach the follow, so a step that a
      // loaded machine delays to the end leaves the follow no shorter.
      if (_plan.logLinesPerSecond > 0) _feed(now);
      _finish(now);
      return;
    }
    if (_window == null && now >= _plan.warmup) {
      _window = _Window(
        now,
        skippedBefore: _schedule.skipped,
        droppedBefore: _follow.dropped,
      );
      _readHeap();
    }

    for (final due in _schedule.due(now)) {
      _tick(_hosts[due.host], due.slot, now);
    }
    if (_plan.logLinesPerSecond > 0) _feed(now);
    _flush(now);

    final window = _window;
    if (window != null && now - _lastRss >= const Duration(seconds: 1)) {
      _lastRss = now;
      final rss = ProcessInfo.currentRss;
      window.rssMax = math.max(window.rssMax, rss);
      if (now - window.start >= _plan.measure * (window.rss.length / 10)) {
        window.rss.add(rss);
        _readHeap();
      }
    }
  }

  void _readHeap() {
    if (_plan.heap == HeapReadings.off) return;

    _setup.ui.send(const _ReadHeap());
  }

  void _tick(_Host host, int slot, Duration now) {
    final bytes = host.replies[slot];
    final clock = Stopwatch()..start();
    final assembled = host.assembler.push(bytes);
    final framed = clock.elapsedMicroseconds;
    final tick = assembled.single;
    if (tick is! HwsTick) {
      throw StateError('${host.serverId} slot $slot did not assemble: $tick');
    }
    final events = host.pipeline.addTick(
      host.streams,
      SamplerReplied(tick),
      _startedAt.add(now),
    );
    final piped = clock.elapsedMicroseconds;
    events.forEach(_send);
    final sent = clock.elapsedMicroseconds;

    final window = _window;
    if (window == null) return;

    window.tickUs.add(sent);
    window.frameUs.add(framed);
    window.pipelineUs.add(piped - framed);
    window.sendUs.add(sent - piped);
    (window.replyBytes[host.collector] ??= []).add(bytes.length);
    window.events += events.length;
  }

  /// Hands the follow the lines due by [now] at the plan's rate.
  void _feed(Duration now) {
    final due =
        _plan.logLinesPerSecond *
        now.inMicroseconds ~/
        Duration.microsecondsPerSecond;
    final lines = due - _linesFed;
    if (lines <= 0) return;

    final clock = Stopwatch()..start();
    final bytes = _journal.feed(_follow, lines);
    _linesFed += lines;

    final window = _window;
    if (window == null) return;

    window.feedUs += clock.elapsedMicroseconds;
    window.linesFed += lines;
    window.bytesFed += bytes;
  }

  void _flush(Duration now) {
    final clock = Stopwatch()..start();
    final batch = _follow.flush(now);
    if (batch == null) return;

    _send(batch);
    final window = _window;
    if (window == null) return;

    window.batchUs.add(clock.elapsedMicroseconds);
    window.recordsPerBatch.add(batch.records.length);
  }

  void _finish(Duration now) {
    final window = _window;
    if (window == null) {
      throw StateError('the run ended before its warm-up did');
    }

    final seconds = (now - window.start).inMicroseconds / 1e6;
    final ticksUs = window.tickUs.fold(0, (a, b) => a + b);
    final batchesUs = window.batchUs.fold(0, (a, b) => a + b);
    final busyUs = ticksUs + window.feedUs + batchesUs;
    final cpuBefore = window.cpuTicksBefore, ticksPerSecond = _setup.clockTicks;
    final records = window.recordsPerBatch.fold(0, (a, b) => a + b);
    final replyBytes = window.replyBytes.values.expand((b) => b);

    Isolate.exit(
      _setup.ui,
      _ReplayReport({
        'windowSeconds': _round(seconds),
        'ticks': {
          'count': window.tickUs.length,
          'perSecond': _round(window.tickUs.length / seconds),
          'skipped': _schedule.skipped - window.skippedBefore,
          'engineMs': _msStats(window.tickUs),
          'frameMs': _msStats(window.frameUs),
          'pipelineMs': _msStats(window.pipelineUs),
          'sendMs': _msStats(window.sendUs),
          'eventsPerTick': window.tickUs.isEmpty
              ? null
              : _round(window.events / window.tickUs.length),
          'replyBytes': {
            for (final MapEntry(key: collector, value: bytes)
                in window.replyBytes.entries)
              collector.wireName: _countStats(bytes),
          },
          'replyBytesPerSecond': _round(
            replyBytes.fold(0, (a, b) => a + b) / seconds,
          ),
        },
        'log': {
          'linesFed': window.linesFed,
          'linesPerSecond': _round(records / seconds),
          'inputBytesPerSecond': _round(window.bytesFed / seconds),
          'batches': window.batchUs.length,
          'batchesPerSecond': _round(window.batchUs.length / seconds),
          'recordsPerBatch': _countStats(window.recordsPerBatch),
          'parseMsPerSecond': _round(window.feedUs / 1000 / seconds),
          'batchSendMs': _msStats(window.batchUs),
          'dropped': _follow.dropped - window.droppedBefore,
          // Whole run: every line parsed was sent, dropped or is pending.
          'malformed': _follow.malformed,
          'maxPending': _follow.maxPendingSeen,
          'runLinesParsed': _follow.linesParsed,
          'pendingAtEnd': _follow.pending,
        },
        'engine': {
          'busyMsPerSecond': _round(busyUs / 1000 / seconds),
          'busyPercentOfOneCore': _round(busyUs / 10000 / seconds),
        },
        'process': {
          'cpuMsPerSecond': cpuBefore == null || ticksPerSecond == null
              ? null
              : _round(
                  (readProcessCpu(pid).self - cpuBefore) *
                      1000 /
                      ticksPerSecond /
                      seconds,
                ),
          'rssBytes': {
            'max': math.max(window.rssMax, ProcessInfo.currentRss),
            'series': [...window.rss, ProcessInfo.currentRss],
          },
          // The replies framed up front, held for the whole run.
          'replayReplyBytes': _hosts.fold(
            0,
            (sum, host) =>
                sum + host.replies.fold(0, (sum, reply) => sum + reply.length),
          ),
        },
      }),
    );
  }
}

double _round(num value) => (value * 1000).round() / 1000;

/// [micros] as milliseconds: nearest-rank median and 99th percentile,
/// the maximum and the mean.
Map<String, num> _msStats(List<int> micros) {
  if (micros.isEmpty) return const {};

  final sorted = [...micros]..sort();
  double ms(num us) => _round(us / 1000);
  int rank(double q) => sorted[math.max(0, (q * sorted.length).ceil() - 1)];
  return {
    'p50': ms(rank(0.5)),
    'p99': ms(rank(0.99)),
    'max': ms(sorted.last),
    'mean': ms(sorted.fold(0, (a, b) => a + b) / sorted.length),
  };
}

Map<String, num> _countStats(Iterable<int> values) {
  if (values.isEmpty) return const {};

  final sorted = [...values]..sort();
  return {
    'min': sorted.first,
    'median': sorted[(sorted.length - 1) ~/ 2],
    'max': sorted.last,
  };
}
