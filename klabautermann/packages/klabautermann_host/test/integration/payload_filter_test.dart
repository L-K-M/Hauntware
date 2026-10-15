// Host-side filtering through the real program (D48, 03 §11.4). Each
// test writes a synthetic /proc and /sys tree, points the assembled
// program at it, runs one tick under dash, bash and, when installed,
// mksh, and parses the reply.
// The trees are hand-made [U]: their shapes follow procfs(5), the kernel's
// sysfs layout and OpenZFS's arcstats, not a captured host.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = <String, String>{
  for (final name in ['dash', 'bash', 'mksh'])
    for (final dir in [
      ...?Platform.environment['PATH']?.split(':'),
      '/bin',
      '/usr/bin',
    ])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

/// Whether [shell] does 64-bit arithmetic; mksh does 32-bit, so its
/// replies carry eight counters per core and miss the size budget (D48).
bool _wide(String shell) =>
    '${Process.runSync(shell, ['-c', r'echo $((2147483647 + 1))']).stdout}'
        .trim() ==
    '2147483648';

/// One tick of [collector] over [root]: the parsed section and the reply's
/// size on the wire, from the `B` marker to the end of the `E` marker.
Future<({HwsSection section, int replyBytes})> _tick(
  String shell,
  Directory root,
  Collector collector,
) async {
  final nonce = generateNonce(Random(1));
  final program = buildSamplerProgram(kind: collector.sampler, nonce: nonce)
      .replaceAll('/proc/', '${root.path}/proc/')
      .replaceAll('cd /proc ', 'cd ${root.path}/proc ')
      .replaceAll('/sys/', '${root.path}/sys/');
  final proc = await Process.start('env', ['LC_ALL=C', 'TZ=UTC', shell, '-s']);
  final out = <int>[];
  final err = StringBuffer();
  final outDone = proc.stdout.forEach(out.addAll);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(err.write);
  proc.stdin
    ..write(program)
    ..write(encodeTickRequest(1, [collector]));
  await proc.stdin.close();
  await outDone;
  await errDone;
  expect(await proc.exitCode, 0, reason: err.toString());
  expect(err.toString(), isEmpty);

  HwsTick? tick;
  var readyBytes = 0;
  for (final e in HwsTickAssembler(nonce: nonce).push(out)) {
    switch (e) {
      case HwsSessionReady():
        readyBytes = out.indexOf(0x0a) + 1;
      case HwsTick():
        tick = e;
      case HwsTickLost(:final detail) || HwsSessionFailed(:final detail):
        fail(detail);
    }
  }
  final section = tick!.section(collector.wireName)!;
  expect(section.status, SectionStatus.ok);
  return (section: section, replyBytes: out.length - readyBytes);
}

void _write(Directory root, String path, String text) => (File(
  '${root.path}/$path',
)..createSync(recursive: true)).writeAsStringSync(text);

void _mark(Directory root, String path) =>
    Directory('${root.path}/$path').createSync(recursive: true);

/// A one-CPU host with one disk and one interface without a device link,
/// as inside a container; [files] adds or replaces paths.
Directory _smallHost([Map<String, String> files = const {}]) {
  final root = Directory.systemTemp.createTempSync('klab-ct');
  addTearDown(() => root.deleteSync(recursive: true));
  ({
    'proc/stat':
        'cpu  1 2 3 4 5 6 7 8 0 0\ncpu0 1 2 3 4 5 6 7 8 0 0\nbtime 5\n',
    'proc/meminfo': 'MemTotal:  1024 kB\nMemAvailable:  512 kB\n',
    'proc/loadavg': '0.00 0.01 0.05 1/9 99\n',
    'proc/uptime': '12.50 40.00\n',
    'proc/diskstats': '   8       0 sda 1 0 8 0 2 0 16 0 0 0 0\n',
    'proc/net/dev':
        'h|\nh|\n    lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n'
        '  eth0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0\n',
    ...files,
  }).forEach((path, text) => _write(root, path, text));
  return root;
}

/// One `core` tick over [root] under [shell], parsed.
Future<ParseResult<CoreSnapshot>> _core(String shell, Directory root) async {
  final r = await _tick(shell, root, Collector.core);
  return parseCore(utf8.decode(r.section.payload), ParseContext.standard);
}

