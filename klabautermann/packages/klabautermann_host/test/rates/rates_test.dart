// Counter-to-rate maths tests (03 §6.4, CN-04): 32- and 64-bit wraps,
// reboots and counter resets, zero and negative intervals, and interfaces
// or devices missing from one side.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _u32 = CounterWidth.bits32;

CpuTimes _cpu(String name, List<int> j) => CpuTimes(name, j);

NetDevEntry _net(String name, int rxBytes, int txBytes) =>
    NetDevEntry(name, rxBytes: rxBytes, txBytes: txBytes);

DiskStatEntry _disk(String name, int sectorsRead, int sectorsWritten) =>
    DiskStatEntry(
      name,
      readsCompleted: 0,
      sectorsRead: sectorsRead,
      writesCompleted: 0,
      sectorsWritten: sectorsWritten,
    );

CoreCpuTimes _core1(String name, int busy, int idle) =>
    CoreCpuTimes(name, busy: busy, idle: idle);

CoreSnapshot _core({
  CpuTimes? cpu,
  Map<String, CoreCpuTimes>? perCpu,
  int? btime,
  List<NetDevEntry>? netdev,
  List<DiskStatEntry>? diskstats,
  double? uptime,
}) => CoreSnapshot(
  cpu: cpu,
  perCpu: perCpu,
  btime: btime,
  meminfo: MemInfo(const {}),
  netdev: netdev,
  diskstats: diskstats,
  uptimeSeconds: uptime,
);

