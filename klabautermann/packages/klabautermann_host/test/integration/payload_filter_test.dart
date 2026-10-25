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

/// Each shell's first hit on PATH, then in /bin or /usr/bin.
final _shells = <String, String>{
  for (final name in ['dash', 'bash', 'mksh'])
    if ([...?Platform.environment['PATH']?.split(':'), '/bin', '/usr/bin']
            .map((dir) => '$dir/$name')
            .where((path) => File(path).existsSync())
            .firstOrNull
        case final path?)
      name: path,
};

/// Whether [shell] does 64-bit arithmetic; mksh does 32-bit, so its
/// replies carry eight counters per core and miss the size budget (D48).
bool _wide(String shell) =>
    '${Process.runSync(shell, ['-c', r'echo $((2147483647 + 1))']).stdout}'
        .trim() ==
    '2147483648';

/// The fast program's arithmetic width probe (D48).
const _widthProbe = r'[ $((2147483647 + 1)) -gt 0 ] && HW_W64=1';

/// [program] without [_widthProbe], so any shell takes the 32-bit
/// branch and CI covers it without mksh.
String _narrow(String program) {
  expect(program, contains(_widthProbe));
  return program.replaceAll(_widthProbe, '');
}

String _asIs(String program) => program;

/// One tick of [collector] over [root]: the parsed section and the reply's
/// size on the wire, from the `B` marker to the end of the `E` marker.
/// [edit] rewrites the program before the tree's paths go in.
Future<({HwsSection section, int replyBytes})> _tick(
  String shell,
  Directory root,
  Collector collector, {
  String Function(String program) edit = _asIs,
}) async {
  final nonce = generateNonce(Random(1));
  final program =
      edit(buildSamplerProgram(kind: collector.sampler, nonce: nonce))
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

/// A fresh tree for `procs`, up [uptime] seconds by its `/proc/uptime`.
Directory _procRoot({String uptime = '2000.00'}) {
  final root = Directory.systemTemp.createTempSync('klab-procs');
  addTearDown(() => root.deleteSync(recursive: true));
  _write(root, 'proc/uptime', '$uptime 7000.00\n');
  return root;
}

/// One process in [root]: [cpu] ticks split 3:2 into utime and stime,
/// started [start] ticks after boot, a `status` with [uid] and [rssKb]
/// (no `VmRSS:` line when null), and a three-argument `cmdline`.
void _proc(
  Directory root,
  int pid, {
  String? comm,
  int cpu = 0,
  int start = 0,
  int uid = 1000,
  int? rssKb,
}) {
  final rest = List.filled(32, 0).join(' ');
  _write(
    root,
    'proc/$pid/stat',
    '$pid (${comm ?? 'worker-$pid'}) S 1 $pid $pid 0 -1 4194560 0 0 0 0 '
        '${cpu * 3 ~/ 5} ${cpu * 2 ~/ 5} 0 0 20 0 1 0 $start $rest\n',
  );
  _write(
    root,
    'proc/$pid/status',
    'Name:\tworker\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t$pid\n'
        'Pid:\t$pid\nPPid:\t1\nUid:\t$uid\t0\t0\t0\n'
        'Gid:\t100\t100\t100\t100\nVmPeak:\t  99999 kB\n'
        '${rssKb == null ? '' : 'VmRSS:\t  $rssKb kB\n'}Threads:\t1\n',
  );
  _write(root, 'proc/$pid/cmdline', '/usr/bin/worker\x00--id\x00$pid\x00');
}

/// One `procs` tick over [root] under [shell], parsed, and its payload.
Future<({ParseResult<ProcsSnapshot> parsed, int payloadBytes})> _procs(
  String shell,
  Directory root, {
  String Function(String program) edit = _asIs,
}) async {
  final r = await _tick(shell, root, Collector.procs, edit: edit);
  return (
    parsed: parseProcs(utf8.decode(r.section.payload), ParseContext.standard),
    payloadBytes: r.section.payload.length,
  );
}

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
  9000 + i,
  0,
];

