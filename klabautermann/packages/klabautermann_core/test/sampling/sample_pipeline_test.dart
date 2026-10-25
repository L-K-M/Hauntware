// The sample pipeline's rules (03 §6.4, §10.1): rates and their resets
// (D43), the engine-owned seq (D44), gaps and sampling phases, collector
// errors, profile changes and values withheld inside containers (D50).
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/argument_masking.dart'
    show kArgumentTokensMasked;
import 'package:klabautermann_core/src/sampling/sample_pipeline.dart';
import 'package:klabautermann_core/src/sampling/sample_results.dart';
import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show HostProfile, HwsSection, ProcEntry, ProcsSnapshot, SectionStatus;
import 'package:test/test.dart';

import '../support/sample_frames.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

const _fast = {SampleStream.overview, SampleStream.core};

/// Counters of one reading; [n] steps every counter by a fixed amount
/// (CPU by 100 jiffies with 40 busy, `cpu0` by 100 with 25 busy, `eth0`
/// by 2,000 bytes in and 1,000 out, `sda` by 8 sectors read and 16
/// written).
String _blocks(int n, {int btime = 1700000000, bool core = true}) {
  final stat = [
    '== stat ==',
    'cpu  ${1000 + 30 * n} 0 ${500 + 10 * n} ${9000 + 60 * n} 0 0 0 0 0 0',
    if (core) ...['cpu0 ${400 + 25 * n} ${4000 + 75 * n}', 'btime $btime'],
  ];
  return [
    ...stat,
    '== meminfo ==',
    'MemTotal: 1000',
    'MemAvailable: 400',
    'Cached: 100',
    'SReclaimable: 20',
    'SwapTotal: 300',
    'SwapFree: 200',
    '== loadavg ==',
    '2.00 1.00 0.50 1/100 42',
    '== netdev ==',
    'eth0 ${10000 + 2000 * n} ${5000 + 1000 * n}',
    if (core) ...[
      '== diskstats ==',
      'sda 10 ${800 + 8 * n} 10 ${1600 + 16 * n}',
      '== uptime ==',
      '${1000 + 2 * n}.00 50.00',
    ],
  ].join('\n');
}

/// A fast reply carrying the given sections, [n] readings in.
SamplerReplied _fastReply(
  int n, {
  int btime = 1700000000,
  double? uptime,
  bool overview = true,
  bool core = true,
}) => reply(n + 1, uptime ?? 1000.0 + 2 * n, [
  if (overview) ok('overview', _blocks(n, core: false)),
  if (core) ok('core', _blocks(n, btime: btime)),
]);

/// A `procs` section listing pid 1 with [utime] user jiffies.
TestSection _procsSection(int utime) => ok(
  'procs',
  '== meta ==\ntotal=1\nselection=all\n'
      '== rows ==\n1 S 0 $utime 0 500 - - init',
);

/// A `procs` reply listing pid 1 with [utime] user jiffies, read at
/// [uptime].
SamplerReplied _procsReply(int utime, double uptime) =>
    reply(1, uptime, [_procsSection(utime)]);

ServerSamplePipeline _sampling({
  SampleSequence? sequence,
  Set<SampleStream> streams = _fast,
  HostProfile? profile,
}) {
  final pipeline = ServerSamplePipeline(
    serverId: 'srv',
    sequence: sequence ?? SampleSequence(),
    profile: profile,
  );
  pipeline.updateConditions(
    streams: streams,
    linkReady: true,
    activity: AppActivity.foreground,
    at: _t0,
  );
  return pipeline;
}

T _result<T extends SampleResult>(List<EngineEvent> events) =>
    events.whereType<Sample>().map((s) => s.result).whereType<T>().single;

List<String> _describe(List<EngineEvent> events) => [
  for (final e in events)
    switch (e) {
      Sample(:final stream, :final seq) => 'sample ${stream.name} $seq',
      Gap(:final streams, :final from, :final until, :final cause) =>
        'gap ${(streams.map((s) => s.name).toList()..sort()).join(',')} '
            '${from.difference(_t0).inSeconds}-'
            '${until.difference(_t0).inSeconds} ${cause.name}',
      SamplingState(:final phase, :final since) =>
        'state ${phase.name} ${since.difference(_t0).inSeconds}',
      HostProfileChanged() => 'profile',
      _ => '$e',
    },
];