void main() {
  group('counterDelta', () {
    test('a normal increase yields the difference', () {
      expect(counterDelta(100, 150), 50);
      expect(counterDelta(0, 0), 0);
    });

    test('a 64-bit decrease is a reset, not a wrap', () {
      expect(counterDelta(150, 100), isNull);
    });

    test('a 32-bit decrease wraps modulo 2^32', () {
      expect(counterDelta(150, 100, width: _u32), (1 << 32) - 50);
    });

    test('negative inputs are refused', () {
      expect(counterDelta(-1, 10), isNull);
      expect(counterDelta(10, -1), isNull);
    });
  });

  group('seriesReset', () {
    test('a changed btime is a reboot', () {
      expect(seriesReset(100, 101), isTrue);
    });

    test('an unchanged or unknown btime is not a reboot', () {
      expect(seriesReset(100, 100), isFalse);
      expect(seriesReset(null, 100), isFalse);
      expect(seriesReset(100, null), isFalse);
    });
  });

  group('cpuDeltaPercent', () {
    test('percentages of the primary fields sum to 100', () {
      final p = cpuDeltaPercent(
        _cpu('cpu', [100, 0, 100, 800, 0, 0, 0, 0, 0, 0]),
        _cpu('cpu', [200, 0, 200, 1600, 0, 0, 0, 0, 0, 0]),
      )!;
      expect(p.user, closeTo(10, 1e-9));
      expect(p.system, closeTo(10, 1e-9));
      expect(p.idle, closeTo(80, 1e-9));
      expect(p.busy, closeTo(20, 1e-9));
    });

    test('a zero interval yields null', () {
      final same = _cpu('cpu', [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(cpuDeltaPercent(same, same), isNull);
    });

    test('a decreasing primary field starts a new series', () {
      expect(
        cpuDeltaPercent(
          _cpu('cpu', [100, 0, 100, 800, 0, 0, 0, 0, 0, 0]),
          _cpu('cpu', [90, 0, 100, 800, 0, 0, 0, 0, 0, 0]),
        ),
        isNull,
      );
    });

    test('a guest decrease is tolerated, not a reset', () {
      final p = cpuDeltaPercent(
        _cpu('cpu', [100, 0, 100, 800, 0, 0, 0, 0, 10, 0]),
        _cpu('cpu', [200, 0, 200, 1600, 0, 0, 0, 0, 5, 0]),
      );
      expect(p, isNotNull);
    });

    test('a shorter next line reads missing fields as zero', () {
      final p = cpuDeltaPercent(
        _cpu('cpu', [100, 0, 100, 800]),
        _cpu('cpu', [200, 0, 200, 1600, 0, 0, 0, 0]),
      );
      expect(p, isNotNull);
    });
  });

  group('perCpuBusyPercent', () {
    test('busy is the busy delta over the busy plus idle delta', () {
      final r = perCpuBusyPercent(
        {'cpu0': _core1('cpu0', 100, 900)},
        {'cpu0': _core1('cpu0', 130, 970)},
      );
      expect(r['cpu0'], 30);
    });

    test('cores missing from either side are skipped', () {
      final r = perCpuBusyPercent(
        {'cpu0': _core1('cpu0', 1, 4)},
        {'cpu0': _core1('cpu0', 2, 5), 'cpu1': _core1('cpu1', 1, 4)},
      );
      expect(r.keys, ['cpu0']);
    });

    test('a decrease or a zero delta yields no entry', () {
      final r = perCpuBusyPercent(
        {'cpu0': _core1('cpu0', 10, 10), 'cpu1': _core1('cpu1', 10, 10)},
        {'cpu0': _core1('cpu0', 5, 20), 'cpu1': _core1('cpu1', 10, 10)},
      );
      expect(r, isEmpty);
    });
  });

  group('netRates', () {
    test('byte rates divide the delta by the interval', () {
      final r = netRates(
        [_net('eth0', 1000, 2000)],
        [_net('eth0', 3000, 6000)],
        2,
      );
      expect(r['eth0']!.rxBytesPerSecond, 1000);
      expect(r['eth0']!.txBytesPerSecond, 2000);
    });

    test('a zero or negative interval yields nothing', () {
      expect(netRates([_net('eth0', 1, 1)], [_net('eth0', 2, 2)], 0), isEmpty);
      expect(netRates([_net('eth0', 1, 1)], [_net('eth0', 2, 2)], -1), isEmpty);
    });

    test('an interface missing from one side yields no entry', () {
      final r = netRates([_net('eth0', 1, 1)], [_net('eth1', 2, 2)], 1);
      expect(r, isEmpty);
    });

    test('a 64-bit reset drops the interface', () {
      final r = netRates([_net('eth0', 100, 100)], [_net('eth0', 10, 10)], 1);
      expect(r, isEmpty);
    });

    test('a 32-bit wrap continues the series', () {
      final r = netRates(
        [_net('eth0', (1 << 32) - 10, 0)],
        [_net('eth0', 10, 0)],
        1,
        width: _u32,
      );
      expect(r['eth0']!.rxBytesPerSecond, 20);
    });
  });

  group('diskRates', () {
    test('sectors convert at 512 bytes each', () {
      final r = diskRates(
        [_disk('sda', 100, 200)],
        [_disk('sda', 300, 500)],
        2,
      );
      expect(r['sda']!.readBytesPerSecond, 200 * 512 / 2);
      expect(r['sda']!.writeBytesPerSecond, 300 * 512 / 2);
    });

    test('a reset or missing device yields no entry', () {
      expect(
        diskRates([_disk('sda', 100, 100)], [_disk('sda', 1, 1)], 1),
        isEmpty,
      );
      expect(diskRates([_disk('sda', 1, 1)], [_disk('sdb', 2, 2)], 1), isEmpty);
    });

    test('a zero interval yields nothing', () {
      expect(diskRates([_disk('sda', 1, 1)], [_disk('sda', 2, 2)], 0), isEmpty);
    });

    DiskStatEntry timed(
      int reads,
      int writes, {
      required int readMs,
      required int writeMs,
      required int ioMs,
    }) => DiskStatEntry(
      'nvme0n1',
      readsCompleted: reads,
      sectorsRead: reads * 8,
      writesCompleted: writes,
      sectorsWritten: writes * 8,
      readMs: readMs,
      writeMs: writeMs,
      ioMs: ioMs,
    );

    test('IOPS, await and busy share from the timings (DSK-04)', () {
      final r = diskRates(
        [timed(1000, 2000, readMs: 500, writeMs: 4000, ioMs: 10000)],
        [timed(1400, 2100, readMs: 900, writeMs: 4600, ioMs: 11500)],
        2,
      )['nvme0n1']!;

      expect(r.readsPerSecond, 200);
      expect(r.writesPerSecond, 50);
      // 400 ms over 400 reads, 600 ms over 100 writes.
      expect(r.readAwaitMs, 1);
      expect(r.writeAwaitMs, 6);
      // 1.5 s of the 2 s interval with I/O in flight.
      expect(r.busyPercent, 75);
    });

    test('no completed reads leaves the read await unknown; busy never '
        'exceeds 100 %', () {
      final r = diskRates(
        [timed(10, 10, readMs: 5, writeMs: 5, ioMs: 0)],
        [timed(10, 20, readMs: 5, writeMs: 25, ioMs: 1020)],
        1,
      )['nvme0n1']!;

      expect(r.readAwaitMs, isNull);
      expect(r.writeAwaitMs, 2);
      expect(r.busyPercent, 100);
    });

    test('a four-counter row keeps throughput without latency or '
        'utilization', () {
      final r = diskRates(
        [_disk('sda', 100, 200)],
        [timed(0, 0, readMs: 1, writeMs: 1, ioMs: 1)],
        1,
      );
      // Different names: the four-counter row is another device.
      expect(r, isEmpty);

      final old = diskRates(
        [_disk('sda', 100, 200)],
        [_disk('sda', 300, 500)],
        1,
      )['sda']!;
      expect(old.readAwaitMs, isNull);
      expect(old.writeAwaitMs, isNull);
      expect(old.busyPercent, isNull);
      expect(old.toJson().containsKey('busyPercent'), isFalse);
    });
  });

  group('diffCoreSnapshots', () {
    test('a changed btime yields a reboot with no rates', () {
      final d = diffCoreSnapshots(
        _core(btime: 100, uptime: 10, netdev: [_net('eth0', 1, 1)]),
        _core(btime: 200, uptime: 20, netdev: [_net('eth0', 2, 2)]),
      );
      expect(d.rebooted, isTrue);
      expect(d.net, isEmpty);
      expect(d.disk, isEmpty);
    });

    test('a missing uptime yields no elapsed time', () {
      final d = diffCoreSnapshots(_core(btime: 100), _core(btime: 100));
      expect(d.elapsedSeconds, isNull);
      expect(d.net, isEmpty);
    });

    test('a zero uptime delta yields no rates', () {
      final d = diffCoreSnapshots(
        _core(btime: 100, uptime: 5),
        _core(btime: 100, uptime: 5),
      );
      expect(d.elapsedSeconds, 0);
      expect(d.net, isEmpty);
    });

    test('a normal pair yields cpu, net and disk rates', () {
      final d = diffCoreSnapshots(
        _core(
          btime: 100,
          uptime: 10,
          cpu: _cpu('cpu', [100, 0, 100, 800]),
          netdev: [_net('eth0', 1000, 2000)],
          diskstats: [_disk('sda', 100, 200)],
        ),
        _core(
          btime: 100,
          uptime: 12,
          cpu: _cpu('cpu', [200, 0, 200, 1600]),
          netdev: [_net('eth0', 3000, 6000)],
          diskstats: [_disk('sda', 300, 500)],
        ),
      );
      expect(d.rebooted, isFalse);
      expect(d.elapsedSeconds, 2);
      expect(d.cpu, isNotNull);
      expect(d.net['eth0']!.rxBytesPerSecond, 1000);
      expect(d.disk['sda']!.readBytesPerSecond, 200 * 512 / 2);
    });
  });

  group('procCpuPercent', () {
    ProcEntry proc(int pid, {int? utime, int? stime, int? start}) =>
        ProcEntry(pid: pid, utime: utime, stime: stime, startTicks: start);

    ProcsSnapshot snap(List<ProcEntry> ps) => ProcsSnapshot(processes: ps);

    test('the utime plus stime delta over the interval is a percentage', () {
      final r = procCpuPercent(
        snap([proc(100, utime: 10, stime: 10, start: 5)]),
        snap([proc(100, utime: 30, stime: 10, start: 5)]),
        2,
      );
      // 20 jiffies over 2 s at 100 Hz = 10 percent of one CPU.
      expect(r[100], 10);
    });

    test('a changed startTicks is a pid reuse and yields no entry', () {
      final r = procCpuPercent(
        snap([proc(100, utime: 10, stime: 10, start: 5)]),
        snap([proc(100, utime: 30, stime: 10, start: 99)]),
        2,
      );
      expect(r, isEmpty);
    });

    test(
      'a jiffy decrease, a missing pid or a zero interval yields nothing',
      () {
        expect(
          procCpuPercent(
            snap([proc(100, utime: 30, stime: 30)]),
            snap([proc(100, utime: 10, stime: 10)]),
            2,
          ),
          isEmpty,
        );
        expect(
          procCpuPercent(
            snap([proc(100, utime: 10, stime: 10)]),
            snap([proc(200, utime: 30, stime: 30)]),
            2,
          ),
          isEmpty,
        );
        expect(
          procCpuPercent(
            snap([proc(100, utime: 10, stime: 10)]),
            snap([proc(100, utime: 20, stime: 20)]),
            0,
          ),
          isEmpty,
        );
      },
    );
  });
}
