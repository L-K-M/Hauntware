// Every platform fixture through the sample pipeline (03 §6.4, §6.5,
// K23): the probe, two fast readings whose counters advance by known
// amounts, and one reading of each slow collector, framed as the sampler
// prints them. The second reading's rates follow from those amounts, and
// the cron reading's jobs rows match `test/fixtures/cron_jobs/` (7.7,
// D57); `KLAB_REGEN_GOLDENS=1` rewrites those goldens.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/sample_pipeline.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show SectionStatus;
import 'package:test/test.dart';

import '../support/sample_frames.dart';

/// The host package's fixtures, from the package or the workspace root.
String _fixturesRoot() {
  for (final path in const [
    '../klabautermann_host/test/fixtures',
    'packages/klabautermann_host/test/fixtures',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  throw StateError('klabautermann_host fixtures not found');
}

/// This package's cron jobs goldens, from the package or the workspace
/// root.
String _goldensRoot() {
  for (final path in const [
    'test/fixtures/cron_jobs',
    'packages/klabautermann_core/test/fixtures/cron_jobs',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  throw StateError('cron_jobs goldens not found');
}

const _fast = {SampleStream.overview, SampleStream.core};
final _slow = SampleStream.values.toSet().difference(_fast);

/// Every field comes from a system-wide `/proc` file, so a container
/// without lxcfs withholds them all (D50).
final _allD50 = MetricField.values.toSet();

/// Per platform: the fields withheld (D50) and whether MEM-01 counts a
/// ZFS ARC as used.
final _expected = <String, (Set<MetricField>, bool)>{
  'alpine-322': (const {}, false), // no detect-virt: values as measured
  'debian-12': (const {}, true),
  'debian-12-lxc': (_allD50, false),
  // lxcfs serves its own meminfo and uptime only (D50); the ARC is the
  // host's, which the container's meminfo does not hold.
  'debian-12-lxc-lxcfs': (
    _allD50.difference({MetricField.memory, MetricField.uptime}),
    false,
  ),
  'rhel-8': (const {}, false),
  'ubuntu-2404': (const {}, false),
};

void main() {
  final root = _fixturesRoot();
  final t0 = DateTime.utc(2026, 10, 15, 12);

  for (final MapEntry(key: platform, value: (withheld, arcUsed))
      in _expected.entries) {
    test('$platform: parse, rates and results', () {
      String fixture(String name) =>
          File('$root/$platform/$name').readAsStringSync();
      final pipeline = ServerSamplePipeline(
        serverId: platform,
        sequence: SampleSequence(),
      );
      final events = <EngineEvent>[
        ...pipeline.updateConditions(
          streams: SampleStream.values.toSet(),
          linkReady: true,
          activity: AppActivity.foreground,
          at: t0,
        ),
        ...pipeline.addProbe(reply(1, 999, _probeSections(fixture))),
      ];
      expect(events, [
        isA<SamplingState>().having(
          (s) => s.phase,
          'phase',
          SamplingPhase.sampling,
        ),
        isA<HostProfileChanged>(),
      ]);

      // Two fast readings, two seconds of host uptime apart.
      final first = _results(
        pipeline.addTick(
          _fast,
          reply(1, 1000, [
            ok('overview', fixture('overview.txt')),
            ok('core', fixture('core.txt')),
          ]),
          t0,
        ),
      );
      final firstCore = first[SampleStream.core]! as CoreResult;
      expect(firstCore.network, isNull, reason: 'no earlier reading');
      expect(firstCore.withheld.keys.toSet(), withheld);

      final second = _results(
        pipeline.addTick(
          _fast,
          reply(2, 1002, [
            ok('overview', _advance(fixture('overview.txt'))),
            ok('core', _advance(fixture('core.txt'))),
          ]),
          t0.add(const Duration(seconds: 2)),
        ),
      );
      final overview = second[SampleStream.overview]! as OverviewResult;
      final core = second[SampleStream.core]! as CoreResult;
      for (final (cpu, network) in [
        (overview.cpu, overview.network),
        (core.cpu, core.network),
      ]) {
        if (withheld.contains(MetricField.cpu)) {
          expect(cpu, isNull);
        } else {
          expect(cpu!.busy, closeTo(40, 1e-9));
          expect(cpu.user, closeTo(30, 1e-9));
        }
        // Namespaced, so never withheld (D50).
        expect(network, isNotEmpty);
        for (final rate in network!.values) {
          expect(rate.rxBytesPerSecond, 1000);
          expect(rate.txBytesPerSecond, 500);
        }
      }

      if (withheld.contains(MetricField.perCpu)) {
        expect(core.perCpu, isNull);
        expect(core.disks, isNull);
        expect(core.load, isNull);
        expect(core.bootedAt, isNull);
      } else {
        expect(core.perCpu, isNotEmpty);
        expect(core.perCpu!.values, everyElement(closeTo(25, 1e-9)));
        expect(core.disks, isNotEmpty);
        for (final rate in core.disks!.values) {
          expect(rate.readBytesPerSecond, 2048);
          expect(rate.writeBytesPerSecond, 4096);
        }
        expect(core.loadPerCore, core.load!.load1 / core.perCpu!.length);
        expect(core.bootedAt, isNotNull);
      }

      if (withheld.contains(MetricField.memory)) {
        expect(core.memory, isNull);
      } else {
        final memory = core.memory!;
        expect(memory.usedBytes, memory.totalBytes! - memory.availableBytes!);
        expect(memory.zfsArcCountedAsUsed, arcUsed);
      }
      expect(
        core.uptime,
        withheld.contains(MetricField.uptime) ? isNull : isNotNull,
      );

      // One reading of every slow collector.
      final slow = _results(
        pipeline.addTick(
          _slow,
          reply(1, 1003, [
            for (final c in [
              'fs',
              'identity',
              'procs',
              'units',
              'timers',
              'cron',
            ])
              ok(c, fixture('$c.txt')),
          ]),
          t0.add(const Duration(seconds: 3)),
        ),
      );
      expect(slow.keys.toSet(), _slow);
      expect(slow[SampleStream.fs], isA<FsResult>());
      expect(
        (slow[SampleStream.identity]! as IdentityResult).kernelRelease,
        isNotNull,
      );
      final procs = slow[SampleStream.procs]! as ProcsResult;
      expect(procs.processes, isNotEmpty);
      // Every fixture lists all of its processes (D48).
      expect(procs.totalProcesses, procs.processes.length);
      expect(procs.selection, ProcsSelection.all);
      expect(procs.processes.map((p) => p.cpuPercent), everyElement(isNull));
      final units = slow[SampleStream.units]! as UnitsResult;
      expect(
        (slow[SampleStream.failedUnits]! as FailedUnitsResult).failed.length,
        units.units.failed.length,
      );
      expect(slow[SampleStream.timers], isA<TimersResult>());
      final cron = slow[SampleStream.cron]! as CronResult;
      final golden = File('${_goldensRoot()}/$platform.golden.json');
      final json = {
        'at': t0.add(const Duration(seconds: 3)).toIso8601String(),
        'zoneName': cron.zoneName,
        'zoneFallback': cron.zoneFallback?.name,
        'jobs': [for (final job in cron.jobs) job.toJson()],
      };
      if (Platform.environment['KLAB_REGEN_GOLDENS'] == '1') {
        golden.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        );
      }
      expect(json, jsonDecode(golden.readAsStringSync()));
    });
  }
}

/// The samples' results by stream, after checking that the samples hold
/// rising seqs and nothing else arrived.
Map<SampleStream, SampleResult> _results(List<EngineEvent> events) {
  final samples = events.cast<Sample>();
  final seqs = [for (final s in samples) s.seq];
  expect(seqs, [for (var i = 0; i < seqs.length; i++) seqs.first + i]);
  return {for (final s in samples) s.stream: s.result};
}

/// [payload] a reading later: every counter advanced by fixed amounts
/// (the aggregate CPU by 30 user, 10 system, 50 idle and 10 iowait
/// jiffies; each core by 25 busy and 75 idle; each interface by 2,000
/// bytes in and 1,000 out; each disk by 8 sectors read and 16 written),
/// and the uptime by two seconds.
String _advance(String payload) {
  var block = '';
  final out = <String>[];
  for (final line in payload.split('\n')) {
    final header = RegExp(r'^== ([a-z0-9_-]+) ==$').firstMatch(line);
    if (header != null) {
      block = header[1]!;
      out.add(line);
      continue;
    }
    final parts = line.trim().split(RegExp(r'\s+'));
    List<num> add(List<num> deltas, {int from = 1}) => [
      for (var i = from; i < parts.length; i++)
        num.parse(parts[i]) + (i - from < deltas.length ? deltas[i - from] : 0),
    ];
    String row(List<num> values) => [parts.first, ...values].join(' ');
    out.add(switch ((block, parts.first)) {
      ('stat', 'cpu') => row(add([30, 0, 10, 50, 10])),
      ('stat', final name) when name.startsWith('cpu') =>
        parts.length == 3
            ? row(add([25, 75]))
            : row(add([10, 0, 5, 60, 15, 5, 3, 2])),
      ('netdev', _) when parts.length == 3 => row(add([2000, 1000])),
      ('diskstats', _) when parts.length == 5 => row(add([1, 8, 1, 16])),
      ('uptime', _) when parts.length == 2 => add([
        2,
      ], from: 0).map((v) => v.toStringAsFixed(2)).join(' '),
      _ => line,
    });
  }
  return out.join('\n');
}

/// The fixture's `### <area> <status>` probe file as `probe_<area>`
/// sections.
List<TestSection> _probeSections(String Function(String) fixture) {
  final sections = <TestSection>[];
  for (final chunk in fixture(
    'probe.sections',
  ).split(RegExp(r'^### ', multiLine: true))) {
    if (chunk.isEmpty) continue;
    final newline = chunk.indexOf('\n');
    final head = chunk.substring(0, newline).split(' ');
    var body = chunk.substring(newline + 1);
    if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
    sections.add((
      'probe_${head[0]}',
      SectionStatus.values.byName(head[1]),
      body,
    ));
  }
  return sections;
}