/// A probe reply: the clock (Europe/Berlin at [offset]) and the
/// virtualization answers.
SamplerReplied _probe({
  String container = 'none',
  String lxcfs = '',
  int epoch = 1750000000,
  String offset = '+0200',
  String session = '10.0.0.1 50000 10.0.0.2 22',
}) => reply(1, 1, [
  ok('probe_kernel', 'Linux 6.1.0 x86_64'),
  ok(
    'probe_virt',
    'virt_rc=0\nvirt=kvm\ncontainer_rc=${container == 'none' ? 1 : 0}\n'
        'container=$container',
  ),
  ok('probe_lxcfs', 'mounts=$lxcfs'),
  ok('probe_session', 'ssh_connection=$session'),
  ok(
    'probe_clock',
    'epoch=$epoch\noffset=$offset\nTimezone=Europe/Berlin\n'
        'etc_timezone=Europe/Berlin',
  ),
]);

HwsSection _section(String name, SectionStatus status, String payload) =>
    HwsSection(name, status, utf8.encode(payload));

/// [p]'s conditions as of [at] seconds, described.
List<String> _set(
  ServerSamplePipeline p,
  int at, {
  Set<SampleStream> streams = _fast,
  bool ready = true,
  AppActivity activity = AppActivity.foreground,
}) => _describe(
  p.updateConditions(
    streams: streams,
    linkReady: ready,
    activity: activity,
    at: _at(at),
  ),
);

