// TRI-02: what in a core reading slows the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/slowness.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// CPU shares in /proc/stat's field order: user, nice, system, idle,
/// iowait, irq, softirq, steal.
CpuPercentages _cpu({double iowait = 0, double steal = 0}) => CpuPercentages([
  10,
  0,
  5,
  85 - iowait - steal,
  iowait,
  0,
  0,
  steal,
], 15 + steal);

StallShares _some(double avg10) =>
    StallShares(some: StallAverages(avg10, avg10, avg10));

List<SlownessKind> _kinds(CoreResult core) => [
  for (final signal in slownessSignals(core)) signal.kind,
];

void main() {
  test('a calm reading has nothing to say', () {
    expect(
      slownessSignals(
        CoreResult(
          cpu: _cpu(),
          loadPerCore: 0.4,
          cpuPressure: _some(1),
          ioPressure: _some(0.5),
          memoryPressure: _some(0),
          disks: const {
            'sda': DiskRate(
              readBytesPerSecond: 0,
              writeBytesPerSecond: 0,
              readAwaitMs: 2,
              busyPercent: 10,
            ),
          },
        ),
      ),
      isEmpty,
    );
  });

  test('every signal at once, most telling first, with its value', () {
    final signals = slownessSignals(
      CoreResult(
        cpu: _cpu(steal: 12),
        cpuPressure: _some(35),
        ioPressure: _some(18),
        memoryPressure: _some(7),
        memory: const MemoryUsage(
          totalBytes: 1000,
          availableBytes: 50,
          swapTotalBytes: 400,
          swapUsedBytes: 300,
        ),
        disks: const {
          'sda': DiskRate(
            readBytesPerSecond: 0,
            writeBytesPerSecond: 0,
            readAwaitMs: 20,
            writeAwaitMs: 120,
            busyPercent: 70,
          ),
          'sdb': DiskRate(
            readBytesPerSecond: 0,
            writeBytesPerSecond: 0,
            readAwaitMs: 5,
            busyPercent: 97,
          ),
        },
      ),
    );
    expect(signals, [
      (kind: SlownessKind.cpuWait, value: 35.0, device: null),
      (kind: SlownessKind.steal, value: 12.0, device: null),
      (kind: SlownessKind.ioStall, value: 18.0, device: null),
      (kind: SlownessKind.slowDisk, value: 120.0, device: 'sda'),
      (kind: SlownessKind.busyDisk, value: 97.0, device: 'sdb'),
      (kind: SlownessKind.memoryStall, value: 7.0, device: null),
      (kind: SlownessKind.swapHeavy, value: 75.0, device: null),
    ]);
  });

  test('without PSI, load and iowait speak for the CPU and storage', () {
    expect(_kinds(CoreResult(cpu: _cpu(iowait: 25), loadPerCore: 2.5)), [
      SlownessKind.loadHigh,
      SlownessKind.iowait,
    ]);
    expect(
      _kinds(
        CoreResult(
          cpu: _cpu(iowait: 25),
          loadPerCore: 2.5,
          cpuPressure: _some(3),
          ioPressure: _some(2),
        ),
      ),
      isEmpty,
      reason: 'PSI, where the host has it, is the better measure',
    );
  });

  test('swap only counts while memory is short too', () {
    expect(
      _kinds(
        CoreResult(
          memory: const MemoryUsage(
            totalBytes: 1000,
            availableBytes: 400,
            swapTotalBytes: 400,
            swapUsedBytes: 390,
          ),
        ),
      ),
      isEmpty,
      reason: 'swap filled long ago, memory free now',
    );
    expect(
      _kinds(
        CoreResult(
          memory: const MemoryUsage(
            totalBytes: 1000,
            availableBytes: 10,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
          ),
        ),
      ),
      isEmpty,
      reason: 'no swap to fill',
    );
  });
}