/// A host with [cpus] CPUs, a NIC in use, an unused one, a VF its master
/// counts, Docker's bridge and veths, a WireGuard tunnel, partitioned
/// NVMe and SATA disks under md and LVM, snap loop devices, ram, zram, a
/// ZFS volume, idle nbd devices, PSI and a ZFS ARC.
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
    ..write(disk(1, 0, 'ram0', 2345, 0))
    ..write(disk(230, 0, 'zd0', 3456789, 4567890))
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
    'ram0',
    'zd0',
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
          // DSK-04's timings: ms reading, ms writing, ms doing I/O.
          expect(core.diskstats.first.readMs, 456789);
          expect(core.diskstats.first.writeMs, 567890);
          expect(core.diskstats.first.ioMs, 678901);

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

      // 03 §11.4 as amended by D48: 30 B for each CPU beyond 32.
      test('each CPU beyond 32 adds at most 30 bytes to core', () async {
        final at32 = await _tick(shell, _bigHost(32), Collector.core);
        final at64 = await _tick(shell, _bigHost(64), Collector.core);
        expect((at64.replyBytes - at32.replyBytes) / 32, lessThanOrEqualTo(30));
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

      test('without a device-backed NIC, bridges and their ports go', () async {
        // Docker inside an LXC container: eth0 is a veth peer, and the
        // nested bridge and its veth repeat eth0's traffic.
        const dev =
            'h|\nh|\n    lo: 9 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n'
            '  eth0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0\n'
            'docker0: 30 1 0 0 0 0 0 0 40 1 0 0 0 0 0 0\n'
            'veth1a2b: 40 1 0 0 0 0 0 0 30 1 0 0 0 0 0 0\n';
        Directory host(List<String> ports) {
          final root = _smallHost({'proc/net/dev': dev});
          _mark(root, 'sys/class/net/docker0/bridge');
          for (final port in ports) {
            Link(
              '${root.path}/sys/class/net/$port/master',
            ).createSync('../docker0', recursive: true);
          }
          return root;
        }

        final core = (await _core(shell, host(['veth1a2b']))).value;
        expect(core.netdev.map((n) => '${n.name} ${n.rxBytes} ${n.txBytes}'), [
          'eth0 100 200',
        ]);
        // With eth0 itself a bridge port nothing else is left, so every
        // interface but lo stays, as without sysfs.
        final bridged = (await _core(shell, host(['eth0', 'veth1a2b'])));
        expect(bridged.value.netdev.map((n) => n.name), [
          'eth0',
          'docker0',
          'veth1a2b',
        ]);
        expect(core.diskstats.single.name, 'sda');
        // No arcstats and no PSI: absent, never zero.
        expect(core.zfsArc, isNull);
        expect(core.cpuPressure, isNull);
      });

      test('Xen netback ports go, a netfront NIC stays', () async {
        // A dom0: each guest port hangs off a xenbus backend device, and
        // OVS forwards its traffic across eth0 or another port again.
        const dev =
            'h|\nh|\n  eth0: 1000 1 0 0 0 0 0 0 10 1 0 0 0 0 0 0\n'
            'vif1.0: 60 1 0 0 0 0 0 0 1000 1 0 0 0 0 0 0\n'
            'vif2.0: 0 1 0 0 0 0 0 0 50 1 0 0 0 0 0 0\n';
        final dom0 = _smallHost({
          'proc/net/dev': dev,
          'sys/class/net/vif1.0/device/nodename': 'backend/vif/1/0\n',
          'sys/class/net/vif2.0/device/nodename': 'backend/vif/2/0\n',
        });
        _mark(dom0, 'sys/class/net/eth0/device');
        for (final port in ['eth0', 'vif1.0']) {
          Link(
            '${dom0.path}/sys/class/net/$port/master',
          ).createSync('../ovs-system', recursive: true);
        }
        final core = (await _core(shell, dom0)).value;
        expect(core.netdev.map((n) => '${n.name} ${n.rxBytes} ${n.txBytes}'), [
          'eth0 1000 10',
        ]);

        // A PV guest, whose NIC is a xenbus frontend device.
        final domU = _smallHost({
          'sys/class/net/eth0/device/nodename': 'device/vif/0\n',
        });
        final guest = (await _core(shell, domU)).value;
        expect(guest.netdev.map((n) => n.name), ['eth0']);
      });

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

      test('the 32-bit branch sends eight counters that parse', () async {
        final root = _smallHost({
          'proc/stat':
              'cpu  1 2 3 4 5 6 7 8 0 0\n'
              'cpu0 120000000 1500000 45000000 2200000000 2400000 0 '
              '1700000 35000 0 0\n'
              'cpu1 1 2 3 4 5 6 7\nbtime 5\n',
        });
        final r = await _tick(shell, root, Collector.core, edit: _narrow);
        final payload = utf8.decode(r.section.payload);
        expect(
          payload,
          contains(
            '\ncpu0 120000000 1500000 45000000 2200000000 2400000 0 '
            '1700000 35000\ncpu1 1 2 3 4 5 6 7 0\n',
          ),
        );
        final core = parseCore(payload, ParseContext.standard);
        expect(core.warnings, isEmpty);
        expect(core.value.perCpu['cpu0']!.busy, 168235000);
        expect(core.value.perCpu['cpu0']!.idle, 2202400000);
        expect(core.value.perCpu['cpu1']!.busy, 19);
        expect(core.value.perCpu['cpu1']!.idle, 9);
      });

      test('procs keeps 500 of 2,000 processes by CPU share and RSS', () async {
        // 2,000 s up and every process started at boot, so pid i's share
        // is 5 * i per mille; its RSS falls with i. The kept rows are pids
        // 1 to 250 (most RSS) and 1751 to 2000 (most CPU).
        final root = _procRoot();
        for (var pid = 1; pid <= 2000; pid++) {
          _proc(
            root,
            pid,
            comm: pid == 1999 ? 'a) b (c' : null,
            cpu: pid * 1000,
            uid: 1000 + pid % 3,
            rssKb: pid == 2000 ? null : (2001 - pid) * 10,
          );
        }

        final r = await _procs(shell, root);
        final snap = r.parsed.value;
        expect(r.parsed.warnings, isEmpty);
        expect(snap.totalProcesses, 2000);
        expect(snap.selection, ProcsSelection.cpuAndMemory);
        expect(snap.truncated, isTrue);
        expect(snap.processes, hasLength(kProcsRowCap));
        expect(snap.processes.map((p) => p.pid).toSet(), {
          for (var i = 1; i <= 250; i++) i,
          for (var i = 1751; i <= 2000; i++) i,
        });
        // Rows and command-line headers follow the pids' byte order.
        final texts = snap.processes.map((p) => '${p.pid}').toList();
        expect(texts, [...texts]..sort());
        expect(snap.forgedHeaders, 0);
        expect(snap.skippedPids, 0);
        for (final p in snap.processes) {
          expect(p.argv, ['/usr/bin/worker', '--id', '${p.pid}']);
          expect(p.utime, p.pid * 600);
          expect(p.uid, 1000 + p.pid % 3);
        }
        expect(snap.processes.firstWhere((p) => p.pid == 1999).comm, 'a) b (c');
        expect(snap.processes.firstWhere((p) => p.pid == 2000).rssKb, isNull);
        expect(snap.processes.firstWhere((p) => p.pid == 1).rssKb, 20000);
        // Far below the 1 MiB section cap that 2,083 untrimmed processes
        // nearly filled in spike S2.
        expect(r.payloadBytes, lessThan(64 * 1024));
      });

      test('inside lxcfs, procs ranks by age on the host clock', () async {
        // The container's init started 1,000 s after the host's boot, and
        // an lxcfs /proc/uptime counts from it. Pids 2 to 301 started with
        // the container and used half a CPU since (500 per mille); pids
        // 302 to 551 started 10 s ago and used 90 % or more, far fewer
        // ticks. Pids 52 to 301 have the most RSS.
        Directory container({required bool lxcfs}) {
          final root = _procRoot(uptime: '1000.00');
          if (lxcfs) {
            _write(
              root,
              'proc/mounts',
              'proc /proc proc rw 0 0\n'
                  'lxcfs ${root.path}/proc/uptime fuse.lxcfs rw 0 0\n',
            );
          }
          _proc(root, 1, start: 100000, rssKb: 100);
          for (var pid = 2; pid <= 301; pid++) {
            _proc(root, pid, cpu: 50000, start: 100000, rssKb: 10000 + pid);
          }
          for (var pid = 302; pid <= 551; pid++) {
            _proc(root, pid, cpu: 598 + pid, start: 199000, rssKb: 100);
          }
          return root;
        }

        final young = {for (var pid = 302; pid <= 551; pid++) pid};
        final r = await _procs(shell, container(lxcfs: true));
        final kept = r.parsed.value.processes.map((p) => p.pid).toSet();
        expect(r.parsed.value.totalProcesses, 551);
        expect(kept, {...young, for (var pid = 52; pid <= 301; pid++) pid});
        // Without the mount the tree is ranked on the container's clock:
        // every process looks younger than it is, and the old ones win.
        final naive = await _procs(shell, container(lxcfs: false));
        final naiveKept = naive.parsed.value.processes.map((p) => p.pid);
        expect(naiveKept.where(young.contains), isEmpty);
      });

      test('without sort, procs keeps the first 500 in glob order', () async {
        final root = _procRoot();
        for (var pid = 1; pid <= 600; pid++) {
          _proc(root, pid, cpu: pid, rssKb: pid);
        }
        String noSort(String program) {
          const probe = 'command -v sort ';
          expect(probe.allMatches(program), hasLength(1));
          return program.replaceAll(probe, 'command -v klab-no-sort ');
        }

        final r = await _procs(shell, root, edit: noSort);
        final snap = r.parsed.value;
        expect(r.parsed.warnings, isEmpty);
        expect(snap.selection, ProcsSelection.pidOrder);
        expect(snap.totalProcesses, 600);
        final glob = [for (var pid = 1; pid <= 600; pid++) '$pid']..sort();
        expect(snap.processes.map((p) => '${p.pid}'), glob.take(kProcsRowCap));
        expect(snap.processes.every((p) => p.argv != null), isTrue);
      });

      test('an empty selection falls back to the glob order', () async {
        // A `sort` that rejects -k leaves the selection empty, as mksh's
        // external printf does above about 2,000 processes (D48). Its
        // complaint must not reach stderr, which _tick rejects.
        final root = _procRoot();
        for (var pid = 1; pid <= 600; pid++) {
          _proc(root, pid, cpu: pid, rssKb: pid);
        }
        // By path, since BusyBox ash may prefer its own sort applet.
        final sort = File('${root.path}/bin/sort')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "#!/bin/sh\necho \"sort: invalid option -- 'k'\" >&2\nexit 1\n",
          );
        expect(Process.runSync('chmod', ['+x', sort.path]).exitCode, 0);
        String sortWithoutK(String program) {
          const call = '| sort -';
          expect(call.allMatches(program), hasLength(3));
          return program.replaceAll(call, '| ${sort.path} -');
        }

        final r = await _procs(shell, root, edit: sortWithoutK);
        final snap = r.parsed.value;
        expect(r.parsed.warnings, isEmpty);
        expect(snap.selection, ProcsSelection.pidOrder);
        expect(snap.totalProcesses, 600);
        final glob = [for (var pid = 1; pid <= 600; pid++) '$pid']..sort();
        expect(snap.processes.map((p) => '${p.pid}'), glob.take(kProcsRowCap));
        for (final p in snap.processes) {
          expect(p.argv, ['/usr/bin/worker', '--id', '${p.pid}']);
        }
      });

      test('procs skips a process that ends during the tick', () async {
        // Pid 11 lost its status after its stat was read; pid 12 was gone
        // before its stat could be read. _tick fails on any stderr.
        final root = _procRoot();
        _proc(root, 10, rssKb: 10);
        _proc(root, 11, rssKb: 11);
        File('${root.path}/proc/11/status').deleteSync();
        Link(
          '${root.path}/proc/12/stat',
        ).createSync('${root.path}/proc/12/gone', recursive: true);
        _proc(root, 13, rssKb: 13);

        final snap = (await _procs(shell, root)).parsed.value;
        expect(snap.totalProcesses, 3);
        expect(snap.selection, ProcsSelection.all);
        expect(snap.truncated, isFalse);
        expect(snap.processes.map((p) => p.pid), [10, 11, 13]);
        final gone = snap.processes[1];
        expect(gone.uid, isNull);
        expect(gone.rssKb, isNull);
        expect(gone.argv, ['/usr/bin/worker', '--id', '11']);
      });

      test('procs skips a stat line cut short by its comm', () async {
        // Any process can name itself "a) \nb" (PR_SET_NAME). The first
        // line of its stat then ends in ") " and holds no fields, which
        // the share's arithmetic must never see: the syntax error would
        // end the sampler. _tick fails on a non-zero exit or any stderr.
        final root = _procRoot();
        _proc(root, 10, rssKb: 10);
        _proc(root, 11, comm: 'a) \nb', rssKb: 11);
        _proc(root, 12, rssKb: 12);

        final snap = (await _procs(shell, root)).parsed.value;
        expect(snap.totalProcesses, 2);
        expect(snap.processes.map((p) => p.pid), [10, 12]);
      });

      test('procs never expands a pattern in a comm', () async {
        // "a) /*/*\nb" leaves "/*/*" after the last ") " of the first
        // stat line. Expanded, its paths would pass the field-count guard
        // and reach the share's arithmetic, which ends the sampler; bash
        // there also runs the subscript of a relative match such as
        // "tmp/q/x[$(cmd)]". A directory of the tree stands in for "/*"
        // so the expansion does not depend on the host.
        Directory globbed({required bool lxcfs}) {
          final root = _procRoot();
          for (var i = 0; i < 30; i++) {
            _mark(root, 'g/d$i');
          }
          final comm = 'a) ${root.path}/g/*\nb';
          if (lxcfs) {
            _write(
              root,
              'proc/mounts',
              'lxcfs ${root.path}/proc/uptime fuse.lxcfs rw 0 0\n',
            );
          }
          _proc(root, 1, comm: lxcfs ? comm : null, rssKb: 1);
          _proc(root, 10, rssKb: 10);
          _proc(root, 11, comm: comm, rssKb: 11);
          return root;
        }

        final plain = (await _procs(shell, globbed(lxcfs: false))).parsed;
        expect(plain.value.totalProcesses, 2);
        expect(plain.value.processes.map((p) => p.pid), [1, 10]);
        // Inside lxcfs, PID 1's stat also sets the clock.
        final lx = (await _procs(shell, globbed(lxcfs: true))).parsed;
        expect(lx.value.totalProcesses, 1);
        expect(lx.value.processes.map((p) => p.pid), [10]);
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