/// A /proc/stat line for one CPU with counters of a host up for 100 days
/// at USER_HZ 100: user nice system idle iowait irq softirq steal guest
/// guest_nice.
List<int> _cpuFields(int i) => [
  120000000 + i * 3571,
  1500000 + i,
  45000000 + i * 977,
  690000000 + i * 7919,
  2400000 + i * 13,
  0,
  1700000 + i * 7,
  35000 + i,
  0,
  0,
];

/// A host with [cpus] CPUs, a NIC in use, an unused one, a VF its master
/// counts, Docker's bridge and veths, a WireGuard tunnel, partitioned
/// NVMe and SATA disks under md and LVM, snap loop devices, zram, idle
/// nbd devices, PSI and a ZFS ARC.
Directory _bigHost(int cpus) {
  final root = Directory.systemTemp.createTempSync('klab-host');
  addTearDown(() => root.deleteSync(recursive: true));

  final total = List.filled(10, 0);
  final cores = StringBuffer();
  for (var i = 0; i < cpus; i++) {
    final f = _cpuFields(i);
    for (var k = 0; k < 10; k++) {
      total[k] += f[k];
    }
    cores.writeln('cpu$i ${f.join(' ')}');
  }
  _write(
    root,
    'proc/stat',
    'cpu  ${total.join(' ')}\n$cores'
        'intr 9876543210 ${List.filled(400, 0).join(' ')}\n'
        'ctxt 98765432109\nbtime 1783000000\nprocesses 87654321\n'
        'procs_running 3\nprocs_blocked 0\n'
        'softirq 1234567890 1 2 3 4 5 6 7 8 9 10\n',
  );
  _write(
    root,
    'proc/meminfo',
    [
      for (final (k, v) in [
        ('MemTotal', 263782400),
        ('MemFree', 15234560),
        ('MemAvailable', 112345600),
        ('Buffers', 2345600),
        ('Cached', 81234560),
        ('SwapCached', 0),
        ('Active', 123456780),
        ('Inactive', 81234560),
        ('SwapTotal', 8388604),
        ('SwapFree', 8388604),
        ('Dirty', 1234),
        ('Shmem', 1234560),
        ('Slab', 12345670),
        ('SReclaimable', 9876540),
        ('SUnreclaim', 2469130),
        ('PageTables', 345670),
        ('Committed_AS', 198765430),
        ('VmallocTotal', 34359738367),
        ('HugePages_Total', 0),
      ])
        '${'$k:'.padRight(16)}${'$v'.padLeft(12)} kB\n',
    ].join(),
  );
  _write(root, 'proc/loadavg', '12.34 10.98 9.87 7/4321 3456789\n');
  _write(root, 'proc/uptime', '8640000.12 270000000.55\n');

  String dev(String name, int rx, int tx) =>
      '${name.padLeft(6)}: $rx 9876543 0 12 0 0 0 4321 $tx 8765432 0 0 0 0 0 0\n';
  _write(
    root,
    'proc/net/dev',
    [
          'Inter-|   Receive                                                |  Transmit\n',
          ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n',
        ].join() +
        dev('lo', 987654321098, 987654321098) +
        dev('eno1', 12345678901234, 2345678901234) +
        dev('eno2', 0, 0) +
        dev('vf0', 345678901234, 45678901234) +
        dev('docker0', 4567890123, 5678901234) +
        dev('br-0a1b2c3d4e5f', 3456789012, 4567890123) +
        dev('wg0', 234567890, 345678901) +
        [
          for (var i = 0; i < 20; i++)
            dev(
              'veth${(0xa1b2c3 + i).toRadixString(16)}',
              1234567 + i,
              7654321,
            ),
        ].join(),
  );
  for (final nic in ['eno1', 'eno2', 'vf0']) {
    _mark(root, 'sys/class/net/$nic/device');
  }
  Link('${root.path}/sys/class/net/vf0/master').createSync('../eno1');

  String disk(int major, int minor, String name, int r, int w) =>
      '${'$major'.padLeft(4)} ${'$minor'.padLeft(7)} $name $r 12345 '
      '${r * 37} 456789 $w 23456 ${w * 61} 567890 0 678901 789012 '
      '0 0 0 0 1234 5678\n';
  final disks = StringBuffer()
    ..write(disk(259, 0, 'nvme0n1', 98765432, 87654321))
    ..write(disk(259, 1, 'nvme0n1p1', 1234, 56))
    ..write(disk(259, 2, 'nvme0n1p2', 45678901, 34567890))
    ..write(disk(259, 3, 'nvme0n1p3', 53085297, 53086375))
    ..write(disk(259, 4, 'nvme1n1', 45670000, 34560000))
    ..write(disk(259, 5, 'nvme1n1p1', 45669000, 34559000))
    // nvme1n1's hidden multipath path, which the head counts again.
    ..write(disk(259, 6, 'nvme1c1n1', 45670000, 34560000))
    ..write(disk(8, 0, 'sda', 7654321, 6543210))
    ..write(disk(8, 1, 'sda1', 7654000, 6543000))
    ..write(disk(9, 0, 'md0', 91347901, 69126890))
    ..write(disk(253, 0, 'dm-0', 50000000, 50000000))
    ..write(disk(253, 1, 'dm-1', 3085297, 3086375))
    ..write(disk(251, 0, 'zram0', 1234567, 2345678))
    ..write(disk(11, 0, 'sr0', 0, 0));
  for (var i = 0; i < 10; i++) {
    disks.write(disk(7, i, 'loop$i', 1234 + i, 0));
  }
  for (var i = 0; i < 16; i++) {
    disks.write(
      '  43 ${'${i * 32}'.padLeft(7)} nbd$i 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n',
    );
  }
  _write(root, 'proc/diskstats', disks.toString());
  for (final part in [
    'nvme0n1p1',
    'nvme0n1p2',
    'nvme0n1p3',
    'nvme1n1p1',
    'sda1',
  ]) {
    _write(root, 'sys/class/block/$part/partition', '1\n');
  }
  for (final whole in [
    'nvme0n1',
    'nvme1n1',
    'nvme1c1n1',
    'sda',
    'sr0',
    'zram0',
  ]) {
    _mark(root, 'sys/class/block/$whole/slaves');
  }
  for (final (holder, slave) in [
    ('md0', 'nvme0n1p2'),
    ('md0', 'nvme1n1p1'),
    ('dm-0', 'nvme0n1p3'),
    ('dm-1', 'nvme0n1p3'),
  ]) {
    _write(root, 'sys/class/block/$holder/slaves/$slave', '');
  }
  for (var i = 0; i < 16; i++) {
    _mark(root, 'sys/class/block/nbd$i/slaves');
  }

  const some = 'some avg10=12.34 avg60=10.21 avg300=8.76 total=98765432109';
  const full = 'full avg10=1.23 avg60=0.98 avg300=0.76 total=9876543210';
  for (final p in ['cpu', 'io', 'memory']) {
    _write(root, 'proc/pressure/$p', '$some\n$full\n');
  }
  _write(
    root,
    'proc/spl/kstat/zfs/arcstats',
    [
      '13 1 0x01 147 39984 4123456789 987654321098765\n',
      'name                            type data\n',
      for (final (k, v) in [
        ('hits', 9876543210),
        ('iohits', 12345),
        ('misses', 123456789),
        ('hash_elements', 1234567),
        ('c', 34359738368),
        ('c_min', 8589934592),
        ('c_max', 135291469824),
        ('size', 34012345678),
        ('compressed_size', 23456789012),
      ])
        '${k.padRight(32)}4    $v\n',
    ].join(),
  );
  return root;
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    final wide = _wide(shell);
    group(name, () {
      test(
        'core keeps whole disks, device NICs, per-core sums (32 CPUs)',
        () async {
          final r = await _tick(shell, _bigHost(32), Collector.core);
          final parsed = parseCore(
            utf8.decode(r.section.payload),
            ParseContext.standard,
          );
          final core = parsed.value;
          expect(parsed.warnings, isEmpty);

          expect(core.perCpu, hasLength(32));
          final f = _cpuFields(31);
          expect(
            core.perCpu['cpu31']!.busy,
            f[0] + f[1] + f[2] + f[5] + f[6] + f[7],
          );
          expect(core.perCpu['cpu31']!.idle, f[3] + f[4]);
          expect(core.cpu!.jiffies, hasLength(10));
          expect(core.btime, 1783000000);
          expect(core.meminfo.fields.keys, hasLength(9));
          expect(core.meminfo.availableKb, 112345600);

          // eno2 never moved a byte; vf0's master eno1 already counts it.
          expect(core.netdev.map((n) => n.name), ['eno1']);
          expect(core.netdev.single.rxBytes, 12345678901234);
          expect(core.diskstats.map((d) => d.name), [
            'nvme0n1',
            'nvme1n1',
            'sda',
          ]);
          expect(core.diskstats.first.sectorsWritten, 87654321 * 61);

          expect(core.cpuPressure!.some!.avg10, 12.34);
          // Under lxcfs, cpu's full line is the container's real figure.
          expect(core.cpuPressure!.full!.avg10, 1.23);
          expect(core.ioPressure!.full!.avg300, 0.76);
          expect(utf8.decode(r.section.payload), isNot(contains('total=')));
          expect(core.zfsArc!.sizeBytes, 34012345678);
          expect(core.zfsArc!.minBytes, 8589934592);

          // 03 §11.4 as amended by D48: 2.5 KB at 32 CPUs.
          if (wide) expect(r.replyBytes, lessThanOrEqualTo(2500));
        },
      );

      test('each CPU beyond 32 adds at most 32 bytes to core', () async {
        final at32 = await _tick(shell, _bigHost(32), Collector.core);
        final at64 = await _tick(shell, _bigHost(64), Collector.core);
        expect((at64.replyBytes - at32.replyBytes) / 32, lessThanOrEqualTo(32));
      }, skip: wide ? false : 'eight counters per core on 32-bit shells (D48)');

      test('overview stays inside the ten-host budget', () async {
        final r = await _tick(shell, _bigHost(32), Collector.overview);
        final o = parseOverview(
          utf8.decode(r.section.payload),
          ParseContext.standard,
        );
        expect(o.warnings, isEmpty);
        expect(o.value.perCpu, isEmpty);
        expect(o.value.netdev.map((n) => n.name), ['eno1']);
        // 10 hosts at the phone cadence of one overview every 10 s stay
        // under 03 §11.4's 1 KB/s.
        const hosts = 10, cadenceSeconds = 10;
        expect(hosts * r.replyBytes / cadenceSeconds, lessThan(1000));
      });

      test(
        'without a device-backed NIC every interface but lo stays',
        () async {
          final root = _smallHost({
            'proc/net/dev':
                'h|\nh|\n    lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n'
                '  eth0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0\n'
                'docker0: 30 1 0 0 0 0 0 0 40 1 0 0 0 0 0 0\n',
          });
          final core = (await _core(shell, root)).value;
          expect(
            core.netdev.map((n) => '${n.name} ${n.rxBytes} ${n.txBytes}'),
            ['eth0 100 200', 'docker0 30 40'],
          );
          expect(core.diskstats.single.name, 'sda');
          // No arcstats and no PSI: absent, never zero.
          expect(core.zfsArc, isNull);
          expect(core.cpuPressure, isNull);
        },
      );

      test('NVMe path rows stay only while their head has no I/O', () async {
        // A kernel that accounts multipath I/O on the paths only.
        final root = _smallHost({
          'proc/diskstats':
              ' 259       0 nvme0n1 0 0 0 0 0 0 0 0 0 0 0\n'
              ' 259       1 nvme0c0n1 5 0 40 0 6 0 48 0 0 0 0\n'
              ' 259       2 nvme0c1n1 7 0 56 0 8 0 64 0 0 0 0\n',
        });
        final core = await _core(shell, root);
        expect(core.value.diskstats.map((d) => d.name), [
          'nvme0c0n1',
          'nvme0c1n1',
        ]);
      });

      test('per-core counters above 2^31 keep their value', () async {
        // A core idle for 254 days at USER_HZ 100.
        final root = _smallHost({
          'proc/stat':
              'cpu  1 2 3 4 5 6 7 8 0 0\n'
              'cpu0 120000000 1500000 45000000 2200000000 2400000 0 '
              '1700000 35000 0 0\nbtime 5\n',
        });
        final core = await _core(shell, root);
        expect(core.warnings, isEmpty);
        expect(core.value.perCpu['cpu0']!.busy, 168235000);
        expect(core.value.perCpu['cpu0']!.idle, 2202400000);
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