void main() {
  group('rates (D43)', () {
    test('a reading diffs against the one before; a changed btime starts '
        'a new series (reboot)', () {
      final p = _sampling();
      expect(
        _result<CoreResult>(p.addTick(_fast, _fastReply(0), _at(0))).network,
        isNull,
      );
      final core = _result<CoreResult>(p.addTick(_fast, _fastReply(1), _at(2)));
      expect(core.cpu!.busy, closeTo(40, 1e-9));
      expect(core.perCpu, {'cpu0': closeTo(25, 1e-9)});
      expect(core.network!['eth0']!.txBytesPerSecond, 500);
      expect(core.disks!['sda']!.writeBytesPerSecond, 4096);
      expect(core.loadPerCore, 2);
      expect(core.uptime, const Duration(seconds: 1002));
      final memory = core.memory!;
      expect(
        [memory.usedBytes, memory.cachedBytes, memory.swapUsedBytes],
        [600 * 1024, 120 * 1024, 100 * 1024],
      );

      final rebooted = _result<CoreResult>(
        p.addTick(_fast, _fastReply(2, btime: 1700009999), _at(4)),
      );
      expect(
        [rebooted.cpu, rebooted.perCpu, rebooted.network, rebooted.disks],
        [null, null, null, null],
      );
      expect(rebooted.bootedAt!.millisecondsSinceEpoch, 1700009999000);
      final next = p.addTick(_fast, _fastReply(3, btime: 1700009999), _at(6));
      expect(_result<CoreResult>(next).cpu!.busy, closeTo(40, 1e-9));
    });

    test('an uptime that went back starts a new series', () {
      final p = _sampling()..addTick(_fast, _fastReply(0), _at(0));
      final back = _result<OverviewResult>(
        p.addTick(_fast, _fastReply(1, core: false, uptime: 5), _at(2)),
      );
      expect(back.cpu, isNull);
      expect(back.network, isNull);

      // The reboot's new btime then starts no second series.
      final core = _result<CoreResult>(
        p.addTick(
          _fast,
          _fastReply(2, overview: false, btime: 1700009999, uptime: 7),
          _at(4),
        ),
      );
      expect(core.cpu!.busy, closeTo(40, 1e-9));
      expect(core.perCpu, isNull);
    });

    test('a slow reply that started before the latest fast one keeps the '
        'series', () {
      // The slow sampler reads its `B` uptime when its request starts, so
      // its reply can arrive after a fast one with an older uptime.
      final streams = {..._fast, SampleStream.fs};
      final p = _sampling(streams: streams)
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick(_fast, _fastReply(1), _at(2))
        ..addTick({SampleStream.fs}, reply(1, 1001.5, [ok('fs', '')]), _at(3));
      final core = _result<CoreResult>(p.addTick(_fast, _fastReply(2), _at(4)));
      expect(core.cpu!.busy, closeTo(40, 1e-9));
      expect(core.network!['eth0']!.rxBytesPerSecond, 1000);
    });

    test('counters that all reset read as unknown, not as none', () {
      final p = _sampling()..addTick(_fast, _fastReply(3), _at(0));
      // Lower counters at a later uptime: each one reset (CN-04).
      final lower = _result<CoreResult>(
        p.addTick(_fast, _fastReply(0, uptime: 1010), _at(2)),
      );
      expect(
        [lower.cpu, lower.network, lower.disks, lower.perCpu],
        [null, null, null, null],
      );
      // So does memory without a meminfo block.
      final bare = reply(1, 1012, [ok('overview', '== loadavg ==\n1 1 1')]);
      expect(
        _result<OverviewResult>(p.addTick(_fast, bare, _at(4))).memory,
        isNull,
      );
    });

    test('disk rates span the time since the last core reading', () {
      final p = _sampling()
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick(_fast, _fastReply(1, core: false), _at(2));
      final core = _result<CoreResult>(p.addTick(_fast, _fastReply(2), _at(4)));
      // Two steps of 16 written sectors over four seconds of uptime.
      expect(core.disks!['sda']!.writeBytesPerSecond, 4096);
      expect(core.network!['eth0']!.rxBytesPerSecond, 1000);
    });

    test('a core section serves the overview stream too', () {
      final p = _sampling()
        ..addTick(_fast, _fastReply(0, overview: false), _at(0));
      final events = p.addTick(_fast, _fastReply(1, overview: false), _at(2));
      expect(_describe(events), ['sample overview 3', 'sample core 4']);
      expect(_result<OverviewResult>(events).cpu!.busy, closeTo(40, 1e-9));
    });

    test('load per core and the ARC wait for a core reading', () {
      const overview = {SampleStream.overview};
      final p = _sampling();
      final before = _result<OverviewResult>(
        p.addTick(overview, _fastReply(0, core: false), _at(0)),
      );
      expect(before.loadPerCore, isNull);
      expect(before.memory!.zfsArcCountedAsUsed, isNull);

      p.addTick({SampleStream.core}, _fastReply(1, overview: false), _at(2));
      final after = _result<OverviewResult>(
        p.addTick(overview, _fastReply(2, core: false), _at(4)),
      );
      expect(after.loadPerCore, 2);
      // No arcstats block: no ARC to count.
      expect(after.memory!.zfsArcCountedAsUsed, isFalse);
    });
  });

  test('seq stays monotonic across sampler restarts and reconnects (D44)', () {
    final sequence = SampleSequence();
    final p = _sampling(sequence: sequence);
    final seqs = <int>[];
    void read(SamplerReplied r, int at) => seqs.addAll(
      p.addTick(_fast, r, _at(at)).whereType<Sample>().map((s) => s.seq),
    );

    read(_fastReply(0), 0);
    read(_fastReply(1), 2);
    // The sampler restarts: its request numbers start again at 1.
    p.addTick(_fast, const SamplerGap(3, SamplerGapReason.deadline), _at(4));
    p.addTick(_fast, const SamplerSkipped(SamplerSkipReason.notReady), _at(6));
    read(_fastReply(0), 8);
    // The link drops and comes back.
    _set(p, 9, ready: false);
    _set(p, 9);
    read(_fastReply(0), 10);
    expect(seqs, [1, 2, 3, 4, 5, 6, 7, 8]);

    // A pipeline built again for the server continues its count; another
    // server counts on its own.
    final again = _sampling(sequence: sequence);
    expect(_describe(again.addTick(_fast, _fastReply(0), _at(12))), [
      'sample overview 9',
      'sample core 10',
    ]);
    expect(sequence.next('other'), 1);
  });

  group('gaps and phases', () {
    test('a lost reading is a gap, and the next rate spans it', () {
      final p = _sampling()..addTick(_fast, _fastReply(0), _at(0));
      p.addTick(_fast, const SamplerGap(2, SamplerGapReason.lost), _at(2));
      p.addTick(
        _fast,
        const SamplerSkipped(SamplerSkipReason.notReady),
        _at(4),
      );

      final events = p.addTick(_fast, _fastReply(2), _at(6));
      expect(_describe(events), [
        'gap core,overview 0-6 readingLost',
        'sample overview 3',
        'sample core 4',
      ]);
      // Two steps of counters over four seconds of host uptime.
      expect(
        _result<CoreResult>(events).network!['eth0']!.rxBytesPerSecond,
        1000,
      );
    });

    test('a sampler that is not ready loses the reading', () {
      final p = _sampling()
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick(
          _fast,
          const SamplerSkipped(SamplerSkipReason.notReady),
          _at(2),
        );
      expect(
        _describe(p.addTick(_fast, _fastReply(1), _at(4))).first,
        'gap core,overview 0-4 readingLost',
      );
    });

    test('a reply without a stream\'s section loses its reading', () {
      final p = _sampling()..addTick(_fast, _fastReply(0), _at(0));
      expect(_describe(p.addTick(_fast, _fastReply(1, core: false), _at(2))), [
        'sample overview 3',
      ]);
      expect(_describe(p.addTick(_fast, _fastReply(2), _at(4))), [
        'gap core 0-4 readingLost',
        'sample overview 4',
        'sample core 5',
      ]);
    });

    test('no gap without an earlier reading, a busy sampler or a close', () {
      final p = _sampling();
      p.addTick(_fast, const SamplerGap(1, SamplerGapReason.lost), _at(0));
      p.addTick(_fast, _fastReply(0), _at(2));
      p.addTick(_fast, const SamplerSkipped(SamplerSkipReason.busy), _at(4));
      p.addTick(_fast, const SamplerGap(2, SamplerGapReason.closed), _at(6));
      expect(_describe(p.addTick(_fast, _fastReply(1), _at(8))), [
        'sample overview 3',
        'sample core 4',
      ]);
    });

    test('the background pauses sampling and starts a new series', () {
      final streams = {..._fast, SampleStream.procs};
      final p = _sampling(streams: streams)
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick({SampleStream.procs}, _procsReply(100, 1000), _at(1));
      expect(_set(p, 3, streams: streams, activity: AppActivity.background), [
        'state pausedInBackground 3',
      ]);
      expect(_set(p, 30, streams: streams), ['state sampling 30']);

      final events = p.addTick(_fast, _fastReply(1), _at(32));
      expect(_describe(events).first, 'gap core,overview 0-32 background');
      expect(_result<CoreResult>(events).cpu, isNull);
      final procs = _result<ProcsResult>(
        p.addTick({SampleStream.procs}, _procsReply(300, 1030), _at(33)),
      );
      expect(procs.processes.single.cpuPercent, isNull);
    });

    test('a lost link outranks a lost reading and keeps its start', () {
      final streams = {..._fast, SampleStream.fs};
      final p = _sampling(streams: streams)
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick({SampleStream.fs}, reply(1, 1001, [ok('fs', '')]), _at(1))
        ..addTick(
          _fast,
          const SamplerGap(2, SamplerGapReason.deadline),
          _at(5),
        );
      _set(p, 8, streams: streams, ready: false);
      _set(p, 20, streams: streams);

      expect(
        _describe(p.addTick(_fast, _fastReply(1), _at(22))).first,
        'gap core,overview 0-22 disconnected',
      );
      // Each stream closes its own gap when it is read again.
      expect(
        _describe(
          p.addTick({SampleStream.fs}, reply(1, 1023, [ok('fs', '')]), _at(23)),
        ),
        ['gap fs 1-23 disconnected', 'sample fs 6'],
      );
    });

    test('a stream subscribed again has no gap and starts a new series', () {
      final streams = {..._fast, SampleStream.procs};
      final p = _sampling(streams: streams)
        ..addTick(_fast, _fastReply(0), _at(0))
        ..addTick({SampleStream.procs}, _procsReply(100, 1000), _at(1))
        ..addTick(_fast, const SamplerGap(2, SamplerGapReason.lost), _at(2));
      double? share(int utime, double uptime, int at) => _result<ProcsResult>(
        p.addTick({SampleStream.procs}, _procsReply(utime, uptime), _at(at)),
      ).processes.single.cpuPercent;
      _set(p, 3, streams: {SampleStream.overview});
      _set(p, 3, streams: streams);

      final events = p.addTick(_fast, _fastReply(1), _at(4));
      expect(_describe(events).first, 'gap overview 0-4 readingLost');
      final core = _result<CoreResult>(events);
      expect(core.perCpu, isNull);
      expect(core.disks, isNull);
      // The overview counters went on, as the overview stream did.
      expect(core.cpu, isNotNull);
      expect(share(300, 1002, 5), isNull);
      // 200 jiffies at 100 per second over two seconds: one full CPU.
      expect(share(500, 1004, 7), 100);

      // Without either metric stream, the overview counters go too.
      _set(p, 8, streams: {SampleStream.procs});
      _set(p, 9, streams: streams);
      final overview = p.addTick(_fast, _fastReply(2), _at(10));
      expect(_result<OverviewResult>(overview).cpu, isNull);
    });

    test('phases follow the conditions; readings count only while '
        'sampling', () {
      final p = ServerSamplePipeline(
        serverId: 'srv',
        sequence: SampleSequence(),
      );
      expect(_set(p, 1, ready: false), ['state waitingForLink 1']);
      expect(p.addTick(_fast, _fastReply(0), _at(2)), isEmpty);
      expect(_set(p, 3, ready: false), isEmpty);
      expect(_set(p, 4, ready: false, activity: AppActivity.background), [
        'state pausedInBackground 4',
      ]);
      expect(_set(p, 5), ['state sampling 5']);
      expect(_set(p, 6, streams: const {}), ['state unsubscribed 6']);
    });
  });

  test('a collector error becomes CollectorUnavailable with its stderr', () {
    const units = {SampleStream.units, SampleStream.failedUnits};
    final events = _sampling(streams: units).addTick(
      units,
      reply(1, 1000, [
        (
          'units',
          SectionStatus.error,
          'hw_timeout=absent\nFailed to connect to bus\x1b[0m\x07\n',
        ),
      ]),
      _at(0),
    );
    expect(events.whereType<Sample>(), hasLength(2));
    for (final sample in events.whereType<Sample>()) {
      final result = sample.result as CollectorUnavailable;
      expect(result.reason, CollectorUnavailableReason.error);
      expect(result.detail, 'Failed to connect to bus[0m');
    }

    // No output is no detail; a long one keeps its end.
    expect(
      collectorUnavailable(_section('fs', SectionStatus.missing, ''))!.detail,
      isNull,
    );
    final long = '${'x' * kCollectorDetailMaxChars}tail';
    final detail = collectorUnavailable(
      _section('fs', SectionStatus.timeout, long),
    )!.detail!;
    expect(detail, hasLength(kCollectorDetailMaxChars));
    expect(detail, endsWith('tail'));

    // The cut never splits a surrogate pair.
    final emoji = collectorUnavailable(
      _section('fs', SectionStatus.error, '${'\u{1F600}' * 2048}z'),
    )!.detail!;
    expect(emoji, '${'\u{1F600}' * 2047}z');
  });

  test('a units reading gives K04\'s external-monitor finding', () {
    UnitsResult list(List<SystemdUnit> units) =>
        UnitsResult(UnitsSnapshot(units: units, format: UnitListFormat.json));
    final report = externalMonitorsIn(
      list([
        SystemdUnit(
          unit: 'netdata.service',
          load: 'loaded',
          active: 'active',
          sub: 'running',
        ),
      ]),
    );
    expect(report.status, AccessStatus.ok);
    expect(report.units.single.unit, 'netdata.service');
    // An empty list means systemctl failed, which rules nothing out.
    expect(externalMonitorsIn(list(const [])).status, AccessStatus.unknown);
  });

  test('a temps section reads as its sensors in °C (HW-01)', () {
    final streams = {SampleStream.temps};
    final p = _sampling(streams: streams);
    final temps = _result<TempsResult>(
      p.addTick(
        streams,
        reply(1, 1000, [
          ok(
            'temps',
            '== hwmon ==\nhwmon2|coretemp|temp1|48000|84000|100000|Package id 0'
                '\n== thermal ==\nthermal_zone0|27800|acpitz',
          ),
        ]),
        _at(0),
      ),
    ).temps;
    expect(temps.sensors.single.label, 'Package id 0');
    expect(temps.sensors.single.celsius, 48);
  });

  test('a reply\'s uptime times procs only when procs leads it', () {
    // The host reads the `B` uptime before the first collector, so a slow
    // `fs` ahead of `procs` would count toward the interval.
    final streams = {SampleStream.fs, SampleStream.procs};
    final p = _sampling(streams: streams);
    double? share(List<TestSection> sections, double uptime, int at) =>
        _result<ProcsResult>(
          p.addTick(streams, reply(1, uptime, sections), _at(at)),
        ).processes.single.cpuPercent;
    final fs = ok('fs', '');

    expect(share([fs, _procsSection(100)], 1000, 0), isNull);
    expect(share([fs, _procsSection(400)], 1012, 12), isNull);
    // Nor does the next reading know when the one before was taken.
    expect(share([_procsSection(700), fs], 1015, 15), isNull);
    // 300 jiffies at 100 per second over three seconds: one full CPU.
    expect(share([_procsSection(1000), fs], 1018, 18), 100);
  });

  test('a reply\'s uptime dates each process\'s start where it counts '
      'from the kernel\'s boot (7.2, D50)', () {
    final streams = {SampleStream.fs, SampleStream.procs};
    final p = _sampling(streams: streams);
    // Read 1,000 s after boot; pid 1 started 5 s after it.
    DateTime? started({List<TestSection>? sections}) => _result<ProcsResult>(
      p.addTick(
        streams,
        reply(1, 1000, sections ?? [_procsSection(100)]),
        _at(1000),
      ),
    ).processes.single.startedAt;

    // Before the probe nothing says what `/proc/uptime` counts from.
    expect(started(), isNull);

    p.addProbe(_probe());
    expect(started(), _at(5));
    // Unlike CPU shares, a start does not need procs to lead the reply.
    expect(started(sections: [ok('fs', ''), _procsSection(100)]), _at(5));

    // lxcfs over another file leaves the kernel's uptime in place.
    p.addProbe(_probe(container: 'lxc', lxcfs: '/proc/meminfo'));
    expect(started(), _at(5));

    // Over `/proc/uptime` it serves the container's age instead.
    p.addProbe(_probe(container: 'lxc', lxcfs: '/proc/uptime'));
    expect(started(), isNull);
  });

  test('a truncated process list carries the host\'s count and how it '
      'chose the rows; a full one counts every row (D48)', () {
    // Above 500 processes the host keeps the top rows by CPU share and by
    // memory and reports how many it counted: "showing N of M" (PRC-01).
    TestSection procs(int total, String selection, int utime) => ok(
      'procs',
      '== meta ==\ntotal=$total\nselection=$selection\n'
          '== rows ==\n1 S 0 $utime 0 500 0 2048 init\n'
          '7 R 1 9000 0 700 1000 409600 java',
    );
    final p = _sampling(streams: {SampleStream.procs});
    ProcsResult read(TestSection section, double uptime, int at) =>
        _result<ProcsResult>(
          p.addTick({SampleStream.procs}, reply(1, uptime, [section]), _at(at)),
        );

    final truncated = read(procs(900, 'cpu_rss', 100), 1000, 0);
    expect(truncated.processes.map((r) => r.pid), [1, 7]);
    expect(truncated.totalProcesses, 900);
    expect(truncated.selection, ProcsSelection.cpuAndMemory);
    // The kept rows are timed as before while procs leads the reply: 200
    // jiffies at 100 per second over two seconds, one full CPU.
    expect(
      read(procs(900, 'cpu_rss', 300), 1002, 2).processes.first.cpuPercent,
      100,
    );

    final full = read(procs(2, 'all', 500), 1004, 4);
    expect(full.processes, hasLength(2));
    expect(full.totalProcesses, 2);
    expect(full.selection, ProcsSelection.all);
  });

  test('a full list from a ps fallback can hold more rows than the host '
      'counted (D48)', () {
    // `ps` runs after the count, so it also lists itself; only the
    // selection says whether the host left processes out.
    final p = _sampling(streams: {SampleStream.procs});
    final procs = _result<ProcsResult>(
      p.addTick(
        {SampleStream.procs},
        reply(1, 1000, [
          ok(
            'procs',
            '== meta ==\ntotal=1\nselection=all\n'
                '== rows ==\n1 S 0 100 0 500 0 2048 init\n'
                '== cmdline ==\n== ps ==\nPID PPID USER STAT RSS COMMAND\n'
                '1 0 root S 2048 /sbin/init\n'
                '9 1 root R 900 ps -eo pid,ppid,user,stat,rss,args',
          ),
        ]),
        _at(0),
      ),
    );
    expect(procs.processes.map((r) => r.pid), [1, 9]);
    expect(procs.totalProcesses, 1);
    expect(procs.selection, ProcsSelection.all);
  });

  test('process rows: RSS in bytes; a ps fallback row lists its '
      'whitespace tokens (7.2); every argument is masked (8.9)', () {
    final rows = procsResult(
      ProcsSnapshot(
        processes: [
          ProcEntry(pid: 1, rssKb: 2, argv: const ['sh', '-c', 'a b']),
          ProcEntry(pid: 2, argsJoined: 'nginx -g daemon off;'),
          ProcEntry(pid: 3, argsJoined: ''),
          ProcEntry(pid: 4),
          ProcEntry(pid: 5, argv: const ['mysql', '-phunter2']),
          ProcEntry(pid: 6, argsJoined: 'app --token t0k3n'),
        ],
      ),
    ).processes;
    expect(rows.map((r) => r.arguments?.map((a) => a.display)), [
      ['sh', '-c', 'a b'],
      ['nginx', '-g', 'daemon', 'off;'],
      isEmpty,
      isNull,
      ['mysql', '-p********'],
      ['app', '--token', '********'],
    ]);
    expect(rows[4].arguments![1].reveal(), '-phunter2');
    expect(rows.first.residentBytes, 2048);
  });

  test('ps\'s bracketed name for an empty command line is no command '
      'line, as the kernel thread\'s empty cmdline is (7.2)', () {
    final rows = procsResult(
      ProcsSnapshot(
        processes: [
          ProcEntry(pid: 2, comm: 'kthreadd', argsJoined: '[kthreadd]'),
          ProcEntry(pid: 3, comm: 'kthreadd', argsJoined: '[kthreadd] x'),
          ProcEntry(pid: 4, argsJoined: '[kthreadd]'),
          ProcEntry(pid: 5, comm: 'app', argv: const ['[app]']),
          // GNU ps's zombie, whose cmdline is empty too.
          ProcEntry(pid: 6, comm: 'bash', argsJoined: '[bash] <defunct>'),
        ],
      ),
    ).processes;

    expect(rows.map((r) => r.arguments?.map((a) => a.display)), [
      isEmpty,
      ['[kthreadd]', 'x'],
      // Without /proc's name nothing says the brackets are ps's.
      ['[kthreadd]'],
      // A real argument vector is what the process set.
      ['[app]'],
      isEmpty,
    ]);
  });

  test('a start is the boot time plus its ticks at 100 a second, and '
      'unknown without either (7.2)', () {
    final booted = DateTime.utc(2026, 10, 3, 11, 23);
    final rows = procsResult(
      ProcsSnapshot(
        processes: [ProcEntry(pid: 1, startTicks: 250), ProcEntry(pid: 2)],
      ),
      bootedAt: booted,
    ).processes;

    expect(rows.map((r) => r.startedAt), [
      booted.add(const Duration(milliseconds: 2500)),
      isNull,
    ]);
    expect(
      procsResult(
        ProcsSnapshot(processes: [ProcEntry(pid: 1, startTicks: 250)]),
      ).processes.single.startedAt,
      isNull,
    );
  });

  test('the rows of one procs reading share one masking budget, so many '
      'processes cannot multiply the work (8.9)', () {
    final half = [for (var i = 0; i < kArgumentTokensMasked ~/ 2; i++) 'a'];
    final rows = procsResult(
      ProcsSnapshot(
        processes: [
          ProcEntry(pid: 1, argv: half),
          ProcEntry(pid: 2, argv: half),
          ProcEntry(pid: 3, argv: const ['mysql', 'db']),
        ],
      ),
    ).processes;

    expect(rows[1].arguments!.last.display, 'a');
    expect(rows[2].arguments, [
      MaskedValue.secret('mysql'),
      MaskedValue.secret('db'),
    ]);
  });

  group('host profile', () {
    test('a changed profile is reported, a new clock or session is not', () {
      final p = _sampling();
      expect(_describe(p.addProbe(_probe())), ['profile']);
      // Daylight saving time ended: the zone keeps its name.
      final again = _probe(
        epoch: 1750000100,
        offset: '+0100',
        session: '10.0.0.9 1 10.0.0.2 22',
      );
      expect(p.addProbe(again), isEmpty);
      expect(p.profile!.epochSeconds, 1750000100);
      expect(_describe(p.addProbe(_probe(container: 'lxc'))), ['profile']);
      expect(
        p.addProbe(const SamplerGap(1, SamplerGapReason.deadline)),
        isEmpty,
      );
    });

    test('a pipeline built again keeps the last profile', () {
      final p = _sampling()..addProbe(_probe(container: 'lxc'));
      final again = _sampling(profile: p.profile);
      final core = _result<CoreResult>(
        again.addTick(_fast, _fastReply(0), _at(0)),
      );
      expect(core.load, isNull);
      expect(again.addProbe(_probe(container: 'lxc', epoch: 1)), isEmpty);
    });

    test('container values are withheld once the probe tells (D50)', () {
      final p = _sampling();
      final before = _result<CoreResult>(
        p.addTick(_fast, _fastReply(0), _at(0)),
      );
      expect(before.withheld, isEmpty);
      expect(before.load, isNotNull);

      p.addProbe(_probe(container: 'lxc', lxcfs: '/proc/meminfo'));
      final events = p.addTick(_fast, _fastReply(1), _at(2));
      final core = _result<CoreResult>(events);
      expect([core.cpu, core.load, core.disks], [null, null, null]);
      expect(
        core.withheld[MetricField.cpu],
        MetricWithheldReason.containerHostFigures,
      );
      expect(core.withheld.containsKey(MetricField.memory), isFalse);
      expect(core.memory!.zfsArcCountedAsUsed, isFalse);
      expect(core.network!['eth0']!.rxBytesPerSecond, 1000);
      expect(
        _result<OverviewResult>(events).withheld.keys,
        unorderedEquals([
          MetricField.cpu,
          MetricField.load,
          MetricField.loadPerCore,
        ]),
      );
    });

    test('without an lxcfs mount the meminfo shown counts the ARC as used, '
        'even while the container question is open (D48)', () {
      final p = _sampling();
      // An empty answer leaves the container unknown, as without
      // systemd-detect-virt; `mounts=` says that no lxcfs mount exists.
      p.addProbe(_probe(container: ''));
      final arc = reply(1, 1000, [
        ok('core', '${_blocks(0)}\n== arcstats ==\nsize 1024\nc_min 512'),
      ]);
      final core = _result<CoreResult>(p.addTick(_fast, arc, _at(0)));
      expect(p.profile!.inContainer, isNull);
      expect(core.withheld, isEmpty);
      expect(core.memory!.zfsArcCountedAsUsed, isTrue);
    });
  });
}
