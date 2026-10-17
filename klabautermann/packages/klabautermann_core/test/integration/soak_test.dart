// The soak and the performance budgets of 03 §11.4 against the sshd
// fixture (K28b): ten aliases of the sampled host, each its own fleet
// server with its own link, at the Phone cadence with one server open,
// for KLABAUTERMANN_SOAK_SECONDS after a warm-up (run.sh: 600 on GitHub
// Actions, 60 elsewhere). It asserts no growth in channels per link,
// descriptors, live heap or resident set, 03 §11.4's fast-tick bytes and
// its ten-host bandwidth; it records the engine process's CPU and the
// links' SSH bytes, which 03 sets no budget for,
// and writes every reading to $KLABAUTERMANN_SOAK_DIR/soak.json before
// it asserts. The server CPU per fast tick is recorded against 03
// §11.4's 5 ms, which 03 gives for its reference VM, not asserted (see
// kFastTickServerCpuMs). run.sh's soak block runs it alone; without that
// block it skips.
@Tags(['soak'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, SamplerKind;
import 'package:test/test.dart';

import '../../tool/src/heap_probe.dart';
import '../../tool/src/local_sampler.dart'
    show clockTicksPerSecond, readProcessCpu;
import 'support/fixture.dart';
import 'support/link_meter.dart';
import 'support/soak.dart';

/// 03 §6.4's Phone column: a fleet row's `overview` every 10 s, and the
/// open server's `core` every 3 s, whose reply also serves its row.
const _overviewEvery = Duration(seconds: 10);
const _coreEvery = Duration(seconds: 3);

/// Covers connecting ten links and their first readings before the
/// warm-up, and disconnecting them after the window.
const _setupAllowance = Duration(minutes: 5);

/// The server whose screen is open, as in S5's `phone` scenario.
final _open = aliasServer(0);

void main() {
  final fixture = Fixture.fromEnvironment();
  final config = SoakConfig.fromEnvironment();
  if (fixture == null || config == null) {
    test('the soak', () {}, skip: soakSkipReason);
    return;
  }

  test(
    'ten hosts at the Phone cadence keep 03 §11.4 for '
    '${config.window.inSeconds} s',
    () => _Soak(fixture, config).run(),
    timeout: Timeout(config.warmup + config.window + _setupAllowance),
  );
}

/// One run of the soak.
final class _Soak {
  _Soak(this._fixture, this._config);

  final Fixture _fixture;
  final SoakConfig _config;
  late final HeapProbe _heap;
  late final LinkMeter _meter;

  /// The window's readings, the first at its start, timed by [_window].
  final _readings = <_Reading>[];
  final _window = Stopwatch();

  /// What reached the test during the window: samples by server and
  /// stream, and the events a steady soak has none of.
  final _samples = <String, Map<String, int>>{};
  final _unsteady = <String>[];

  Future<void> run() async {
    final clockTicks = await clockTicksPerSecond();
    // The VM service it may start holds descriptors of its own, opened
    // here, before the first reading.
    _heap = await HeapProbe.open();
    addTearDown(_heap.close);
    _meter = LinkMeter();
    addTearDown(_meter.close);
    final hostKeys = await _fixture.hostKeys();
    // The CPUs the sampled host's /proc/stat lists, which its `core`
    // reply carries one line each of (D48).
    final cpus = int.parse(
      (await _fixture.exec(FixtureService.sshd, [
        'sh',
        '-c',
        "grep -c '^cpu[0-9]' /proc/stat",
      ])).trim(),
    );
    final loadStart = _loadavg();

    final engine = await FixtureEngine.startAliases(
      _fixture,
      'soak',
      count: kSoakHosts,
      evidenceDirectory: _config.evidenceDirectory,
      entryPoint: _meter.entryPoint,
    );
    engine.send(const SetCadenceProfile(CadenceProfile.phone));

    // The open server first and alone, so the sampler shells that appear
    // are its own.
    final before = {for (final shell in await _shells()) shell.pid};
    await engine.connect(_open, hostKeys);
    await engine.subscribe(_open, {SampleStream.overview, SampleStream.core});
    await engine.sample(_open, SampleStream.core);
    final openShells = {
      for (final shell in await _shells())
        if (!before.contains(shell.pid)) shell.pid,
    };
    expect(openShells, hasLength(2), reason: 'the open server\'s samplers');
    for (var i = 1; i < kSoakHosts; i++) {
      await engine.connect(aliasServer(i), hostKeys);
      await engine.subscribe(aliasServer(i), {SampleStream.overview});
    }
    for (var i = 1; i < kSoakHosts; i++) {
      await engine.firstSample(aliasServer(i), SampleStream.overview);
    }

    engine.note('warm-up of ${_config.warmup.inSeconds} s');
    await engine.pump(_config.warmup, (_) {});

    engine.note('window of ${_config.window.inSeconds} s');
    _window.start();
    _readings.add(await _read());
    for (var i = 1; i <= SoakConfig.readingsPerWindow; i++) {
      await engine.pump(_config.interval * i - _window.elapsed, _tally);
      if (_readings.length > 1) _readings.last = _readings.last.slim();
      _readings.add(await _read());
    }

    final report = _report(
      cpus: cpus,
      clockTicks: clockTicks,
      openFastShell: openShells.reduce((a, b) => a > b ? a : b),
      loadStart: loadStart,
    );
    final file = File('${_config.evidenceDirectory}/soak.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report.json)}\n',
    );
    print(report.summary.join('\n'));

    if (report.failures.isNotEmpty) {
      fail(
        '${report.failures.length} of 03 §11.4\'s checks failed; every '
        'reading is in ${file.path}:\n'
        '${report.failures.map((f) => '- $f').join('\n')}',
      );
    }
  }

  void _tally(EngineEvent event) {
    final seconds = _window.elapsedMilliseconds / 1000;
    switch (event) {
      case Sample(:final serverId, :final stream):
        (_samples[serverId] ??= {}).update(
          stream.name,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      case Gap(:final serverId, :final streams, :final cause):
        _unsteady.add(
          '${round3(seconds)} s: gap on $serverId (${cause.name}) for '
          '${[for (final s in streams) s.name].join(', ')}',
        );
      case LinkState(:final serverId, :final status):
        _unsteady.add(
          '${round3(seconds)} s: $serverId link ${status.runtimeType}',
        );
      case SamplingState(:final serverId, :final phase):
        _unsteady.add('${round3(seconds)} s: $serverId ${phase.name}');
      case RequestRejected(:final requestName, :final reason):
        _unsteady.add('${round3(seconds)} s: $requestName rejected: $reason');
      default:
        break;
    }
  }

  /// The sampler shells on the sampled host with their CPU.
  Future<List<ShellCpu>> _shells() async => parseShellStats(
    await _fixture.exec(FixtureService.sshd, [
      'sh',
      '-c',
      r'for pid in $(fixture-samplers); do '
          r'cat "/proc/$pid/stat" 2>/dev/null || true; done',
    ]),
  );

  /// Payload bytes of each TCP connection to the fixture's published
  /// port, or the reason there are none: `ss` is iproute2's, which
  /// GitHub's Ubuntu runners have and a container may lack.
  Future<({Map<String, WireBytes>? connections, String? missing})>
  _wire() async {
    final ProcessResult result;
    try {
      result = await Process.run('ss', [
        '-tinH',
        'state',
        'established',
        'dport',
        '=',
        ':${_fixture.direct.port}',
      ]);
    } on ProcessException catch (error) {
      return (connections: null, missing: 'no ss: ${error.message}');
    }
    if (result.exitCode != 0) {
      return (
        connections: null,
        missing: 'ss exited ${result.exitCode}: ${result.stderr}',
      );
    }
    return (connections: parseSsTcpInfo('${result.stdout}'), missing: null);
  }

  Future<_Reading> _read() async {
    final at = _window.elapsed;
    // The descriptor count first, before this reading opens any.
    final fds = Directory('/proc/self/fd').listSync().length;
    final rss = ProcessInfo.currentRss;
    final processCpuTicks = readProcessCpu(pid).self;
    final heapBytes = await _heap.liveHeapBytes();
    return _Reading(
      at: at,
      fds: fds,
      rssBytes: rss,
      heapBytes: heapBytes,
      processCpuTicks: processCpuTicks,
      links: await _meter.read(),
      shells: await _shells(),
      wire: await _wire(),
    );
  }

  _Report _report({
    required int cpus,
    required int clockTicks,
    required int openFastShell,
    required String? loadStart,
  }) {
    final first = _readings.first, last = _readings.last;
    final seconds = (last.at - first.at).inMicroseconds / 1e6;
    final failures = <String>[];
    final summary = <String>[];
    double ms(int ticks) => ticks * 1000 / clockTicks;

    // -- Fast-tick bytes (03 §11.4, D48) ------------------------------
    final tickBudget = fastTickByteBudget(cpus);
    final ticksByServer = <String, Map<String, Map<String, num>>>{};
    final fastTicksByServer = <String, int>{};
    var largest = (bytes: 0, server: '', collectors: '');
    var replyBytes = 0;
    for (final (index, link) in last.linkList.indexed) {
      final serverId = link['serverId']! as String;
      final startReplies = first.repliesOf(index);
      final byCollectors = <String, Map<String, num>>{};
      for (final MapEntry(key: collectors, value: all)
          in (link['replies']! as Map<String, Object?>).entries) {
        final window = (all! as List<Object?>)
            .skip(startReplies[collectors]?.length ?? 0)
            .cast<int>()
            .toList();
        if (window.isEmpty) continue;

        byCollectors[collectors] = countStats(window);
        replyBytes += window.fold(0, (a, b) => a + b);
        if (!_fast(collectors)) continue;

        fastTicksByServer.update(
          serverId,
          (n) => n + window.length,
          ifAbsent: () => window.length,
        );
        for (final bytes in window) {
          if (bytes > largest.bytes) {
            largest = (bytes: bytes, server: serverId, collectors: collectors);
          }
        }
      }
      ticksByServer[serverId] = byCollectors;
    }
    summary.add(
      'largest fast tick: ${largest.bytes} B (${largest.collectors} on '
      '${largest.server}); budget $tickBudget B at $cpus CPUs',
    );
    if (largest.bytes == 0) {
      failures.add(
        'fast ticks: none in the window, so the tick budget was not '
        'measured; see soak.json ticks and soak.events',
      );
    } else if (largest.bytes > tickBudget) {
      failures.add(
        'fast tick: a `${largest.collectors}` reply on ${largest.server} '
        'was ${largest.bytes} B, over 03 §11.4\'s $tickBudget B for $cpus '
        'CPUs (2.5 KB plus 30 B per CPU beyond 32, D48): trim that '
        'fragment on the host (klabautermann_host collectors) or amend '
        '11.4; soak.json ticks has every server\'s sizes',
      );
    }

    // -- Ten-host bandwidth (03 §11.4) --------------------------------
    var channelBytes = 0, requestBytes = 0;
    for (final (index, link) in last.linkList.indexed) {
      final start = first.linkList.elementAtOrNull(index) ?? const {};
      int delta(String key) =>
          (link[key]! as int) - ((start[key] as int?) ?? 0);
      channelBytes += delta('stdoutBytes') + delta('stderrBytes');
      requestBytes += delta('stdinBytes');
    }
    final bytesPerSecond = channelBytes / seconds;
    summary.add(
      'ten hosts: ${round3(bytesPerSecond)} B/s of channel output '
      '(${round3(replyBytes / seconds)} B/s in replies); budget '
      '$kTenHostBytesPerSecond B/s',
    );
    if (bytesPerSecond >= kTenHostBytesPerSecond) {
      failures.add(
        'ten-host bandwidth: the hosts sent ${round3(bytesPerSecond)} B/s '
        'on their channels over ${round3(seconds)} s, not under 03 '
        '§11.4\'s $kTenHostBytesPerSecond B/s at the Phone cadence with '
        'one server open; soak.json ticks shows which replies grew',
      );
    }

    // -- Server CPU per fast tick (03 §11.4) --------------------------
    final startCpu = {for (final s in first.shells) s.pid: s.cpuTicks};
    final endCpu = {for (final s in last.shells) s.pid: s.cpuTicks};
    final fast = fastShells(last.shells);
    final restarted = fastShells(first.shells).difference(fast);
    var openTicks = 0, rowTicks = 0;
    for (final MapEntry(key: server, value: ticks)
        in fastTicksByServer.entries) {
      server == _open ? openTicks += ticks : rowTicks += ticks;
    }
    var openCpu = 0, rowCpu = 0;
    for (final shell in fast) {
      final used = (endCpu[shell] ?? 0) - (startCpu[shell] ?? 0);
      shell == openFastShell ? openCpu += used : rowCpu += used;
    }
    Map<String, Object?> perTick(int cpuTicks, int ticks) => {
      'ticks': ticks,
      'cpuMs': round3(ms(cpuTicks)),
      'msPerTick': ticks == 0 ? null : round3(ms(cpuTicks) / ticks),
    };
    final serverCpu = {
      'openServer': perTick(openCpu, openTicks),
      'fleetRows': perTick(rowCpu, rowTicks),
    };
    summary.add(
      'server CPU per fast tick: $serverCpu; budget '
      '$kFastTickServerCpuMs ms (recorded)',
    );
    if (restarted.isNotEmpty) {
      failures.add(
        'sampler shells: fast samplers ${restarted.join(', ')} were gone '
        'by the window\'s end, so a sampler restarted during the soak '
        '(soak.events has its gap); no CPU per tick without them',
      );
    }
    for (final MapEntry(:key, value: figures) in serverCpu.entries) {
      final perTick = figures['msPerTick'] as double?;
      if (perTick == null) {
        failures.add('server CPU ($key): no fast ticks in the window');
      } else if (perTick > kFastTickServerCpuMs) {
        // Recorded, not asserted (kFastTickServerCpuMs): the summary and
        // soak.json say so, and the job stays green.
        summary.add(
          'NOTE server CPU ($key): $perTick ms of sampler-shell CPU per '
          'fast tick, over 03 §11.4\'s $kFastTickServerCpuMs ms for the '
          'reference VM [E]; this runner is not that VM, so it is '
          'recorded only',
        );
      }
    }

    // -- No growth (03 §11.4) -----------------------------------------
    final growth = [
      growthOf('descriptors', [
        for (final r in _readings) r.fds,
      ], tolerance: kDescriptorGrowth),
      growthOf('heapBytes', [
        for (final r in _readings) r.heapBytes,
      ], tolerance: kHeapGrowthBytes),
      growthOf('rssBytes', [
        for (final r in _readings) r.rssBytes,
      ], tolerance: kRssGrowthBytes),
    ];
    for (final check in growth.where((g) => !g.ok)) {
      failures.add(
        '${check.series} grew by ${check.growth} (median of the window\'s '
        'first third ${check.first}, of its last ${check.last}), beyond '
        'the ${check.tolerance} 03 §11.4\'s "no growth" allows here: '
        'compare soak.json readings[].${check.series}',
      );
    }
    for (var index = 0; index < kSoakHosts; index++) {
      final counts = [for (final r in _readings) r.channelsOf(index)];
      final rose = counts.indexWhere((n) => n > counts.first + kChannelGrowth);
      if (rose < 0) continue;
      failures.add(
        'channels: ${aliasServer(index)} held ${counts[rose]} channels at '
        '${round3(_readings[rose].at.inMilliseconds / 1000)} s, '
        '${counts.first} at the window\'s start: a channel the engine '
        'opened and kept (03 §5.2); soak.json readings[].channelsByLink has them',
      );
    }
    final dials = last.links['dials']! as int;
    if (dials != kSoakHosts) {
      failures.add(
        'links: the engine dialed $dials links for $kSoakHosts hosts, so '
        'a link was lost and redialed; soak.events has its states',
      );
    }

    // -- Steady sampling ----------------------------------------------
    if (_unsteady.isNotEmpty) {
      failures.add(
        'sampling was not steady in the window: '
        '${_unsteady.take(5).join('; ')}'
        '${_unsteady.length > 5 ? ' and ${_unsteady.length - 5} more' : ''}',
      );
    }
    for (var index = 0; index < kSoakHosts; index++) {
      final serverId = aliasServer(index);
      final (stream, every) = serverId == _open
          ? (SampleStream.core, _coreEvery)
          : (SampleStream.overview, _overviewEvery);
      final expected = seconds * 1000 ~/ every.inMilliseconds - 1;
      final got = _samples[serverId]?[stream.name] ?? 0;
      if (got < expected) {
        failures.add(
          'samples: $serverId had $got `${stream.name}` samples in '
          '${round3(seconds)} s, under the $expected its Phone period of '
          '${every.inSeconds} s gives (03 §6.4): ticks were skipped or '
          'lost; soak.events has the sampler states',
        );
      }
    }

    // -- Recorded only ------------------------------------------------
    final engineCpuMsPerSecond =
        ms(last.processCpuTicks - first.processCpuTicks) / seconds;
    summary.add(
      'engine process CPU: ${round3(engineCpuMsPerSecond)} ms/s (recorded)',
    );
    final wire = _wireDelta(first, last, seconds);
    summary.add('SSH payload on the wire: $wire (recorded)');

    return _Report(
      json: {
        'schemaVersion': 1,
        'tool': 'klabautermann_core/test/integration/soak_test.dart',
        'measuredAt': DateTime.now().toUtc().toIso8601String(),
        'runtime': {'dart': Platform.version, 'mode': 'jit'},
        'machine': {
          'os': Platform.operatingSystemVersion,
          'cpus': Platform.numberOfProcessors,
          'githubActions': Platform.environment['GITHUB_ACTIONS'] == 'true',
          // Other work on the machine shows here (proc_loadavg(5)).
          'loadavg': {'start': loadStart, 'end': _loadavg()},
        },
        'plan': {
          'hosts': [for (var i = 0; i < kSoakHosts; i++) aliasServer(i)],
          'cadence': CadenceProfile.phone.name,
          'openServer': _open,
          'streams': {
            _open: [SampleStream.overview.name, SampleStream.core.name],
            'others': [SampleStream.overview.name],
          },
          'warmupSeconds': _config.warmup.inSeconds,
          'windowSeconds': round3(seconds),
          'intervalSeconds': _config.interval.inMilliseconds / 1000,
          'sampledHostCpus': cpus,
        },
        'budgets': [
          {
            'name': 'fastTickBytes',
            'spec': '03 §11.4, D48: 2.5 KB plus 30 B per CPU beyond 32',
            'limit': tickBudget,
            'measured': largest.bytes,
            'asserted': true,
          },
          {
            'name': 'fastTickServerCpuMs',
            'spec': '03 §11.4: 5 ms of server CPU on the reference VM [E]',
            'limit': kFastTickServerCpuMs,
            'measured': serverCpu,
            'overBudget': [
              for (final MapEntry(:key, value: figures) in serverCpu.entries)
                if (((figures['msPerTick'] as double?) ?? 0) >
                    kFastTickServerCpuMs)
                  key,
            ],
            'asserted': false,
          },
          {
            'name': 'tenHostBytesPerSecond',
            'spec': '03 §11.4: 10 hosts at the phone cadence under 1 KB/s',
            'limit': kTenHostBytesPerSecond,
            'measured': round3(bytesPerSecond),
            'replyBytesPerSecond': round3(replyBytes / seconds),
            'requestBytesPerSecond': round3(requestBytes / seconds),
            'asserted': true,
          },
        ],
        'growth': [for (final g in growth) g.toJson()],
        'ticks': ticksByServer,
        'samples': _samples,
        'unsteady': _unsteady,
        'serverCpu': {
          'clockTicksPerSecond': clockTicks,
          ...serverCpu,
          'shells': [
            for (final shell in last.shells)
              {
                'pid': shell.pid,
                'ppid': shell.ppid,
                'fast': fast.contains(shell.pid),
                'openServer': shell.pid == openFastShell,
                'cpuTicks': shell.cpuTicks - (startCpu[shell.pid] ?? 0),
              },
          ],
        },
        'recorded': {
          'engineProcessCpuMsPerSecond': round3(engineCpuMsPerSecond),
          'sshPayload': wire,
        },
        'readings': [for (final r in _readings) r.json],
      },
      summary: summary,
      failures: failures,
    );
  }

  /// The SSH payload bytes the fixture's connections carried in the
  /// window, by the kernel's count, or why there is no count.
  Map<String, Object?> _wireDelta(
    _Reading first,
    _Reading last,
    double seconds,
  ) {
    final start = first.wire.connections, end = last.wire.connections;
    if (start == null || end == null) {
      return {'available': false, 'reason': last.wire.missing};
    }
    var sent = 0, received = 0, connections = 0;
    for (final MapEntry(key: local, value: bytes) in end.entries) {
      final before = start[local];
      if (before == null) continue;
      connections++;
      sent += bytes.sent - before.sent;
      received += bytes.received - before.received;
    }
    return {
      'available': true,
      'connections': connections,
      'sentBytesPerSecond': round3(sent / seconds),
      'receivedBytesPerSecond': round3(received / seconds),
    };
  }

  static bool _fast(String collectors) => collectors
      .split(' ')
      .every(
        (name) =>
            Collector.values
                .where((c) => c.wireName == name)
                .firstOrNull
                ?.sampler ==
            SamplerKind.fast,
      );

  static String? _loadavg() => File('/proc/loadavg').readAsStringSync().trim();
}

/// One reading of the soak's window. Only the first and the latest keep
/// the meter's whole answer, the shells and the connections ([slim]):
/// readings kept whole would grow the heap the soak watches by tens of
/// kilobytes each.
final class _Reading {
  _Reading({
    required this.at,
    required this.fds,
    required this.rssBytes,
    required this.heapBytes,
    required this.processCpuTicks,
    required Map<String, Object?> links,
    required List<ShellCpu> shells,
    required ({Map<String, WireBytes>? connections, String? missing}) wire,
  }) : _detail = (links: links, shells: shells, wire: wire),
       channels = [
         for (final link in _linksIn(links))
           (link['channels']! as Map<String, Object?>).values.cast<int>().fold(
             0,
             (a, b) => a + b,
           ),
       ],
       stdoutBytes = [
         for (final link in _linksIn(links)) link['stdoutBytes']! as int,
       ],
       dials = links['dials']! as int,
       samplerShells = shells.length,
       connections = {for (final shell in shells) shell.ppid}.length,
       sshConnections = wire.connections?.length;

  _Reading._slim(_Reading full)
    : at = full.at,
      fds = full.fds,
      rssBytes = full.rssBytes,
      heapBytes = full.heapBytes,
      processCpuTicks = full.processCpuTicks,
      channels = full.channels,
      stdoutBytes = full.stdoutBytes,
      dials = full.dials,
      samplerShells = full.samplerShells,
      connections = full.connections,
      sshConnections = full.sshConnections,
      _detail = null;

  /// Since the window's start.
  final Duration at;
  final int fds, rssBytes, heapBytes, processCpuTicks;

  /// Open channels and stdout bytes so far per link, in dial order, and
  /// the links dialed so far.
  final List<int> channels, stdoutBytes;
  final int dials;

  /// Sampler shells and their sshd connections on the fixture, and the
  /// TCP connections `ss` saw (null without it).
  final int samplerShells, connections;
  final int? sshConnections;

  /// What soak.json keeps of it: numbers only, so the readings a long
  /// soak keeps stay small.
  Map<String, Object?> get json => {
    'seconds': round3(at.inMicroseconds / 1e6),
    'descriptors': fds,
    'rssBytes': rssBytes,
    'heapBytes': heapBytes,
    'processCpuTicks': processCpuTicks,
    'dials': dials,
    'channelsByLink': channels,
    'stdoutBytesByLink': stdoutBytes,
    'samplerShells': samplerShells,
    'connections': connections,
    'sshConnections': sshConnections,
  };

  final ({
    Map<String, Object?> links,
    List<ShellCpu> shells,
    ({Map<String, WireBytes>? connections, String? missing}) wire,
  })?
  _detail;

  /// This reading without its detail.
  _Reading slim() => _Reading._slim(this);

  ({
    Map<String, Object?> links,
    List<ShellCpu> shells,
    ({Map<String, WireBytes>? connections, String? missing}) wire,
  })
  get _kept => _detail ?? (throw StateError('a slimmed reading'));

  /// [LinkMeter.read]'s answer.
  Map<String, Object?> get links => _kept.links;
  List<ShellCpu> get shells => _kept.shells;
  ({Map<String, WireBytes>? connections, String? missing}) get wire =>
      _kept.wire;

  List<Map<String, Object?>> get linkList => _linksIn(links);

  Map<String, List<Object?>> repliesOf(int index) => switch (linkList
      .elementAtOrNull(index)) {
    final link? =>
      (link['replies']! as Map<String, Object?>).cast<String, List<Object?>>(),
    null => const {},
  };

  int channelsOf(int index) => channels.elementAtOrNull(index) ?? 0;

  static List<Map<String, Object?>> _linksIn(Map<String, Object?> links) =>
      (links['links']! as List<Object?>).cast<Map<String, Object?>>();
}

final class _Report {
  _Report({required this.json, required this.summary, required this.failures});

  final Map<String, Object?> json;
  final List<String> summary;
  final List<String> failures;
}
