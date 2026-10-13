// Counter-to-rate maths tests (03 §6.4, CN-04): 32- and 64-bit wraps,
// reboots and counter resets, zero and negative intervals, and interfaces
// or devices missing from one side.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _u32 = CounterWidth.bits32;

CpuTimes _cpu(String name, List<int> j) => CpuTimes(name, j);

NetDevEntry _net(String name, int rxBytes, int txBytes) => NetDevEntry(
  name,
  [rxBytes, 0, 0, 0, 0, 0, 0, 0],
  [txBytes, 0, 0, 0, 0, 0, 0, 0],
);

DiskStatEntry _disk(String name, int sectorsRead, int sectorsWritten) =>
    DiskStatEntry(8, 0, name, [
      0,
      0,
      sectorsRead,
      0,
      0,
      0,
      sectorsWritten,
      0,
      0,
      0,
      0,
    ]);

CoreSnapshot _core({
  CpuTimes? cpu,
  Map<String, CpuTimes>? perCpu,
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

  group('perCpuDeltaPercent', () {
    test('cores missing from either side are skipped', () {
      final r = perCpuDeltaPercent(
        {
          'cpu0': _cpu('cpu0', [1, 2, 3, 4]),
        },
        {
          'cpu0': _cpu('cpu0', [2, 3, 4, 5]),
          'cpu1': _cpu('cpu1', [1, 2, 3, 4]),
        },
      );
      expect(r.keys, ['cpu0']);
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
}
